import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native/audio_management.dart';
import 'package:flutter_webrtc/src/native/local_audio_capture.dart';
import 'package:flutter_webrtc/src/web/local_audio_capture_processor_source.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('supports peerless capture on every native implementation', () {
    for (final platform in [
      TargetPlatform.iOS,
      TargetPlatform.macOS,
      TargetPlatform.android,
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        NativeAudioManagement.supportsLocalAudioCapture,
        isTrue,
        reason: platform.name,
      );
    }
  });

  test('decodes generation-scoped post-APM format and frames', () {
    final format = decodeLocalAudioCaptureEvent({
      'event': 'onLocalAudioFormat',
      'generation': 7,
      'sampleRateHz': 48000,
      'channels': 1,
      'inputChannels': 2,
      'encoding': 'pcmS16le',
    }) as LocalAudioFormatEvent;
    final frame = decodeLocalAudioCaptureEvent({
      'event': 'onLocalAudioFrame',
      'generation': 7,
      'sequence': 4,
      'frameCount': 960,
      'droppedFrames': 0,
      'pcm': Uint8List(1920),
    }) as LocalAudioFrameEvent;

    expect(format.generation, 7);
    expect(format.sampleRateHz, 48000);
    expect(format.channels, 1);
    expect(frame.generation, format.generation);
    expect(frame.sequence, 4);
    expect(frame.pcm16.length, frame.frameCount * 2);
  });

  test('ignores unrelated plugin events', () {
    expect(
      decodeLocalAudioCaptureEvent({'event': 'onDeviceChange'}),
      isNull,
    );
  });

  test('web worklet static asset and browser-test fallback stay identical', () {
    expect(
      File('assets/local_audio_capture_processor.js').readAsStringSync(),
      localAudioCaptureProcessorSource,
    );
  });
}
