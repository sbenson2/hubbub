// Measures what happens to a voice on its way through Hubbub's audio pipeline on one PC:
//   reference speech -> capture hook (RNNoise, gain, limiter) -> Opus -> E2EE -> LiveKit SFU
//   -> decode -> remote track
// and compares the sent and the received signal (tools/audio_compare.py). Windows only:
//   cmd /c "set HUBBUB_ROOT=C:\Users\shawn\AppData\Local\Temp\hubbub-audio-root& cd /d C:\dev\hubbub\app &&
//           C:\src\flutter\bin\flutter.bat test integration_test\audio_quality_test.dart -d windows"
//
// How it works (all local, nothing downloaded, nothing played):
//  * The reference is made with Windows SAPI text to speech (tools/make-speech-ref.ps1).
//  * "Inject" replaces the microphone signal at the capture post-processing hook. That hook
//    is the first point of the capture path the patched flutter_webrtc can reach: the audio
//    engine's own echo cancellation, noise suppression and gain control run before it, on
//    the real microphone, and their output is thrown away. So "Standard" (the engine's noise
//    suppressor) cannot show a difference here; RNNoise, gain, the limiter, the 16 kHz
//    processing rate, Opus, E2EE and the SFU are all in the measured path.
//  * The receiving room's playout is muted at the render hook, so nothing reaches the speakers;
//    the decoded audio is still recorded from the remote track (and from the playout mix).
//  * Two rooms (sender, receiver) live in this process, like video_fps_test.dart.
// The test never fails on audio quality, only on a harness error. The summary table is also
// written to .superpowers/sdd/2026-10-19-audio/baseline.md.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:hubbub/capture_options.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart';

const _key = 'devkey';
const _secret = 'hubbub-audio-test-secret-0123456789abcdef';

void _log(String s) {
  // ignore: avoid_print
  print('audio-it: $s');
}

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
      'room': 'audio',
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
      if (d.parent.path == d.path) break;
      d = d.parent;
    }
  }
  final fallback = File(r'C:\dev\hubbub\vendor\livekit\windows-amd64\livekit-server.exe');
  return fallback.existsSync() ? fallback : null;
}

/// The repository root: the folder above `app` that holds `tools/audio_compare.py`.
Directory _repoRoot() {
  var d = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    if (File('${d.path}/tools/audio_compare.py').existsSync()) return d;
    if (d.parent.path == d.path) break;
    d = d.parent;
  }
  fail('tools/audio_compare.py not found above ${Directory.current.path}');
}

String _f(Object? v, [int d = 1]) => v is num ? v.toStringAsFixed(d) : '-';

class _Rig {
  Process? server;
  File? cfg;
  Room? sender;
  Room? viewer;

  Future<void> start() async {
    final exe = _findServer();
    if (exe == null) fail('livekit-server.exe not found; set HUBBUB_LIVEKIT');
    final ip = await _localIp();
    final signalPort = await _freePort(udp: false);
    final udpPort = await _freePort(udp: true);
    final c = cfg = File('${Directory.systemTemp.path}/hubbub-audio-livekit-$pid-$signalPort.yaml');
    c.writeAsStringSync('port: $signalPort\n'
        'bind_addresses: ["127.0.0.1"]\n'
        'rtc:\n  tcp_port: 0\n  udp_port: $udpPort\n  use_external_ip: false\n'
        '  node_ip: $ip\n  ips:\n    includes: ["$ip/32"]\n'
        'keys:\n  $_key: $_secret\n'
        'logging:\n  level: warn\n');
    server = await Process.start(exe.path, ['--config', c.path]);
    server!.stdout.listen((_) {});
    server!.stderr.listen((_) {});
    final end = DateTime.now().add(const Duration(seconds: 15));
    var up = false;
    while (!up && DateTime.now().isBefore(end)) {
      try {
        final s = await Socket.connect('127.0.0.1', signalPort, timeout: const Duration(milliseconds: 500));
        s.destroy();
        up = true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (!up) fail('livekit-server did not listen on 127.0.0.1:$signalPort within 15 s');
    final keys = await BaseKeyProvider.create();
    await keys.setSharedKey('hubbub-audio-test-shared-key');
    Future<Room> join(String id) async {
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: false,
          dynacast: true,
          e2eeOptions: E2EEOptions(keyProvider: keys),
        ),
      );
      await room.connect('ws://127.0.0.1:$signalPort', _token(id),
          connectOptions: const ConnectOptions(autoSubscribe: true));
      return room;
    }

    // The viewer joins first, so its playout is up before the sender's capture starts.
    viewer = await join('viewer');
    sender = await join('sender');
    _log('livekit up (advertising $ip); sender and viewer connected, E2EE on');
  }

  Future<void> stop() async {
    try {
      await sender?.disconnect();
      await viewer?.disconnect();
    } catch (_) {}
    server?.kill();
    try {
      cfg?.deleteSync();
    } catch (_) {}
  }

  /// The viewer's subscribed audio track of the sender (a new one per publish).
  Future<RemoteAudioTrack?> waitRemoteAudio({String? notSid}) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(end)) {
      final p = viewer!.remoteParticipants.values.firstOrNull;
      for (final pub in p?.audioTrackPublications ?? const <RemoteTrackPublication<RemoteAudioTrack>>[]) {
        final t = pub.track;
        if (pub.subscribed && t != null && pub.sid != notSid) return t;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }
}

class _Config {
  const _Config(this.ns, this.gain);
  final NoiseSuppression ns;
  final double gain;
  String get id => '${ns.name}-g${(gain * 100).round()}';
  rtc.HubbubNoiseSuppression get hook => switch (ns) {
        NoiseSuppression.none => rtc.HubbubNoiseSuppression.off,
        NoiseSuppression.standard => rtc.HubbubNoiseSuppression.webrtc,
        NoiseSuppression.rnnoise => rtc.HubbubNoiseSuppression.rnnoise,
      };
}

/// One comparison made by tools/audio_compare.py.
class _Cmp {
  _Cmp(this.leg, this.json);
  final String leg;
  final Map<String, dynamic> json;

  Map<String, dynamic>? get err => json['error'] == null ? null : json;
  num? at(List<String> path) {
    Object? v = json;
    for (final k in path) {
      if (v is Map) {
        v = v[k];
      } else {
        return null;
      }
    }
    return v is num ? v : null;
  }

  String row(String setting) {
    if (json['error'] != null) return '| $setting | $leg | error: ${json['error']} | | | | | | | | |';
    final m = json['muffled'] as Map;
    return '| $setting | $leg | ${_f(at(['delay', 'ms']), 0)} | ${_f(at(['level', 'speech_level_diff_db']))} '
        '| ${m['verdict']} | ${_f(at(['spectrum', 'above_4k_share_change_db']))} '
        '| ${_f(at(['spectrum', 'recv', 'rolloff95_hz']), 0)} | ${_f(m['cutoff_hz_recv'] as num?, 0)} '
        '| ${_f(((at(['endings', 'share_truncated']) ?? 0) * 100), 0)} % / ${_f(at(['endings', 'mean_truncated_ms']), 0)} ms '
        '| ${at(['dropouts', 'count'])} (${at(['dropouts', 'total_ms'])} ms) '
        '| ${_f(at(['scores', 'pesq_wb']), 2)} / ${_f(at(['scores', 'stoi']), 3)} |';
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('record a reference voice through the pipeline and compare sent and received audio',
      (tester) async {
    expect(Platform.isWindows, isTrue, reason: 'this harness is for the Windows host');
    final repo = _repoRoot();
    final root = Platform.environment['HUBBUB_ROOT'];
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final out = Directory('${root ?? Directory.systemTemp.path}/audio-quality-$stamp')..createSync(recursive: true);
    _log('files in ${out.path}');

    // ---- reference speech
    final refEnv = Platform.environment['HUBBUB_AUDIO_REF'];
    final ref = File(refEnv ?? '${out.path}/reference.wav');
    if (refEnv == null) {
      final r = await Process.run('powershell.exe', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', '${repo.path}\\tools\\make-speech-ref.ps1',
        '-Out', ref.path,
      ]);
      if (r.exitCode != 0 || !ref.existsSync()) fail('could not make the reference speech: ${r.stderr}');
    }
    _log('reference ${ref.path} (${ref.lengthSync()} bytes)');

    // ---- python
    final venvPy = File('${repo.path}/tools/.venv/Scripts/python.exe');
    final python = Platform.environment['HUBBUB_PYTHON'] ?? (venvPy.existsSync() ? venvPy.path : 'python');
    Future<_Cmp> compare(String leg, String sent, String recv, String name, {bool png = false}) async {
      if (!File(sent).existsSync() || !File(recv).existsSync()) {
        return _Cmp(leg, {'error': 'missing file ${File(sent).existsSync() ? recv : sent}'});
      }
      final args = [
        '${repo.path}/tools/audio_compare.py', '--sent', sent, '--received', recv,
        '--out-dir', out.path, '--name', name, '--label', name, '--quiet', if (!png) '--no-png',
      ];
      final r = await Process.run(python, args);
      final j = File('${out.path}/$name.json');
      if (!j.existsSync()) return _Cmp(leg, {'error': 'audio_compare failed: ${r.stderr}'.trim()});
      return _Cmp(leg, jsonDecode(j.readAsStringSync()) as Map<String, dynamic>);
    }

    // ---- the rig; playout muted before any audio flows
    final rig = _Rig();
    addTearDown(() async {
      try {
        await rtc.HubbubTaps.injectStop();
      } catch (_) {}
      await rig.stop();
    });
    await rtc.HubbubTaps.setPlayoutMuted(true);
    final play = await rtc.HubbubTaps.playoutStatus();
    expect(play?['muted'], isTrue, reason: 'playout must be muted before a test plays anything');
    await rig.start();

    final configs = <_Config>[
      for (final ns in [NoiseSuppression.rnnoise, NoiseSuppression.standard, NoiseSuppression.none])
        for (final g in [1.0, 1.5]) _Config(ns, g),
    ];
    final only = Platform.environment['HUBBUB_AUDIO_ONLY']; // e.g. "rnnoise-g100" for a quick run
    final rows = <String>[];
    final notes = <String>[];
    String? hookLayout;
    String? lastSid;

    // Clock check: how many 10 ms blocks the capture hook gets per second of wall clock with the
    // plain microphone (only counters are read, nothing is recorded). 100 is real time.
    {
      final local = rig.sender!.localParticipant!;
      final mic = await LocalAudioTrack.create(captureOptionsFor(null, noiseSuppression: NoiseSuppression.none));
      await local.publishAudioTrack(mic);
      await Future<void>.delayed(const Duration(seconds: 2));
      final a = await rtc.HubbubAudio.status();
      final p0 = await rtc.HubbubTaps.playoutStatus();
      final t0 = DateTime.now();
      await Future<void>.delayed(const Duration(seconds: 8));
      final b = await rtc.HubbubAudio.status();
      final p1 = await rtc.HubbubTaps.playoutStatus();
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000;
      final capRate = ((b?['processed'] as num) - (a?['processed'] as num)) / secs;
      final renRate = p0 == null || p1 == null ? 0.0 : ((p1['calls'] as num) - (p0['calls'] as num)) / secs;
      notes.add('Clock check (plain microphone, 8 s): capture hook ${capRate.toStringAsFixed(1)} blocks/s, '
          'render hook ${renRate.toStringAsFixed(1)} blocks/s (100 is real time).');
      _log(notes.last);
      await local.unpublishAllTracks();
      await mic.stop();
    }

    for (final c in configs) {
      if (only != null && !only.split(',').contains(c.id)) continue;
      _log('==== ${c.id} ====');
      final dir = Directory('${out.path}/${c.id}')..createSync();
      final local = rig.sender!.localParticipant!;
      await local.unpublishAllTracks();
      await Future<void>.delayed(const Duration(milliseconds: 800));

      await rtc.HubbubAudio.setNoiseSuppression(c.hook);
      await rtc.HubbubAudio.setInputGain(c.gain);
      await rtc.HubbubTaps.injectLoad(ref.path); // the microphone is silent from here on
      final mic = await LocalAudioTrack.create(captureOptionsFor(null, noiseSuppression: c.ns));
      await local.publishAudioTrack(mic);
      final remote = await rig.waitRemoteAudio(notSid: lastSid);
      if (remote == null) {
        await mic.stop();
        fail('the receiver never subscribed to the sender audio (${c.id})');
      }
      final trackId = remote.mediaStreamTrack.id!;
      lastSid = remote.sid;
      await Future<void>.delayed(const Duration(seconds: 1)); // let the capture path settle

      final proc = '${dir.path}/send-processed.wav';
      final inp = '${dir.path}/send-hook-input.wav';
      final rcv = '${dir.path}/recv-sender.wav';
      final mix = '${dir.path}/recv-playout-mix.wav';
      await rtc.HubbubTaps.start(rtc.HubbubSendTap.processed, proc);
      await rtc.HubbubTaps.start(rtc.HubbubSendTap.input, inp);
      await rtc.HubbubTaps.recordTrack(trackId, rcv);
      await rtc.HubbubTaps.playoutTapStart(mix);
      final started = await rtc.HubbubTaps.injectPlay();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        final s = await rtc.HubbubTaps.status();
        if (s?['injectFinished'] == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await Future<void>.delayed(const Duration(milliseconds: 2500)); // the tail still in flight

      final rProc = await rtc.HubbubTaps.stop(rtc.HubbubSendTap.processed);
      final rInp = await rtc.HubbubTaps.stop(rtc.HubbubSendTap.input);
      final rRcv = await rtc.HubbubTaps.stopTrack(trackId);
      final rMix = await rtc.HubbubTaps.playoutTapStop();
      final status = await rtc.HubbubAudio.status();
      final pstat = await rtc.HubbubTaps.playoutStatus();
      hookLayout ??= 'capture hook: rate=${status?['rate']} channels=${status?['channels']} '
          'bands=${status?['bands']} frames=${status?['frames']} processed=${status?['processed']} '
          'skipped=${status?['skipped']}; render hook: rate=${pstat?['rate']} channels=${pstat?['channels']} '
          'calls=${pstat?['calls']}';
      _log('${c.id}: started $started; send ${rProc?.seconds.toStringAsFixed(1)} s @${rProc?.sourceRate} Hz, '
          'hook-in ${rInp?.seconds.toStringAsFixed(1)} s, recv ${rRcv?.seconds.toStringAsFixed(1)} s '
          '@${rRcv?.sourceRate} Hz (sink calls ${rRcv?.sinkCalls}), mix ${rMix?.seconds.toStringAsFixed(1)} s '
          '@${rMix?.sourceRate} Hz, max gap ms send/in/recv/mix ${[rProc, rInp, rRcv, rMix].map((r) => '${r?.maxGapMs}(${r?.gapsOver50Ms})').join('/')}, wall s send/recv/mix ${[rProc, rRcv, rMix].map((r) => r == null ? '-' : ((r.lastSampleMs - r.firstSampleMs) / 1000).toStringAsFixed(1)).join('/')}; '
          'dropped chunks ${[rProc, rInp, rRcv, rMix].map((r) => r?.droppedChunks).join('/')}');

      await rtc.HubbubTaps.injectStop();
      await local.unpublishAllTracks();
      await mic.stop();

      final overall = await compare('reference -> received', ref.path, rcv, '${c.id}-overall', png: true);
      final legA = await compare('reference -> sent (hook out)', ref.path, proc, '${c.id}-leg-capture');
      final legB = await compare('sent (hook out) -> received', proc, rcv, '${c.id}-leg-network');
      final legMix = await compare('reference -> playout mix', ref.path, mix, '${c.id}-leg-mix');
      final tag = '${c.ns.label}, gain ${(c.gain * 100).round()} %';
      for (final leg in [overall, legA, legB, legMix]) {
        rows.add(leg.row(tag));
      }
      _log('${c.id}: ${overall.row(tag)}');
    }

    // ---- the baseline
    final md = StringBuffer()
      ..writeln('# Audio pipeline baseline (${DateTime.now().toIso8601String().substring(0, 16)})')
      ..writeln()
      ..writeln('Harness: `app/integration_test/audio_quality_test.dart`; reference: Windows SAPI speech '
          '(`tools/make-speech-ref.ps1`), injected at the capture post-processing hook, sent to a second room on a '
          'local LiveKit with E2EE, received audio taken from the remote track sink; playout muted at the render hook. '
          'Compared with `tools/audio_compare.py`. Files: `${out.path}`.')
      ..writeln()
      ..writeln(hookLayout ?? '')
      ..writeln()
      ..writeln('Legs: *reference -> received* is the whole path; *reference -> sent* is the capture hook only '
          '(RNNoise, gain, limiter; the audio engine runs the hook at its own rate, see above); *sent -> received* '
          'is Opus + E2EE + SFU + decode; *playout mix* is the render-hook tap of the same received audio.')
      ..writeln()
      ..writeln('| Setting | Leg | Delay ms | Level dB | Muffled? | >4 kHz share dB | 95% roll-off Hz | Highest band Hz | Truncated segs / mean | Dropouts | PESQ-WB / STOI |')
      ..writeln('|---|---|---|---|---|---|---|---|---|---|---|');
    for (final r in rows) {
      md.writeln(r);
    }
    for (final n in notes) {
      md.writeln('\n$n');
    }
    final baseline = File('${repo.path}/.superpowers/sdd/2026-10-19-audio/baseline.md');
    baseline.parent.createSync(recursive: true);
    baseline.writeAsStringSync(md.toString());
    _log('==== SUMMARY ====\n$md\n=================');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
