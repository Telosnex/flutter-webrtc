package com.cloudwebrtc.webrtc.audio;

import androidx.annotation.Nullable;

import com.twilio.audioswitch.AudioDevice;

import java.util.HashMap;
import java.util.Map;

public enum AudioDeviceKind {
    BLUETOOTH("bluetooth", "bluetooth", AudioDevice.BluetoothHeadset.class),
    WIRED_HEADSET("wired-headset", "wired", AudioDevice.WiredHeadset.class),
    SPEAKER("speaker", "speaker", AudioDevice.Speakerphone.class),
    EARPIECE("earpiece", "receiver", AudioDevice.Earpiece.class);

    public final String typeName;
    public final String routeKind;
    public final Class<? extends AudioDevice> audioDeviceClass;

    AudioDeviceKind(String typeName, String routeKind,
                    Class<? extends AudioDevice> audioDeviceClass) {
        this.typeName = typeName;
        this.routeKind = routeKind;
        this.audioDeviceClass = audioDeviceClass;
    }

    @Nullable
    public static AudioDeviceKind fromAudioDevice(@Nullable AudioDevice audioDevice) {
        if (audioDevice == null) {
            return null;
        }
        for (AudioDeviceKind kind : values()) {
            if (kind.audioDeviceClass.equals(audioDevice.getClass())) {
                return kind;
            }
        }
        return null;
    }

    @Nullable
    public static AudioDeviceKind fromTypeName(String typeName) {
        for (AudioDeviceKind kind : values()) {
            if (kind.typeName.equals(typeName)) {
                return kind;
            }
        }
        return null;
    }

    @Nullable
    public static Map<String, Object> toAudioRouteMap(@Nullable AudioDevice audioDevice) {
        AudioDeviceKind kind = fromAudioDevice(audioDevice);
        if (audioDevice == null || kind == null) {
            return null;
        }

        Map<String, Object> route = new HashMap<>();
        route.put("id", kind.typeName);
        route.put("label", audioDevice.getName());
        route.put("kind", kind.routeKind);
        return route;
    }
}
