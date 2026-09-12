package com.cloudwebrtc.webrtc.audio;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.HashMap;
import java.util.Map;

/** Thin SDK bridge; PCM and lifecycle live on WebRTC's worker, never AudioTrack #2. */
public final class LocalPcmPlayoutController {
  private final Object factory;
  private final Method start, write, clear, stop, state;
  private volatile long generation;
  public boolean hasOwner() { return generation != 0; }
  private volatile boolean closed;

  // Reflection is only compatibility gating for the old published AAR. Once
  // detected, native failures propagate; they never select another speaker.
  public LocalPcmPlayoutController(Object factory) throws NoSuchMethodException {
    this.factory = factory;
    Class<?> type = factory.getClass();
    start = type.getMethod("startPcmPlayout");
    write = type.getMethod("writePcmPlayout", long.class, long.class, byte[].class);
    clear = type.getMethod("clearPcmPlayout", long.class, long.class);
    stop = type.getMethod("stopPcmPlayout", long.class);
    state = type.getMethod("getPcmPlayoutState");
  }
  public void close() { closed = true; }
  public void release() throws Exception {
    if (generation != 0 && ((Number) invoke(stop, generation)).intValue() == 0) generation = 0;
  }
  private Object invoke(Method method, Object... args) throws Exception {
    try { return method.invoke(factory, args); }
    catch (InvocationTargetException e) {
      Throwable cause = e.getCause();
      if (cause instanceof Exception) throw (Exception) cause;
      throw new IllegalStateException("Native PCM call failed", cause);
    }
  }
  private static long integer(Object value) {
    return value instanceof Long || value instanceof Integer ? ((Number) value).longValue() : -1;
  }
  public Map<String, Object> perform(String method, Map<?, ?> args) throws Exception {
    if (closed) throw new IllegalStateException("PCM controller disposed");
    int code = 0;
    if (method.equals("pcmPlayoutStart")) {
      if (generation != 0) throw new IllegalStateException("PCM output already owned");
      long acquired = ((Number) invoke(start)).longValue();
      if (acquired <= 0) throw new IllegalStateException("Could not start shared output");
      generation = acquired;
    } else {
      long owner = args == null ? -1 : integer(args.get("generation"));
      long epoch = args == null ? -1 : integer(args.get("epoch"));
      if (owner <= 0 || owner != generation) throw new IllegalArgumentException("Stale PCM generation");
      switch (method) {
        case "pcmPlayoutWrite":
          Object pcm = args.get("pcm");
          if (!(pcm instanceof byte[])) throw new IllegalArgumentException("Expected PCM16LE bytes");
          byte[] bytes = (byte[]) pcm;
          if (bytes.length == 0 || bytes.length > 48000 || bytes.length % 2 != 0) throw new IllegalArgumentException("Invalid PCM size");
          code = ((Number) invoke(write, owner, epoch, bytes)).intValue(); break;
        case "pcmPlayoutClear": code = ((Number) invoke(clear, owner, epoch)).intValue(); break;
        case "pcmPlayoutStop":
          code = ((Number) invoke(stop, owner)).intValue();
          if (code == 0) generation = 0;
          break;
        case "pcmPlayoutState": break;
        default: throw new IllegalArgumentException("Unknown PCM operation");
      }
    }
    if (code != 0) throw new IllegalStateException("PCM operation rejected (" + code + ")");
    long[] s = (long[]) invoke(state);
    if (s == null || s.length != 10) throw new IllegalStateException("Invalid PCM state");
    String[] keys = {"generation", "epoch", "queuedFrames", "acceptedFrames", "consumedFrames", "discardedFrames", "renderCallbacks", "underrunCallbacks", "playing", "delayMs"};
    Map<String, Object> result = new HashMap<>();
    for (int i = 0; i < s.length; i++) result.put(keys[i], i == 8 ? Boolean.valueOf(s[i] != 0) : Long.valueOf(s[i]));
    return result;
  }
}
