#include "flutter_local_audio_capture.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

namespace flutter_webrtc_plugin {

FlutterLocalAudioCapture::FlutterLocalAudioCapture(EventEmitter emitter)
    : emitter_(std::move(emitter)),
      drain_thread_(&FlutterLocalAudioCapture::DrainLoop, this) {}

FlutterLocalAudioCapture::~FlutterLocalAudioCapture() {
  Shutdown();
}

int32_t FlutterLocalAudioCapture::Activate() {
  std::lock_guard<std::mutex> lock(drain_mutex_);
  read_sequence_.store(write_sequence_.load(std::memory_order_acquire),
                       std::memory_order_release);
  processed_callbacks_.store(0);
  processed_frames_.store(0);
  dropped_callbacks_.store(0);
  output_sequence_.store(0);
  const int32_t generation = generation_counter_.fetch_add(1) + 1;
  active_generation_.store(generation, std::memory_order_release);
  return generation;
}

bool FlutterLocalAudioCapture::Deactivate(int32_t generation,
                                          const std::string& reason) {
  std::lock_guard<std::mutex> lock(drain_mutex_);
  int32_t expected = generation;
  if (!active_generation_.compare_exchange_strong(expected, 0)) {
    return false;
  }
  read_sequence_.store(write_sequence_.load(std::memory_order_acquire),
                       std::memory_order_release);
  EncodableMap event;
  event[EncodableValue("event")] = EncodableValue("onLocalAudioStopped");
  event[EncodableValue("generation")] = EncodableValue(generation);
  event[EncodableValue("reason")] = EncodableValue(reason);
  emitter_(event);
  return true;
}

void FlutterLocalAudioCapture::Shutdown() {
  if (closed_.exchange(true)) {
    return;
  }
  active_generation_.store(0);
  wake_condition_.notify_one();
  if (drain_thread_.joinable()) {
    drain_thread_.join();
  }
}

void FlutterLocalAudioCapture::Initialize(int sample_rate_hz,
                                          int num_channels) {
  sample_rate_hz_.store(sample_rate_hz, std::memory_order_relaxed);
  input_channels_.store(num_channels, std::memory_order_relaxed);
}

void FlutterLocalAudioCapture::Reset(int new_rate) {
  sample_rate_hz_.store(new_rate, std::memory_order_relaxed);
}

void FlutterLocalAudioCapture::Release() {
  // The plugin owns this processor. Unregistration is an acknowledgement, not
  // a request to delete an object potentially still referenced by its worker.
}

void FlutterLocalAudioCapture::Process(int num_bands,
                                       int num_frames,
                                       int buffer_size,
                                       float* buffer) {
  (void)num_bands;
  (void)num_frames;
  const int32_t generation =
      active_generation_.load(std::memory_order_acquire);
  if (generation == 0 || closed_.load(std::memory_order_relaxed) ||
      buffer == nullptr) {
    return;
  }

  // The desktop wrapper passes one full-band channel and its exact float count
  // in buffer_size. num_bands is diagnostic metadata; multiplying it by
  // num_frames would over-read 48 kHz frames (3 * 480 vs. a 480-float buffer).
  const size_t sample_count = static_cast<size_t>(buffer_size);
  if (buffer_size <= 0 || sample_count > kMaxSamplesPerCallback) {
    dropped_callbacks_.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  const uint64_t write = write_sequence_.load(std::memory_order_relaxed);
  const uint64_t read = read_sequence_.load(std::memory_order_acquire);
  if (write - read >= kPoolSize) {
    dropped_callbacks_.fetch_add(1, std::memory_order_relaxed);
    return;
  }

  Frame& frame = frames_[write % kPoolSize];
  std::memcpy(frame.samples.data(), buffer, sample_count * sizeof(float));
  if (active_generation_.load(std::memory_order_acquire) != generation) {
    return;
  }
  frame.generation = generation;
  frame.sample_rate_hz = sample_rate_hz_.load(std::memory_order_relaxed);
  frame.input_channels = input_channels_.load(std::memory_order_relaxed);
  frame.sample_count = sample_count;
  processed_callbacks_.fetch_add(1, std::memory_order_relaxed);
  processed_frames_.fetch_add(static_cast<int64_t>(sample_count),
                              std::memory_order_relaxed);
  write_sequence_.store(write + 1, std::memory_order_release);
  wake_condition_.notify_one();
}

void FlutterLocalAudioCapture::DrainLoop() {
  while (!closed_.load(std::memory_order_acquire)) {
    {
      std::unique_lock<std::mutex> lock(wake_mutex_);
      wake_condition_.wait_for(lock, std::chrono::milliseconds(20), [this] {
        return closed_.load(std::memory_order_acquire) ||
               read_sequence_.load(std::memory_order_relaxed) !=
                   write_sequence_.load(std::memory_order_acquire);
      });
    }
    if (closed_.load(std::memory_order_acquire)) {
      break;
    }

    std::lock_guard<std::mutex> drain_lock(drain_mutex_);
    uint64_t read = read_sequence_.load(std::memory_order_relaxed);
    const uint64_t write = write_sequence_.load(std::memory_order_acquire);
    if (read == write) {
      continue;
    }

    std::array<Frame*, kMaxBatchCallbacks> batch{};
    Frame& first = frames_[read % kPoolSize];
    size_t batch_size = 0;
    size_t sample_count = 0;
    while (read < write && batch_size < kMaxBatchCallbacks) {
      Frame& next = frames_[read % kPoolSize];
      if (next.generation != first.generation ||
          next.sample_rate_hz != first.sample_rate_hz ||
          next.input_channels != first.input_channels) {
        break;
      }
      batch[batch_size++] = &next;
      sample_count += next.sample_count;
      ++read;
    }

    if (active_generation_.load(std::memory_order_acquire) ==
        first.generation) {
      EmitFormat(first);
      EmitFrames(batch, batch_size, sample_count);
    }
    read_sequence_.store(read, std::memory_order_release);
  }
}

void FlutterLocalAudioCapture::EmitFormat(const Frame& frame) {
  if (emitted_generation_ == frame.generation &&
      emitted_sample_rate_hz_ == frame.sample_rate_hz &&
      emitted_input_channels_ == frame.input_channels) {
    return;
  }
  emitted_generation_ = frame.generation;
  emitted_sample_rate_hz_ = frame.sample_rate_hz;
  emitted_input_channels_ = frame.input_channels;

  EncodableMap event;
  event[EncodableValue("event")] = EncodableValue("onLocalAudioFormat");
  event[EncodableValue("generation")] = EncodableValue(frame.generation);
  event[EncodableValue("sampleRateHz")] =
      EncodableValue(frame.sample_rate_hz);
  event[EncodableValue("channels")] = EncodableValue(1);
  event[EncodableValue("inputChannels")] =
      EncodableValue(frame.input_channels);
  event[EncodableValue("encoding")] = EncodableValue("pcmS16le");
  emitter_(event);
}

void FlutterLocalAudioCapture::EmitFrames(
    const std::array<Frame*, kMaxBatchCallbacks>& batch,
    size_t batch_size,
    size_t sample_count) {
  std::vector<uint8_t> pcm(sample_count * sizeof(int16_t));
  size_t output = 0;
  for (size_t batch_index = 0; batch_index < batch_size; ++batch_index) {
    const Frame& frame = *batch[batch_index];
    for (size_t index = 0; index < frame.sample_count; ++index) {
      const float value = std::clamp(frame.samples[index], -1.0f, 1.0f);
      const int16_t sample = static_cast<int16_t>(std::lround(
          value * (value < 0.0f ? 32768.0f : 32767.0f)));
      pcm[output++] = static_cast<uint8_t>(sample & 0xff);
      pcm[output++] = static_cast<uint8_t>((sample >> 8) & 0xff);
    }
  }

  EncodableMap event;
  event[EncodableValue("event")] = EncodableValue("onLocalAudioFrame");
  event[EncodableValue("generation")] =
      EncodableValue(batch[0]->generation);
  event[EncodableValue("sequence")] = EncodableValue(output_sequence_++);
  event[EncodableValue("frameCount")] =
      EncodableValue(static_cast<int64_t>(sample_count));
  event[EncodableValue("droppedFrames")] =
      EncodableValue(dropped_callbacks_.exchange(0));
  event[EncodableValue("pcm")] = EncodableValue(std::move(pcm));
  emitter_(event);
}

}  // namespace flutter_webrtc_plugin
