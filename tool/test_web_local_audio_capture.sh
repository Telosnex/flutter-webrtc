#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REAL_CHROME=${TELOSNEX_TEST_CHROME:-}
if [ -z "$REAL_CHROME" ]; then
  for candidate in \
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
    "$(command -v google-chrome 2>/dev/null || true)" \
    "$(command -v chromium 2>/dev/null || true)" \
    "$(command -v chromium-browser 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      REAL_CHROME=$candidate
      break
    fi
  done
fi
if [ -z "$REAL_CHROME" ]; then
  echo 'Chrome/Chromium not found; set TELOSNEX_TEST_CHROME.' >&2
  exit 1
fi

WRAPPER=$(mktemp "${TMPDIR:-/tmp}/flutter-webrtc-chrome.XXXXXX")
ANALYSIS_BACKUP="$WRAPPER.analysis_options"
cp "$ROOT/analysis_options.yaml" "$ANALYSIS_BACKUP"
cleanup() {
  cp "$ANALYSIS_BACKUP" "$ROOT/analysis_options.yaml"
  rm -f "$WRAPPER" "$ANALYSIS_BACKUP"
}
trap cleanup EXIT INT TERM
cat > "$WRAPPER" <<'SCRIPT'
#!/bin/sh
exec "$TELOSNEX_REAL_CHROME" \
  --use-fake-device-for-media-stream \
  --use-fake-ui-for-media-stream \
  --autoplay-policy=no-user-gesture-required \
  "$@"
SCRIPT
chmod +x "$WRAPPER"

cd "$ROOT"
TELOSNEX_REAL_CHROME="$REAL_CHROME" \
CHROME_EXECUTABLE="$WRAPPER" \
  flutter test --platform chrome test/web_local_audio_capture_test.dart
TELOSNEX_REAL_CHROME="$REAL_CHROME" \
CHROME_EXECUTABLE="$WRAPPER" \
  flutter test --wasm --platform chrome test/web_local_audio_capture_test.dart
