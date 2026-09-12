import 'dart:async';
import 'local_pcm_playout_backend_stub.dart'
    if (dart.library.js_interop) '../web/local_pcm_playout_backend.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'factory_impl.dart'
    if (dart.library.js_interop) '../web/factory_impl.dart';
import 'utils.dart' if (dart.library.js_interop) '../web/utils.dart';

/// Native mixer queue counters, not a claim that hardware has played samples.
class LocalPcmPlayoutState {
  LocalPcmPlayoutState.fromMap(Map<dynamic, dynamic> map)
      : generation = (map['generation'] as num).toInt(),
        epoch = (map['epoch'] as num).toInt(),
        queuedFrames = (map['queuedFrames'] as num).toInt(),
        consumedFrames = (map['consumedFrames'] as num).toInt(),
        renderCallbacks = (map['renderCallbacks'] as num).toInt(),
        playing = map['playing'] as bool,
        delayMs = (map['delayMs'] as num).toInt();
  final int generation, epoch, queuedFrames, consumedFrames, renderCallbacks;
  final bool playing;
  final int delayMs;
}

/// V1 app-owned PCM16LE / mono / 24kHz input to native WebRTC's render mixer.
/// Web uses a browser media element; browser AEC reference coverage is opaque.
/// No microphone, SDP, remote peer, encoder, network audio or loopback.
/// Unsupported platforms report false; operational failures are NOT fallback.
class LocalPcmPlayout {
  LocalPcmPlayout({Future<RTCPeerConnection> Function()? createAnchor})
      : _createAnchor =
            createAnchor ?? (() => createPeerConnection({'iceServers': []}));
  final Future<RTCPeerConnection> Function() _createAnchor;
  final _browser = BrowserPcmPlayout();
  Future<dynamic> _invoke(String method, [dynamic args]) => kIsWeb
      ? _browser.invoke(method, args)
      : WebRTC.invokeMethod(method, args);

  /// Uses the same route API as RTC output. Web routes this browser PCM owner.
  static Future<void> selectAudioOutput(String deviceId) async {
    if (kIsWeb) {
      await BrowserPcmPlayout.selectAudioOutput(deviceId);
      return;
    }
    await WebRTC.invokeMethod('selectAudioOutput', {'deviceId': deviceId});
  }

  RTCPeerConnection? _anchor;
  int? _generation;
  int _epoch = 0;
  int _pendingBytes = 0;
  bool _stopping = false;
  bool _starting = false;
  Future<void> _tail = Future.value();

  static Future<bool> isSupported() async {
    if (kIsWeb) return BrowserPcmPlayout.isSupported;
    try {
      final value = await WebRTC.invokeMethod('pcmPlayoutCapabilities');
      return value is Map &&
          value['version'] == 1 &&
          value['sampleRate'] == 24000 &&
          value['channels'] == 1;
    } on MissingPluginException {
      return false;
    }
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _tail.then((_) => work());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> start() async {
    if (_starting || _generation != null || _anchor != null || _stopping) {
      throw StateError('PCM output owner already started or stopping');
    }
    _starting = true;
    try {
      if (!await isSupported()) {
        throw UnsupportedError('Native PCM playout unavailable');
      }
      // M144 lazily creates/owns its shared media engine through a Call.
      // This empty, unnegotiated lifetime anchor pins that engine; actual PCM
      // plays directly through a mixer source, never through this connection.
      if (!kIsWeb) {
        final caps = await WebRTC.invokeMethod('pcmPlayoutCapabilities');
        if (caps is! Map || caps['requiresAnchor'] != false) {
          _anchor = await _createAnchor();
        }
      }
      final raw = await _invoke('pcmPlayoutStart');
      if (raw is Map &&
          raw['generation'] is num &&
          (raw['generation'] as num) > 0) {
        _generation = (raw['generation'] as num).toInt();
      }
      final state = LocalPcmPlayoutState.fromMap(raw as Map);
      if (state.generation <= 0) throw StateError('Invalid PCM generation');
      _generation = state.generation;
      _epoch = state.epoch;
    } catch (_) {
      if (kIsWeb) await _browser.stop();
      if (!kIsWeb && _generation != null) {
        await _invoke('pcmPlayoutStop', {'generation': _generation});
        _generation = null;
      }
      await _releaseAnchor();
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> write(Uint8List pcm) {
    if (_generation == null || _stopping) {
      return Future.error(StateError('PCM output not active'));
    }
    if (pcm.isEmpty || pcm.length.isOdd || pcm.length > 48000) {
      return Future.error(
          ArgumentError('Expected 1–24000 complete PCM16 frames'));
    }
    if (_pendingBytes + pcm.length > 240000) {
      return Future.error(StateError('Pending PCM exceeds 5 seconds'));
    }
    // Caller may reuse its input immediately after invoking this method.
    final bytes = Uint8List.fromList(pcm);
    final epoch = _epoch;
    _pendingBytes += bytes.length;
    return _serial(() async {
      try {
        if (_stopping || epoch != _epoch) return;
        await _invoke('pcmPlayoutWrite',
            {'generation': _generation, 'epoch': epoch, 'pcm': bytes});
      } finally {
        _pendingBytes -= bytes.length;
      }
    });
  }

  Future<void> clear() {
    if (_generation == null || _stopping) {
      return Future.error(StateError('PCM output not active'));
    }
    final epoch = ++_epoch; // Invalidates pending writes before any await.
    return _serial(() async {
      if (_stopping) return;
      await _invoke(
          'pcmPlayoutClear', {'generation': _generation, 'epoch': epoch});
    });
  }

  Future<LocalPcmPlayoutState> getState() => _serial(() async {
        if (_generation == null || _stopping) {
          throw StateError('PCM output not active');
        }
        final raw =
            await _invoke('pcmPlayoutState', {'generation': _generation});
        return LocalPcmPlayoutState.fromMap(raw as Map);
      });

  /// Clear/release only this output. Failed native stop retains its owner and
  /// anchor, rejects further writes and permits retry; never kills shared mic.
  Future<void> stop() {
    if (_starting) {
      return Future.error(StateError('Await PCM start before stop'));
    }
    _stopping = true;
    ++_epoch;
    return _serial(() async {
      if (kIsWeb) {
        await _browser.stop();
        _generation = null;
      }
      if (_generation != null) {
        await _invoke('pcmPlayoutStop', {'generation': _generation});
        _generation = null;
      }
      await _releaseAnchor();
    });
  }

  Future<void> _releaseAnchor() async {
    final anchor = _anchor;
    if (anchor == null) return;
    await anchor.close();
    await anchor.dispose();
    _anchor = null;
  }
}
