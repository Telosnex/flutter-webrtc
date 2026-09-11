#!/usr/bin/env python3
"""Verify a Telosnex Android WebRTC artifact before pinning or publication."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

ABIS = ("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
NATIVE_LIBRARY = "libjingle_peerconnection_so.so"
NATIVE_SYMBOLS = (
    b"Java_org_webrtc_PeerConnectionFactory_nativeAcquireAudioRecording",
    b"Java_org_webrtc_PeerConnectionFactory_nativeReleaseAudioRecording",
    b"Java_org_webrtc_PeerConnectionFactory_nativeGetAudioRecordingState",
)
JAVA_METHODS = {
    "org.webrtc.PeerConnectionFactory": (
        "public int acquireAudioRecording();",
        "public int releaseAudioRecording();",
        "public org.webrtc.PeerConnectionFactory$AudioRecordingState getAudioRecordingState();",
    ),
    "org.webrtc.audio.JavaAudioDeviceModule": (
        "public void applyAudioProcessingOptions(org.webrtc.audio.AudioProcessingOptions);",
    ),
}


def read_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", "[")) or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("aar", type=Path)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "third_party"
        / "libwebrtc_version.ini",
    )
    parser.add_argument(
        "--expected-sha",
        help="Pre-publication override; final verification should use the manifest pin.",
    )
    args = parser.parse_args()

    manifest = read_manifest(args.manifest)
    expected_sha = (args.expected_sha or manifest.get("android_sha256", "")).lower()
    if len(expected_sha) != 64 or any(c not in "0123456789abcdef" for c in expected_sha):
        raise SystemExit("expected Android SHA-256 is missing or malformed")
    actual_sha = hashlib.sha256(args.aar.read_bytes()).hexdigest()
    if actual_sha != expected_sha:
        raise SystemExit(f"SHA-256 mismatch: expected {expected_sha}, got {actual_sha}")

    with tempfile.TemporaryDirectory() as temporary:
        classes_jar = Path(temporary) / "classes.jar"
        with zipfile.ZipFile(args.aar) as archive:
            names = set(archive.namelist())
            if "classes.jar" not in names:
                raise SystemExit("AAR has no classes.jar")
            classes_jar.write_bytes(archive.read("classes.jar"))
            for abi in ABIS:
                member = f"jni/{abi}/{NATIVE_LIBRARY}"
                if member not in names:
                    raise SystemExit(f"AAR is missing {member}")
                library = archive.read(member)
                for symbol in NATIVE_SYMBOLS:
                    if symbol not in library:
                        raise SystemExit(
                            f"{member} is missing JNI symbol {symbol.decode()}"
                        )

        for class_name, methods in JAVA_METHODS.items():
            output = subprocess.check_output(
                ["javap", "-public", "-classpath", str(classes_jar), class_name],
                text=True,
            )
            for method in methods:
                if method not in output:
                    raise SystemExit(f"{class_name} is missing: {method}")

    print(f"verified {args.aar}: sha256={actual_sha}, ABIs={','.join(ABIS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
