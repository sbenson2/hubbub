//! The election's view of each candidate, built only from what other members measured.
use std::collections::HashMap;

use crate::election::Candidate;
use crate::ids::MemberId;
use crate::proto::PeerReport;

/// Lower median: for an even count, the lower of the two middle values.
pub fn median(xs: &[u32]) -> Option<u32> {
    if xs.is_empty() {
        return None;
    }
    let mut v = xs.to_vec();
    v.sort_unstable();
    Some(v[(v.len() - 1) / 2])
}

/// One `Candidate` per `online` entry, in order. Everything measured about X comes from the
/// other members' reports; what X says about itself is dropped. `me` does not affect the result.
pub fn build_view(
    me: &MemberId,
    online: &[(MemberId, bool, u64)],
    reports: &HashMap<MemberId, Vec<PeerReport>>,
) -> Vec<Candidate> {
    let _ = me;
    online
        .iter()
        .map(|&(member, can_host, online_since_ms)| {
            let about: Vec<&PeerReport> = reports
                .iter()
                .filter(|(reporter, _)| **reporter != member)
                .flat_map(|(_, rs)| rs.iter().filter(|r| r.member == member))
                .collect();
            let rtts: Vec<u32> = about.iter().map(|r| r.rtt_ms).collect();
            let ups: Vec<u32> = about.iter().filter_map(|r| r.upload_mbps).collect();
            let direct = about.iter().filter(|r| r.direct).count();
            Candidate {
                member,
                can_host,
                reachable: 2 * direct > about.len(),
                median_rtt_ms: median(&rtts).unwrap_or(0),
                upload_mbps: median(&ups).unwrap_or(0),
                online_since_ms,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(n: u8) -> MemberId {
        MemberId([n; 32])
    }
    fn online3() -> Vec<(MemberId, bool, u64)> {
        vec![(m(1), true, 100), (m(2), true, 200), (m(3), false, 300)]
    }
    fn rep(member: MemberId, rtt_ms: u32, direct: bool, upload_mbps: Option<u32>) -> PeerReport {
        PeerReport { member, rtt_ms, direct, upload_mbps }
    }

    #[test]
    fn median_lower_for_even() {
        assert_eq!(median(&[40, 10, 30, 20]), Some(20));
        assert_eq!(median(&[]), None);
    }

    #[test]
    fn reachable_requires_peer_reports_not_self_report() {
        let mut reports = HashMap::new();
        reports.insert(m(1), vec![rep(m(1), 1, true, Some(900))]);
        reports.insert(m(2), vec![rep(m(1), 50, false, None)]);
        reports.insert(m(3), vec![rep(m(1), 60, false, None)]);
        let v = build_view(&m(9), &online3(), &reports);
        let x = v.iter().find(|c| c.member == m(1)).unwrap();
        assert!(!x.reachable);
        assert_eq!(x.median_rtt_ms, 50);
        assert_eq!(x.upload_mbps, 0);
    }

    #[test]
    fn rtt_and_upload_are_medians_of_others() {
        let mut reports = HashMap::new();
        reports.insert(m(2), vec![rep(m(1), 10, true, Some(20))]);
        reports.insert(m(3), vec![rep(m(1), 30, true, Some(40))]);
        reports.insert(m(4), vec![rep(m(1), 50, false, Some(60))]);
        let v = build_view(&m(2), &online3(), &reports);
        let x = v.iter().find(|c| c.member == m(1)).unwrap();
        assert_eq!((x.median_rtt_ms, x.upload_mbps), (30, 40));
        assert!(x.reachable);
    }

    #[test]
    fn no_reports_and_copied_fields() {
        let v = build_view(&m(1), &online3(), &HashMap::new());
        assert_eq!(v.len(), 3);
        assert_eq!(v[2].member, m(3));
        assert!(!v[2].can_host);
        assert_eq!(v[2].online_since_ms, 300);
        assert!(v.iter().all(|c| !c.reachable && c.median_rtt_ms == 0 && c.upload_mbps == 0));
    }
}
