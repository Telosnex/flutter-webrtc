import 'dart:typed_data';

/// Requested peerless speech-processing profile.
class LocalAudioProcessingProfile {
  const LocalAudioProcessingProfile({
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
    this.highPassFilter = true,
  });

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;
  final bool highPassFilter;

  Map<String, dynamic> toMap() => {
        'echoCancellation': echoCancellation,
        'noiseSuppression': noiseSuppression,
        'autoGainControl': autoGainControl,
        'highPassFilter': highPassFilter,
      };
}

class LocalAudioCaptureStart {
  const LocalAudioCaptureStart({
    required this.generation,
    required this.requestedProfile,
    required this.processingState,
    required this.platformVoiceProcessingAllowed,
    required this.voiceProcessingBypassed,
  });

  final int generation;
  final LocalAudioProcessingProfile requestedProfile;

  /// Native requested/resolved/active diagnostics keyed by APM component.
  final Map<String, dynamic> processingState;
  final bool platformVoiceProcessingAllowed;
  final bool voiceProcessingBypassed;
}

sealed class LocalAudioCaptureEvent {
  const LocalAudioCaptureEvent({required this.generation});

  final int generation;
}

class LocalAudioFormatEvent extends LocalAudioCaptureEvent {
  const LocalAudioFormatEvent({
    required super.generation,
    required this.sampleRateHz,
    required this.channels,
    required this.inputChannels,
    required this.encoding,
  });

  final int sampleRateHz;
  final int channels;
  final int inputChannels;
  final String encoding;
}

class LocalAudioFrameEvent extends LocalAudioCaptureEvent {
  const LocalAudioFrameEvent({
    required super.generation,
    required this.sequence,
    required this.frameCount,
    required this.droppedFrames,
    required this.pcm16,
  });

  final int sequence;
  final int frameCount;
  final int droppedFrames;
  final Uint8List pcm16;
}

class LocalAudioStoppedEvent extends LocalAudioCaptureEvent {
  const LocalAudioStoppedEvent({
    required super.generation,
    required this.reason,
  });

  final String reason;
}

LocalAudioCaptureEvent? decodeLocalAudioCaptureEvent(
  Map<dynamic, dynamic> event,
) {
  final generation = (event['generation'] as num?)?.toInt();
  if (generation == null) return null;
  return switch (event['event']) {
    'onLocalAudioFormat' => LocalAudioFormatEvent(
        generation: generation,
        sampleRateHz: (event['sampleRateHz'] as num).toInt(),
        channels: (event['channels'] as num).toInt(),
        inputChannels: (event['inputChannels'] as num).toInt(),
        encoding: event['encoding'] as String,
      ),
    'onLocalAudioFrame' => LocalAudioFrameEvent(
        generation: generation,
        sequence: (event['sequence'] as num).toInt(),
        frameCount: (event['frameCount'] as num).toInt(),
        droppedFrames: (event['droppedFrames'] as num).toInt(),
        pcm16: event['pcm'] as Uint8List,
      ),
    'onLocalAudioStopped' => LocalAudioStoppedEvent(
        generation: generation,
        reason: event['reason'] as String,
      ),
    _ => null,
  };
}
