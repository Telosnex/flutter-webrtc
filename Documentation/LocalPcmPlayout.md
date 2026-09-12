# PCM playout

`LocalPcmPlayout` accepts PCM16LE, mono, 24kHz. Native output is a source in
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

- One PCM owner per factory. Five-second native queue; overflow rejects the
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

Native pins now use the same-run published .09 artifacts across Apple, Android, Linux, and Windows. For local testing, C++ accepts a matching complete archive via
`TELOSNEX_LIBWEBRTC_ARCHIVE` plus `TELOSNEX_LIBWEBRTC_SHA256`; Android accepts
`TELOSNEX_WEBRTC_AAR` plus `TELOSNEX_WEBRTC_AAR_SHA256`. Both verify content hashes.
Do not replace one library under an old artifact identity.
