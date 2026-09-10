#ifndef FLUTTER_WEBRTC_AUDIO_CLOCK_CORRECTION_H_
#define FLUTTER_WEBRTC_AUDIO_CLOCK_CORRECTION_H_

#include <flutter/encodable_value.h>
#include <string>
#include "rtc_audio_processing.h"

// Old pinned native artifacts remain buildable and explicitly unsupported.
// Publishing the new native header AND library enables this optional API.
#if __has_include("rtc_audio_clock_correction.h")
#include "rtc_audio_clock_correction.h"
#define FLUTTER_WEBRTC_CLOCK_CORRECTION_V1 1
#endif

namespace flutter_webrtc_plugin {
using flutter::EncodableMap;
using flutter::EncodableValue;
inline EncodableMap ClockCorrectionStateMap(libwebrtc::RTCAudioProcessing* apm) {
  EncodableMap result;
  result[EncodableValue("supported")] = EncodableValue(false);
  result[EncodableValue("apiVersion")] = EncodableValue(0);
#ifdef FLUTTER_WEBRTC_CLOCK_CORRECTION_V1
  result[EncodableValue("apiVersion")] = EncodableValue(1);
  const auto state = libwebrtc::GetAudioClockCorrectionStateV1(apm);
  result[EncodableValue("supported")] = EncodableValue(state.supported);
  const char* mode = state.mode == 0 ? "off" : state.mode == 1 ? "observe"
      : state.mode == 2 ? "control" : "legacyCallback";
  result[EncodableValue("mode")] = EncodableValue(mode);
  result[EncodableValue("locked")] = EncodableValue(state.capture_started);
  result[EncodableValue("engaged")] = EncodableValue(state.engaged);
  result[EncodableValue("hardwareReady")] = EncodableValue(state.hardware_ready);
  result[EncodableValue("hardwareControlling")] = EncodableValue(state.hardware_controlling);
  result[EncodableValue("appliedPpm")] = EncodableValue(state.applied_ppm);
#endif
  return result;
}

// Empty means success. Validate before changing any APM settings or acquiring
// recording. Omission intentionally preserves legacy environment policy.
inline std::string ConfigureCaptureClockCorrection(
    libwebrtc::RTCAudioProcessing* apm, const EncodableMap& profile) {
  const auto it = profile.find(EncodableValue("clockCorrection"));
  if (it == profile.end()) return {};
  if (!std::holds_alternative<std::string>(it->second))
    return "clockCorrection must be off, observe or control";
  const auto& mode = std::get<std::string>(it->second);
  if (mode != "off" && mode != "observe" && mode != "control")
    return "clockCorrection must be off, observe or control";
#ifdef FLUTTER_WEBRTC_CLOCK_CORRECTION_V1
  if (!libwebrtc::GetAudioClockCorrectionStateV1(apm).supported)
    return "clockCorrection requires the ALSA native audio backend";
  const auto policy = mode == "off" ? libwebrtc::AudioClockCorrectionMode::kOff
      : mode == "observe" ? libwebrtc::AudioClockCorrectionMode::kObserve
                          : libwebrtc::AudioClockCorrectionMode::kControl;
  const int status = libwebrtc::ConfigureAudioClockCorrectionV1(apm, policy);
  if (status == 0) return {};
  if (status == -2)
    return "clockCorrection is locked after first capture; restart WebRTC to change it";
  return "Native clockCorrection configuration failed";
#else
  return "clockCorrection requires a newer libwebrtc artifact (API V1)";
#endif
}
}  // namespace flutter_webrtc_plugin
#endif
