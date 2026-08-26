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
