import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class Anchor implements RTCPeerConnection {
  int closes = 0, disposals = 0;
  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final calls = <MethodCall>[];
  var failStop = false;
  Completer<void>? heldWrite;
  Map<String, dynamic> state() => {
    'generation': 7,
    'epoch': 0,
    'queuedFrames': 0,
    'consumedFrames': 0,
    'renderCallbacks': 0,
    'playing': true,
    'delayMs': 0,
  };
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    calls.clear();
    failStop = false;
    heldWrite = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'initialize') return null;
          if (call.method == 'pcmPlayoutCapabilities') {
            return {'version': 1, 'sampleRate': 24000, 'channels': 1};
          }
          if (call.method == 'pcmPlayoutWrite') await heldWrite?.future;
          if (call.method == 'pcmPlayoutStop' && failStop) {
            throw PlatformException(code: 'stopFailed');
          }
          return state();
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'clear rejects queued stale writes; new PCM waits for clear acknowledgement',
    () async {
      final anchor = Anchor();
      final sink = LocalPcmPlayout(createAnchor: () async => anchor);
      await sink.start();
      heldWrite = Completer();
      final a = sink.write(Uint8List(480));
      await Future<void>.delayed(Duration.zero);
      final b = sink.write(Uint8List(480));
      final clear = sink.clear();
      final c = sink.write(Uint8List(480));
      heldWrite!.complete();
      await Future.wait([a, b, clear, c]);
      final writes = calls.where((c) => c.method == 'pcmPlayoutWrite').toList();
      expect(writes.map((c) => c.arguments['epoch']), [0, 1]);
      expect(
        calls
            .where(
              (c) =>
                  c.method.startsWith('pcmPlayout') &&
                  ![
                    'pcmPlayoutStart',
                    'pcmPlayoutCapabilities',
                  ].contains(c.method),
            )
            .map((c) => c.method),
        ['pcmPlayoutWrite', 'pcmPlayoutClear', 'pcmPlayoutWrite'],
      );
      await sink.stop();
      expect(anchor.closes, 1);
      expect(anchor.disposals, 1);
    },
  );
  test(
    'stop failure retains anchor/generation; retries cannot revive writes',
    () async {
      final anchor = Anchor();
      final sink = LocalPcmPlayout(createAnchor: () async => anchor);
      await sink.start();
      failStop = true;
      await expectLater(sink.stop(), throwsA(isA<PlatformException>()));
      expect(anchor.closes, 0);
      await expectLater(sink.write(Uint8List(480)), throwsStateError);
      failStop = false;
      await sink.stop();
      expect(anchor.closes, 1);
      expect(
        calls
            .where((c) => c.method == 'pcmPlayoutStop')
            .map((c) => c.arguments['generation']),
        [7, 7],
      );
    },
  );
  test(
    'all native platforms query capability; old SDK remains unsupported',
    () async {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(await LocalPcmPlayout.isSupported(), true);
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'initialize') return null;
            throw MissingPluginException();
          });
      expect(await LocalPcmPlayout.isSupported(), false);
    },
  );
  test('SDK-owned lifetime skips empty-peer anchor', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'pcmPlayoutCapabilities') {
            return {
              'version': 1,
              'sampleRate': 24000,
              'channels': 1,
              'requiresAnchor': false,
            };
          }
          return state();
        });
    final sink = LocalPcmPlayout(
      createAnchor: () async {
        throw StateError('must not create peer');
      },
    );
    await sink.start();
    await sink.stop();
  });
}
