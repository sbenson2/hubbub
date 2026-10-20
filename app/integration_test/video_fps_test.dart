// Measures video frame rate through capture -> encode -> LiveKit SFU -> decode on one PC.
// Runs on the Windows desktop (it starts the bundled livekit-server on loopback):
//   flutter test integration_test/video_fps_test.dart -d windows
// Two rooms live in this process: a sender that publishes a screen share (and the camera,
// when there is one) with the app's own options, and a viewer that subscribes at HIGH.
// It never fails on a low frame rate, only on a harness error; read the printed `fps-it:`
// lines and the summary block at the end. Set HUBBUB_LIVEKIT to a livekit-server.exe path
// when the default search (vendor/livekit/windows-amd64 above the working directory) misses.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/room_adapter.dart' show fitShareStep, videoTxFromReports;
import 'package:hubbub/video_options.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';

const _key = 'devkey';
const _secret = 'hubbub-fps-test-secret-0123456789abcdef';
const _ramp = Duration(seconds: 5);
const _samples = 10;

void _log(String s) {
  // ignore: avoid_print
  print('fps-it: $s');
}

/// A port nothing listens on right now (TCP for the signal port, UDP for media).
Future<int> _freePort({required bool udp}) async {
  if (udp) {
    final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    s.close();
    return port;
  }
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

String _token(String identity) {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final head = _b64(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final body = _b64(utf8.encode(jsonEncode({
    'iss': _key,
    'sub': identity,
    'name': identity,
    'nbf': now - 10,
    'exp': now + 3600,
    'video': {
      'room': 'fps',
      'roomJoin': true,
      'canPublish': true,
      'canSubscribe': true,
      'canPublishData': true,
    },
  })));
  final sig = Hmac(sha256, utf8.encode(_secret)).convert(utf8.encode('$head.$body')).bytes;
  return '$head.$body.${_b64(sig)}';
}

Future<String> _localIp() async {
  final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
  String? any;
  for (final i in all) {
    for (final a in i.addresses) {
      if (a.isLoopback || a.address.startsWith('169.254.')) continue;
      any ??= a.address;
      if (a.address.startsWith('192.168.') || a.address.startsWith('10.')) return a.address;
    }
  }
  if (any == null) fail('no non-loopback IPv4 address for LiveKit to advertise');
  return any;
}

File? _findServer() {
  final env = Platform.environment['HUBBUB_LIVEKIT'];
  if (env != null && File(env).existsSync()) return File(env);
  final starts = [Directory.current.path, File(Platform.resolvedExecutable).parent.path];
  for (final s in starts) {
    var d = Directory(s);
    for (var i = 0; i < 10; i++) {
      final f = File('${d.path}/vendor/livekit/windows-amd64/livekit-server.exe');
      if (f.existsSync()) return f;
      final f2 = File('${d.path}/livekit-server.exe');
      if (f2.existsSync()) return f2;
      if (d.parent.path == d.path) break;
      d = d.parent;
    }
  }
  final fallback = File(r'C:\dev\hubbub\vendor\livekit\windows-amd64\livekit-server.exe');
  return fallback.existsSync() ? fallback : null;
}

num? _n(Object? v) => v is num ? v : (v == null ? null : num.tryParse('$v'));

String _f(num? v, [int d = 1]) => v == null ? '-' : v.toStringAsFixed(d);

/// One sample of what the sender and the viewer report, reduced to the numbers we print.
class _Row {
  double? capFps;
  String cap = '-';
  final layers = <String, String>{};
  final layerFps = <String, double>{};
  String rx = '-';
  double? rxFps;
  num? rxDropped;
  String net = '-';
}

class _Rig {
  Process? server;
  File? cfg;
  int signalPort = 0;
  Timer? fitTimer;
  final tracks = <LocalVideoTrack>[];
  Room? sender;
  Room? viewer;
  final prevTx = <String, (num, num)>{}; // report id -> (bytes, timestamp us)
  final prevRx = <String, (num, num)>{};

  Future<void> start() async {
    final exe = _findServer();
    if (exe == null) fail('livekit-server.exe not found; set HUBBUB_LIVEKIT');
    // libwebrtc ignores loopback candidates (the app relays through its TURN shim instead),
    // so LiveKit advertises this PC's own LAN address; the packets still never leave the PC.
    final ip = await _localIp();
    _log('advertising $ip');
    signalPort = await _freePort(udp: false);
    final udpPort = await _freePort(udp: true);
    // Its own file per run, deleted at teardown.
    final cfg = this.cfg = File('${Directory.systemTemp.path}/hubbub-fps-livekit-$pid-$signalPort.yaml');
    cfg.writeAsStringSync('port: $signalPort\n'
        'bind_addresses: ["127.0.0.1"]\n'
        'rtc:\n  tcp_port: 0\n  udp_port: $udpPort\n  use_external_ip: false\n'
        '  node_ip: $ip\n  ips:\n    includes: ["$ip/32"]\n'
        'keys:\n  $_key: $_secret\n'
        'logging:\n  level: ${Platform.environment['HUBBUB_FPS_VERBOSE'] == '1' ? 'debug' : 'warn'}\n');
    final proc = server = await Process.start(exe.path, ['--config', cfg.path]);
    final verbose = Platform.environment['HUBBUB_FPS_VERBOSE'] == '1';
    void echo(List<int> b) {
      if (verbose) _log('livekit: ${utf8.decode(b, allowMalformed: true).trim()}');
    }

    proc.stdout.listen(echo);
    proc.stderr.listen(echo);
    final end = DateTime.now().add(const Duration(seconds: 15));
    var up = false;
    while (!up && DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect('127.0.0.1', signalPort,
            timeout: const Duration(milliseconds: 500));
        s.destroy();
        up = true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!up) fail('livekit-server did not listen on 127.0.0.1:$signalPort within 15 s (run with HUBBUB_FPS_VERBOSE=1)');
    final keys = BaseKeyProvider.create();
    Future<Room> join(String id) async {
      final kp = await keys;
      await kp.setSharedKey('hubbub-fps-test-shared-key');
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: false,
          dynacast: true,
          e2eeOptions: E2EEOptions(keyProvider: kp),
        ),
      );
      await room.connect('ws://127.0.0.1:$signalPort', _token(id),
          connectOptions: const ConnectOptions(autoSubscribe: true));
      return room;
    }

    sender = await join('sender');
    viewer = await join('viewer');
    _log('livekit up at ${exe.path} advertising $ip; sender and viewer connected (E2EE on)');
  }

  Future<void> stop() async {
    fitTimer?.cancel();
    for (final t in tracks) {
      try {
        await t.stop();
      } catch (_) {}
    }
    tracks.clear();
    try {
      await sender?.disconnect();
      await viewer?.disconnect();
    } catch (_) {}
    server?.kill();
    try {
      cfg?.deleteSync();
    } catch (_) {}
  }

  /// The remote publication for [source] on the viewer, once the sender has published it.
  Future<RemoteTrackPublication<RemoteVideoTrack>?> waitRemote(TrackSource source) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final p = viewer!.remoteParticipants.values.firstOrNull;
      final pub = p?.getTrackPublicationBySource(source);
      if (pub is RemoteTrackPublication<RemoteVideoTrack> && pub.subscribed && pub.track != null) {
        return pub;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  Future<_Row> sample(LocalVideoTrack local, RemoteVideoTrack remote) async {
    final row = _Row();
    final tx = await local.sender?.getStats() ?? <rtc.StatsReport>[];
    for (final r in tx) {
      final v = r.values;
      if (r.type == 'media-source' && v['kind'] == 'video') {
        row.capFps = _n(v['framesPerSecond'])?.toDouble();
        row.cap = '${_n(v['width'])}x${_n(v['height'])}@${_f(row.capFps)}';
      } else if (r.type == 'outbound-rtp' && v['kind'] == 'video') {
        final rid = '${v['rid'] ?? '-'}';
        final bytes = _n(v['bytesSent']);
        // Report timestamps differ by platform; the wall clock times the byte deltas.
        final ts = DateTime.now().microsecondsSinceEpoch;
        double? kbps;
        final prev = prevTx[r.id];
        if (bytes != null) {
          if (prev != null && ts > prev.$2) kbps = (bytes - prev.$1) * 8 / 1000 / ((ts - prev.$2) / 1e6);
          prevTx[r.id] = (bytes, ts);
        }
        final fps = _n(v['framesPerSecond'])?.toDouble();
        if (fps != null) row.layerFps[rid] = fps;
        row.layers[rid] = '${_n(v['frameWidth'])}x${_n(v['frameHeight'])}@${_f(fps)} '
            '${_f(kbps, 0)}kbps lim=${v['qualityLimitationReason']} enc=${v['encoderImplementation']}';
      } else if (r.type == 'candidate-pair' && (v['nominated'] == true || v['state'] == 'succeeded')) {
        row.net = 'rtt=${_f((_n(v['currentRoundTripTime']) ?? 0) * 1000, 1)}ms '
            'availOut=${_f((_n(v['availableOutgoingBitrate']) ?? 0) / 1000, 0)}kbps';
      }
    }
    final rxs = await remote.receiver?.getStats() ?? <rtc.StatsReport>[];
    for (final r in rxs) {
      final v = r.values;
      if (r.type == 'inbound-rtp' && v['kind'] == 'video') {
        final bytes = _n(v['bytesReceived']);
        // Report timestamps differ by platform; the wall clock times the byte deltas.
        final ts = DateTime.now().microsecondsSinceEpoch;
        double? kbps;
        final prev = prevRx[r.id];
        if (bytes != null) {
          if (prev != null && ts > prev.$2) kbps = (bytes - prev.$1) * 8 / 1000 / ((ts - prev.$2) / 1e6);
          prevRx[r.id] = (bytes, ts);
        }
        row.rxFps = _n(v['framesPerSecond'])?.toDouble();
        row.rxDropped = _n(v['framesDropped']);
        row.rx = '${_n(v['frameWidth'])}x${_n(v['frameHeight'])}@${_f(row.rxFps)} '
            '${_f(kbps, 0)}kbps dropped=${row.rxDropped} dec=${v['decoderImplementation']}';
      }
    }
    return row;
  }

  /// Ramps, then samples once a second, printing a line per sample and returning a summary.
  Future<String> measure(String label, LocalVideoTrack local, RemoteVideoTrack remote) async {
    prevTx.clear();
    prevRx.clear();
    await Future<void>.delayed(_ramp);
    await sample(local, remote); // primes the bitrate deltas
    final rows = <_Row>[];
    for (var i = 0; i < _samples; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final r = await sample(local, remote);
      rows.add(r);
      _log('$label t=${i + 1}s capture=${r.cap} | tx ${r.layers.entries.map((e) => '[${e.key}] ${e.value}').join(' ')} '
          '| rx ${r.rx} | ${r.net}');
    }
    double avg(Iterable<double?> xs) {
      final l = xs.whereType<double>().toList();
      return l.isEmpty ? 0 : l.reduce((a, b) => a + b) / l.length;
    }

    final rids = <String>{for (final r in rows) ...r.layers.keys};
    final last = rows.isEmpty ? _Row() : rows.last;
    final tx = rids.map((k) => '[$k] ${_f(avg(rows.map((r) => r.layerFps[k])))}fps ${last.layers[k]}').join('\n    ');
    return '$label\n  capture: ${_f(avg(rows.map((r) => r.capFps)))}fps (last ${last.cap})\n'
        '  sent:\n    $tx\n'
        '  viewer: ${_f(avg(rows.map((r) => r.rxFps)))}fps (last ${last.rx})\n  ${last.net}';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('measure screen share and camera frame rates through a local LiveKit',
      (tester) async {
    final rig = _Rig();
    final summary = <String>[];
    addTearDown(rig.stop);
    await rig.start();

    // Screen share of the primary screen, watched at HIGH.
    final sources = await rtc.desktopCapturer.getSources(types: [rtc.SourceType.Screen]);
    expect(sources, isNotEmpty, reason: 'no screen to capture');
    final screen = await LocalVideoTrack.createScreenShareTrack(screenCaptureOptionsFor(sources.first.id));
    final dims = screen.currentOptions.params.dimensions;
    _log('screen source ${sources.first.name}; constraint ${dims.width}x${dims.height}');
    rig.tracks.add(screen);
    await rig.sender!.localParticipant!
        .publishVideoTrack(screen, publishOptions: screenPublishOptionsFor());
    // What the app does on its stats tick after publishing a share (the same ShareFit step);
    // set HUBBUB_FPS_NOFIT=1 to see it without.
    if (Platform.environment['HUBBUB_FPS_NOFIT'] != '1') {
      final fit = ShareFit();
      var busy = false;
      rig.fitTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (busy || fit.done) return;
        busy = true;
        try {
          final reports = await screen.sender?.getStats();
          if (reports == null) return;
          final sample = videoTxFromReports('screen', reports, <String, (num, num)>{},
              nowMs: DateTime.now().millisecondsSinceEpoch);
          await fitShareStep(fit, screen, sample);
        } finally {
          busy = false;
        }
      });
    }
    final screenPub = await rig.waitRemote(TrackSource.screenShareVideo);
    expect(screenPub, isNotNull, reason: 'viewer never subscribed to the screen share');
    await screenPub!.setVideoQuality(VideoQuality.HIGH);
    summary.add(await rig.measure('screen @HIGH', screen, screenPub.track!));
    rig.fitTimer?.cancel();
    await rig.sender!.localParticipant!.unpublishAllTracks();
    await screen.stop();

    // Camera, if the machine has one, watched at HIGH and then at LOW.
    final devices = await rtc.navigator.mediaDevices.enumerateDevices();
    final cams = devices.where((d) => d.kind == 'videoinput').toList();
    if (cams.isEmpty) {
      summary.add('camera: skipped, no videoinput device');
    } else {
      _log('camera ${cams.first.label}');
      // HUBBUB_FPS_LOWLIGHT=0/1 sets "Keep full frame rate in low light" (default: on).
      // HUBBUB_CAMDIAG=<camdiag.exe> logs the camera's auto-exposure priority while it runs and
      // after it stopped (it must read 0 then 1 with the setting on).
      final lowLight = Platform.environment['HUBBUB_FPS_LOWLIGHT'];
      if (lowLight != null) await rtc.HubbubCamera.setLowLightFullFrameRate(lowLight == '1');
      final camdiag = Platform.environment['HUBBUB_CAMDIAG'];
      Future<String> priority() async {
        if (camdiag == null) return 'n/a';
        final r = await Process.run(camdiag, ['info']);
        return (r.stdout as String).split('\n').where((l) => l.contains('priority')).join().trim();
      }
      final cam = await LocalVideoTrack.createCameraTrack(cameraCaptureOptionsFor(null));
      rig.tracks.add(cam);
      await rig.sender!.localParticipant!.publishVideoTrack(cam, publishOptions: cameraPublishOptions);
      final camPub = await rig.waitRemote(TrackSource.camera);
      expect(camPub, isNotNull, reason: 'viewer never subscribed to the camera');
      summary.add('camera setting low-light=${lowLight ?? 'default(on)'}; while running: ${await priority()}');
      await camPub!.setVideoQuality(VideoQuality.HIGH);
      summary.add(await rig.measure('camera @HIGH', cam, camPub.track!));
      await camPub.setVideoQuality(VideoQuality.LOW);
      summary.add(await rig.measure('camera @LOW', cam, camPub.track!));
      await rig.sender!.localParticipant!.unpublishAllTracks();
      await cam.stop();
      await Future<void>.delayed(const Duration(seconds: 1));
      summary.add('after the camera stopped: ${await priority()}');
    }

    _log('==== SUMMARY ====\n${summary.join('\n')}\n=================');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
