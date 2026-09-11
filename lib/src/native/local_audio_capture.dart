import 'dart:typed_data';

/// Optional native ALSA capture-clock policy. Omission preserves the current
/// deployment/environment policy; it does not select a new default.
/// Configure before first capture. Reapplying the same mode is idempotent;
/// changing mode afterward requires a WebRTC factory/application restart.
enum LocalAudioClockCorrection { off, observe, control }

/// Requested peerless speech-processing profile.
class LocalAudioProcessingProfile {
  const LocalAudioProcessingProfile({
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
    this.highPassFilter = true,
    this.clockCorrection,
  });

  final bool echoCancellation;
  final bool noiseSuppression;
  final bool autoGainControl;
  final bool highPassFilter;

  /// `control` preserves the native bounded hardware servo with callback
  /// fallback. `observe` measures without resampling. Unsupported backends or
  /// older native binaries reject explicit requests rather than ignoring them.
  final LocalAudioClockCorrection? clockCorrection;

  Map<String, dynamic> toMap() => {
        'echoCancellation': echoCancellation,
        'noiseSuppression': noiseSuppression,
        'autoGainControl': autoGainControl,
        'highPassFilter': highPassFilter,
        if (clockCorrection != null) 'clockCorrection': clockCorrection!.name,
      };
}

/// Capture opened, but policy acknowledgement and its cleanup both failed.
/// The owner must retain its track/transport and retry stop for [generation].
/// This is not a successful capture start and must not create another owner.
class LocalAudioCaptureStartCleanupException extends StateError {
  LocalAudioCaptureStartCleanupException({
    required this.generation,
    required this.cleanupError,
  }) : super('Native capture policy was not acknowledged and cleanup failed');

  final int generation;
  final Object cleanupError;
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
