// PCM sink only: no microphone, local peer, or capture permissions.
class FlutterWebRTCPcmPlayout extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.generation = options.processorOptions.generation;
    this.epoch = 0;
    this.ring = new Float32Array(120000);
    this.read = 0;
    this.size = 0;
    this.accepted = this.consumed = this.discarded = this.callbacks = this.underruns = 0;
    this.stopped = false;
    this.port.onmessage = ({data: m}) => {
      let error;
      if (m.generation !== this.generation || this.stopped) error = 'Stale PCM generation';
      else if (m.type === 'write') {
        if (m.epoch !== this.epoch) error = 'Stale PCM epoch';
        else if (!(m.pcm instanceof Uint8Array) || !m.pcm.length || m.pcm.length % 2 || m.pcm.length > 48000) error = 'Invalid PCM';
        else {
          const count = m.pcm.length / 2;
          if (count > this.ring.length - this.size) error = 'PCM backlog exceeds five seconds';
          else {
            const view = new DataView(m.pcm.buffer, m.pcm.byteOffset, m.pcm.byteLength);
            for (let i = 0; i < count; ++i) this.ring[(this.read + this.size + i) % this.ring.length] = view.getInt16(i * 2, true) / 32768;
            this.size += count;
            this.accepted += count;
          }
        }
      } else if (m.type === 'clear') {
        if (!Number.isSafeInteger(m.epoch) || m.epoch <= this.epoch) error = 'Stale PCM epoch';
        else { this.epoch = m.epoch; this.discarded += this.size; this.size = this.read = 0; }
      } else if (m.type === 'stop') {
        this.discarded += this.size;
        this.size = this.read = 0;
        this.stopped = true;
      } else if (m.type !== 'state') error = 'Unknown PCM operation';
      this.port.postMessage({id: m.id, error, state: {
        generation: this.stopped ? 0 : this.generation, epoch: this.epoch,
        queuedFrames: this.size, acceptedFrames: this.accepted, consumedFrames: this.consumed,
        discardedFrames: this.discarded, renderCallbacks: this.callbacks, underrunCallbacks: this.underruns,
      }});
    };
  }
  process(inputs, outputs) {
    const out = outputs[0]?.[0];
    if (!out) return !this.stopped;
    out.fill(0);
    if (this.stopped) return false;
    const count = Math.min(out.length, this.size);
    for (let i = 0; i < count; ++i) out[i] = this.ring[(this.read + i) % this.ring.length];
    this.read = (this.read + count) % this.ring.length;
    this.size -= count;
    this.consumed += count;
    ++this.callbacks;
    if (count < out.length) ++this.underruns;
    return true;
  }
}
registerProcessor('flutter-webrtc-pcm-playout', FlutterWebRTCPcmPlayout);
