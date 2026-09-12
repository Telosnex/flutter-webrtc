import shutil
import tempfile
import unittest
from pathlib import Path

from verify_native_pins import verify


class NativePinTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = Path(__file__).resolve().parents[1]
        for name in ("ios/flutter_webrtc.podspec", "macos/flutter_webrtc.podspec",
                     "ios/flutter_webrtc/Package.swift", "macos/flutter_webrtc/Package.swift",
                     "third_party/libwebrtc_version.ini", "android/build.gradle"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source / name, path)

    def change(self, name, before, after):
        path = self.root / name
        text = path.read_text()
        self.assertIn(before, text)
        path.write_text(text.replace(before, after))

    def test_current_pins_match(self):
        verify(self.root)

    def test_fork_suffix_drift_is_rejected(self):
        self.change("ios/flutter_webrtc.podspec", "-telosnex.", "-other.")
        with self.assertRaises(ValueError):
            verify(self.root)

    def test_spm_checksum_drift_is_rejected(self):
        path = self.root / "macos/flutter_webrtc/Package.swift"
        import re
        path.write_text(re.sub(r'checksum: "[0-9a-f]{64}"', 'checksum: "' + '0' * 64 + '"', path.read_text()))
        with self.assertRaises(ValueError):
            verify(self.root)

    def test_upstream_android_dependency_is_rejected(self):
        self.change("android/build.gradle", "implementation telosnexWebRtcDependency",
                    "implementation 'io.github.webrtc-sdk:android:144.7559.09'")
        with self.assertRaises(ValueError):
            verify(self.root)

    def test_missing_android_hash_is_rejected(self):
        self.change("third_party/libwebrtc_version.ini", "android_sha256", "unused_hash")
        with self.assertRaises(ValueError):
            verify(self.root)
