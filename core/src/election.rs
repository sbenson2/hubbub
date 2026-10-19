//! Host election. The election state machine arrives in Task 3; this file
//! currently holds only `RankKey`, which the control protocol's `Announce` carries.
use std::cmp::Reverse;

use serde::{Deserialize, Serialize};

use crate::ids::MemberId;

/// Candidate ranking. A greater value is a better candidate; fields compare in order.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct RankKey {
    /// Peers observed a direct connection to this member (never self-reported).
    pub reachable: bool,
    /// `median_rtt_ms / 10` (10 ms buckets); lower is better.
    pub rtt: Reverse<u32>,
    /// `upload_mbps / 10` (10 Mbps buckets).
    pub upload: u32,
    /// `online_since_ms / 60_000` (1-minute buckets); earlier is better.
    pub age: Reverse<u64>,
    /// Final tie-break: the lower member id wins.
    pub id: Reverse<MemberId>,
}

/// How often a hosting node announces itself.
pub const HEARTBEAT_MS: u64 = 500;
/// A host whose heartbeats stay silent this long is replaced even while its connection is up
/// (its election loop is stuck). Silence alone never triggers sooner (R33): a dropped connection
/// is reported as `PeerDown`, and relay gaps of a few seconds are normal.
pub const HOST_SILENT_MS: u64 = 5_000;
/// A freshly started node never claims within this window, so it can hear an existing host.
pub const STARTUP_GRACE_MS: u64 = 1_500;

/// One live member as seen by the local node. Callers pass only live members, including themselves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub member: MemberId,
    pub can_host: bool,
    pub reachable: bool,
    pub median_rtt_ms: u32,
    pub upload_mbps: u32,
    pub online_since_ms: u64,
}

pub fn rank_key(c: &Candidate) -> RankKey {
    RankKey {
        reachable: c.reachable,
        rtt: Reverse(c.median_rtt_ms / 10),
        upload: c.upload_mbps / 10,
        age: Reverse(c.online_since_ms / 60_000),
        id: Reverse(c.member),
    }
}

/// The best host-capable candidate, if any.
pub fn best(view: &[Candidate]) -> Option<MemberId> {
    best_excluding(view, None)
}

fn best_excluding(view: &[Candidate], excluded: Option<MemberId>) -> Option<MemberId> {
    view.iter()
        .filter(|c| c.can_host && Some(c.member) != excluded)
        .max_by_key(|c| rank_key(c))
        .map(|c| c.member)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HostState {
    pub host: Option<MemberId>,
    pub term: u64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Input {
    Tick { now_ms: u64 },
    Heartbeat { from: MemberId, term: u64, key: RankKey, now_ms: u64 },
    Announce { from: MemberId, term: u64, key: RankKey, now_ms: u64 },
    Resign { from: MemberId, term: u64, now_ms: u64 },
    PeerDown { member: MemberId, now_ms: u64 },
    /// This node gives up hosting (e.g. its media server failed to start).
    SelfResign { now_ms: u64 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Action {
    StartHosting { term: u64 },
    StopHosting,
    SendHeartbeat { term: u64, key: RankKey },
    SendAnnounce { term: u64, key: RankKey },
    HostChanged(HostState),
}

/// Pure host-election state machine: no I/O, no clocks.
pub struct Election {
    me: MemberId,
    can_host: bool,
    started_ms: u64,
    state: HostState,
    max_seen_term: u64,
    /// When the current host was last heard from (or this node last claimed).
    last_host_seen_ms: u64,
    last_heartbeat_ms: u64,
    /// A host that just timed out or resigned; not a successor candidate until a new host is accepted.
    excluded: Option<MemberId>,
    /// A host that explicitly resigned; its same-term messages are not re-accepted.
    resigned: Option<MemberId>,
    /// The current host's key from its last heartbeat/announce (our own frozen claim key when hosting).
    host_key: Option<RankKey>,
}

impl Election {
    pub fn new(me: MemberId, can_host: bool, started_ms: u64) -> Self {
        Self {
            me,
            can_host,
            started_ms,
            state: HostState { host: None, term: 0 },
            max_seen_term: 0,
            last_host_seen_ms: started_ms,
            last_heartbeat_ms: started_ms,
            excluded: None,
            resigned: None,
            host_key: None,
        }
    }

    pub fn state(&self) -> &HostState {
        &self.state
    }

    pub fn set_can_host(&mut self, can_host: bool) {
        self.can_host = can_host;
    }

    fn hosting(&self) -> bool {
        self.state.host == Some(self.me)
    }

    fn my_key(&self, view: &[Candidate]) -> RankKey {
        let c = view
            .iter()
            .find(|c| c.member == self.me)
            .copied()
            // Not in the view (caller error): rank as the weakest possible candidate.
            .unwrap_or(Candidate {
                member: self.me,
                can_host: self.can_host,
                reachable: false,
                median_rtt_ms: u32::MAX,
                upload_mbps: 0,
                online_since_ms: u64::MAX,
            });
        rank_key(&c)
    }

    pub fn step(&mut self, input: Input, view: &[Candidate]) -> Vec<Action> {
        let mut out = Vec::new();
        match input {
            Input::Tick { now_ms } => self.on_tick(now_ms, view, &mut out),
            Input::Heartbeat { from, term, key, now_ms } | Input::Announce { from, term, key, now_ms } => {
                self.max_seen_term = self.max_seen_term.max(term);
                self.on_host_msg(from, term, key, now_ms, &mut out);
            }
            Input::Resign { from, term, now_ms } => {
                self.max_seen_term = self.max_seen_term.max(term);
                if from != self.me && self.state.host == Some(from) && term == self.state.term {
                    self.host_gone(true, now_ms, view, &mut out);
                }
            }
            Input::PeerDown { member, now_ms } => {
                if member != self.me && self.state.host == Some(member) {
                    self.host_gone(false, now_ms, view, &mut out);
                }
            }
            Input::SelfResign { .. } => {
                if self.hosting() {
                    self.state.host = None;
                    self.host_key = None;
                    out.push(Action::StopHosting);
                    out.push(Action::HostChanged(self.state));
                }
            }
        }
        out
    }

    /// Shared handling for Heartbeat and Announce.
    fn on_host_msg(&mut self, from: MemberId, term: u64, key: RankKey, now_ms: u64, out: &mut Vec<Action>) {
        if from == self.me || term < self.state.term {
            return;
        }
        if term > self.state.term {
            self.accept(from, term, key, now_ms, out);
            return;
        }
        if self.resigned == Some(from) {
            return;
        }
        match self.state.host {
            None => self.accept(from, term, key, now_ms, out),
            Some(h) if h == from => {
                self.last_host_seen_ms = now_ms;
                self.host_key = Some(key);
            }
            Some(_) => {
                // Two hosts at the same term: the higher key wins.
                if self.host_key.is_none_or(|hk| key > hk) {
                    self.accept(from, term, key, now_ms, out);
                } else if self.hosting() {
                    // We win the tie; tell the loser so it steps down.
                    if let Some(mine) = self.host_key {
                        out.push(Action::SendAnnounce { term, key: mine });
                    }
                }
            }
        }
    }

    fn on_tick(&mut self, now_ms: u64, view: &[Candidate], out: &mut Vec<Action>) {
        match self.state.host {
            Some(h) if h == self.me => {
                if now_ms.saturating_sub(self.last_heartbeat_ms) >= HEARTBEAT_MS {
                    self.last_heartbeat_ms = now_ms;
                    if let Some(key) = self.host_key {
                        out.push(Action::SendHeartbeat { term: self.state.term, key });
                    }
                }
            }
            Some(_) => {
                if now_ms.saturating_sub(self.last_host_seen_ms) > HOST_SILENT_MS {
                    self.host_gone(false, now_ms, view, out);
                }
            }
            None => {
                self.try_claim(now_ms, view, out);
            }
        }
    }

    /// Accept `from` as host at `term`, stepping down if this node was hosting.
    fn accept(&mut self, from: MemberId, term: u64, key: RankKey, now_ms: u64, out: &mut Vec<Action>) {
        if self.hosting() {
            out.push(Action::StopHosting);
        }
        self.state = HostState { host: Some(from), term };
        self.host_key = Some(key);
        self.last_host_seen_ms = now_ms;
        self.excluded = None;
        self.resigned = None;
        out.push(Action::HostChanged(self.state));
    }

    /// The host is gone: clear it, then claim if this node is the best remaining candidate.
    /// `resigned` marks an explicit Resign; PeerDown and timeouts are only local observations and stay re-acceptable.
    fn host_gone(&mut self, resigned: bool, now_ms: u64, view: &[Candidate], out: &mut Vec<Action>) {
        self.excluded = self.state.host;
        self.resigned = if resigned { self.state.host } else { None };
        self.state.host = None;
        self.host_key = None;
        if !self.try_claim(now_ms, view, out) {
            out.push(Action::HostChanged(self.state));
        }
    }

    /// Claims the host role if allowed and best. Returns whether it claimed.
    fn try_claim(&mut self, now_ms: u64, view: &[Candidate], out: &mut Vec<Action>) -> bool {
        if !self.can_host || now_ms.saturating_sub(self.started_ms) < STARTUP_GRACE_MS {
            return false;
        }
        if best_excluding(view, self.excluded) != Some(self.me) {
            return false;
        }
        let term = self.max_seen_term + 1;
        let key = self.my_key(view);
        self.max_seen_term = term;
        self.state = HostState { host: Some(self.me), term };
        self.host_key = Some(key);
        self.last_host_seen_ms = now_ms;
        self.last_heartbeat_ms = now_ms;
        self.excluded = None;
        self.resigned = None;
        out.push(Action::StartHosting { term });
        out.push(Action::SendAnnounce { term, key });
        out.push(Action::HostChanged(self.state));
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(n: u8) -> MemberId {
        MemberId([n; 32])
    }
    fn cand(id: u8, reachable: bool, rtt: u32, up: u32, since: u64) -> Candidate {
        Candidate {
            member: m(id),
            can_host: true,
            reachable,
            median_rtt_ms: rtt,
            upload_mbps: up,
            online_since_ms: since,
        }
    }
    fn cand_phone(id: u8) -> Candidate {
        Candidate { can_host: false, ..cand(id, true, 0, 0, 0) }
    }
    /// A weak key for heartbeats whose key does not matter.
    fn dk() -> RankKey {
        rank_key(&cand(99, false, 1000, 0, 0))
    }
    fn starts(a: &[Action]) -> Vec<u64> {
        a.iter()
            .filter_map(|x| match x {
                Action::StartHosting { term } => Some(*term),
                _ => None,
            })
            .collect()
    }
    /// Election for `me` that is hosting at `term` (learned of an old host at term-1, then it resigned).
    fn hosting_at(me: u8, term: u64, view: &[Candidate]) -> Election {
        // Claim while seeing only itself, so it wins regardless of how it ranks in `view`.
        let own: Vec<Candidate> = view.iter().filter(|c| c.member == m(me)).copied().collect();
        let mut e = Election::new(m(me), true, 0);
        e.step(Input::Heartbeat { from: m(99), term: term - 1, key: dk(), now_ms: 2_000 }, &own);
        let a = e.step(Input::Resign { from: m(99), term: term - 1, now_ms: 2_100 }, &own);
        assert!(a.contains(&Action::StartHosting { term }));
        e
    }

    #[test]
    fn rank_orders_reachable_then_rtt_then_upload_then_uptime_then_id() {
        let v = [cand(1, false, 5, 900, 0), cand(2, true, 80, 10, 0), cand(3, true, 20, 10, 0), cand(4, true, 20, 50, 0)];
        assert_eq!(best(&v), Some(m(4)));
    }
    #[test]
    fn rtt_bucket_10ms_prevents_flap() {
        assert_eq!(rank_key(&cand(1, true, 21, 10, 0)).rtt, rank_key(&cand(1, true, 29, 10, 0)).rtt);
    }
    #[test]
    fn single_desktop_claims_after_grace() {
        let mut e = Election::new(m(1), true, 0);
        let v = [cand(1, true, 0, 0, 0)];
        assert!(e.step(Input::Tick { now_ms: 1_000 }, &v).is_empty());
        let a = e.step(Input::Tick { now_ms: 1_600 }, &v);
        assert!(a.contains(&Action::StartHosting { term: 1 }));
        assert!(a.contains(&Action::HostChanged(HostState { host: Some(m(1)), term: 1 })));
    }
    #[test]
    fn phone_never_claims() {
        let mut e = Election::new(m(1), false, 0);
        assert!(!e.step(Input::Tick { now_ms: 10_000 }, &[cand_phone(1)]).iter().any(|a| matches!(a, Action::StartHosting { .. })));
    }
    #[test]
    fn better_newcomer_does_not_preempt() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 100, 10, 0)];
        let mut e = Election::new(m(1), true, 0);
        let mut t = 2_000;
        while t <= 7_000 {
            e.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: t }, &v);
            let a = e.step(Input::Tick { now_ms: t }, &v);
            assert!(starts(&a).is_empty(), "preempted at {t}");
            t += 500;
        }
        assert_eq!(e.state().host, Some(m(2)));
    }
    #[test]
    fn heartbeat_silence_under_5s_never_replaces_a_live_host() {
        // R33: a host whose connection is up (no PeerDown) is not replaced by a short heartbeat gap.
        let v = [cand(1, true, 20, 10, 0), cand(2, true, 0, 100, 0)];
        let mut e = Election::new(m(1), true, 0);
        e.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: 0 }, &v);
        let mut t = 100;
        while t <= 4_900 {
            assert!(e.step(Input::Tick { now_ms: t }, &v).is_empty(), "acted at {t} ms");
            t += 100;
        }
        assert_eq!(e.state(), &HostState { host: Some(m(2)), term: 3 });
    }
    #[test]
    fn host_silent_5s_triggers_reelection_by_best() {
        // m2 is the best in view but is the silent old host, so it must be excluded.
        let v = [cand(1, true, 20, 10, 0), cand(2, true, 0, 100, 0)];
        let mut e = Election::new(m(1), true, 0);
        e.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: 0 }, &v);
        assert!(starts(&e.step(Input::Tick { now_ms: 4_900 }, &v)).is_empty());
        let a = e.step(Input::Tick { now_ms: 5_100 }, &v);
        assert_eq!(starts(&a), vec![4]);
    }
    #[test]
    fn graceful_resign_reelects_immediately() {
        let v = [cand(1, true, 20, 10, 0), cand(2, true, 0, 100, 0)];
        let mut e = Election::new(m(1), true, 0);
        e.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: 2_000 }, &v);
        let a = e.step(Input::Resign { from: m(2), term: 3, now_ms: 2_100 }, &v);
        assert_eq!(starts(&a), vec![4]);
    }
    #[test]
    fn peer_down_of_host_reelects_and_non_best_only_clears() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 20, 10, 0), cand(3, true, 40, 10, 0)];
        let mut e3 = Election::new(m(3), true, 0);
        e3.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: 2_000 }, &v);
        let a = e3.step(Input::PeerDown { member: m(2), now_ms: 2_100 }, &v);
        assert!(starts(&a).is_empty());
        assert_eq!(a, vec![Action::HostChanged(HostState { host: None, term: 3 })]);
        let mut e1 = Election::new(m(1), true, 0);
        e1.step(Input::Heartbeat { from: m(2), term: 3, key: dk(), now_ms: 2_000 }, &v);
        assert_eq!(starts(&e1.step(Input::PeerDown { member: m(2), now_ms: 2_100 }, &v)), vec![4]);
    }
    #[test]
    fn split_brain_same_term_higher_key_wins() {
        let v = [cand(1, true, 50, 10, 0), cand(2, true, 0, 100, 0)];
        let mut e = hosting_at(1, 4, &v);
        let a = e.step(Input::Announce { from: m(2), term: 4, key: rank_key(&v[1]), now_ms: 3_000 }, &v);
        assert_eq!(a, vec![Action::StopHosting, Action::HostChanged(HostState { host: Some(m(2)), term: 4 })]);
        assert_eq!(e.state().host, Some(m(2)));
    }
    #[test]
    fn same_term_lower_key_keeps_hosting() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 50, 10, 0)];
        let mut e = hosting_at(1, 4, &v);
        let a = e.step(Input::Announce { from: m(2), term: 4, key: rank_key(&v[1]), now_ms: 3_000 }, &v);
        assert!(!a.contains(&Action::StopHosting));
        assert_eq!(e.state().host, Some(m(1)));
    }
    #[test]
    fn higher_term_announce_wins() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 80, 10, 0)];
        let mut e = hosting_at(1, 4, &v);
        let a = e.step(Input::Announce { from: m(2), term: 5, key: rank_key(&v[1]), now_ms: 3_000 }, &v);
        assert_eq!(a, vec![Action::StopHosting, Action::HostChanged(HostState { host: Some(m(2)), term: 5 })]);
    }
    #[test]
    fn partition_heal_two_hosts_converge() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 50, 10, 0)];
        // Each side of the partition only saw itself (and the old host m99).
        let mut e1 = hosting_at(1, 4, &v[..1]);
        let mut e2 = hosting_at(2, 4, &v[1..]);
        let (k1, k2) = (rank_key(&v[0]), rank_key(&v[1]));
        e1.step(Input::Announce { from: m(2), term: 4, key: k2, now_ms: 5_000 }, &v);
        e2.step(Input::Announce { from: m(1), term: 4, key: k1, now_ms: 5_000 }, &v);
        let hosts = [e1.state().host == Some(m(1)), e2.state().host == Some(m(2))];
        assert_eq!(hosts.iter().filter(|h| **h).count(), 1);
        assert_eq!(e1.state(), e2.state());
        assert_eq!(e1.state().host, Some(m(1)));
    }
    #[test]
    fn stale_host_after_sleep_steps_down() {
        let v = [cand(1, true, 0, 100, 0), cand(3, true, 20, 10, 0)];
        let mut e = hosting_at(1, 2, &v);
        let a = e.step(Input::Heartbeat { from: m(3), term: 3, key: dk(), now_ms: 62_000 }, &v);
        assert_eq!(a, vec![Action::StopHosting, Action::HostChanged(HostState { host: Some(m(3)), term: 3 })]);
    }
    #[test]
    fn hosting_node_heartbeats_every_500ms_and_never_times_itself_out() {
        let v = [cand(1, true, 0, 0, 0)];
        let mut e = hosting_at(1, 2, &v); // claimed at 2_100
        assert!(e.step(Input::Tick { now_ms: 2_400 }, &v).is_empty());
        assert_eq!(e.step(Input::Tick { now_ms: 2_600 }, &v), vec![Action::SendHeartbeat { term: 2, key: rank_key(&v[0]) }]);
        assert!(e.step(Input::Tick { now_ms: 2_900 }, &v).is_empty());
        assert_eq!(e.step(Input::Tick { now_ms: 60_000 }, &v), vec![Action::SendHeartbeat { term: 2, key: rank_key(&v[0]) }]);
        assert_eq!(e.state().host, Some(m(1)));
    }

    fn hb(from: u8, term: u64, key: RankKey, now_ms: u64) -> Input {
        Input::Heartbeat { from: m(from), term, key, now_ms }
    }

    #[test]
    fn follower_switches_to_higher_key_same_term_host() {
        let v = [cand(4, true, 0, 100, 0), cand(1, true, 10, 50, 0), cand(3, true, 40, 10, 0)];
        let mut f3 = Election::new(m(3), true, 0);
        f3.step(hb(9, 3, dk(), 2_000), &v);
        f3.step(Input::Announce { from: m(1), term: 4, key: rank_key(&v[1]), now_ms: 2_100 }, &v);
        assert_eq!(f3.state().host, Some(m(1)));
        f3.step(Input::Announce { from: m(4), term: 4, key: rank_key(&v[0]), now_ms: 2_110 }, &v);
        assert_eq!(f3.state(), &HostState { host: Some(m(4)), term: 4 });
        // A lower-key same-term sender does not switch it back.
        f3.step(hb(1, 4, rank_key(&v[1]), 2_200), &v);
        assert_eq!(f3.state().host, Some(m(4)));
    }
    #[test]
    fn non_successor_follower_reaccepts_live_host_after_gap() {
        let v = [cand(2, true, 0, 100, 0), cand(1, true, 10, 50, 0), cand(3, true, 40, 10, 0)];
        let mut f3 = Election::new(m(3), true, 0);
        f3.step(hb(2, 3, rank_key(&v[0]), 2_000), &v);
        f3.step(Input::Tick { now_ms: 7_100 }, &v); // gap: host cleared
        assert_eq!(f3.state().host, None);
        let mut t = 7_200;
        while t <= 12_000 {
            let a = f3.step(hb(2, 3, rank_key(&v[0]), t), &v);
            assert!(starts(&f3.step(Input::Tick { now_ms: t }, &v)).is_empty() && starts(&a).is_empty());
            t += 500;
        }
        assert_eq!(f3.state(), &HostState { host: Some(m(2)), term: 3 });
    }
    #[test]
    fn same_term_hosts_converge_on_heartbeats_only() {
        let v = [cand(1, true, 0, 100, 0), cand(2, true, 50, 10, 0)];
        let mut e1 = hosting_at(1, 4, &v[..1]);
        let mut e2 = hosting_at(2, 4, &v[1..]);
        let (k1, k2) = (rank_key(&v[0]), rank_key(&v[1]));
        e1.step(hb(2, 4, k2, 5_000), &v);
        let a = e2.step(hb(1, 4, k1, 5_000), &v);
        assert_eq!(a, vec![Action::StopHosting, Action::HostChanged(HostState { host: Some(m(1)), term: 4 })]);
        assert_eq!(e1.state(), e2.state());
        assert_eq!(e1.state().host, Some(m(1)));
    }
    #[test]
    fn stale_resign_is_ignored() {
        let v = [cand(1, true, 20, 10, 0), cand(2, true, 0, 100, 0)];
        let mut e = Election::new(m(1), true, 0);
        e.step(hb(2, 3, rank_key(&v[1]), 2_000), &v);
        assert!(e.step(Input::Resign { from: m(2), term: 2, now_ms: 2_100 }, &v).is_empty());
        assert_eq!(e.state(), &HostState { host: Some(m(2)), term: 3 });
        // A resigned host's same-term heartbeats are not re-accepted.
        e.step(Input::Resign { from: m(2), term: 3, now_ms: 2_200 }, &v);
        assert_eq!(e.state().host, Some(m(1)));
    }
    #[test]
    fn peer_down_host_is_reaccepted_at_same_term() {
        let v = [cand(2, true, 0, 100, 0), cand(1, true, 10, 50, 0), cand(3, true, 40, 10, 0)];
        let mut f3 = Election::new(m(3), true, 0);
        f3.step(hb(2, 3, rank_key(&v[0]), 2_000), &v);
        f3.step(Input::PeerDown { member: m(2), now_ms: 2_100 }, &v);
        assert_eq!(f3.state().host, None);
        let a = f3.step(hb(2, 3, rank_key(&v[0]), 2_200), &v);
        assert!(starts(&a).is_empty());
        assert_eq!(f3.state(), &HostState { host: Some(m(2)), term: 3 });
    }
    #[test]
    fn resigned_host_not_reaccepted_at_same_term() {
        let v = [cand(2, true, 0, 100, 0), cand(1, true, 10, 50, 0), cand(3, true, 40, 10, 0)];
        let mut f3 = Election::new(m(3), true, 0);
        f3.step(hb(2, 3, rank_key(&v[0]), 2_000), &v);
        f3.step(Input::Resign { from: m(2), term: 3, now_ms: 2_100 }, &v);
        let a = f3.step(hb(2, 3, rank_key(&v[0]), 2_200), &v);
        assert!(a.is_empty());
        assert_eq!(f3.state().host, None);
    }
    #[test]
    fn self_resign_steps_down_and_does_not_reclaim() {
        let v = [cand(1, true, 0, 100, 0)];
        let mut e = hosting_at(1, 2, &v);
        e.set_can_host(false);
        let a = e.step(Input::SelfResign { now_ms: 3_000 }, &v);
        assert_eq!(a, vec![Action::StopHosting, Action::HostChanged(HostState { host: None, term: 2 })]);
        assert!(e.step(Input::Tick { now_ms: 10_000 }, &v).is_empty());
        e.set_can_host(true);
        assert_eq!(starts(&e.step(Input::Tick { now_ms: 70_000 }, &v)), vec![3]);
    }
}
