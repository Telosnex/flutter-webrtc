#include "flutter_local_audio_capture.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <string>
#include <vector>

using flutter_webrtc_plugin::FlutterLocalAudioCapture;

namespace {

std::string EventName(const EncodableMap& event) {
  const auto value = event.find(EncodableValue("event"));
  return value != event.end() && TypeIs<std::string>(value->second)
             ? GetValue<std::string>(value->second)
             : std::string();
}

}  // namespace

int main() {
  std::mutex mutex;
  std::condition_variable condition;
  std::vector<EncodableMap> events;
  FlutterLocalAudioCapture capture([&](const EncodableMap& event) {
    std::lock_guard<std::mutex> lock(mutex);
    events.push_back(event);
    condition.notify_one();
  });

  capture.Initialize(48000, 1);
  const int32_t generation = capture.Activate();
  assert(generation == 1);

  float samples[480] = {};
  samples[0] = -40000.0f;
  samples[1] = -1234.0f;
  samples[2] = -1.0f;
  samples[3] = 0.0f;
  samples[4] = 1.0f;
  samples[5] = 1234.0f;
  samples[6] = 40000.0f;
  // Desktop passes full-band num_frames and the exact mono float count in
  // buffer_size, even when num_bands reports the APM split-band count.
  for (int index = 0; index < 4; ++index) {
    capture.Process(3, 480, 480, samples);
  }

  {
    std::unique_lock<std::mutex> lock(mutex);
    assert(condition.wait_for(lock, std::chrono::seconds(2), [&] {
      return std::any_of(events.begin(), events.end(), [](const auto& event) {
        return EventName(event) == "onLocalAudioFrame";
      });
    }));
  }

  assert(capture.processed_callbacks() == 4);
  assert(capture.processed_frames() == 1920);
  {
    std::lock_guard<std::mutex> lock(mutex);
    const auto frame =
        std::find_if(events.begin(), events.end(), [](const auto& event) {
          return EventName(event) == "onLocalAudioFrame";
        });
    assert(frame != events.end());
    const auto pcm_value = frame->find(EncodableValue("pcm"));
    assert(pcm_value != frame->end());
    const auto& pcm = GetValue<std::vector<uint8_t>>(pcm_value->second);
    auto sample = [&pcm](size_t index) {
      return static_cast<int16_t>(
          static_cast<uint16_t>(pcm[index * 2]) |
          (static_cast<uint16_t>(pcm[index * 2 + 1]) << 8));
    };
    assert(sample(0) == -32768);
    assert(sample(1) == -1234);
    assert(sample(2) == -1);
    assert(sample(3) == 0);
    assert(sample(4) == 1);
    assert(sample(5) == 1234);
    assert(sample(6) == 32767);
  }
  assert(capture.Deactivate(generation, "test"));
  const int64_t callbacks = capture.processed_callbacks();
  capture.Process(3, 480, 480, samples);
  assert(capture.processed_callbacks() == callbacks);
  capture.Shutdown();
  return 0;
}
