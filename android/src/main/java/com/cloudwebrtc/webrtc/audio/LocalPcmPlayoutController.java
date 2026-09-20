package com.cloudwebrtc.webrtc.audio;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Thin SDK bridge; PCM and lifecycle live on WebRTC's worker, never AudioTrack #2. */
public final class LocalPcmPlayoutController {
  public static final class PcmException extends IllegalStateException {
    private static final long serialVersionUID = 1L;
    public final String code;
    PcmException(int result) {
      super("PCM operation rejected (" + result + ")");
      code = result == -5 ? "pcmPlayoutBusy" : result == -4 ? "pcmPlayoutCapacity" :
          result == -3 ? "pcmPlayoutArguments" : result == -2 ? "pcmPlayoutStale" : "pcmPlayoutFailed";
    }
  }
  private final Object factory;
  private final Method start, write, clear, stop, state;
  private Method startSource, sourceState;
  private final Set<Long> owners = new HashSet<>(); // pcmQueue only
  private volatile boolean active;
  public boolean hasOwner() { return active; }
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
    try {
      Method s = type.getMethod("startPcmPlayoutSource", int.class, int.class, boolean.class);
      sourceState = type.getMethod("getPcmPlayoutSourceState", long.class);
      startSource = s;
    } catch (NoSuchMethodException oldSdk) { /* Legacy exclusive API. */ }
  }
  public Map<String, Object> capabilities() {
    Map<String, Object> caps = new HashMap<>();
    caps.put("version", 1); caps.put("sampleRate", 24000); caps.put("channels", 1);
    caps.put("requiresAnchor", false);
    if (startSource != null) {
      caps.put("maxSharedSources", 2);
      Map<String, Object> speech = new HashMap<>(), music = new HashMap<>();
      speech.put("sampleRate", 24000); speech.put("channels", 1);
      music.put("sampleRate", 48000); music.put("channels", 2);
      caps.put("supportedFormats", Arrays.asList(speech, music));
    }
    return caps;
  }
  public void close() { closed = true; }
  public void release() throws Exception {
    for (long generation : new ArrayList<>(owners)) {
      if (((Number) invoke(stop, generation)).intValue() == 0) owners.remove(generation);
    }
    active = !owners.isEmpty();
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
    long generation;
    if (method.equals("pcmPlayoutStart")) {
      boolean format = args != null && (args.containsKey("sampleRate") || args.containsKey("channels"));
      long rate = format ? integer(args.get("sampleRate")) : 24000;
      long channels = format ? integer(args.get("channels")) : 1;
      Object mode = args != null && args.containsKey("ownershipMode") ? args.get("ownershipMode") : "exclusive";
      if (!((rate == 24000 && channels == 1) || (rate == 48000 && channels == 2)) ||
          !("exclusive".equals(mode) || "shared".equals(mode))) throw new IllegalArgumentException("Unsupported PCM format or mode");
      if (startSource == null && (rate != 24000 || channels != 1 || !"exclusive".equals(mode)))
        throw new UnsupportedOperationException("Matching PCM SDK required");
      if (startSource == null && !owners.isEmpty()) throw new IllegalStateException("PCM output already owned");
      long acquired = ((Number) (startSource == null ? invoke(start) :
          invoke(startSource, (int)rate, (int)channels, "shared".equals(mode)))).longValue();
      if (acquired <= 0) throw new PcmException((int)acquired);
      generation = acquired;
      owners.add(generation);
      active = true;
    } else {
      long owner = args == null ? -1 : integer(args.get("generation"));
      long epoch = args == null ? -1 : integer(args.get("epoch"));
      if (owner <= 0 || !owners.contains(owner)) throw new IllegalArgumentException("Stale PCM generation");
      generation = owner;
      switch (method) {
        case "pcmPlayoutWrite":
          Object pcm = args.get("pcm");
          if (!(pcm instanceof byte[])) throw new IllegalArgumentException("Expected PCM16LE bytes");
          byte[] bytes = (byte[]) pcm;
          if (bytes.length == 0 || bytes.length > (startSource == null ? 48000 : 192000) || bytes.length % 2 != 0) throw new IllegalArgumentException("Invalid PCM size");
          code = ((Number) invoke(write, owner, epoch, bytes)).intValue(); break;
        case "pcmPlayoutClear": code = ((Number) invoke(clear, owner, epoch)).intValue(); break;
        case "pcmPlayoutStop":
          code = ((Number) invoke(stop, owner)).intValue();
          if (code == 0) { owners.remove(owner); active = !owners.isEmpty(); }
          break;
        case "pcmPlayoutState": break;
        default: throw new IllegalArgumentException("Unknown PCM operation");
      }
    }
    if (code != 0) throw new PcmException(code);
    long[] s = (long[]) (startSource == null ? invoke(state) : invoke(sourceState, generation));
    if (s == null || s.length != (startSource == null ? 10 : 13)) throw new IllegalStateException("Invalid PCM state");
    String[] keys = {"generation", "epoch", "queuedFrames", "acceptedFrames", "consumedFrames", "discardedFrames", "renderCallbacks", "underrunCallbacks", "playing", "delayMs"};
    Map<String, Object> result = new HashMap<>();
    for (int i = 0; i < 10; i++) result.put(keys[i], i == 8 ? Boolean.valueOf(s[i] != 0) : Long.valueOf(s[i]));
    if (s.length == 13) {
      result.put("sampleRate", s[10]); result.put("channels", s[11]);
      result.put("ownershipMode", s[12] != 0 ? "shared" : "exclusive");
    }
    return result;
  }
}
