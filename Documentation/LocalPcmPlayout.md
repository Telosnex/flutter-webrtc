# PCM playout

`LocalPcmPlayout` defaults to PCM16LE, mono, 24kHz, with exclusive ownership.
The concurrent extension also accepts 48kHz stereo. Native output is a source in
WebRTC's render mixer: the same ADM, output routing, and APM render reference as
RTP audio. It does not open the microphone.

```dart
if (await LocalPcmPlayout.isSupported()) {
  final output = LocalPcmPlayout();
  await output.start();
  await output.write(pcm16le); // <=48,000 bytes per call; copied on submission
  await output.clear();      // invalidates pending writes and queued audio
  await output.stop();       // retry on the same object if native stop fails
}
```

- Exclusive ownership by default. Five-second native queue per owner; overflow rejects the
  entire write rather than dropping speech. Generation/epoch checks reject
  stale input. Hardware-buffered samples cannot be recalled by `clear()`.
- `getState()` reports mixer consumption and estimated ADM delay, not exact
  hardware-played timestamps. Native stop quiesces even if device stop fails,
  retains ownership for retry, and cannot stop another receiver or capture.
- Apple and Android use factory-owned media-engine lifetime; no peer is needed.
  The initial C++ bridge retains its empty, unnegotiated engine anchor.
- Native builds require the matching PCM-enabled SDK/header/library. Older
  binaries return unsupported so callers can retain their previous player.
  Operational failures must not silently select another device/player.
- Browser output uses a bounded AudioWorklet -> MediaStream -> HTMLAudioElement,
  like the browser RTC renderer. **Browsers do not expose native APM reverse
  input; AEC reference coverage is browser-controlled and not guaranteed.**
  No local peer loopback or microphone is created. Start from an allowed user
  gesture; autoplay, suspension, and output-selection failures are errors.
- `LocalPcmPlayout.selectAudioOutput` / `Helper.selectAudioOutput` route PCM.
  Browser support for non-default outputs depends on `setSinkId`; existing RTC
  renderer output selection remains renderer-local.

Native pins use the same-run published `.10` artifacts across Apple, Android,
Linux, and Windows. For local testing, C++ accepts a matching complete archive via
`TELOSNEX_LIBWEBRTC_ARCHIVE` plus `TELOSNEX_LIBWEBRTC_SHA256`; Android accepts
`TELOSNEX_WEBRTC_AAR` plus `TELOSNEX_WEBRTC_AAR_SHA256`. Both verify content hashes.
Do not replace one library under an old artifact identity.

## Concurrent format-aware playout

```dart
if (await LocalPcmPlayout.isSupported(
    sampleRate: 48000, channels: 2, ownership: LocalPcmOwnership.shared)) {
  final music = LocalPcmPlayout(sampleRate: 48000, channels: 2,
      ownership: LocalPcmOwnership.shared);
  final speech = LocalPcmPlayout(ownership: LocalPcmOwnership.shared);
  // Each caller acquires, writes, clears, drains, and stops its own object.
  // Stopping speech does not stop music. Both callers must stop in finally.
}
```

- At most two shared sources per factory. Exclusive sources conflict with both.
- Shared input formats are 24kHz mono and 48kHz interleaved stereo PCM16LE.
  One frame contains all channels. Each write contains complete frames and at
  most one second. Pending and native queues each hold at most five seconds.
- The mixer resamples mono speech and places it in both channels. Stereo music
  retains channel separation on a stereo-capable device route. The browser uses
  a stable 48kHz stereo graph, sinc speech interpolation, and a linked peak limiter.
- `supportedFormats` and `maxSharedSources` extend version-one capabilities.
  An absent extension means legacy exclusive speech only. Non-default starts
  return their accepted format and ownership mode for caller verification.
- Native support requires matching `.10` or newer binaries containing
  `concurrent_pcm_playout.patch` from the native repository.
