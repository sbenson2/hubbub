import 'src/rust/api/hubbub.dart' show AppMediaLink, AppMediaSnapshot;

export 'src/rust/api/hubbub.dart' show AppMediaLink, AppMediaSnapshot;

/// What the Stream Stats panel and the journal say about the media connection: which path it
/// takes (a relayed one is TCP and adds head-of-line blocking), the QUIC round trip and the
/// loss since the previous sample. Built from two consecutive core snapshots.
class MediaLinkReading {
  const MediaLinkReading({
    required this.path,
    required this.rttMs,
    required this.lossPercent,
    required this.mtu,
    required this.maxDatagram,
    required this.sendBufferSpace,
    required this.cwnd,
    required this.congestionEvents,
    required this.viaStreamDelta,
    required this.droppedDelta,
    required this.tryFailedDelta,
    required this.enqueuedDelta,
    required this.sentDelta,
    required this.links,
  });

  /// `direct`, `relay` or `unknown`.
  final String path;
  final int rttMs;
  final double lossPercent;
  final int mtu;
  final int maxDatagram;
  final int sendBufferSpace;
  final int cwnd;
  final int congestionEvents;

  /// Tunnel counters since the previous sample.
  final int viaStreamDelta;
  final int droppedDelta;
  final int tryFailedDelta;
  final int enqueuedDelta;
  final int sentDelta;

  /// How many media connections were summarised (the host has one per member).
  final int links;
}

/// Picks the connection to report (the worst one: a relay beats direct, then the slowest) and
/// diffs the counters against [prev]. Null when there is no media connection.
MediaLinkReading? readMediaLink(AppMediaSnapshot now, AppMediaSnapshot? prev) {
  if (now.links.isEmpty) return null;
  int rank(AppMediaLink l) => (l.path == 'relay' ? 2 : (l.path == 'unknown' ? 1 : 0)) * 100000 + l.rttMs;
  final worst = now.links.reduce((a, b) => rank(a) >= rank(b) ? a : b);
  final before = prev?.links.where((l) => l.role == worst.role).fold<AppMediaLink?>(null, (a, b) => a == null || b.sentPackets > a.sentPackets ? b : a);
  var loss = 0.0;
  if (before != null) {
    final sent = worst.sentPackets - before.sentPackets;
    final lost = worst.lostPackets - before.lostPackets;
    if (sent > 0 && lost > 0) loss = lost * 100 / sent;
  }
  int d(int a, int b) => a - b < 0 ? 0 : a - b;
  return MediaLinkReading(
    path: worst.path,
    rttMs: worst.rttMs,
    lossPercent: loss,
    mtu: worst.mtu,
    maxDatagram: worst.maxDatagram,
    sendBufferSpace: worst.sendBufferSpace,
    cwnd: worst.cwnd,
    congestionEvents: worst.congestionEvents,
    viaStreamDelta: prev == null ? 0 : d(now.viaStream, prev.viaStream),
    droppedDelta: prev == null ? 0 : d(now.dropped, prev.dropped),
    tryFailedDelta: prev == null ? 0 : d(now.trySendFailed, prev.trySendFailed),
    enqueuedDelta: prev == null ? 0 : d(now.dgramEnqueued, prev.dgramEnqueued),
    sentDelta: prev == null ? 0 : d(now.wireTxPkts, prev.wireTxPkts),
    links: now.links.length,
  );
}

/// The panel line, e.g. `Connection: direct · 42 ms · 0.1% loss`.
String formatMediaLinkPanel(MediaLinkReading r) =>
    'Connection: ${r.path} · ${r.rttMs} ms · ${_pct(r.lossPercent)}% loss';

String _pct(double v) => v < 10 ? v.toStringAsFixed(1) : v.round().toString();

/// The `media_link` journal line, logged next to `video_tx` / `video_rx`.
String formatMediaLink(MediaLinkReading r) => [
      'media_link path=${r.path}',
      'rtt=${r.rttMs}ms',
      'loss=${r.lossPercent.toStringAsFixed(2)}%',
      'mtu=${r.mtu}',
      'maxdgram=${r.maxDatagram}',
      'cwnd=${r.cwnd}',
      'cong=${r.congestionEvents}',
      'bufspace=${r.sendBufferSpace}',
      'tx=${r.sentDelta}',
      'enq=${r.enqueuedDelta}',
      'via_stream=${r.viaStreamDelta}',
      'dropped=${r.droppedDelta}',
      'try_fail=${r.tryFailedDelta}',
      'links=${r.links}',
    ].join(' ');
