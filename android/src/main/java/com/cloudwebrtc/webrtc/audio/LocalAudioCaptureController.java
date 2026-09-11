package com.cloudwebrtc.webrtc.audio;

/**
 * Serializes app-owned native recording demand independently of peer senders.
 *
 * <p>The native owner performs ADM arbitration on WebRTC's worker thread. This
 * controller retains ownership after a failed release so callers can retry
 * instead of reporting that a still-live microphone was stopped.
 */
public final class LocalAudioCaptureController {
  public interface NativeRecordingOwner {
    int acquire();

    int release();

    State getState();
  }

  public static final class State {
    public final boolean available;
    public final boolean initialized;
    public final boolean recording;
    public final boolean externalDemand;

    public State(
        boolean available, boolean initialized, boolean recording, boolean externalDemand) {
      this.available = available;
      this.initialized = initialized;
      this.recording = recording;
      this.externalDemand = externalDemand;
    }
  }

  private final NativeRecordingOwner nativeOwner;
  private boolean acquired;
  private boolean closed;

  public LocalAudioCaptureController(NativeRecordingOwner nativeOwner) {
    this.nativeOwner = nativeOwner;
  }

  public synchronized int acquire() {
    if (closed || acquired) {
      return -1;
    }
    int result = nativeOwner.acquire();
    if (result == 0) {
      acquired = true;
    }
    return result;
  }

  public synchronized int release() {
    if (!acquired) {
      return 0;
    }
    int result = nativeOwner.release();
    if (result == 0) {
      acquired = false;
    }
    return result;
  }

  /** Prevents queued work from acquiring after plugin disposal and releases current demand. */
  public synchronized int shutdown() {
    closed = true;
    return release();
  }

  public synchronized boolean isAcquired() {
    return acquired;
  }

  public synchronized boolean isClosed() {
    return closed;
  }

  public State getState() {
    return nativeOwner.getState();
  }
}
