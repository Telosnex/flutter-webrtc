// Keep this fallback in sync with assets/local_audio_capture_processor.js.
// A VM test enforces byte-for-byte parity.
const localAudioCaptureProcessorSource =
    r'''// Read-only Web Audio sink for Telosnex's generation-scoped local PCM tap.
// The browser's getUserMedia track has already passed through its selected
// capture processing. This processor only downmixes/copies it; it never changes
// the MediaStreamTrack borrowed by RTCRtpSender.
class FlutterWebRTCLocalAudioCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const requestedBatchMs = options.processorOptions?.batchMs ?? 20;
    this.batchFrames = Math.max(128, Math.round(sampleRate * requestedBatchMs / 1000));
    this.offset = 0;
    this.sequence = 0;
    this.droppedFrames = 0;
    this.inputChannels = 0;
    this.stopped = false;
    this.buffers = [];
    for (let index = 0; index < 8; index += 1) {
      this.buffers.push(new Int16Array(this.batchFrames));
    }
    this.current = this.buffers.pop();
    this.port.onmessage = (event) => {
      if (event.data?.type === 'recycle' && event.data.buffer) {
        this.buffers.push(new Int16Array(event.data.buffer));
      } else if (event.data?.type === 'stop') {
        this.stopped = true;
      }
    };
  }

  process(inputs) {
    if (this.stopped) return false;
    const channels = inputs[0];
    if (!channels || channels.length === 0 || channels[0].length === 0) {
      return true;
    }
    if (this.inputChannels !== channels.length) {
      this.inputChannels = channels.length;
      this.port.postMessage({
        type: 'format',
        sampleRateHz: sampleRate,
        channels: 1,
        inputChannels: this.inputChannels,
        encoding: 'pcmS16le',
      });
    }

    const quantumFrames = channels[0].length;
    for (let frame = 0; frame < quantumFrames; frame += 1) {
      let mono = 0;
      for (let channel = 0; channel < channels.length; channel += 1) {
        mono += channels[channel][frame] ?? 0;
      }
      mono /= channels.length;
      mono = Math.max(-1, Math.min(1, mono));
      this.current[this.offset++] = mono < 0
        ? Math.round(mono * 32768)
        : Math.round(mono * 32767);

      if (this.offset !== this.batchFrames) continue;
      const completed = this.current;
      const replacement = this.buffers.pop();
      if (!replacement) {
        // The main thread has not returned a buffer. Preserve realtime behavior
        // by dropping this local copy; the sender's source track is unaffected.
        this.droppedFrames += this.batchFrames;
        this.offset = 0;
        completed.fill(0);
        continue;
      }
      this.current = replacement;
      this.offset = 0;
      const buffer = completed.buffer;
      this.port.postMessage({
        type: 'frames',
        sequence: this.sequence++,
        frameCount: this.batchFrames,
        droppedFrames: this.droppedFrames,
        buffer,
      }, [buffer]);
      this.droppedFrames = 0;
    }
    return true;
  }
}

registerProcessor(
  'flutter-webrtc-local-audio-capture',
  FlutterWebRTCLocalAudioCaptureProcessor,
);
''';
