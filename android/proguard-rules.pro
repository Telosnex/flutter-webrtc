# Flutter WebRTC
-keep class com.cloudwebrtc.webrtc.** { *; }
-keep class org.webrtc.** { *; }
-keep class org.jni_zero.** { *; }

# Capability-gated SDK PCM bridge uses reflection to preserve old-AAR support.
-keepclassmembers class org.webrtc.PeerConnectionFactory {
    public long startPcmPlayout();
    public int writePcmPlayout(long, long, byte[]);
    public int clearPcmPlayout(long, long);
    public int stopPcmPlayout(long);
    public long[] getPcmPlayoutState();
}
