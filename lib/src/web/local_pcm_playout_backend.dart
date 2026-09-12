import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:web/web.dart' as web;
import 'local_pcm_playout_processor_source.dart';

/// Browser equivalent: bounded PCM worklet -> MediaStream -> HTMLAudioElement,
/// like RTCVideoRenderer audio. Browsers expose NO native APM reverse-feed API;
/// this supplies route parity, not an assertion of browser AEC equivalence.
class BrowserPcmPlayout {
  static BrowserPcmPlayout? _owner;
  static int _nextGeneration = 0;
  static String _output = '';
  int _generation = 0;
  int _id = 0;
  final _pending = <int, Completer<Map>>{};
  web.AudioContext? _context;
  web.AudioWorkletNode? _node;
  web.MediaStreamAudioDestinationNode? _destination;
  web.HTMLAudioElement? _audio;
  Object? _error;

  static bool get isSupported =>
      web.window.isSecureContext &&
      web.window.hasProperty('AudioWorkletNode'.toJS).toDart;

  static Future<void> selectAudioOutput(String deviceId) async {
    final owner = _owner;
    if (owner?._audio != null) {
      await owner!._setOutput(deviceId);
    } else if (deviceId.isNotEmpty &&
        !web.HTMLAudioElement().hasProperty('setSinkId'.toJS).toDart) {
      throw UnsupportedError('Browser does not support output selection');
    }
    _output = deviceId; // Keep last successful selection for the next owner.
  }

  Future<void> _setOutput(String deviceId) async {
    final audio = _audio!;
    if (!audio.hasProperty('setSinkId'.toJS).toDart) {
      if (deviceId.isEmpty) return;
      throw UnsupportedError('Browser does not support output selection');
    }
    await (audio.callMethod('setSinkId'.toJS, deviceId.toJS) as JSPromise)
        .toDart;
  }

  Future<dynamic> invoke(String method, [dynamic args]) async {
    if (method == 'pcmPlayoutStart') return _start();
    if (args is! Map || args['generation'] != _generation || _generation == 0) {
      throw StateError('Stale PCM generation');
    }
    if (method == 'pcmPlayoutStop') {
      // Disconnect immediately even if the worklet/context is suspended. Do not
      // wait for an audio-thread ACK that cannot run during OS suspension.
      await _close();
      return <String, dynamic>{};
    }
    if (_error != null) {
      throw StateError('Browser PCM processor failed: $_error');
    }
    if (_context?.state != 'running' || _audio!.paused) {
      throw StateError('Browser output suspended');
    }
    final type = switch (method) {
      'pcmPlayoutWrite' => 'write',
      'pcmPlayoutClear' => 'clear',
      'pcmPlayoutState' => 'state',
      _ => throw UnsupportedError(method),
    };
    if (type == 'clear') _audio!.muted = true;
    try {
      return await _request(type, args);
    } finally {
      if (type == 'clear') _audio?.muted = false;
    }
  }

  Future<Map> _start() async {
    if (!isSupported || _owner != null) {
      throw StateError('Browser PCM unavailable or already owned');
    }
    _owner = this;
    _generation = ++_nextGeneration;
    try {
      // Browser resamples 24kHz render to hardware rate; no linear JS resampler.
      final context = web.AudioContext(web.AudioContextOptions(
          sampleRate: 24000, latencyHint: 'interactive'.toJS));
      _context = context;
      if (context.sampleRate != 24000) {
        throw StateError('Browser rejected PCM render rate');
      }
      final module = Uri.parse(web.document.baseURI)
          .resolve(
              'assets/packages/flutter_webrtc/assets/local_pcm_playout_processor.js')
          .toString();
      try {
        await context.audioWorklet.addModule(module).toDart;
      } catch (_) {
        final blob = web.Blob(
            <JSString>[localPcmPlayoutProcessorSource.toJS].toJS,
            web.BlobPropertyBag(type: 'text/javascript'));
        final url = web.URL.createObjectURL(blob);
        try {
          await context.audioWorklet.addModule(url).toDart;
        } finally {
          web.URL.revokeObjectURL(url);
        }
      }
      final node = web.AudioWorkletNode(
          context,
          'flutter-webrtc-pcm-playout',
          web.AudioWorkletNodeOptions(
              numberOfInputs: 0,
              numberOfOutputs: 1,
              outputChannelCount: <JSNumber>[1.toJS].toJS,
              processorOptions:
                  {'generation': _generation}.jsify()! as JSObject));
      _node = node;
      node.port.onmessage = ((web.MessageEvent event) {
        final data = event.data.dartify();
        if (data is! Map) return;
        final pending = _pending.remove(data['id']);
        if (pending == null) return;
        if (data['error'] != null) {
          pending.completeError(StateError(data['error'] as String));
        } else {
          pending.complete(data['state'] as Map);
        }
      }).toJS;
      node.onprocessorerror = ((web.Event _) {
        _error = 'AudioWorklet failed';
      }).toJS;
      final destination = context.createMediaStreamDestination();
      _destination = destination;
      node.connect(destination);
      final audio = web.HTMLAudioElement()
        ..srcObject = destination.stream
        ..autoplay = true;
      _audio = audio;
      // No microphone track; no RTP/loopback connection and no extra capture.
      web.document.body?.append(audio);
      await _setOutput(_output);
      await context.resume().toDart.timeout(const Duration(seconds: 3));
      await audio.play().toDart.timeout(const Duration(seconds: 3));
      if (context.state != 'running' || audio.paused) {
        throw StateError('Start PCM from a user gesture');
      }
      return await _request('state', {'generation': _generation});
    } catch (_) {
      await _close();
      rethrow;
    }
  }

  Future<Map> _request(String type, Map args) async {
    final id = ++_id;
    final reply = Completer<Map>();
    _pending[id] = reply;
    _node!.port.postMessage({...args, 'id': id, 'type': type}.jsify());
    try {
      final state = await reply.future.timeout(const Duration(seconds: 2));
      return <String, dynamic>{
        ...state.cast<String, dynamic>(),
        'playing': _context?.state == 'running' && !(_audio?.paused ?? true),
        'delayMs': -1,
        'backend': 'browserMediaElement',
        'aecReferenceVerified': false
      };
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> stop() => _close();

  Future<void> _close() async {
    _audio?.pause();
    _audio?.srcObject = null;
    _node?.disconnect();
    _node?.port.close();
    for (final track in _destination?.stream.getTracks().toDart ??
        <web.MediaStreamTrack>[]) {
      track.stop();
    }
    _audio?.remove();
    // Retain ownership on close failure for retry rather than admitting a second player.
    if (_context != null && _context!.state != 'closed') {
      await _context!.close().toDart.timeout(const Duration(seconds: 3));
    }
    _context = null;
    _node = null;
    _destination = null;
    _audio = null;
    _generation = 0;
    if (identical(_owner, this)) _owner = null;
    for (final pending in _pending.values) {
      pending.completeError(StateError('PCM output stopped'));
    }
    _pending.clear();
  }
}
