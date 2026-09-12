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
}
