import com.cloudwebrtc.webrtc.audio.LocalPcmPlayoutController;
import java.util.HashMap;
import java.util.Map;

/** Device-free contract test. Run with javac/java; no Android runtime needed. */
public final class LocalPcmPlayoutControllerTest {
  public static class LegacyFactory {
    long token;
    boolean failStop;
    public long startPcmPlayout() { return token == 0 ? (token = 7) : -5; }
    public int writePcmPlayout(long owner, long epoch, byte[] pcm) { return 0; }
    public int clearPcmPlayout(long owner, long epoch) { return 0; }
    public int stopPcmPlayout(long owner) { if (failStop) return -1; token = 0; return 0; }
    public long[] getPcmPlayoutState() { return new long[] {token,0,0,0,0,0,0,0,1,0}; }
  }
  public static final class SharedFactory extends LegacyFactory {
    final Map<Long, long[]> owners = new HashMap<>();
    long next;
    public long startPcmPlayoutSource(int rate, int channels, boolean shared) {
      for (long[] s : owners.values()) if (!shared || s[12] == 0) return -5;
      if (owners.size() == 2) return -4;
      long owner = ++next;
      owners.put(owner, new long[] {owner,0,0,0,0,0,0,0,1,0,rate,channels,shared ? 1 : 0});
      return owner;
    }
    public long[] getPcmPlayoutSourceState(long owner) {
      return owners.getOrDefault(owner, new long[13]);
    }
    @Override public int stopPcmPlayout(long owner) {
      if (failStop) return -1;
      owners.remove(owner); return 0;
    }
  }
  private static void check(boolean condition) {
    if (!condition) throw new AssertionError();
  }
  private static Map<String,Object> format(int rate, int channels) {
    return Map.of("sampleRate", rate, "channels", channels, "ownershipMode", "shared");
  }
  private static void rejects(LocalPcmPlayoutController c, String method, Map<?,?> args) throws Exception {
    try { c.perform(method, args); }
    catch (IllegalArgumentException | IllegalStateException | UnsupportedOperationException expected) { return; }
    throw new AssertionError("Expected rejection: " + method);
  }
  public static void main(String[] args) throws Exception {
    LegacyFactory legacy = new LegacyFactory();
    LocalPcmPlayoutController old = new LocalPcmPlayoutController(legacy);
    check(!old.capabilities().containsKey("maxSharedSources"));
    rejects(old, "pcmPlayoutStart", format(48000,2));
    check(!old.hasOwner());
    old.perform("pcmPlayoutStart", null);
    rejects(old, "pcmPlayoutStart", null);
    legacy.failStop = true;
    rejects(old, "pcmPlayoutStop", Map.of("generation",7));
    check(old.hasOwner());
    legacy.failStop = false;
    old.perform("pcmPlayoutStop", Map.of("generation",7));
    check(!old.hasOwner());

    SharedFactory factory = new SharedFactory();
    LocalPcmPlayoutController c = new LocalPcmPlayoutController(factory);
    check(c.capabilities().get("maxSharedSources").equals(2));
    rejects(c,"pcmPlayoutStart",Map.of("sampleRate",48000));
    rejects(c,"pcmPlayoutStart",Map.of("sampleRate",48000.0,"channels",2));
    c.perform("pcmPlayoutStart",format(24000,1));
    Map<String,Object> music = c.perform("pcmPlayoutStart",format(48000,2));
    check(music.get("sampleRate").equals(48000L));
    check(music.get("ownershipMode").equals("shared"));
    rejects(c,"pcmPlayoutStart",format(24000,1));
    rejects(c,"pcmPlayoutStart",null);
    c.perform("pcmPlayoutStop",Map.of("generation",1));
    check(c.hasOwner());
    check(factory.owners.size() == 1);
    rejects(c,"pcmPlayoutState",Map.of("generation",1));
    c.perform("pcmPlayoutState",Map.of("generation",2));
    factory.failStop = true;
    rejects(c,"pcmPlayoutStop",Map.of("generation",2));
    check(c.hasOwner());
    factory.failStop = false;
    c.perform("pcmPlayoutStop",Map.of("generation",2));
    check(!c.hasOwner());
    c.close();
    rejects(c,"pcmPlayoutStart",null);
    System.out.println("PASS: Android PCM legacy/shared contract, owner isolation, failure retry");
  }
}
