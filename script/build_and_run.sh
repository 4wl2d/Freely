#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build-only|--release|--logs|--telemetry|--debug) ;; *) echo "Usage: $0 [--verify|--build-only|--release|--logs|--telemetry|--debug]" >&2; exit 2;; esac
CONFIGURATION="${MEETINGCOPILOT_CONFIGURATION:-debug}"
if [[ "$MODE" == --release ]]; then CONFIGURATION=release; fi
case "$CONFIGURATION" in debug|release) ;; *) echo "Configuration must be debug or release." >&2; exit 2;; esac
if pgrep -x MeetingCopilot >/dev/null; then
  pkill -TERM -x MeetingCopilot
  for _ in {1..30}; do if ! pgrep -x MeetingCopilot >/dev/null; then break; fi; sleep 0.1; done
  if pgrep -x MeetingCopilot >/dev/null; then echo "MeetingCopilot is still stopping; retry when it exits." >&2; exit 1; fi
fi
swift build -c "$CONFIGURATION" --arch arm64 --product MeetingCopilot
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP_BUNDLE="$TASK_ROOT/dist/MeetingCopilot.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/MeetingCopilot" "$APP_BUNDLE/Contents/MacOS/MeetingCopilot"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp MeetingCopilot/Resources/model-manifest.json "$APP_BUNDLE/Contents/Resources/model-manifest.json"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ditto Resources/Licenses "$APP_BUNDLE/Contents/Resources/Licenses"
if [[ -n "${MEETINGCOPILOT_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MEETINGCOPILOT_BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "${MEETINGCOPILOT_OAUTH_CLIENT_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :MeetingCopilotOAuthClientID string $MEETINGCOPILOT_OAUTH_CLIENT_ID" "$APP_BUNDLE/Contents/Info.plist"
fi
# The app's own required resources use Bundle.main in the standard Resources directory.
# FluidAudio's optional TTS resources are retained for license/completeness; the ASR path
# loads only the explicitly verified model directory and does not access Bundle.module.
shopt -s nullglob
for bundle in "$BIN_DIR"/FluidAudio_*.bundle; do ditto "$bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"; done
codesign --force --sign "${MEETINGCOPILOT_SIGN_IDENTITY:--}" --options runtime --entitlements Resources/MeetingCopilot.entitlements "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
if [[ "$MODE" == --build-only ]]; then echo "$APP_BUNDLE"; exit 0; fi
/usr/bin/open -n "$APP_BUNDLE"
case "$MODE" in
  --verify) sleep 1; pgrep -x MeetingCopilot ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "MeetingCopilot"' ;;
  --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.meetingcopilot.app"' ;;
  --debug) lldb -n MeetingCopilot ;;
esac
