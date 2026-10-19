//! Text channels, the spike subset: channel names, end-to-end encryption of each message,
//! the host's relay that orders messages per channel, the local store, and the queue of
//! messages this node sent that it has not yet seen delivered.
//!
//! A member seals a message and submits it to the host. The host's `Relay` gives it the next
//! sequence number of its term on that channel and delivers it to every member, the sender
//! included. The relay holds no key: it only ever handles ciphertext. Members open each
//! delivery, store it, and show it.
//!
//! A message is named by `(from, client_id)`, its `MessageKey`, and each member stores and
//! shows it once, in the order it arrived. `(term, seq)` is not an id: a message resent
//! after a hand-over gets a new one, and terms start again at 1 when every node restarts.
//! A message can even carry two of them: ordered by a host that then lost a split, it keeps
//! that `(term, seq)` on the nodes that already had it, and the winner's on the rest. Two
//! different messages can then share one on a node. Only `(from, client_id)` is identity.
//!
//! Catching up: a node tells each peer what it holds (`CtlMsg::TextHave`), and a host
//! sends back only what that node lacks and that was ordered since the node first ran this
//! community. Nothing from before a member was added is ever sent (no history, as in Signal).
//! The "since" bound is best-effort until MLS (spec §4.2): the device claims it, and every
//! member holds the text key, so a modified client can ask for more; it is the device clock
//! against the host's clock, so skew moves it either way; and a copied data dir carries it.
//! The hub resets it on every join (`mark_joined`).
//! A node resubmits what it sent lately, delivered or not, whenever the host or term changes,
//! so a message ordered by a host that lost a split still reaches the host that won.
//!
//! Spike-only: the key is derived from the community secret instead of MLS.
use std::collections::{HashMap, VecDeque};
use std::fs::{self, OpenOptions};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, ensure, Context, Result};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use serde::{Deserialize, Serialize};

use crate::community::CommunityState;
use crate::ids::MemberId;
use crate::proto::{CtlMsg, HaveChannel};

/// Longest message body, in characters.
pub const MAX_BODY_CHARS: usize = 4000;
/// Largest ciphertext the host relays, in bytes.
pub const MAX_CIPHERTEXT: usize = 16 * 1024;
/// Longest channel name, in characters.
pub const MAX_CHANNEL_NAME: usize = 32;
/// The random nonce in front of every ciphertext.
const NONCE_LEN: usize = 12;
/// How many of each channel's latest messages a node remembers, to know a second delivery of
/// one. Every member keeps the keys, read back from the store at start. The host keeps
/// this term's deliveries, to send one again: at most this many `MAX_CIPHERTEXT`s a channel.
pub const DEDUP_WINDOW: usize = 512;

/// What names a message for good: its sender and the client id the sender gave it.
pub type MessageKey = (MemberId, u64);

/// A community's channels. `CommunityState::channels` gives these defaults when the file has
/// none, and a file that lists only one kind gets the default for the other.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Channels {
    pub text: Vec<String>,
    pub voice: Vec<String>,
}

impl Default for Channels {
    fn default() -> Self {
        Channels { text: vec!["general".into()], voice: vec!["lobby".into()] }
    }
}

/// Whether `name` may name a text channel: 1 to 32 of `[a-z0-9-]`, so it is safe in a path.
pub fn valid_channel_name(name: &str) -> bool {
    (1..=MAX_CHANNEL_NAME).contains(&name.len())
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

pub(crate) fn check_channel_name(name: &str) -> Result<()> {
    ensure!(valid_channel_name(name), "invalid channel name {name:?}: use 1 to {MAX_CHANNEL_NAME} of a-z, 0-9 and -");
    Ok(())
}

/// One delivered message, as stored and shown. `(from, client_id)` names it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TextMessage {
    pub term: u64,
    pub seq: u64,
    pub from: MemberId,
    /// What `send_text` returned to the sender. 0 only on a line stored before the store
    /// kept client ids; no sender uses 0.
    #[serde(default)]
    pub client_id: u64,
    pub sent_ms: u64,
    pub body: String,
}

/// How many of its newest messages a node lists per channel in `TextHave`, at most.
const HAVE_PER_CHANNEL: usize = 64;
/// All channels together list at most this many ids, so the frame stays small.
const HAVE_TOTAL: usize = 256;
/// `TextHave` lists at most this many channels, so a community with many cannot overflow a frame.
const HAVE_CHANNELS: usize = 128;
/// A node resubmits delivered messages younger than this when the host changes: a split
/// hand-over, not an old one. At most `RESEND_KEEP` of them.
const RESEND_WINDOW: Duration = Duration::from_secs(30);
const RESEND_KEEP: usize = 32;

/// Whether a message delivered by `by` goes to the route's host and term too. Only when the
/// host changed within one term: that is a tie broken between two self-elected hosts, so the
/// message may never have reached the winner. A hand-over starts a new term; the old host's
/// messages were heard by every member that mattered, and sending them again would only burn
/// seqs.
fn resend_after_swap(by: (MemberId, u64), route: (MemberId, u64)) -> bool {
    by.1 == route.1 && by.0 != route.0
}

/// The keys of each channel's last `DEDUP_WINDOW` messages, each with a value.
pub(crate) struct Recent<V> {
    values: HashMap<MessageKey, V>,
    /// Per channel, oldest first.
    order: HashMap<String, VecDeque<MessageKey>>,
}

impl<V> Default for Recent<V> {
    fn default() -> Self {
        Recent { values: HashMap::new(), order: HashMap::new() }
    }
}

impl<V> Recent<V> {
    pub fn get(&self, key: &MessageKey) -> Option<&V> {
        self.values.get(key)
    }

    /// Remembers `key` as `channel`'s newest message, forgetting the channel's oldest beyond
    /// the window. False, and nothing changes, when `key` is already remembered.
    pub fn insert(&mut self, channel: &str, key: MessageKey, value: V) -> bool {
        if self.values.contains_key(&key) {
            return false;
        }
        let order = self.order.entry(channel.to_string()).or_default();
        order.push_back(key);
        if order.len() > DEDUP_WINDOW {
            if let Some(oldest) = order.pop_front() {
                self.values.remove(&oldest);
            }
        }
        self.values.insert(key, value);
        true
    }

    /// The remembered values: channels by name, each channel's oldest first.
    pub fn in_order(&self) -> Vec<&V> {
        let mut channels: Vec<&String> = self.order.keys().collect();
        channels.sort();
        channels.into_iter().flat_map(|c| &self.order[c]).filter_map(|k| self.values.get(k)).collect()
    }

    /// `channel`'s newest `n` keys with their values, oldest first.
    pub fn tail(&self, channel: &str, n: usize) -> Vec<(MessageKey, &V)> {
        let Some(order) = self.order.get(channel) else { return Vec::new() };
        let skip = order.len().saturating_sub(n);
        order.iter().skip(skip).filter_map(|k| Some((*k, self.values.get(k)?))).collect()
    }
}

/// A message on its way to the host: what `TextSubmit` carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Submission {
    pub channel: String,
    pub client_id: u64,
    pub ciphertext: Vec<u8>,
}

/// A message the host ordered: what `TextDeliver` carries.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Delivery {
    pub channel: String,
    pub term: u64,
    pub seq: u64,
    /// The member whose connection submitted it, as the host authenticated it.
    pub from: MemberId,
    pub client_id: u64,
    /// The host's wall clock when it ordered the message, in ms since the Unix epoch.
    pub sent_ms: u64,
    pub ciphertext: Vec<u8>,
}

impl Submission {
    pub fn to_msg(&self) -> CtlMsg {
        CtlMsg::TextSubmit { channel: self.channel.clone(), client_id: self.client_id, ciphertext: self.ciphertext.clone() }
    }
}

impl Delivery {
    pub fn to_msg(&self) -> CtlMsg {
        CtlMsg::TextDeliver {
            channel: self.channel.clone(),
            term: self.term,
            seq: self.seq,
            from: self.from,
            client_id: self.client_id,
            sent_ms: self.sent_ms,
            ciphertext: self.ciphertext.clone(),
        }
    }
}

/// What a ciphertext holds once opened.
#[derive(Serialize, Deserialize)]
struct Plaintext {
    body: String,
}

/// The associated data: the channel (length first), the sender and the client id.
fn aad(channel: &str, from: &MemberId, client_id: u64) -> Vec<u8> {
    let mut a = Vec::with_capacity(4 + channel.len() + 32 + 8);
    a.extend_from_slice(&(channel.len() as u32).to_be_bytes());
    a.extend_from_slice(channel.as_bytes());
    a.extend_from_slice(&from.0);
    a.extend_from_slice(&client_id.to_be_bytes());
    a
}

/// Encrypts `body` with ChaCha20-Poly1305: a random nonce, then the ciphertext and tag. The
/// associated data binds the channel, the sender and the client id.
pub fn seal(key: &[u8; 32], channel: &str, from: &MemberId, client_id: u64, body: &str) -> Vec<u8> {
    let plaintext = serde_json::to_vec(&Plaintext { body: body.to_string() }).expect("a string always encodes");
    let mut nonce = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce).expect("system randomness unavailable");
    let payload = Payload { msg: &plaintext, aad: &aad(channel, from, client_id) };
    let sealed = ChaCha20Poly1305::new(&Key::from(*key))
        .encrypt(&Nonce::from(nonce), payload)
        .expect("ChaCha20-Poly1305 takes any message this small");
    [nonce.as_slice(), &sealed].concat()
}

/// Decrypts what `seal` made. Fails when anything was changed, including the channel, the
/// sender or the client id it was sealed for.
pub fn open(key: &[u8; 32], channel: &str, from: &MemberId, client_id: u64, ciphertext: &[u8]) -> Result<String> {
    let (nonce, sealed) = ciphertext.split_at_checked(NONCE_LEN).context("ciphertext shorter than its nonce")?;
    let nonce: [u8; NONCE_LEN] = nonce.try_into().expect("split at NONCE_LEN");
    let payload = Payload { msg: sealed, aad: &aad(channel, from, client_id) };
    let plaintext = ChaCha20Poly1305::new(&Key::from(*key))
        .decrypt(&Nonce::from(nonce), payload)
        .map_err(|_| anyhow!("the message does not open: another key, sender, channel or client id, or changed"))?;
    let p: Plaintext = serde_json::from_slice(&plaintext).context("decoding an opened message")?;
    Ok(p.body)
}

/// The host's ordering for one term: per channel, sequence numbers from 1.
pub struct Sequencer {
    term: u64,
    /// The next seq of each text channel; other channels are unknown.
    next: HashMap<String, u64>,
    /// The deliveries of this term, by `(from, client_id)`: the last `DEDUP_WINDOW` per channel.
    ordered: Recent<Delivery>,
}

impl Sequencer {
    pub fn new(term: u64, channels: &[String]) -> Self {
        Sequencer { term, next: channels.iter().map(|c| (c.clone(), 1)).collect(), ordered: Recent::default() }
    }

    /// Orders one message from `from`. A `(from, client_id)` already ordered this term gets
    /// its original delivery back, as `Again`, and takes no seq. None when it is dropped: an
    /// unknown channel or a ciphertext over `MAX_CIPHERTEXT`.
    pub fn submit(&mut self, from: MemberId, s: Submission, sent_ms: u64) -> Option<Ordered> {
        if s.ciphertext.len() > MAX_CIPHERTEXT {
            return None;
        }
        if let Some(original) = self.ordered.get(&(from, s.client_id)) {
            return Some(Ordered::Again(original.clone()));
        }
        let next = self.next.get_mut(&s.channel)?;
        let seq = *next;
        *next += 1;
        let d = Delivery {
            channel: s.channel,
            term: self.term,
            seq,
            from,
            client_id: s.client_id,
            sent_ms,
            ciphertext: s.ciphertext,
        };
        self.ordered.insert(&d.channel, (from, d.client_id), d.clone());
        Some(Ordered::New(d))
    }

    /// The deliveries of this term that a node lacks, channels by name and each in seq order.
    /// It is owed those ordered at or after `since_ms` and after the `floor_ms` of its list for
    /// the channel, other than the ones it lists.
    pub fn missing(&self, since_ms: u64, have: &[HaveChannel]) -> Vec<Delivery> {
        self.ordered
            .in_order()
            .into_iter()
            .filter(|d| {
                let h = have.iter().find(|h| h.channel == d.channel);
                let floor = h.map_or(0, |h| h.floor_ms);
                d.sent_ms >= since_ms.max(floor) && !h.is_some_and(|h| h.ids.contains(&(d.from, d.client_id)))
            })
            .cloned()
            .collect()
    }
}

/// What the host's sequencer made of a submission.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ordered {
    /// A new message: it goes to every member.
    New(Delivery),
    /// A message already ordered this term, sent again because its sender missed the
    /// delivery: the original, which goes back to the sender only.
    Again(Delivery),
}

/// Delivered messages on disk: one JSON line per message in `<data_dir>/text/<channel>.jsonl`.
pub struct Store {
    dir: PathBuf,
    /// Held through each append, so lines never interleave.
    writing: Mutex<()>,
}

impl Store {
    pub fn new(data_dir: &Path) -> Self {
        Store { dir: data_dir.join("text"), writing: Mutex::new(()) }
    }

    fn file(&self, channel: &str) -> Result<PathBuf> {
        check_channel_name(channel)?;
        Ok(self.dir.join(format!("{channel}.jsonl")))
    }

    pub fn append(&self, channel: &str, m: &TextMessage) -> Result<()> {
        let path = self.file(channel)?;
        let mut line = serde_json::to_vec(m)?;
        line.push(b'\n');
        let _writing = self.writing.lock().unwrap();
        fs::create_dir_all(&self.dir).with_context(|| format!("creating {}", self.dir.display()))?;
        OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .and_then(|mut f| f.write_all(&line))
            .with_context(|| format!("appending to {}", path.display()))
    }

    /// The last `limit` messages of `channel`, in arrival order. A line that does not parse, such
    /// as one cut short by a crash, is skipped.
    pub fn load(&self, channel: &str, limit: usize) -> Result<Vec<TextMessage>> {
        let path = self.file(channel)?;
        let text = match fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        let mut all: Vec<TextMessage> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
        Ok(all.split_off(all.len().saturating_sub(limit)))
    }
}

/// Where pending messages were last submitted. A new route (another host or term, or a new
/// session to the host) gets every pending message again; the host drops those it has.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Route {
    /// This node, hosting at `term`.
    Local { term: u64 },
    /// `host`'s control session `session`, at `term`.
    Remote { host: MemberId, term: u64, session: u64 },
}

impl Route {
    fn host_term(&self, me: MemberId) -> (MemberId, u64) {
        match *self {
            Route::Local { term } => (me, term),
            Route::Remote { host, term, .. } => (host, term),
        }
    }
}

/// A delivery this node opened and stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Received {
    pub channel: String,
    pub message: TextMessage,
}

/// A message this node sent and has not yet seen delivered.
struct Pending {
    submission: Submission,
    sent_on: Option<Route>,
    /// The `(host, term)` that last delivered it to this node, and when. Delivered messages
    /// stay for `RESEND_WINDOW` after that, to go again if another host takes over the same term.
    delivered_by: Option<(MemberId, u64)>,
    delivered_at: Option<Instant>,
}

/// A member's side of text: sealing, the pending queue, opening deliveries, and the store.
pub(crate) struct Chat {
    me: MemberId,
    key: [u8; 32],
    channels: Channels,
    store: Store,
    /// Oldest first. In memory only.
    pending: Mutex<Vec<Pending>>,
    /// Held through each flush, so messages reach the host in the order they were sent.
    flushing: Mutex<()>,
    /// The messages this node stored lately, read back from the store at start. Held from
    /// the check through the store and the show, so both keep the order messages arrived in.
    /// Each value is when the host ordered the message.
    received: Mutex<Recent<u64>>,
    /// When this device first ran this community, in ms since the Unix epoch.
    since_ms: u64,
    /// Tests: the session bringing this node's next own delivery ends before reading it.
    #[cfg(feature = "test-util")]
    lose_own_delivery: std::sync::atomic::AtomicBool,
}

impl Chat {
    pub fn new(me: MemberId, community: &CommunityState, data_dir: &Path) -> Self {
        let (channels, store) = (community.channels(), Store::new(data_dir));
        let mut received = Recent::default();
        for channel in &channels.text {
            match store.load(channel, DEDUP_WINDOW) {
                // A line stored without a client id names no message.
                Ok(stored) => stored.iter().filter(|m| m.client_id != 0).for_each(|m| {
                    received.insert(channel, (m.from, m.client_id), m.sent_ms);
                }),
                Err(e) => eprintln!("hubbub node: stored #{channel} messages not read: {e:#}"),
            }
        }
        Chat {
            me,
            key: community.text_key(),
            channels,
            store,
            pending: Mutex::new(Vec::new()),
            flushing: Mutex::new(()),
            received: Mutex::new(received),
            since_ms: first_run_ms(data_dir),
            #[cfg(feature = "test-util")]
            lose_own_delivery: Default::default(),
        }
    }

    /// Tests: the session that brings this node's next own delivery ends before reading it.
    #[cfg(feature = "test-util")]
    pub fn lose_next_own_delivery(&self) {
        self.lose_own_delivery.store(true, std::sync::atomic::Ordering::Relaxed);
    }

    /// Tests: whether a delivery from `from` is the one to lose. True once per `lose_next_own_delivery`.
    #[cfg(feature = "test-util")]
    pub fn loses_delivery_from(&self, from: &MemberId) -> bool {
        *from == self.me && self.lose_own_delivery.swap(false, std::sync::atomic::Ordering::Relaxed)
    }

    pub fn channels(&self) -> &Channels {
        &self.channels
    }

    /// Seals a new message and queues it until this node sees it delivered. Returns its client id.
    pub fn compose(&self, channel: &str, body: &str) -> Result<u64> {
        ensure!(self.channels.text.iter().any(|c| c == channel), "there is no text channel #{channel}");
        ensure!(!body.trim().is_empty(), "the message is empty");
        let chars = body.chars().count();
        ensure!(chars <= MAX_BODY_CHARS, "the message has {chars} characters; the limit is {MAX_BODY_CHARS}");
        let client_id = new_client_id();
        let ciphertext = seal(&self.key, channel, &self.me, client_id, body);
        ensure!(ciphertext.len() <= MAX_CIPHERTEXT, "the message is too large to send");
        let submission = Submission { channel: channel.to_string(), client_id, ciphertext };
        self.pending.lock().unwrap().push(Pending {
            submission,
            sent_on: None,
            delivered_by: None,
            delivered_at: None,
        });
        Ok(client_id)
    }

    /// Hands `send` each pending message not yet submitted on `route`, oldest first.
    pub fn flush(&self, route: Route, mut send: impl FnMut(Submission)) {
        let _in_order = self.flushing.lock().unwrap();
        let unsent: Vec<Submission> = {
            let mut pending = self.pending.lock().unwrap();
            Self::forget_old(&mut pending);
            let host_term = route.host_term(self.me);
            pending
                .iter_mut()
                .filter(|p| p.sent_on != Some(route) && p.delivered_by.is_none_or(|by| resend_after_swap(by, host_term)))
                .map(|p| {
                    p.sent_on = Some(route);
                    p.submission.clone()
                })
                .collect()
        };
        unsent.into_iter().for_each(&mut send);
    }

    /// Opens a delivery, stores it, drops it from the queue if this node sent it, and hands it
    /// to `show`, which runs under the lock that keeps arrival order. Nothing happens when it
    /// does not open (an unknown channel, or a sender or channel it was not sealed for), when
    /// its client id is 0, or when this node already has its `(from, client_id)`.
    pub fn receive(&self, d: &Delivery, host: MemberId, show: impl FnOnce(Received)) {
        if d.client_id == 0 || !self.channels.text.contains(&d.channel) {
            return;
        }
        let Ok(body) = open(&self.key, &d.channel, &d.from, d.client_id, &d.ciphertext) else { return };
        // Delivered, even if this node already had it (a second host sent it again).
        if d.from == self.me {
            let mut pending = self.pending.lock().unwrap();
            if let Some(p) = pending.iter_mut().find(|p| p.submission.client_id == d.client_id) {
                p.delivered_by = Some((host, d.term));
                p.delivered_at = Some(Instant::now());
            }
            Self::forget_old(&mut pending);
        }
        let mut received = self.received.lock().unwrap();
        if !received.insert(&d.channel, (d.from, d.client_id), d.sent_ms) {
            return;
        }
        let message =
            TextMessage { term: d.term, seq: d.seq, from: d.from, client_id: d.client_id, sent_ms: d.sent_ms, body };
        if let Err(e) = self.store.append(&d.channel, &message) {
            eprintln!("hubbub node: text message not stored: {e:#}");
        }
        show(Received { channel: d.channel.clone(), message });
    }

    /// Drops delivered messages too old to resubmit, and all but the newest `RESEND_KEEP`.
    fn forget_old(pending: &mut Vec<Pending>) {
        pending.retain(|p| p.delivered_at.is_none_or(|at| at.elapsed() < RESEND_WINDOW));
        let delivered = pending.iter().filter(|p| p.delivered_by.is_some()).count();
        let mut excess = delivered.saturating_sub(RESEND_KEEP);
        pending.retain(|p| {
            let drop = excess > 0 && p.delivered_by.is_some();
            excess -= usize::from(drop);
            !drop
        });
    }

    /// What this node tells a peer it holds, and since when it has been a member here.
    pub fn have(&self) -> (u64, Vec<HaveChannel>) {
        let received = self.received.lock().unwrap();
        let listed = &self.channels.text[..self.channels.text.len().min(HAVE_CHANNELS)];
        let each = (HAVE_TOTAL / listed.len().max(1)).clamp(1, HAVE_PER_CHANNEL);
        let have = listed
            .iter()
            .map(|c| {
                let tail = received.tail(c, each);
                // By the host's clock, not arrival: an older message may arrive late.
                let floor_ms = if tail.len() == each { tail.iter().map(|(_, ms)| **ms).min().unwrap_or(0) } else { 0 };
                HaveChannel { channel: c.clone(), floor_ms, ids: tail.into_iter().map(|(k, _)| k).collect() }
            })
            .collect();
        (self.since_ms, have)
    }

    pub fn history(&self, channel: &str, limit: usize) -> Result<Vec<TextMessage>> {
        self.store.load(channel, limit)
    }
}

/// When this device first ran this community: read from `<data_dir>/first_run_ms`, written
/// now if absent. The community state keeps no admission time, and a node starts its
/// community right after it joins. A node that cannot write the file counts from now.
fn first_run_ms(data_dir: &Path) -> u64 {
    let file = data_dir.join("first_run_ms");
    if let Some(ms) = fs::read_to_string(&file).ok().and_then(|s| s.trim().parse().ok()) {
        return ms;
    }
    mark_joined(data_dir)
}

/// Starts this device's membership of a community now: nothing ordered before this moment is
/// caught up on. The hub calls it on every join, so a device that was removed and invited
/// again does not get the messages sent while it was out. Returns the time.
pub fn mark_joined(data_dir: &Path) -> u64 {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
    let _ = fs::write(data_dir.join("first_run_ms"), now.to_string());
    now
}

/// A random client id. Never 0, which marks a line stored before the store kept client ids.
fn new_client_id() -> u64 {
    loop {
        let id = getrandom::u64().expect("system randomness unavailable");
        if id != 0 {
            return id;
        }
    }
}

/// The host's side of text. It holds no key: it orders and passes on ciphertext only.
pub(crate) struct Relay {
    channels: Vec<String>,
    sequencer: Mutex<Option<Sequencer>>,
}

impl Relay {
    pub fn new(channels: &Channels) -> Self {
        Relay { channels: channels.text.clone(), sequencer: Mutex::new(None) }
    }

    /// This node starts hosting at `term`.
    pub fn start(&self, term: u64) {
        *self.sequencer.lock().unwrap() = Some(Sequencer::new(term, &self.channels));
    }

    pub fn stop(&self) {
        *self.sequencer.lock().unwrap() = None;
    }

    /// While hosting, calls `send` with the deliveries a node lacks (see `Sequencer::missing`).
    /// It runs under the relay's lock, like `relay`'s `deliver`: what is sent here goes out
    /// before any later delivery. Without a live sequencer it still runs, with none.
    pub fn catch_up(&self, since_ms: u64, have: &[HaveChannel], send: impl FnOnce(Vec<Delivery>)) {
        let sequencer = self.sequencer.lock().unwrap();
        send(sequencer.as_ref().map(|q| q.missing(since_ms, have)).unwrap_or_default());
    }

    /// While hosting, orders `s` from `from` and calls `deliver` with the result, a new
    /// delivery or a sent-again one. `deliver` runs under the relay's lock, so deliveries go
    /// out in sequence order.
    pub fn relay(&self, from: MemberId, s: Submission, deliver: impl FnOnce(Ordered)) {
        let mut sequencer = self.sequencer.lock().unwrap();
        let now_ms = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64);
        if let Some(o) = sequencer.as_mut().and_then(|q| q.submit(from, s, now_ms)) {
            deliver(o);
        }
    }
}

#[cfg(test)]
mod tests {
    fn test_state() -> CommunityState {
        CommunityState::create("t", &crate::identity::Identity::from_secret_bytes([7; 32]), true)
    }

    use serde_json::json;

    use super::*;

    const KEY: [u8; 32] = [7; 32];

    fn id(b: u8) -> MemberId {
        MemberId([b; 32])
    }

    fn channels() -> Vec<String> {
        vec!["general".into(), "games".into()]
    }

    fn submission(channel: &str, client_id: u64) -> Submission {
        Submission { channel: channel.into(), client_id, ciphertext: vec![1, 2, 3] }
    }

    /// The delivery of a submission the sequencer ordered as new.
    fn new(ordered: Option<Ordered>) -> Delivery {
        match ordered {
            Some(Ordered::New(d)) => d,
            other => panic!("expected a new delivery, got {other:?}"),
        }
    }

    fn message(seq: u64) -> TextMessage {
        TextMessage { term: 2, seq, from: id(1), client_id: 100 + seq, sent_ms: 1_000 + seq, body: format!("m{seq}") }
    }

    #[test]
    fn sealed_message_opens_to_its_body() {
        let ct = seal(&KEY, "general", &id(1), 42, "hello \"there\" ✓");
        assert_eq!(open(&KEY, "general", &id(1), 42, &ct).unwrap(), "hello \"there\" ✓");
        assert_ne!(seal(&KEY, "general", &id(1), 42, "hello \"there\" ✓"), ct, "each seal has a fresh nonce");
        assert!(!ct.windows(5).any(|w| w == b"hello"), "the body is not in the clear");
    }

    #[test]
    fn tampered_or_truncated_ciphertext_fails_to_open() {
        let ct = seal(&KEY, "general", &id(1), 42, "hi");
        for i in [0, NONCE_LEN, ct.len() - 1] {
            let mut bad = ct.clone();
            bad[i] ^= 1;
            assert!(open(&KEY, "general", &id(1), 42, &bad).is_err(), "byte {i} flipped");
        }
        assert!(open(&KEY, "general", &id(1), 42, &ct[..NONCE_LEN]).is_err());
        assert!(open(&KEY, "general", &id(1), 42, &[]).is_err());
        assert!(open(&[8; 32], "general", &id(1), 42, &ct).is_err(), "another key");
    }

    #[test]
    fn mismatched_sender_channel_or_client_id_fails_to_open() {
        let ct = seal(&KEY, "general", &id(1), 42, "hi");
        assert!(open(&KEY, "general", &id(2), 42, &ct).is_err(), "another sender");
        assert!(open(&KEY, "games", &id(1), 42, &ct).is_err(), "another channel");
        assert!(open(&KEY, "general", &id(1), 43, &ct).is_err(), "another client id");
    }

    #[test]
    fn sequencer_numbers_each_channel_from_1_and_knows_duplicates() {
        let mut s = Sequencer::new(5, &channels());
        let g1 = new(s.submit(id(1), submission("general", 10), 100));
        let g2 = new(s.submit(id(2), submission("general", 10), 101));
        let games1 = new(s.submit(id(1), submission("games", 11), 102));
        let g3 = new(s.submit(id(1), submission("general", 12), 103));
        assert_eq!([g1.seq, g2.seq, g3.seq, games1.seq], [1, 2, 3, 1]);
        assert!([&g1, &g2, &g3, &games1].iter().all(|d| d.term == 5));
        assert_eq!((g1.from, g2.from), (id(1), id(2)), "another sender's client id 10 is not a duplicate");
        let again = Some(Ordered::Again(g1.clone()));
        assert_eq!(s.submit(id(1), submission("general", 10), 104), again, "(from, client_id) seen this term");
        assert_eq!(s.submit(id(1), submission("games", 10), 104), again, "on any channel");
        assert_eq!(new(s.submit(id(1), submission("general", 13), 105)).seq, 4, "a duplicate takes no seq");
    }

    #[test]
    fn sequencer_answers_a_duplicate_with_the_original_delivery() {
        let mut s = Sequencer::new(5, &channels());
        let original = new(s.submit(id(1), submission("general", 10), 100));
        new(s.submit(id(2), submission("general", 11), 101));
        // The sender's retry on a new session, later: same (term, seq), time and bytes.
        let again = s.submit(id(1), submission("general", 10), 999);
        assert_eq!(again, Some(Ordered::Again(original.clone())));
        assert_eq!(new(s.submit(id(1), submission("general", 12), 1_000)).seq, 3, "the retry took no seq");
    }

    #[test]
    fn sequencer_drops_unknown_channels_and_oversized_ciphertext() {
        let mut s = Sequencer::new(1, &channels());
        assert!(s.submit(id(1), submission("random", 1), 0).is_none());
        let big = Submission { channel: "general".into(), client_id: 2, ciphertext: vec![0; MAX_CIPHERTEXT + 1] };
        assert!(s.submit(id(1), big, 0).is_none());
        let max = Submission { channel: "general".into(), client_id: 3, ciphertext: vec![0; MAX_CIPHERTEXT] };
        assert_eq!(new(s.submit(id(1), max, 0)).seq, 1, "dropped messages take no seq");
    }

    #[test]
    fn sequencer_passes_ciphertext_through_untouched() {
        // Not ciphertext at all: the sequencer has no key and never looks inside.
        let mut s = Sequencer::new(3, &channels());
        let opaque = Submission { channel: "general".into(), client_id: 9, ciphertext: b"opaque".to_vec() };
        let d = new(s.submit(id(4), opaque, 77));
        let want = Delivery {
            channel: "general".into(),
            term: 3,
            seq: 1,
            from: id(4),
            client_id: 9,
            sent_ms: 77,
            ciphertext: b"opaque".to_vec(),
        };
        assert_eq!(d, want);
    }

    #[test]
    fn store_appends_and_loads_the_last_messages_in_order() {
        let d = tempfile::tempdir().unwrap();
        let store = Store::new(d.path());
        assert!(store.load("general", 10).unwrap().is_empty(), "no file yet");
        let msgs: Vec<TextMessage> = (1..=5).map(message).collect();
        for m in &msgs {
            store.append("general", m).unwrap();
        }
        assert_eq!(store.load("general", 10).unwrap(), msgs);
        assert_eq!(store.load("general", 2).unwrap(), msgs[3..]);
        assert!(store.load("general", 0).unwrap().is_empty());
        assert!(store.load("games", 10).unwrap().is_empty(), "each channel has its own file");

        let reopened = Store::new(d.path());
        reopened.append("general", &message(6)).unwrap();
        assert_eq!(reopened.load("general", 1).unwrap(), [message(6)]);

        let file = std::fs::read_to_string(d.path().join("text").join("general.jsonl")).unwrap();
        assert_eq!(file.lines().count(), 6);
        let first: serde_json::Value = serde_json::from_str(file.lines().next().unwrap()).unwrap();
        let want =
            json!({"term": 2, "seq": 1, "from": id(1).to_string(), "client_id": 101, "sent_ms": 1001, "body": "m1"});
        assert_eq!(first, want);
    }

    #[test]
    fn invalid_channel_names_are_rejected() {
        let longest = "a".repeat(MAX_CHANNEL_NAME);
        for ok in ["general", "a", "off-topic", "2nd", longest.as_str()] {
            assert!(valid_channel_name(ok), "{ok:?}");
        }
        let too_long = "a".repeat(MAX_CHANNEL_NAME + 1);
        for bad in ["", "General", "..", "../etc", "a/b", "a\\b", "a b", "a.b", "é", too_long.as_str()] {
            assert!(!valid_channel_name(bad), "{bad:?}");
        }
        let d = tempfile::tempdir().unwrap();
        let store = Store::new(d.path());
        assert!(store.load("../general", 1).is_err());
        assert!(store.append("../general", &message(1)).is_err());
        assert!(!d.path().join("general.jsonl").exists());

        let p = d.path().join("c.json");
        let mut c = test_state();
        c.channels = Channels { text: vec!["../oops".into()], voice: vec![] };
        c.save_atomic(&p).unwrap();
        assert!(CommunityState::load(&p).is_err(), "a community file naming a bad text channel");
    }

    #[test]
    fn community_channels_default_when_the_field_is_absent() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("c.json");
        let fresh = test_state();
        assert_eq!(fresh.channels(), Channels { text: vec!["general".into()], voice: vec!["lobby".into()] });
        // A state file without the field gets the defaults.
        let mut v = serde_json::to_value(&fresh).unwrap();
        v.as_object_mut().unwrap().remove("channels");
        std::fs::write(&p, v.to_string()).unwrap();
        assert_eq!(CommunityState::load(&p).unwrap().channels(), fresh.channels());

        v["channels"] = serde_json::json!({"text": ["general", "games"], "voice": ["lobby", "afk"]});
        std::fs::write(&p, v.to_string()).unwrap();
        let c = CommunityState::load(&p).unwrap();
        assert_eq!(c.channels().text, ["general", "games"]);
        assert_eq!(c.channels().voice, ["lobby", "afk"]);

        v["channels"] = serde_json::json!({"text": ["games"]});
        std::fs::write(&p, v.to_string()).unwrap();
        assert_eq!(CommunityState::load(&p).unwrap().channels().voice, ["lobby"]);
    }

    #[test]
    fn text_key_is_derived_and_separate_from_the_media_key() {
        let c = test_state();
        assert_eq!(c.text_key(), c.clone().text_key());
        assert_ne!(c.text_key(), c.e2ee_key());
        assert_ne!(c.text_key(), test_state().text_key());
    }

    #[test]
    fn compose_rejects_unknown_channels_and_empty_or_long_bodies() {
        let d = tempfile::tempdir().unwrap();
        let chat = Chat::new(id(1), &test_state(), d.path());
        assert!(chat.compose("random", "hi").is_err(), "not a channel of this community");
        assert!(chat.compose("../general", "hi").is_err());
        assert!(chat.compose("general", "").is_err());
        assert!(chat.compose("general", " \n").is_err(), "only whitespace");
        assert!(chat.compose("general", &"é".repeat(MAX_BODY_CHARS + 1)).is_err());
        let a = chat.compose("general", &"é".repeat(MAX_BODY_CHARS)).unwrap();
        let b = chat.compose("general", "hi").unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn pending_messages_go_once_per_route_until_seen_delivered() {
        let d = tempfile::tempdir().unwrap();
        let community = test_state();
        let chat = Chat::new(id(1), &community, d.path());
        let a = chat.compose("general", "one").unwrap();
        let b = chat.compose("general", "two").unwrap();
        let flush = |route| {
            let mut out = Vec::new();
            chat.flush(route, |s| out.push(s));
            out
        };
        let first = flush(Route::Remote { host: id(7), term: 4, session: 1 });
        assert_eq!(first.iter().map(|s| s.client_id).collect::<Vec<_>>(), [a, b]);
        assert!(flush(Route::Remote { host: id(7), term: 4, session: 1 }).is_empty(), "already submitted on this route");
        assert_eq!(flush(Route::Remote { host: id(7), term: 4, session: 2 }).len(), 2, "a new session to the host");
        assert_eq!(flush(Route::Remote { host: id(7), term: 5, session: 2 }).len(), 2, "the same session at a new term");

        let mut seq = Sequencer::new(4, &community.channels().text);
        let delivered = new(seq.submit(id(1), first[0].clone(), 500));
        let got = receive(&chat, &delivered).unwrap();
        let want = TextMessage { term: 4, seq: 1, from: id(1), client_id: a, sent_ms: 500, body: "one".into() };
        assert_eq!(got.message, want);
        let same_host = flush(Route::Remote { host: id(7), term: 4, session: 3 });
        assert_eq!(same_host.iter().map(|s| s.client_id).collect::<Vec<_>>(), [b], "delivered by this host and term");
        let left = flush(Route::Local { term: 6 });
        assert_eq!(left.iter().map(|s| s.client_id).collect::<Vec<_>>(), [b], "a new term: delivered ones leave the queue");
        let swapped = flush(Route::Remote { host: id(8), term: 4, session: 9 });
        assert_eq!(swapped.iter().map(|s| s.client_id).collect::<Vec<_>>(), [a, b], "another host, same term: a tie was broken");
        assert_eq!(chat.history("general", 10).unwrap(), [got.message]);
    }

    #[test]
    fn missing_is_what_a_node_lacks_and_was_ordered_since_it_began() {
        let mut seq = Sequencer::new(3, &channels());
        let mut ordered = Vec::new();
        for (i, ms) in [100u64, 200, 300, 400].into_iter().enumerate() {
            ordered.push(new(seq.submit(id(2), submission("general", i as u64 + 1), ms)));
        }
        let have = |floor_ms, ids: &[u64]| {
            vec![HaveChannel { channel: "general".into(), floor_ms, ids: ids.iter().map(|&c| (id(2), c)).collect() }]
        };
        let ids = |ds: Vec<Delivery>| ds.iter().map(|d| d.client_id).collect::<Vec<_>>();
        assert_eq!(ids(seq.missing(0, &[])), [1, 2, 3, 4], "a node with nothing, from the start");
        assert_eq!(ids(seq.missing(250, &[])), [3, 4], "nothing ordered before the node began");
        assert_eq!(ids(seq.missing(0, &have(0, &[1, 2]))), [3, 4], "a node that came back");
        assert_eq!(ids(seq.missing(0, &have(0, &[1, 2, 3, 4]))), Vec::<u64>::new(), "up to date");
        assert_eq!(ids(seq.missing(0, &have(0, &[2, 4]))), [1, 3], "by id, not by position");
        assert_eq!(ids(seq.missing(0, &have(300, &[]))), [3, 4], "the floor of a full list");
    }

    #[test]
    fn have_lists_the_newest_stored_messages_of_each_channel() {
        let d = tempfile::tempdir().unwrap();
        let community = test_state();
        let chat = Chat::new(id(1), &community, d.path());
        let key = community.text_key();
        let each = (HAVE_TOTAL / community.channels().text.len().max(1)).clamp(1, HAVE_PER_CHANNEL);
        for n in 1..=(each + 5) as u64 {
            let mut dl = delivery(&key, id(2), n, "x");
            dl.sent_ms = n * 10;
            receive(&chat, &dl).unwrap();
        }
        let (since, have) = chat.have();
        let general = have.iter().find(|h| h.channel == "general").unwrap();
        assert_eq!(general.ids.len(), each);
        assert_eq!(general.ids.last().unwrap().1, (each + 5) as u64, "the newest last");
        assert_eq!(general.floor_ms, general.ids[0].1 * 10, "a full list has a floor");
        assert_eq!(Chat::new(id(1), &community, d.path()).have().0, since, "the first run time is kept");
    }

    #[test]
    fn text_have_fits_a_frame_however_many_channels_there_are() {
        let d = tempfile::tempdir().unwrap();
        let mut community = test_state();
        community.channels.text = (0..1000).map(|i| format!("{i:0>width$}", width = MAX_CHANNEL_NAME)).collect();
        let chat = Chat::new(id(1), &community, d.path());
        let key = community.text_key();
        for (k, c) in community.channels.text.iter().take(HAVE_CHANNELS).enumerate() {
            for n in (1..=3u64).map(|n| n + 10 * k as u64) {
                let mut dl = delivery(&key, id(2), n, "x");
                dl.channel = c.clone();
                dl.ciphertext = seal(&key, c, &id(2), n, "x");
                dl.sent_ms = n;
                receive(&chat, &dl).unwrap();
            }
        }
        let (since_ms, have) = chat.have();
        assert_eq!(have.len(), HAVE_CHANNELS);
        let body = serde_json::to_vec(&CtlMsg::TextHave { since_ms, have }).unwrap();
        assert!(body.len() < crate::proto::MAX_FRAME / 2, "{} bytes", body.len());
    }

    #[test]
    fn mark_joined_restarts_the_since_bound() {
        let d = tempfile::tempdir().unwrap();
        let first = Chat::new(id(1), &test_state(), d.path()).have().0;
        std::thread::sleep(Duration::from_millis(5));
        assert_eq!(Chat::new(id(1), &test_state(), d.path()).have().0, first, "kept across restarts");
        let again = mark_joined(d.path());
        assert!(again > first);
        assert_eq!(Chat::new(id(1), &test_state(), d.path()).have().0, again, "reset by a join");
    }

    #[test]
    fn receive_drops_deliveries_that_do_not_open() {
        let d = tempfile::tempdir().unwrap();
        let community = test_state();
        let chat = Chat::new(id(1), &community, d.path());
        let key = community.text_key();
        let honest = Delivery {
            channel: "general".into(),
            term: 1,
            seq: 1,
            from: id(2),
            client_id: 7,
            sent_ms: 0,
            ciphertext: seal(&key, "general", &id(2), 7, "from two"),
        };
        assert_eq!(receive(&chat, &honest).unwrap().message.body, "from two");
        let forged = Delivery { from: id(3), seq: 2, ..honest.clone() };
        assert!(receive(&chat, &forged).is_none(), "`from` does not match the sealed sender");
        let unknown = Delivery { channel: "random".into(), seq: 3, ..honest.clone() };
        assert!(receive(&chat, &unknown).is_none());
        assert_eq!(chat.history("general", 10).unwrap().len(), 1, "only the honest delivery is stored");
    }

    /// What `chat` shows for `d`, if anything.
    fn receive(chat: &Chat, d: &Delivery) -> Option<Received> {
        let mut shown = None;
        chat.receive(d, id(7), |r| shown = Some(r));
        shown
    }

    fn delivery(key: &[u8; 32], from: MemberId, client_id: u64, body: &str) -> Delivery {
        Delivery {
            channel: "general".into(),
            term: 1,
            seq: 1,
            from,
            client_id,
            sent_ms: 0,
            ciphertext: seal(key, "general", &from, client_id, body),
        }
    }

    #[test]
    fn a_second_delivery_of_a_message_is_neither_stored_nor_shown_even_after_a_reload() {
        let d = tempfile::tempdir().unwrap();
        let community = test_state();
        let key = community.text_key();
        let chat = Chat::new(id(1), &community, d.path());
        let first = delivery(&key, id(2), 7, "once");
        assert!(receive(&chat, &first).is_some());
        // The same message from the next host, after a hand-over: another (term, seq).
        let next_host = Delivery { term: 2, seq: 4, ..first.clone() };
        assert!(receive(&chat, &next_host).is_none(), "(from, client_id) names the message");
        assert!(receive(&chat, &first).is_none(), "the very same delivery");
        let other = Delivery { seq: 2, ..delivery(&key, id(3), 7, "another sender's 7") };
        assert!(receive(&chat, &other).is_some(), "another sender's client id 7 is another message");
        assert_eq!(chat.history("general", 10).unwrap().len(), 2);

        drop(chat);
        let reloaded = Chat::new(id(1), &community, d.path());
        assert!(receive(&reloaded, &next_host).is_none(), "remembered across a restart");
        assert!(receive(&reloaded, &other).is_none());
        let stored = reloaded.history("general", 10).unwrap();
        let stored: Vec<MessageKey> = stored.iter().map(|m| (m.from, m.client_id)).collect();
        assert_eq!(stored, [(id(2), 7), (id(3), 7)], "history keeps each message's key");
    }

    #[test]
    fn lines_stored_without_a_client_id_load_and_name_no_message() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(d.path().join("text")).unwrap();
        let legacy = json!({"term": 1, "seq": 1, "from": id(2).to_string(), "sent_ms": 5, "body": "old"});
        std::fs::write(d.path().join("text").join("general.jsonl"), format!("{legacy}\n")).unwrap();
        let community = test_state();
        let key = community.text_key();
        let chat = Chat::new(id(1), &community, d.path());
        let stored = chat.history("general", 10).unwrap();
        assert_eq!((stored[0].client_id, stored[0].body.as_str()), (0, "old"));

        // The same sender at the same (term, seq) after a full restart: a new message.
        assert!(receive(&chat, &delivery(&key, id(2), 9, "new")).is_some());
        assert!(receive(&chat, &delivery(&key, id(2), 0, "zero")).is_none(), "no sender uses client id 0");
        let ids: Vec<u64> = chat.history("general", 10).unwrap().iter().map(|m| m.client_id).collect();
        assert_eq!(ids, [0, 9]);
    }

    #[test]
    fn recent_remembers_the_last_window_of_each_channel() {
        let mut r = Recent::default();
        for n in 1..=DEDUP_WINDOW as u64 {
            assert!(r.insert("general", (id(1), n), n));
        }
        assert!(!r.insert("general", (id(1), 1), 0), "a key it remembers");
        assert_eq!(r.get(&(id(1), 1)), Some(&1), "and its value is kept");
        assert!(r.insert("games", (id(2), 1), 0), "another channel has its own window");
        assert!(r.get(&(id(1), 1)).is_some(), "so it pushes nothing out of #general");

        assert!(r.insert("general", (id(1), DEDUP_WINDOW as u64 + 1), 0));
        assert!(r.get(&(id(1), 1)).is_none(), "the oldest of #general is forgotten");
        assert!(r.get(&(id(1), 2)).is_some());
        assert!(r.get(&(id(2), 1)).is_some());
        assert_eq!(r.values.len(), DEDUP_WINDOW + 1, "the window bounds what it holds");
    }
}
