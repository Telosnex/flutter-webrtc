import 'package:webrtc_interface/webrtc_interface.dart';

import 'event_channel.dart';
import 'local_audio_capture.dart';
import 'utils.dart';

/// Platform-channel implementation of the generation-scoped PCM bridge.
class LocalAudioCaptureBackend {
  Stream<LocalAudioCaptureEvent>? _events;

  bool get isSupported =>
      WebRTC.platformIsIOS ||
      WebRTC.platformIsMacOS ||
      WebRTC.platformIsAndroid ||
      WebRTC.platformIsWindows ||
      WebRTC.platformIsLinux;

  Stream<LocalAudioCaptureEvent> get events =>
      _events ??= FlutterWebRTCEventChannel.instance.handleEvents.stream
          .map((wrapped) {
            final map = wrapped.values.first;
            return decodeLocalAudioCaptureEvent(map);
          })
          .where((event) => event != null)
          .cast<LocalAudioCaptureEvent>();

  Future<LocalAudioCaptureStart> start({
    required LocalAudioProcessingProfile profile,
    MediaStreamTrack? track,
    String? trackId,
  }) async {
    final requestedClock = profile.toMap()['clockCorrection'];
    if (requestedClock != null) {
      if (!['off', 'observe', 'control'].contains(requestedClock)) {
        throw ArgumentError.value(requestedClock, 'clockCorrection');
      }
      final state = await getState();
      final processing = state['processingState'];
      final clock = processing is Map ? processing['clockCorrection'] : null;
      if (clock is! Map || clock['supported'] != true) {
        throw UnsupportedError(
            'Native clockCorrection API V1/ALSA is unavailable');
      }
    }
    final response = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
      'startLocalAudioCapture',
      <String, dynamic>{
        'profile': profile.toMap(),
        'trackId': trackId ?? track?.id,
      },
    );
    if (response == null) {
      throw StateError('startLocalAudioCapture returned no state');
    }
    if (requestedClock != null) {
      final processing = response['processingState'];
      final clock = processing is Map ? processing['clockCorrection'] : null;
      if (clock is! Map ||
          clock['supported'] != true ||
          clock['mode'] != requestedClock) {
        // Retire only the generation this call opened; never silently run a
        // requested policy that the native implementation did not acknowledge.
        final generation = (response['generation'] as num).toInt();
        try {
          await stop(generation);
        } catch (error) {
          throw LocalAudioCaptureStartCleanupException(
            generation: generation,
            cleanupError: error,
          );
        }
        throw StateError(
            'Native capture did not acknowledge clockCorrection=$requestedClock');
      }
    }
    return LocalAudioCaptureStart(
      generation: (response['generation'] as num).toInt(),
      requestedProfile: profile,
      processingState: Map<String, dynamic>.from(
        response['processingState'] as Map? ?? const {},
      ),
      platformVoiceProcessingAllowed:
          response['platformVoiceProcessingAllowed'] as bool? ?? false,
      voiceProcessingBypassed:
          response['voiceProcessingBypassed'] as bool? ?? false,
    );
  }

  Future<void> stop(int generation) => WebRTC.invokeMethod<void, dynamic>(
        'stopLocalAudioCapture',
        <String, dynamic>{'generation': generation},
      );

  Future<Map<String, dynamic>> getState() async {
    final response = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
      'getLocalAudioCaptureState',
      const <String, dynamic>{},
    );
    return Map<String, dynamic>.from(response ?? const {});
  }
}
