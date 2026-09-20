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
  static final _owners = <BrowserPcmPlayout, String>{};
  static Future<void> _lifecycle = Future.value();
  static Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _lifecycle.then((_) => operation());
    _lifecycle = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

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
    if (method == 'pcmPlayoutStart') return _serial(() => _start(args));
    if (args is! Map || args['generation'] != _generation || _generation == 0) {
      throw StateError('Stale PCM generation');
    }
    if (method == 'pcmPlayoutStop') {
      // Disconnect immediately even if the worklet/context is suspended. Do not
      // wait for an audio-thread ACK that cannot run during OS suspension.
      await stop();
      return <String, dynamic>{};
    }
    final output = _owner!;
    if (output._error != null) {
      throw StateError('Browser PCM processor failed: ${output._error}');
    }
    if (output._context?.state != 'running' || output._audio!.paused) {
      throw StateError('Browser output suspended');
    }
    final type = switch (method) {
      'pcmPlayoutWrite' => 'write',
      'pcmPlayoutClear' => 'clear',
      'pcmPlayoutState' => 'state',
      _ => throw UnsupportedError(method),
    };
    return output._request(type, args);
  }

  Future<Map> _start(dynamic args) async {
    if (!isSupported || _generation != 0) {
      throw StateError('PCM unavailable or already started');
    }
    if (args != null && args is! Map) {
      throw ArgumentError('Expected PCM arguments');
    }
    final params = args as Map? ?? {};
    final rate = params['sampleRate'] ?? 24000;
    final channels = params['channels'] ?? 1;
    final mode = params['ownershipMode'] ?? 'exclusive';
    if (!((rate == 24000 && channels == 1) ||
            (rate == 48000 && channels == 2)) ||
        !['exclusive', 'shared'].contains(mode)) {
      throw ArgumentError('Unsupported PCM format or mode');
    }
    if (_owners.isNotEmpty &&
        (mode == 'exclusive' || _owners.containsValue('exclusive'))) {
      throw StateError('PCM output already owned');
    }
    if (_owners.length >= 2) throw StateError('PCM source capacity exceeded');
    if (_owner != null && _owners.isEmpty) {
      throw StateError('Previous PCM output still requires cleanup');
    }
    if (_owner == null) {
      _owner = this;
      try {
        await _open();
      } catch (_) {
        await _close();
        rethrow;
      }
    }
    _generation = ++_nextGeneration;
    _owners[this] = mode as String;
    // Register before awaiting: a timed-out start can still create its source.
    // stop() must retain that token for cleanup without touching another owner.
    return _owner!._request('start', {
      'generation': _generation,
      'sampleRate': rate,
      'channels': channels,
      'ownershipMode': mode,
    });
  }

  Future<void> _open() async {
    try {
      final context = web.AudioContext(web.AudioContextOptions(
          sampleRate: 48000, latencyHint: 'interactive'.toJS));
      _context = context;
      if (context.sampleRate != 48000) {
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
              outputChannelCount: <JSNumber>[2.toJS].toJS));
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
    } catch (_) {
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

  Future<void> stop() => _serial(() async {
        if (!_owners.containsKey(this)) {
          if (_owners.isEmpty && identical(_owner, this)) await _close();
          return;
        }
        final output = _owner!;
        if (_owners.length == 1) {
          // The last owner can disconnect even while the context is suspended.
          await output._close();
        } else if (output._error == null) {
          // Never mute the shared element. Await only this source's removal.
          await output._request('stop', {'generation': _generation});
        }
        // A dead processor cannot acknowledge or render any source. Release
        // this token locally; other callers still observe the shared failure.
        _owners.remove(this);
        _generation = 0;
      });

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
    if (identical(_owner, this)) _owner = null;
    for (final pending in _pending.values) {
      pending.completeError(StateError('PCM output stopped'));
    }
    _pending.clear();
  }
}
