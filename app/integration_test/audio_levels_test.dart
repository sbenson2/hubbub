// Runs on the desktop with a real microphone:
//   flutter test integration_test/audio_levels_test.dart -d windows   (or -d linux)
// It proves the patched plugin's levels events reach Dart while the platform thread keeps
// answering method calls (a re-entrant task runner used to deadlock it on the first event).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mic levels reach Dart and the platform thread stays responsive', (tester) async {
    expect(HubbubAudio.supported, isTrue);
    final levels = <HubbubLevels>[];
    final layouts = <String>[];
    final levelSub = HubbubAudio.levels.listen(levels.add);
    final layoutSub = HubbubAudio.layout.listen(layouts.add);

    // Capture only runs once an audio sender is negotiated, so connect two local peers.
    final mic = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final a = await createPeerConnection({});
    final b = await createPeerConnection({});
    a.onIceCandidate = (c) => b.addCandidate(c);
    b.onIceCandidate = (c) => a.addCandidate(c);
    for (final t in mic.getAudioTracks()) {
      await a.addTrack(t, mic);
    }
    final offer = await a.createOffer();
    await a.setLocalDescription(offer);
    await b.setRemoteDescription(offer);
    final answer = await b.createAnswer();
    await b.setLocalDescription(answer);
    await a.setRemoteDescription(answer);

    // The audio device starts once the send stream is up; give it a few seconds.
    final start = DateTime.now().add(const Duration(seconds: 10));
    while (levels.isEmpty && DateTime.now().isBefore(start)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    levels.clear();

    final slowest = Stopwatch();
    var worstMs = 0;
    final until = DateTime.now().add(const Duration(seconds: 4));
    while (DateTime.now().isBefore(until)) {
      slowest
        ..reset()
        ..start();
      await HubbubAudio.status().timeout(const Duration(seconds: 2));
      if (slowest.elapsedMilliseconds > worstMs) worstMs = slowest.elapsedMilliseconds;
      await tester.pump(const Duration(milliseconds: 100));
    }
    final status = await HubbubAudio.status();
    // ignore: avoid_print
    print('hubbub-it: levels=${levels.length} worstStatusMs=$worstMs layouts=$layouts status=$status');

    expect(worstMs, lessThan(1000));
    expect(levels.length, greaterThan(20), reason: 'about 20 events a second while capturing');
    expect(levels.every((l) => l.pre.isFinite && l.post.isFinite), isTrue);

    await levelSub.cancel();
    await layoutSub.cancel();
    await a.close();
    await b.close();
    for (final t in mic.getTracks()) {
      await t.stop();
    }
    await mic.dispose();
  });
}
