#!/bin/sh
# Device-free Foundation test. No Flutter host or WebRTC binary is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/webrtc-controller.XXXXXX")
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
  -Wno-unused-parameter -framework Foundation \
  -I"$ROOT/common/darwin/Classes" \
  "$ROOT/common/darwin/Classes/LocalAudioCaptureController.m" \
  "$ROOT/test/darwin/local_audio_capture_controller_test.m" \
  -o "$OUT/controller-test"
"$OUT/controller-test"
