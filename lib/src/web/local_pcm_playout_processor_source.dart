// Embedded fallback for hosts that do not serve plugin assets.
const localPcmPlayoutProcessorSource = r'''
// Fixed 48k stereo output. Each owner keeps input-format frame counters.
// No microphone, peer, or capture permissions.
class FlutterWebRTCPcmPlayout extends AudioWorkletProcessor {
  constructor() {
    super();
    this.sources = new Map();
    this.lastGeneration = 0;
    this.gain = 1;
    // 32-tap Blackman-windowed sinc for the half-sample phase of 2x speech
    // interpolation. Integer phase is delayed 16 input frames. No linear
    // interpolation, rate drift, allocation, or transcendental math at render.
    this.half = new Float64Array(32);
    let total = 0;
    for (let i = 0; i < 32; ++i) {
      const x = i - 15.5;
      const window = 0.42 - 0.5 * Math.cos(2 * Math.PI * i / 31) + 0.08 * Math.cos(4 * Math.PI * i / 31);
      total += this.half[i] = Math.sin(Math.PI * x) / (Math.PI * x) * window;
    }
    for (let i = 0; i < 32; ++i) this.half[i] /= total;
    this.port.onmessage = ({data: m}) => {
      let error;
      let s = this.sources.get(m.generation);
      if (m.type === 'start') {
        const rate = m.sampleRate ?? 24000, channels = m.channels ?? 1;
        const mode = m.ownershipMode ?? 'exclusive';
        if (!Number.isSafeInteger(m.generation) || m.generation <= this.lastGeneration) error = 'Stale PCM generation';
        else if (!((rate === 24000 && channels === 1) || (rate === 48000 && channels === 2)) || !['shared', 'exclusive'].includes(mode)) error = 'Invalid PCM format or mode';
        else if (this.sources.size && (mode === 'exclusive' || [...this.sources.values()].some(v => v.mode === 'exclusive'))) error = 'PCM output already owned';
        else if (this.sources.size >= 2) error = 'PCM source capacity exceeded';
        else {
          this.lastGeneration = m.generation;
          s = {generation: m.generation, rate, channels, mode, epoch: 0,
            ring: new Float32Array(rate * channels * 5), capacity: rate * 5,
            read: 0, size: 0, accepted: 0, consumed: 0, discarded: 0,
            callbacks: 0, underruns: 0, history: new Float32Array(32), head: 0, phase: 0};
          this.sources.set(m.generation, s);
        }
      } else if (!s && m.type === 'stop' && Number.isSafeInteger(m.generation) && m.generation > 0 && m.generation <= this.lastGeneration) {
        // A stop acknowledgement can time out during suspension. Retry is safe
        // and cannot affect a new source because tokens are never reused.
      } else if (!s) error = 'Stale PCM generation';
      else if (m.type === 'write') {
        if (m.epoch !== s.epoch) error = 'Stale PCM epoch';
        else if (!(m.pcm instanceof Uint8Array) || !m.pcm.length || m.pcm.length % (2 * s.channels) || m.pcm.length > s.rate * s.channels * 2) error = 'Invalid PCM';
        else {
          const frames = m.pcm.length / (2 * s.channels);
          if (frames > s.capacity - s.size) error = 'PCM backlog exceeds five seconds';
          else {
            const view = new DataView(m.pcm.buffer, m.pcm.byteOffset, m.pcm.byteLength);
            for (let i = 0; i < frames * s.channels; ++i) s.ring[((s.read + s.size) * s.channels + i) % s.ring.length] = view.getInt16(i * 2, true) / 32768;
            s.size += frames; s.accepted += frames;
          }
        }
      } else if (m.type === 'clear' || m.type === 'stop') {
        if (m.type === 'clear' && (!Number.isSafeInteger(m.epoch) || m.epoch <= s.epoch)) error = 'Stale PCM epoch';
        else {
          s.discarded += s.size; s.size = s.read = s.head = s.phase = 0;
          s.history.fill(0);
          if (m.type === 'clear') s.epoch = m.epoch;
          else this.sources.delete(m.generation);
        }
      } else if (m.type !== 'state') error = 'Unknown PCM operation';
      this.port.postMessage({id: m.id, error, state: s ? {
        generation: m.type === 'stop' && !error ? 0 : s.generation, epoch: s.epoch,
        sampleRate: s.rate, channels: s.channels, ownershipMode: s.mode,
        queuedFrames: s.size, acceptedFrames: s.accepted, consumedFrames: s.consumed,
        discardedFrames: s.discarded, renderCallbacks: s.callbacks, underrunCallbacks: s.underruns,
      } : {}});
    };
  }
  process(inputs, outputs) {
    const [left, right] = outputs[0] ?? [];
    if (!left || !right) return true;
    left.fill(0); right.fill(0);
    for (const s of this.sources.values()) {
      let underrun = false;
      for (let i = 0; i < left.length; ++i) {
        if (s.rate === 48000) {
          if (!s.size) { underrun = true; continue; }
          left[i] += s.ring[s.read * 2]; right[i] += s.ring[s.read * 2 + 1];
          s.read = (s.read + 1) % s.capacity; --s.size; ++s.consumed;
        } else {
          if (s.phase === 0) {
            s.head = (s.head + 1) % 32;
            s.history[s.head] = s.size ? s.ring[s.read] : 0;
            if (s.size) { s.read = (s.read + 1) % s.capacity; --s.size; ++s.consumed; }
            else underrun = true;
          }
          let sample = s.history[(s.head + 16) % 32];
          if (s.phase) {
            sample = 0;
            for (let tap = 0; tap < 32; ++tap) sample += this.half[tap] * s.history[(s.head - tap + 32) % 32];
          }
          left[i] += sample; right[i] += sample;
          s.phase ^= 1;
        }
      }
      ++s.callbacks; if (underrun) ++s.underruns;
    }
    // Linked instantaneous attack, 50ms release. No owner-count attenuation.
    for (let i = 0; i < left.length; ++i) {
      const peak = Math.max(Math.abs(left[i]), Math.abs(right[i]));
      const ceiling = peak > 1 ? 1 / peak : 1;
      this.gain = Math.min(ceiling, this.gain + (1 - this.gain) / 2400);
      left[i] *= this.gain; right[i] *= this.gain;
    }
    return true;
  }
}
registerProcessor('flutter-webrtc-pcm-playout', FlutterWebRTCPcmPlayout);
''';
