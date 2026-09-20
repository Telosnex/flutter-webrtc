@TestOn('browser')
library;

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('browser PCM renders and clears without requesting capture',
      (_) async {
    expect(await LocalPcmPlayout.isSupported(), true);
    final player = LocalPcmPlayout();
    final other = LocalPcmPlayout();
    try {
      await player.start();
      await expectLater(other.start(), throwsStateError);
      await player.write(Uint8List(9600)); // 200ms silence, real browser graph.
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      var state = await player.getState();
      while (state.consumedFrames < 4800 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        state = await player.getState();
      }
      expect(state.playing, true);
      expect(state.consumedFrames, 4800);
      await player.clear();
      expect((await player.getState()).queuedFrames, 0);
      await player.stop();
      await player.stop();
      await expectLater(player.write(Uint8List(2)), throwsStateError);
      final next = LocalPcmPlayout();
      await next.start();
      await next.stop();
    } finally {
      await player.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
  testWidgets('shared music survives speech clear and stop', (_) async {
    final speech = LocalPcmPlayout(ownership: LocalPcmOwnership.shared);
    final music = LocalPcmPlayout(
        sampleRate: 48000, channels: 2, ownership: LocalPcmOwnership.shared);
    try {
      await speech.start();
      await music.start();
      await expectLater(LocalPcmPlayout().start(), throwsStateError);
      await expectLater(
          LocalPcmPlayout(ownership: LocalPcmOwnership.shared).start(),
          throwsStateError);
      await music.write(Uint8List(192000));
      await speech.write(Uint8List(4800));
      await speech.clear();
      await speech.stop();
      final before = await music.getState();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final after = await music.getState();
      expect(after.playing, true);
      expect(after.generation, before.generation);
      expect(after.consumedFrames, greaterThan(before.consumedFrames));
    } finally {
      await speech.stop();
      await music.stop();
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}
