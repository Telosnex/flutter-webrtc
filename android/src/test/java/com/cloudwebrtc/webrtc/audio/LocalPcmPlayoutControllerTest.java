package com.cloudwebrtc.webrtc.audio;
import org.junit.Test;
import static org.junit.Assert.*;
import java.util.HashMap;
import java.util.Map;

public class LocalPcmPlayoutControllerTest {
  public static class Factory {
    long generation;
    boolean failStop;
    int starts,stops;
    public long startPcmPlayout(){starts++;return generation=7;}
    public int writePcmPlayout(long g,long e,byte[] pcm){return 0;}
    public int clearPcmPlayout(long g,long e){return 0;}
    public int stopPcmPlayout(long g){stops++;if(failStop)return -1;generation=0;return 0;}
    public long[] getPcmPlayoutState(){return new long[]{generation,0,0,0,0,0,0,0,1,10};}
  }
  private Map<String,Object> args(){Map<String,Object> a=new HashMap<>();a.put("generation",7L);a.put("epoch",0L);a.put("pcm",new byte[480]);return a;}
  @Test public void stopFailureRetainsOwnerAndRejectsSecondStart() throws Exception {
    Factory factory=new Factory();LocalPcmPlayoutController controller=new LocalPcmPlayoutController(factory);
    assertEquals(7L,controller.perform("pcmPlayoutStart",null).get("generation"));
    assertEquals(true,controller.perform("pcmPlayoutWrite",args()).get("playing"));
    factory.failStop=true;
    assertThrows(IllegalStateException.class,()->controller.perform("pcmPlayoutStop",args()));
    assertThrows(IllegalStateException.class,()->controller.perform("pcmPlayoutStart",null));
    factory.failStop=false;
    controller.perform("pcmPlayoutStop",args());
    assertEquals(2,factory.stops);
  }
  @Test public void oldSdkAndInvalidArgumentsFailExplicitly() throws Exception {
    assertThrows(NoSuchMethodException.class,()->new LocalPcmPlayoutController(new Object()));
    Factory factory=new Factory();LocalPcmPlayoutController controller=new LocalPcmPlayoutController(factory);
    controller.perform("pcmPlayoutStart",null);
    Map<String,Object> a=args();a.put("generation",7.0);
    assertThrows(IllegalArgumentException.class,()->controller.perform("pcmPlayoutWrite",a));
    a.put("generation",7L);a.put("pcm",new byte[1]);
    assertThrows(IllegalArgumentException.class,()->controller.perform("pcmPlayoutWrite",a));
    controller.close();
    assertThrows(IllegalStateException.class,()->controller.perform("pcmPlayoutStart",null));
    controller.release();assertEquals(1,factory.stops);
  }
}
