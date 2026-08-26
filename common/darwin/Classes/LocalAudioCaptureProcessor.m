#import "LocalAudioCaptureProcessor.h"

#if TARGET_OS_IPHONE
#import <Flutter/Flutter.h>
#elif TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <math.h>
#import <stdatomic.h>

// APM normally supplies 10 ms blocks (480 frames at 48 kHz). Leave enough
// room for a 100 ms callback without allocating on the audio thread.
#define LOCAL_AUDIO_MAX_FRAMES 4800
#define LOCAL_AUDIO_RING_SLOTS 64
#define LOCAL_AUDIO_BATCH_SLOTS 4

typedef struct {
  uint32_t generation;
  uint32_t frames;
  float samples[LOCAL_AUDIO_MAX_FRAMES];
} LocalAudioSlot;

@implementation LocalAudioCaptureProcessor {
  LocalAudioCaptureEventHandler _eventHandler;
  dispatch_queue_t _drainQueue;
  dispatch_source_t _drainSource;
  LocalAudioSlot* _slots;

  atomic_uint_fast32_t _writeIndex;
  atomic_uint_fast32_t _readIndex;
  atomic_uint_fast32_t _generation;
  atomic_uint_fast32_t _sampleRate;
  atomic_uint_fast32_t _inputChannels;
  atomic_uint_fast32_t _droppedFrames;
  atomic_uint_fast64_t _processedCallbacks;
  atomic_uint_fast64_t _processedFrames;
  atomic_bool _active;
  atomic_bool _formatPending;
  atomic_bool _releasePending;

  uint64_t _sequence;
}

- (instancetype)initWithEventHandler:(LocalAudioCaptureEventHandler)eventHandler {
  self = [super init];
  if (self) {
    _eventHandler = [eventHandler copy];
    _slots = calloc(LOCAL_AUDIO_RING_SLOTS, sizeof(LocalAudioSlot));
    NSAssert(_slots != NULL, @"Unable to allocate local audio ring");
    atomic_init(&_writeIndex, 0);
    atomic_init(&_readIndex, 0);
    atomic_init(&_generation, 0);
    atomic_init(&_sampleRate, 0);
    atomic_init(&_inputChannels, 0);
    atomic_init(&_droppedFrames, 0);
    atomic_init(&_processedCallbacks, 0);
    atomic_init(&_processedFrames, 0);
    atomic_init(&_active, false);
    atomic_init(&_formatPending, false);
    atomic_init(&_releasePending, false);

    _drainQueue = dispatch_queue_create("FlutterWebRTC.LocalAudioCapture", DISPATCH_QUEUE_SERIAL);
    _drainSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, _drainQueue);
    __weak LocalAudioCaptureProcessor* weakSelf = self;
    dispatch_source_set_event_handler(_drainSource, ^{
      [weakSelf drain];
    });
    dispatch_resume(_drainSource);
  }
  return self;
}

- (void)dealloc {
  atomic_store_explicit(&_active, false, memory_order_release);
  if (_drainSource != nil) {
    dispatch_source_cancel(_drainSource);
  }
  free(_slots);
}

- (NSUInteger)activeGeneration {
  return atomic_load_explicit(&_generation, memory_order_acquire);
}

- (BOOL)isActive {
  return atomic_load_explicit(&_active, memory_order_acquire);
}

- (NSUInteger)processedCallbacks {
  return atomic_load_explicit(&_processedCallbacks, memory_order_acquire);
}

- (NSUInteger)processedFrames {
  return atomic_load_explicit(&_processedFrames, memory_order_acquire);
}

- (NSUInteger)activate {
  atomic_store_explicit(&_active, false, memory_order_release);
  uint32_t generation = atomic_fetch_add_explicit(&_generation, 1, memory_order_acq_rel) + 1;
  dispatch_sync(_drainQueue, ^{
    atomic_store_explicit(&self->_readIndex, 0, memory_order_release);
    atomic_store_explicit(&self->_writeIndex, 0, memory_order_release);
    atomic_store_explicit(&self->_droppedFrames, 0, memory_order_release);
    atomic_store_explicit(&self->_processedCallbacks, 0, memory_order_release);
    atomic_store_explicit(&self->_processedFrames, 0, memory_order_release);
    self->_sequence = 0;
  });
  atomic_store_explicit(&_releasePending, false, memory_order_release);
  atomic_store_explicit(&_formatPending, true, memory_order_release);
  atomic_store_explicit(&_active, true, memory_order_release);
  dispatch_source_merge_data(_drainSource, 1);
  return generation;
}

- (BOOL)deactivateGeneration:(NSUInteger)generation {
  if (generation != self.activeGeneration) return NO;
  atomic_store_explicit(&_active, false, memory_order_release);
  dispatch_source_merge_data(_drainSource, 1);
  return YES;
}

- (void)audioProcessingInitializeWithSampleRate:(size_t)sampleRateHz channels:(size_t)channels {
  // Called under AudioProcessingAdapter's unfair lock on the realtime thread.
  atomic_store_explicit(&_sampleRate, (uint32_t)sampleRateHz, memory_order_release);
  atomic_store_explicit(&_inputChannels, (uint32_t)channels, memory_order_release);
  atomic_store_explicit(&_formatPending, true, memory_order_release);
  dispatch_source_merge_data(_drainSource, 1);
}

- (void)audioProcessingProcess:(RTC_OBJC_TYPE(RTCAudioBuffer) *)audioBuffer {
  if (!atomic_load_explicit(&_active, memory_order_acquire)) return;
  const size_t frames = audioBuffer.frames;
  if (frames == 0) return;
  atomic_fetch_add_explicit(&_processedCallbacks, 1, memory_order_relaxed);
  atomic_fetch_add_explicit(&_processedFrames, frames, memory_order_relaxed);
  if (frames > LOCAL_AUDIO_MAX_FRAMES || audioBuffer.channels == 0) {
    atomic_fetch_add_explicit(&_droppedFrames, (uint32_t)frames, memory_order_relaxed);
    return;
  }

  const uint32_t write = atomic_load_explicit(&_writeIndex, memory_order_relaxed);
  const uint32_t read = atomic_load_explicit(&_readIndex, memory_order_acquire);
  if (write - read >= LOCAL_AUDIO_RING_SLOTS) {
    // Never wait behind Dart/Flutter. Dropping this local copy cannot alter RTP.
    atomic_fetch_add_explicit(&_droppedFrames, (uint32_t)frames, memory_order_relaxed);
    return;
  }

  LocalAudioSlot* slot = &_slots[write % LOCAL_AUDIO_RING_SLOTS];
  slot->generation = atomic_load_explicit(&_generation, memory_order_relaxed);
  slot->frames = (uint32_t)frames;
  memcpy(slot->samples, [audioBuffer rawBufferForChannel:0], frames * sizeof(float));
  atomic_store_explicit(&_writeIndex, write + 1, memory_order_release);

  // Native-batch the usual 10 ms callbacks into at least 20 ms events. A stop
  // or release signal flushes an odd final callback.
  if (write + 1 - read >= 2) {
    dispatch_source_merge_data(_drainSource, 1);
  }
}

- (void)audioProcessingRelease {
  atomic_store_explicit(&_releasePending, true, memory_order_release);
  dispatch_source_merge_data(_drainSource, 1);
}

- (void)drain {
  const uint32_t generation = atomic_load_explicit(&_generation, memory_order_acquire);
  const uint32_t sampleRate = atomic_load_explicit(&_sampleRate, memory_order_acquire);
  const uint32_t inputChannels = atomic_load_explicit(&_inputChannels, memory_order_acquire);

  if (atomic_exchange_explicit(&_formatPending, false, memory_order_acq_rel) && sampleRate > 0) {
    _eventHandler(@{
      @"event" : @"onLocalAudioFormat",
      @"generation" : @(generation),
      @"sampleRateHz" : @(sampleRate),
      @"channels" : @1,
      @"inputChannels" : @(inputChannels),
      @"encoding" : @"pcmS16le"
    });
  }

  while (true) {
    uint32_t read = atomic_load_explicit(&_readIndex, memory_order_relaxed);
    const uint32_t write = atomic_load_explicit(&_writeIndex, memory_order_acquire);
    if (read == write) break;

    uint32_t batchSlots = MIN((uint32_t)LOCAL_AUDIO_BATCH_SLOTS, write - read);
    size_t totalFrames = 0;
    for (uint32_t index = 0; index < batchSlots; index++) {
      LocalAudioSlot* slot = &_slots[(read + index) % LOCAL_AUDIO_RING_SLOTS];
      if (slot->generation == generation) totalFrames += slot->frames;
    }
    if (totalFrames == 0) {
      atomic_store_explicit(&_readIndex, read + batchSlots, memory_order_release);
      continue;
    }

    NSMutableData* pcm = [NSMutableData dataWithLength:totalFrames * sizeof(int16_t)];
    int16_t* output = pcm.mutableBytes;
    size_t outputIndex = 0;
    for (uint32_t index = 0; index < batchSlots; index++) {
      LocalAudioSlot* slot = &_slots[(read + index) % LOCAL_AUDIO_RING_SLOTS];
      if (slot->generation != generation) continue;
      for (uint32_t frame = 0; frame < slot->frames; frame++) {
        float value = slot->samples[frame];
        value = fmaxf(-32768.0f, fminf(32767.0f, value));
        output[outputIndex++] = (int16_t)lrintf(value);
      }
    }
    atomic_store_explicit(&_readIndex, read + batchSlots, memory_order_release);

    const uint32_t dropped = atomic_exchange_explicit(&_droppedFrames, 0, memory_order_acq_rel);
    _eventHandler(@{
      @"event" : @"onLocalAudioFrame",
      @"generation" : @(generation),
      @"sequence" : @(_sequence++),
      @"frameCount" : @(outputIndex),
      @"droppedFrames" : @(dropped),
      @"pcm" : [FlutterStandardTypedData typedDataWithBytes:pcm]
    });
  }

  if (atomic_exchange_explicit(&_releasePending, false, memory_order_acq_rel)) {
    _eventHandler(@{
      @"event" : @"onLocalAudioStopped",
      @"generation" : @(generation),
      @"reason" : @"audioProcessingReleased"
    });
  }
}

@end
