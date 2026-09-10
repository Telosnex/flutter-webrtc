// Assertions are release qualification gates, not debug-only checks.
#undef NDEBUG
#include "flutter_audio_clock_correction.h"
#include <cassert>

#ifdef FLUTTER_WEBRTC_CLOCK_CORRECTION_V1
namespace libwebrtc {
AudioClockCorrectionState state;
int configure_status = 0;
int configure_calls = 0;
AudioClockCorrectionState GetAudioClockCorrectionStateV1(RTCAudioProcessing*) {
  return state;
}
int ConfigureAudioClockCorrectionV1(RTCAudioProcessing*, AudioClockCorrectionMode mode) {
  ++configure_calls;
  if (configure_status == 0) state.mode = static_cast<int>(mode);
  return configure_status;
}
}
#endif

int main() {
  using namespace flutter_webrtc_plugin;
  assert(ConfigureCaptureClockCorrection(nullptr, {}).empty());
  assert(!ConfigureCaptureClockCorrection(nullptr, {
    {EncodableValue("clockCorrection"), EncodableValue(42)}}).empty());
  assert(!ConfigureCaptureClockCorrection(nullptr, {
    {EncodableValue("clockCorrection"), EncodableValue("auto")}}).empty());
  EncodableMap profile{{EncodableValue("clockCorrection"), EncodableValue("control")}};
#ifdef FLUTTER_WEBRTC_CLOCK_CORRECTION_V1
  assert(!ConfigureCaptureClockCorrection(nullptr, profile).empty());
  assert(libwebrtc::configure_calls == 0);  // unsupported doesn't mutate
  libwebrtc::state.supported = true;
  assert(ConfigureCaptureClockCorrection(nullptr, profile).empty());
  auto readback = ClockCorrectionStateMap(nullptr);
  assert(std::get<std::string>(readback[EncodableValue("mode")]) == "control");
  assert(std::get<int32_t>(readback[EncodableValue("apiVersion")]) == 1);
  libwebrtc::configure_status = -2;
  assert(ConfigureCaptureClockCorrection(nullptr, profile).find("locked") != std::string::npos);
  libwebrtc::configure_status = -1;
  assert(!ConfigureCaptureClockCorrection(nullptr, profile).empty());
#else
  auto readback = ClockCorrectionStateMap(nullptr);
  assert(!std::get<bool>(readback[EncodableValue("supported")]));
  assert(std::get<int32_t>(readback[EncodableValue("apiVersion")]) == 0);
  assert(ConfigureCaptureClockCorrection(nullptr, profile).find("newer") != std::string::npos);
#endif
}
