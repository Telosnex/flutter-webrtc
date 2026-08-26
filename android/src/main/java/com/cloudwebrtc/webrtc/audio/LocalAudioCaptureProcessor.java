package com.cloudwebrtc.webrtc.audio;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Read-only, generation-scoped post-APM bridge.
 *
 * The WebRTC callback only copies floats into a fixed pool and wakes a worker.
 * Conversion, batching, map allocation, and Flutter delivery happen off the
 * realtime audio thread.
 */
public final class LocalAudioCaptureProcessor
    implements AudioProcessingAdapter.ExternalAudioFrameProcessing, AutoCloseable {
  public interface EventEmitter {
    void emit(Map<String, Object> event);
  }

  private static final int POOL_SIZE = 24;
  private static final int MAX_SAMPLES_PER_CALLBACK = 4800;
  private static final int MAX_BATCH_CALLBACKS = 4;

  private static final class Frame {
    final float[] samples = new float[MAX_SAMPLES_PER_CALLBACK];
    int generation;
    int sampleRateHz;
    int inputChannels;
    int sampleCount;
  }

  private final EventEmitter eventEmitter;
  private final ConcurrentLinkedQueue<Frame> freeFrames = new ConcurrentLinkedQueue<>();
  private final ConcurrentLinkedQueue<Frame> pendingFrames = new ConcurrentLinkedQueue<>();
  private final Semaphore pendingSignal = new Semaphore(0);
  private final AtomicInteger generationCounter = new AtomicInteger();
  private final AtomicInteger activeGeneration = new AtomicInteger();
  private final AtomicInteger droppedCallbacks = new AtomicInteger();
  private final AtomicLong processedCallbacks = new AtomicLong();
  private final AtomicLong processedFrames = new AtomicLong();
  private final Thread drainThread;

  private volatile int sampleRateHz;
  private volatile int inputChannels = 1;
  private volatile boolean closed;
  private long sequence;

  public LocalAudioCaptureProcessor(EventEmitter eventEmitter) {
    this.eventEmitter = eventEmitter;
    for (int i = 0; i < POOL_SIZE; i++) {
      freeFrames.offer(new Frame());
    }
    drainThread = new Thread(this::drainLoop, "FlutterWebRTC.LocalAudioCapture");
    drainThread.setDaemon(true);
    drainThread.start();
  }

  public synchronized int activate() {
    recyclePendingFrames();
    droppedCallbacks.set(0);
    processedCallbacks.set(0);
    processedFrames.set(0);
    sequence = 0;
    int generation = generationCounter.incrementAndGet();
    activeGeneration.set(generation);
    return generation;
  }

  public boolean isActive() {
    return activeGeneration.get() != 0;
  }

  public int getActiveGeneration() {
    return activeGeneration.get();
  }

  public long getProcessedCallbacks() {
    return processedCallbacks.get();
  }

  public long getProcessedFrames() {
    return processedFrames.get();
  }

  public synchronized boolean deactivateGeneration(int generation, String reason) {
    if (!activeGeneration.compareAndSet(generation, 0)) {
      return false;
    }
    recyclePendingFrames();
    Map<String, Object> event = new HashMap<>();
    event.put("event", "onLocalAudioStopped");
    event.put("generation", generation);
    event.put("reason", reason);
    eventEmitter.emit(event);
    return true;
  }

  @Override
  public void initialize(int newSampleRateHz, int numChannels) {
    sampleRateHz = newSampleRateHz;
    inputChannels = numChannels;
  }

  @Override
  public void reset(int newRate) {
    sampleRateHz = newRate;
  }

  @Override
  public void process(int numBands, int numFrames, ByteBuffer buffer) {
    int generation = activeGeneration.get();
    if (generation == 0 || closed) {
      return;
    }

    int sampleCount = buffer.capacity() / Float.BYTES;
    if (sampleCount <= 0 || sampleCount > MAX_SAMPLES_PER_CALLBACK) {
      droppedCallbacks.incrementAndGet();
      return;
    }

    Frame frame = freeFrames.poll();
    if (frame == null) {
      frame = pendingFrames.poll();
      if (frame == null) {
        droppedCallbacks.incrementAndGet();
        return;
      }
      droppedCallbacks.incrementAndGet();
    }

    buffer.order(ByteOrder.nativeOrder());
    for (int i = 0; i < sampleCount; i++) {
      frame.samples[i] = buffer.getFloat(i * Float.BYTES);
    }
    frame.generation = generation;
    frame.sampleRateHz = sampleRateHz != 0 ? sampleRateHz : numFrames * 100;
    frame.inputChannels = inputChannels;
    frame.sampleCount = sampleCount;
    processedCallbacks.incrementAndGet();
    processedFrames.addAndGet(sampleCount);
    pendingFrames.offer(frame);
    pendingSignal.release();
  }

  private void drainLoop() {
    while (!closed) {
      try {
        pendingSignal.acquire();
      } catch (InterruptedException ignored) {
        continue;
      }
      Frame first = pendingFrames.poll();
      if (first == null) {
        continue;
      }

      List<Frame> batch = new ArrayList<>(MAX_BATCH_CALLBACKS);
      batch.add(first);
      int sampleCount = first.sampleCount;
      while (batch.size() < MAX_BATCH_CALLBACKS) {
        Frame next = pendingFrames.peek();
        if (next == null
            || next.generation != first.generation
            || next.sampleRateHz != first.sampleRateHz
            || next.inputChannels != first.inputChannels) {
          break;
        }
        next = pendingFrames.poll();
        if (next == null) {
          break;
        }
        batch.add(next);
        sampleCount += next.sampleCount;
        pendingSignal.tryAcquire();
      }

      if (activeGeneration.get() == first.generation) {
        emitFormat(first);
        emitFrames(first, batch, sampleCount);
      }
      for (Frame frame : batch) {
        freeFrames.offer(frame);
      }
    }
  }

  private int emittedGeneration;
  private int emittedSampleRateHz;
  private int emittedInputChannels;

  private void emitFormat(Frame frame) {
    if (emittedGeneration == frame.generation
        && emittedSampleRateHz == frame.sampleRateHz
        && emittedInputChannels == frame.inputChannels) {
      return;
    }
    emittedGeneration = frame.generation;
    emittedSampleRateHz = frame.sampleRateHz;
    emittedInputChannels = frame.inputChannels;
    Map<String, Object> event = new HashMap<>();
    event.put("event", "onLocalAudioFormat");
    event.put("generation", frame.generation);
    event.put("sampleRateHz", frame.sampleRateHz);
    event.put("channels", 1);
    event.put("inputChannels", frame.inputChannels);
    event.put("encoding", "pcmS16le");
    eventEmitter.emit(event);
  }

  private void emitFrames(Frame first, List<Frame> batch, int sampleCount) {
    byte[] pcm = new byte[sampleCount * 2];
    int output = 0;
    for (Frame frame : batch) {
      for (int i = 0; i < frame.sampleCount; i++) {
        float value = Math.max(-1.0f, Math.min(1.0f, frame.samples[i]));
        int sample = Math.round(value * (value < 0 ? 32768.0f : 32767.0f));
        pcm[output++] = (byte) (sample & 0xff);
        pcm[output++] = (byte) ((sample >>> 8) & 0xff);
      }
    }
    Map<String, Object> event = new HashMap<>();
    event.put("event", "onLocalAudioFrame");
    event.put("generation", first.generation);
    event.put("sequence", sequence++);
    event.put("frameCount", sampleCount);
    event.put("droppedFrames", droppedCallbacks.getAndSet(0));
    event.put("pcm", pcm);
    eventEmitter.emit(event);
  }

  private void recyclePendingFrames() {
    Frame frame;
    while ((frame = pendingFrames.poll()) != null) {
      freeFrames.offer(frame);
      pendingSignal.tryAcquire();
    }
  }

  @Override
  public void close() {
    closed = true;
    activeGeneration.set(0);
    pendingSignal.release();
    drainThread.interrupt();
    recyclePendingFrames();
  }
}
