import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:dart_webrtc/src/media_stream_track_impl.dart';
import 'package:web/web.dart' as web;
import 'package:webrtc_interface/webrtc_interface.dart';

import '../native/local_audio_capture.dart';
import 'local_audio_capture_processor_source.dart';

const _processorName = 'flutter-webrtc-local-audio-capture';
const _processorAsset =
    'assets/packages/flutter_webrtc/assets/local_audio_capture_processor.js';

/// Browser implementation backed by the controller-owned getUserMedia track.
///
/// The same browser-processed track feeds this Web Audio graph and any RTP
/// sender. This graph is a read-only sink and never creates a second capture.
class LocalAudioCaptureBackend {
  final StreamController<LocalAudioCaptureEvent> _events =
      StreamController<LocalAudioCaptureEvent>.broadcast(sync: true);

  _WebCaptureRun? _active;
  _WebCaptureRun? _stoppingRun;
  int _nextGeneration = 1;
  int? _lastStoppedGeneration;

  bool get isSupported =>
      web.window.isSecureContext &&
      web.window.hasProperty('AudioWorkletNode'.toJS).toDart;

  Stream<LocalAudioCaptureEvent> get events => _events.stream;

  Future<LocalAudioCaptureStart> start({
    required LocalAudioProcessingProfile profile,
    MediaStreamTrack? track,
    String? trackId,
  }) async {
    if (_active != null || _stoppingRun != null) {
      throw StateError('A local audio capture generation is already active');
    }
    if (track is! MediaStreamTrackWeb || track.kind != 'audio') {
      throw ArgumentError.value(
        track,
        'track',
        'Web capture requires the controller-owned browser audio track',
      );
    }
    if (track.jsTrack.readyState != 'live') {
      throw StateError('The browser audio track is not live');
    }

    await track.applyConstraints(<String, dynamic>{
      'echoCancellation': profile.echoCancellation,
      'noiseSuppression': profile.noiseSuppression,
      'autoGainControl': profile.autoGainControl,
      'channelCount': 1,
    });
    final settings = track.getSettings();
    final processingState = _processingState(profile, settings);
    final context = web.AudioContext(
      web.AudioContextOptions(latencyHint: 'interactive'.toJS),
    );
    final generation = _nextGeneration++;
    _WebCaptureRun? run;
    try {
      final moduleUrl = Uri.parse(
        web.document.baseURI,
      ).resolve(_processorAsset).toString();
      await _loadProcessor(context, moduleUrl);
      await context.resume().toDart;
      if (context.state != 'running') {
        throw StateError(
          'AudioContext is ${context.state}; start capture from a user gesture',
        );
      }

      final jsStream = web.MediaStream(
        <web.MediaStreamTrack>[track.jsTrack].toJS,
      );
      final source = context.createMediaStreamSource(jsStream);
      final node = web.AudioWorkletNode(
        context,
        _processorName,
        web.AudioWorkletNodeOptions(
          channelCount: 1,
          channelCountMode: 'explicit',
          numberOfInputs: 1,
          numberOfOutputs: 0,
          processorOptions:
              <String, JSAny?>{'batchMs': 20.toJS}.jsify()! as JSObject,
        ),
      );
      final createdRun = _WebCaptureRun(
        generation: generation,
        processingState: processingState,
        track: track,
        jsStream: jsStream,
        context: context,
        source: source,
        node: node,
      );
      run = createdRun;
      _active = createdRun;
      node.port.onmessage = ((web.MessageEvent event) {
        _onWorkletMessage(createdRun, event);
      }).toJS;
      node.onprocessorerror = ((web.Event event) {
        if (identical(_active, createdRun)) {
          _events.addError(
            StateError('The local audio AudioWorklet processor failed'),
          );
        }
      }).toJS;
      context.onstatechange = ((web.Event event) {
        if (identical(_active, createdRun) &&
            !createdRun.stopping &&
            context.state != 'running') {
          _events.addError(
            StateError('AudioContext changed to ${context.state}'),
          );
        }
      }).toJS;
      createdRun.trackEndedListener = ((web.Event event) {
        if (identical(_active, createdRun)) {
          unawaited(_stopRun(createdRun, reason: 'trackEnded'));
        }
      }).toJS;
      track.jsTrack.addEventListener('ended', createdRun.trackEndedListener);
      source.connect(node);

      final observedValues = <bool>[
        if (settings['echoCancellation'] case final bool value) value,
        if (settings['noiseSuppression'] case final bool value) value,
        if (settings['autoGainControl'] case final bool value) value,
      ];
      final requestedProcessing = profile.echoCancellation ||
          profile.noiseSuppression ||
          profile.autoGainControl;
      return LocalAudioCaptureStart(
        generation: generation,
        requestedProfile: profile,
        processingState: processingState,
        platformVoiceProcessingAllowed: observedValues.any((value) => value),
        voiceProcessingBypassed: requestedProcessing &&
            observedValues.isNotEmpty &&
            observedValues.every((value) => !value),
      );
    } catch (error, stack) {
      try {
        if (run case final createdRun?) {
          await _stopRun(createdRun, reason: 'startFailed');
        } else {
          await context.close().toDart;
        }
      } catch (_) {
        // Preserve the startup failure rather than replacing it with cleanup.
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> _loadProcessor(
    web.AudioContext context,
    String moduleUrl,
  ) async {
    try {
      await context.audioWorklet.addModule(moduleUrl).toDart;
      return;
    } catch (_) {
      // Flutter's browser test server does not expose package assets at the
      // production URL. Retry the byte-identical checked fallback as a blob;
      // production and CSP-restricted apps stay on the static URL above.
      final blob = web.Blob(
        <JSString>[localAudioCaptureProcessorSource.toJS].toJS,
        web.BlobPropertyBag(type: 'text/javascript'),
      );
      final blobUrl = web.URL.createObjectURL(blob);
      try {
        await context.audioWorklet.addModule(blobUrl).toDart;
      } finally {
        web.URL.revokeObjectURL(blobUrl);
      }
    }
  }

  Future<void> stop(int generation) async {
    final active = _active;
    final stopping = _stoppingRun;
    final run = active?.generation == generation
        ? active
        : stopping?.generation == generation
            ? stopping
            : null;
    if (run == null && _lastStoppedGeneration == generation) return;
    if (run == null || run.generation != generation) {
      throw StateError('Capture generation $generation is no longer active');
    }
    await _stopRun(run, reason: 'requested');
  }

  Future<Map<String, dynamic>> getState() async {
    final run = _active;
    if (run == null) {
      return const <String, dynamic>{
        'active': false,
        'recording': false,
        'externalRecordingDemand': false,
        'browserCaptureDemand': false,
      };
    }
    return <String, dynamic>{
      'active': true,
      'generation': run.generation,
      'recording': run.track.jsTrack.readyState == 'live',
      'externalRecordingDemand': false,
      'browserCaptureDemand': true,
      'trackId': run.track.id,
      'audioContextState': run.context.state,
      'sampleRateHz': run.context.sampleRate.round(),
      'processingState': run.processingState,
    };
  }

  void _onWorkletMessage(_WebCaptureRun run, web.MessageEvent event) {
    if (!identical(_active, run) || run.stopping) return;
    final dartData = event.data.dartify();
    if (dartData is! Map) return;
    final data = dartData.cast<String, Object?>();
    final type = data['type'];
    switch (type) {
      case 'format':
        final sampleRate = (data['sampleRateHz'] as num).toInt();
        _events.add(
          LocalAudioFormatEvent(
            generation: run.generation,
            sampleRateHz: sampleRate,
            channels: (data['channels'] as num).toInt(),
            inputChannels: (data['inputChannels'] as num).toInt(),
            encoding: data['encoding'] as String,
          ),
        );
      case 'frames':
        final buffer = data['buffer'] as ByteBuffer;
        // Copy before returning the transferable buffer to the realtime pool.
        final pcm = Uint8List.fromList(buffer.asUint8List());
        _events.add(
          LocalAudioFrameEvent(
            generation: run.generation,
            sequence: (data['sequence'] as num).toInt(),
            frameCount: (data['frameCount'] as num).toInt(),
            droppedFrames: (data['droppedFrames'] as num).toInt(),
            pcm16: pcm,
          ),
        );
        if (identical(_active, run) && !run.stopping) {
          final jsBuffer = buffer.toJS;
          run.node.port.postMessage(
            <String, JSAny?>{
              'type': 'recycle'.toJS,
              'buffer': jsBuffer,
            }.jsify(),
            <JSObject>[jsBuffer].toJS,
          );
        }
    }
  }

  Future<void> _stopRun(
    _WebCaptureRun run, {
    required String reason,
  }) {
    final existing = run.stopWork;
    if (existing != null) return existing;
    run.stopping = true;
    final operation = _performStop(run, reason: reason);
    run.stopWork = operation;
    return operation;
  }

  Future<void> _performStop(
    _WebCaptureRun run, {
    required String reason,
  }) async {
    if (identical(_active, run)) _active = null;
    _stoppingRun = run;
    run.track.jsTrack.removeEventListener('ended', run.trackEndedListener);
    run.context.onstatechange = null;
    run.node.onprocessorerror = null;
    run.node.port.onmessage = null;
    try {
      run.node.port.postMessage(
        <String, JSAny?>{'type': 'stop'.toJS}.jsify(),
      );
      run.source.disconnect();
      run.node.disconnect();
      run.jsStream.removeTrack(run.track.jsTrack);
      run.node.port.close();
      await run.context.close().toDart;
    } finally {
      if (identical(_stoppingRun, run)) _stoppingRun = null;
      _lastStoppedGeneration = run.generation;
      _events.add(
        LocalAudioStoppedEvent(
          generation: run.generation,
          reason: reason,
        ),
      );
    }
  }

  Map<String, dynamic> _processingState(
    LocalAudioProcessingProfile profile,
    Map<String, dynamic> settings,
  ) =>
      <String, dynamic>{
        'implementation': 'browserMediaTrack',
        'echoCancellation': _componentState(
          requested: profile.echoCancellation,
          resolved: settings['echoCancellation'],
        ),
        'noiseSuppression': _componentState(
          requested: profile.noiseSuppression,
          resolved: settings['noiseSuppression'],
        ),
        'autoGainControl': _componentState(
          requested: profile.autoGainControl,
          resolved: settings['autoGainControl'],
        ),
        'highPassFilter': <String, dynamic>{
          'requested': profile.highPassFilter,
          'resolved': null,
          'active': null,
          'observable': false,
        },
        'settings': Map<String, dynamic>.from(settings),
      };

  Map<String, dynamic> _componentState({
    required bool requested,
    required Object? resolved,
  }) =>
      <String, dynamic>{
        'requested': requested,
        'resolved': resolved is bool ? resolved : null,
        'active': resolved is bool ? resolved : null,
        'observable': resolved is bool,
      };
}

class _WebCaptureRun {
  _WebCaptureRun({
    required this.generation,
    required this.processingState,
    required this.track,
    required this.jsStream,
    required this.context,
    required this.source,
    required this.node,
  });

  final int generation;
  final Map<String, dynamic> processingState;
  final MediaStreamTrackWeb track;
  final web.MediaStream jsStream;
  final web.AudioContext context;
  final web.MediaStreamAudioSourceNode source;
  final web.AudioWorkletNode node;
  web.EventHandler trackEndedListener;
  bool stopping = false;
  Future<void>? stopWork;
}
