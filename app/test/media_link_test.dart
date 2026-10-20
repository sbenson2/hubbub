import 'package:flutter_test/flutter_test.dart';
import 'package:hubbub/media_link.dart';

AppMediaLink link(String path, int rtt, int sent, int lost, {String role = 'uplink'}) => AppMediaLink(
    role: role, path: path, rttMs: rtt, cwnd: 50000, sentPackets: sent, lostPackets: lost, congestionEvents: 2,
    mtu: 1452, maxDatagram: 1410, sendBufferSpace: 131072, frameTxDatagrams: sent);

AppMediaSnapshot snap(List<AppMediaLink> links, {int via = 0, int dropped = 0, int tryFailed = 0, int enq = 0, int tx = 0}) =>
    AppMediaSnapshot(
        links: links, wireTxPkts: tx, wireRxPkts: 0, viaStream: via, dropped: dropped, trySendFailed: tryFailed, dgramEnqueued: enq);

void main() {
  test('no media connection means no reading', () {
    expect(readMediaLink(snap(const []), null), isNull);
  });

  test('the_panel_line_names_path_rtt_and_loss_over_the_interval', () {
    final a = snap([link('direct', 40, 1000, 0)]);
    final b = snap([link('direct', 42, 2000, 1)]);
    final r = readMediaLink(b, a)!;
    expect(formatMediaLinkPanel(r), 'Connection: direct · 42 ms · 0.1% loss');
    expect(formatMediaLinkPanel(readMediaLink(a, null)!), 'Connection: direct · 40 ms · 0.0% loss');
    final heavy = readMediaLink(snap([link('relay', 120, 2100, 51)]), b)!;
    expect(formatMediaLinkPanel(heavy), 'Connection: relay · 120 ms · 50% loss');
  });

  test('the_worst_link_is_reported_a_relay_over_a_slower_direct_one', () {
    final r = readMediaLink(snap([link('direct', 300, 10, 0, role: 'member'), link('relay', 50, 10, 0, role: 'member')]), null)!;
    expect(r.path, 'relay');
    expect(r.links, 2);
  });

  test('the_media_link_log_line_carries_tunnel_deltas', () {
    final a = snap([link('direct', 40, 1000, 0)], via: 3, dropped: 1, tryFailed: 0, enq: 900, tx: 1000);
    final b = snap([link('direct', 41, 2000, 4)], via: 8, dropped: 6, tryFailed: 2, enq: 1900, tx: 2000);
    final line = formatMediaLink(readMediaLink(b, a)!);
    expect(line, startsWith('media_link path=direct rtt=41ms loss=0.40% mtu=1452 maxdgram=1410'));
    expect(line, contains('via_stream=5 dropped=5 try_fail=2'));
    expect(line, contains('tx=1000 enq=1000'));
  });

  test('counters_that_went_backwards_read_as_zero', () {
    final a = snap([link('direct', 40, 5000, 9)], via: 9, tx: 500);
    final b = snap([link('direct', 40, 10, 0)], via: 0, tx: 5);
    final r = readMediaLink(b, a)!;
    expect((r.lossPercent, r.viaStreamDelta, r.sentDelta), (0.0, 0, 0));
  });
}
