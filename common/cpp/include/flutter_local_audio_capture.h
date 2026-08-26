#ifndef FLUTTER_LOCAL_AUDIO_CAPTURE_HXX
#define FLUTTER_LOCAL_AUDIO_CAPTURE_HXX

#include "flutter_common.h"
#include "rtc_audio_processing.h"

#include <array>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>
#include <vector>

namespace flutter_webrtc_plugin {

/// Bounded, generation-scoped post-APM bridge for Windows and Linux.
///
/// Process() performs one fixed-pool copy and never allocates or enters a
/// mutex. PCM conversion, batching, map allocation, and Flutter delivery run
/// on the drain thread.
class FlutterLocalAudioCapture
    : public libwebrtc::RTCAudioProcessing::CustomProcessing {
 public:
  using EventEmitter = std::function<void(const EncodableMap&)>;

  explicit FlutterLocalAudioCapture(EventEmitter emitter);
  ~FlutterLocalAudioCapture() override;

  int32_t Activate();
  bool Deactivate(int32_t generation, const std::string& reason);
  void Shutdown();

  bool active() const { return active_generation_.load() != 0; }
  int32_t active_generation() const { return active_generation_.load(); }
  int64_t processed_callbacks() const { return processed_callbacks_.load(); }
  int64_t processed_frames() const { return processed_frames_.load(); }

  void Initialize(int sample_rate_hz, int num_channels) override;
  void Process(int num_bands,
               int num_frames,
               int buffer_size,
               float* buffer) override;
  void Reset(int new_rate) override;
  void Release() override;

 private:
  static constexpr size_t kPoolSize = 32;
  static constexpr size_t kMaxSamplesPerCallback = 4800;
  static constexpr size_t kMaxBatchCallbacks = 4;

  struct Frame {
    std::array<float, kMaxSamplesPerCallback> samples;
    int32_t generation = 0;
    int sample_rate_hz = 0;
    int input_channels = 1;
    size_t sample_count = 0;
  };

  void DrainLoop();
  void EmitFormat(const Frame& frame);
  void EmitFrames(const std::array<Frame*, kMaxBatchCallbacks>& batch,
                  size_t batch_size,
                  size_t sample_count);

  EventEmitter emitter_;
  std::array<Frame, kPoolSize> frames_;
  std::atomic<uint64_t> write_sequence_{0};
  std::atomic<uint64_t> read_sequence_{0};
  std::atomic<int32_t> generation_counter_{0};
  std::atomic<int32_t> active_generation_{0};
  std::atomic<int> sample_rate_hz_{0};
  std::atomic<int> input_channels_{1};
  std::atomic<int64_t> processed_callbacks_{0};
  std::atomic<int64_t> processed_frames_{0};
  std::atomic<int64_t> dropped_callbacks_{0};
  std::atomic<bool> closed_{false};

  std::mutex wake_mutex_;
  std::mutex drain_mutex_;
  std::condition_variable wake_condition_;
  std::thread drain_thread_;
  int32_t emitted_generation_ = 0;
  int emitted_sample_rate_hz_ = 0;
  int emitted_input_channels_ = 0;
  std::atomic<int64_t> output_sequence_{0};
};

}  // namespace flutter_webrtc_plugin

#endif  // FLUTTER_LOCAL_AUDIO_CAPTURE_HXX
