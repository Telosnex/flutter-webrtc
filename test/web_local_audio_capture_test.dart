@TestOn('browser')
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'one browser track feeds processed PCM across sender attach and detach',
    (_) async {
      expect(NativeAudioManagement.supportsLocalAudioCapture, isTrue);

      MediaStream? stream;
      RTCPeerConnection? peer;
      StreamSubscription<LocalAudioCaptureEvent>? subscription;
      int? generation;
      var frames = 0;
      var droppedFrames = 0;
      var stoppedEvents = 0;
      LocalAudioFormatEvent? format;
      LocalAudioFrameEvent? firstFrame;
      final firstPcm = Completer<void>();

      Future<void> waitForAdditionalFrames(int count) async {
        final target = frames + count;
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (frames < target && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(frames, greaterThanOrEqualTo(target));
      }

      try {
        subscription = NativeAudioManagement.localAudioEvents.listen((event) {
          switch (event) {
            case LocalAudioFormatEvent():
              format = event;
            case LocalAudioFrameEvent():
              frames += event.frameCount;
              droppedFrames += event.droppedFrames;
              firstFrame ??= event;
              if (!firstPcm.isCompleted) firstPcm.complete();
            case LocalAudioStoppedEvent():
              stoppedEvents += 1;
          }
        });
        stream = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        });
        final track = stream.getAudioTracks().single;
        final start = await NativeAudioManagement.startLocalAudioCapture(
          track: track,
          trackId: track.id,
        );
        generation = start.generation;
        await firstPcm.future.timeout(const Duration(seconds: 10));

        expect(format?.generation, start.generation);
        expect(format?.sampleRateHz, greaterThan(0));
        expect(format?.channels, 1);
        expect(format?.encoding, 'pcmS16le');
        expect(firstFrame?.pcm16.length, firstFrame!.frameCount * 2);
        expect(
          start.processingState['implementation'],
          'browserMediaTrack',
        );
        for (final component in [
          'echoCancellation',
          'noiseSuppression',
          'autoGainControl',
        ]) {
          expect(
            (start.processingState[component] as Map)['active'],
            isTrue,
            reason: component,
          );
        }

        final beforeAttach = frames;
        peer = await createPeerConnection({
          'sdpSemantics': 'unified-plan',
          'iceServers': <dynamic>[],
        });
        await peer.addTrack(track, stream);
        final offer = await peer.createOffer();
        await peer.setLocalDescription(offer);
        await waitForAdditionalFrames(4800);
        expect(frames, greaterThan(beforeAttach));

        final beforeDetach = frames;
        await peer.close();
        await peer.dispose();
        peer = null;
        await waitForAdditionalFrames(4800);
        expect(frames, greaterThan(beforeDetach));

        final state = await NativeAudioManagement.getLocalAudioCaptureState();
        expect(state['generation'], start.generation);
        expect(state['recording'], isTrue);
        expect(state['browserCaptureDemand'], isTrue);
        expect(state['audioContextState'], 'running');
        expect(droppedFrames, 0);

        await Future.wait([
          NativeAudioManagement.stopLocalAudioCapture(start.generation),
          NativeAudioManagement.stopLocalAudioCapture(start.generation),
        ]);
        generation = null;
        final stoppedState =
            await NativeAudioManagement.getLocalAudioCaptureState();
        expect(stoppedState['active'], isFalse);
        expect(stoppedState['browserCaptureDemand'], isFalse);
        expect(stoppedEvents, 1);
      } finally {
        if (generation case final activeGeneration?) {
          await NativeAudioManagement.stopLocalAudioCapture(activeGeneration);
        }
        if (peer != null) {
          await peer.close();
          await peer.dispose();
        }
        if (stream != null) {
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
        }
        await subscription?.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
