import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/local_audio_capture.dart';
import 'package:flutter_webrtc/src/native/local_audio_capture_backend.dart';
import 'package:flutter_webrtc/src/native/utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  var supported = true;
  var reportedMode = 'control';
  setUp(() {
    WebRTC.initialized = true;
    calls.clear();
    supported = true;
    reportedMode = 'control';
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final state = {
        'clockCorrection': {'supported': supported, 'mode': reportedMode}
      };
      return switch (call.method) {
        'getLocalAudioCaptureState' => {'processingState': state},
        'startLocalAudioCapture' => {'generation': 7, 'processingState': state},
        'stopLocalAudioCapture' => null,
        _ => throw StateError(call.method),
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    WebRTC.initialized = false;
  });
  test('omission preserves old profile and needs no capability probe',
      () async {
    const profile = LocalAudioProcessingProfile();
    expect(profile.toMap().containsKey('clockCorrection'), isFalse);
    await LocalAudioCaptureBackend().start(profile: profile);
    expect(calls.map((call) => call.method), ['startLocalAudioCapture']);
  });
  for (final mode in LocalAudioClockCorrection.values) {
    test('sends and acknowledges ${mode.name} without factory reinitialization',
        () async {
      reportedMode = mode.name;
      final result = await LocalAudioCaptureBackend().start(
        profile: LocalAudioProcessingProfile(clockCorrection: mode),
        trackId: 'borrowed-mic',
      );
      expect(result.generation, 7);
      expect(calls.map((call) => call.method),
          ['getLocalAudioCaptureState', 'startLocalAudioCapture']);
      expect(calls.last.arguments['profile']['clockCorrection'], mode.name);
      expect(calls.last.arguments['trackId'], 'borrowed-mic');
    });
  }
  test('unsupported native implementation fails before capture', () async {
    supported = false;
    await expectLater(
        LocalAudioCaptureBackend().start(
          profile: const LocalAudioProcessingProfile(
              clockCorrection: LocalAudioClockCorrection.control),
        ),
        throwsUnsupportedError);
    expect(calls.map((call) => call.method), ['getLocalAudioCaptureState']);
  });
  test('unacknowledged policy retires exactly the opened generation', () async {
    reportedMode = 'off';
    await expectLater(
        LocalAudioCaptureBackend().start(
          profile: const LocalAudioProcessingProfile(
              clockCorrection: LocalAudioClockCorrection.control),
        ),
        throwsStateError);
    expect(calls.last.method, 'stopLocalAudioCapture');
    expect(calls.last.arguments, {'generation': 7});
  });
}
