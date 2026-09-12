#!/usr/bin/env python3
"""Check fork pin consistency. Artifact verification is a separate gate."""
import argparse
from pathlib import Path
import re


def one(pattern, text, label):
    matches = re.findall(pattern, text)
    if len(matches) != 1:
        raise ValueError(f"{label}: expected exactly one pin, found {len(matches)}")
    return matches[0]


def verify(root):
    apple = []
    for platform in ("ios", "macos"):
        pod = (root / platform / "flutter_webrtc.podspec").read_text()
        version = one(r"s\.dependency 'WebRTC-SDK', '([^']+)'", pod, platform)
        spm = (root / platform / "flutter_webrtc/Package.swift").read_text()
        url = one(r'url:\s*"([^"]+/WebRTC\.xcframework\.zip)"', spm, platform)
        digest = one(r'checksum:\s*"([0-9a-f]{64})"', spm, platform)
        expected = f"https://github.com/Telosnex/libwebrtc/releases/download/libwebrtc.m{version}/WebRTC.xcframework.zip"
        if url != expected:
            raise ValueError(f"{platform}: pod version and fork SPM URL disagree")
        apple.append((version, digest))
    if apple[0] != apple[1]:
        raise ValueError("iOS and macOS versions/checksums disagree")
    text = (root / "third_party/libwebrtc_version.ini").read_text()
    pins = dict(re.findall(r"^\s*([a-z0-9_]+)\s*=\s*(\S+)\s*$", text, re.M))
    if pins.get("download_url") != "https://github.com/Telosnex/libwebrtc/releases/download":
        raise ValueError("native download URL must identify the Telosnex fork")
    for key in ("linux_x64_sha256", "linux_arm64_sha256", "win_x64_sha256",
                "win_arm64_sha256", "android_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", pins.get(key, "")):
            raise ValueError(f"missing or malformed {key}")
    for key in ("binary_version", "android_binary_version"):
        if not re.fullmatch(r"libwebrtc\.m\d+\.\d+\.\d+-telosnex\.\d+", pins.get(key, "")):
            raise ValueError(f"missing or malformed {key}")
    if pins.get("android_asset") != "libwebrtc-android-release.aar":
        raise ValueError("unexpected Android asset name")
    android = (root / "android/build.gradle").read_text()
    if "io.github.webrtc-sdk:android" in android or "implementation telosnexWebRtcDependency" not in android:
        raise ValueError("Android must consume the checksum-verified fork AAR")
    print(f"pin consistency passed: Apple={apple[0][0]}, desktop={pins['binary_version']}, Android={pins['android_binary_version']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        verify(args.root)
    except ValueError as error:
        raise SystemExit(str(error))
