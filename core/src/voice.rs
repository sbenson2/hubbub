//! Who is in which voice channel, as one node shows it.
//!
//! Each node tells its direct peers its own state (`CtlMsg::VoiceState`). The host turns its
//! own state and every direct peer's into the roster and sends that to everyone
//! (`CtlMsg::VoiceRoster`), because in a star a leaf knows only the hub. A node shows the
//! host's last accepted roster with its own current state on top.
use std::collections::{BTreeMap, HashMap};

use crate::election::HostState;
use crate::ids::MemberId;
use crate::proto::VoicePresence;

/// One member's place in a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Slot {
    pub channel: String,
    pub muted: bool,
    pub deafened: bool,
}

impl Slot {
    fn presence(&self, member: MemberId) -> VoicePresence {
        VoicePresence { member, channel: self.channel.clone(), muted: self.muted, deafened: self.deafened }
    }
}

/// What `VoiceBook::refresh` wants done.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Refresh {
    /// A roster to send to every peer (this node hosts and the roster or term changed).
    pub broadcast: Option<(u64, Vec<VoicePresence>)>,
    /// The roster this node now shows, if it differs from what it showed before.
    pub shown: Option<Vec<VoicePresence>>,
}

#[derive(Default)]
pub struct VoiceBook {
    mine: Option<Slot>,
    /// Direct peers' own states.
    peers: HashMap<MemberId, Slot>,
    /// The newest roster each peer sent, with its term; used when that peer is the host.
    offered: HashMap<MemberId, (u64, Vec<VoicePresence>)>,
    /// The last roster accepted from a host; kept across a host change.
    accepted: Vec<VoicePresence>,
    shown: Vec<VoicePresence>,
    sent: Option<(u64, Vec<VoicePresence>)>,
}

fn normalized(entries: impl IntoIterator<Item = VoicePresence>) -> Vec<VoicePresence> {
    let by_member: BTreeMap<MemberId, VoicePresence> = entries.into_iter().map(|e| (e.member, e)).collect();
    let mut v: Vec<VoicePresence> = by_member.into_values().collect();
    v.sort_by(|a, b| (&a.channel, a.member).cmp(&(&b.channel, b.member)));
    v
}

impl VoiceBook {
    pub fn set_mine(&mut self, slot: Option<Slot>) {
        self.mine = slot;
    }

    pub fn mine(&self) -> Option<&Slot> {
        self.mine.as_ref()
    }

    pub fn set_peer(&mut self, peer: MemberId, slot: Option<Slot>) {
        match slot {
            Some(s) => self.peers.insert(peer, s),
            None => self.peers.remove(&peer),
        };
    }

    /// The peer's last session ended.
    pub fn peer_down(&mut self, peer: MemberId) {
        self.peers.remove(&peer);
        self.offered.remove(&peer);
    }

    /// A roster `peer` sent; `entries` must already hold only known voice channels.
    pub fn offer(&mut self, peer: MemberId, term: u64, entries: Vec<VoicePresence>) {
        self.offered.insert(peer, (term, entries));
    }

    pub fn shown(&self) -> &[VoicePresence] {
        &self.shown
    }

    /// Recomputes what this node shows (and, as host, what it sends) given who hosts now.
    pub fn refresh(&mut self, me: MemberId, host: HostState) -> Refresh {
        let mut out = Refresh::default();
        let hosting = host.host == Some(me);
        if hosting {
            let all = self.mine.iter().map(|s| s.presence(me)).chain(self.peers.iter().map(|(m, s)| s.presence(*m)));
            self.accepted = normalized(all);
            if self.sent.as_ref() != Some(&(host.term, self.accepted.clone())) {
                self.sent = Some((host.term, self.accepted.clone()));
                out.broadcast = Some((host.term, self.accepted.clone()));
            }
        } else {
            self.sent = None;
            if let Some(h) = host.host {
                if let Some((term, entries)) = self.offered.get(&h) {
                    if *term == host.term {
                        self.accepted = normalized(entries.iter().cloned());
                    }
                }
            }
        }
        let shown = normalized(
            self.accepted
                .iter()
                .filter(|e| e.member != me)
                .cloned()
                .chain(self.mine.iter().map(|s| s.presence(me))),
        );
        if shown != self.shown {
            self.shown = shown.clone();
            out.shown = Some(shown);
        }
        out
    }

    /// The roster to send a new session while this node hosts at `term`.
    pub fn roster_for_new_session(&self, me: MemberId, host: HostState) -> Option<(u64, Vec<VoicePresence>)> {
        (host.host == Some(me)).then(|| (host.term, self.accepted.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u8) -> MemberId {
        MemberId([n; 32])
    }
    fn slot(channel: &str) -> Slot {
        Slot { channel: channel.into(), muted: false, deafened: false }
    }
    fn hs(host: u8, term: u64) -> HostState {
        HostState { host: Some(id(host)), term }
    }

    #[test]
    fn host_lists_itself_and_direct_peers_and_broadcasts_changes_once() {
        let mut b = VoiceBook::default();
        b.set_mine(Some(slot("lobby")));
        b.set_peer(id(2), Some(slot("lobby")));
        let r = b.refresh(id(1), hs(1, 4));
        assert_eq!(r.shown.as_ref().unwrap().len(), 2);
        assert_eq!(r.broadcast.as_ref().unwrap().0, 4);
        assert_eq!(b.refresh(id(1), hs(1, 4)), Refresh::default());
        b.peer_down(id(2));
        let r = b.refresh(id(1), hs(1, 4));
        assert_eq!(r.shown.unwrap().len(), 1);
    }

    #[test]
    fn member_takes_the_roster_only_from_the_host_at_its_term() {
        let mut b = VoiceBook::default();
        let entry = VoicePresence { member: id(3), channel: "lobby".into(), muted: false, deafened: false };
        b.offer(id(2), 5, vec![entry.clone()]);
        assert_eq!(b.refresh(id(1), hs(2, 6)).shown, None, "wrong term");
        assert_eq!(b.refresh(id(1), hs(9, 5)).shown, None, "not the host");
        assert_eq!(b.refresh(id(1), hs(2, 5)).shown, Some(vec![entry.clone()]), "offer held until it matches");
        // The roster stays across a host change, and the member's own state is on top.
        b.set_mine(Some(slot("lobby")));
        let r = b.refresh(id(1), HostState { host: None, term: 5 });
        assert_eq!(r.shown.unwrap().len(), 2);
        assert!(r.broadcast.is_none());
    }
}
