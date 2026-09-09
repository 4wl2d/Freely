#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
MODE="${1:-run}"
case "$MODE" in run|--verify|--build-only|--release|--logs|--telemetry|--debug|--diagnostics) ;; *) echo "Usage: $0 [--verify|--build-only|--release|--logs|--telemetry|--debug|--diagnostics]" >&2; exit 2;; esac
CONFIGURATION="${FREELY_CONFIGURATION:-debug}"
if [[ "$MODE" == --release ]]; then CONFIGURATION=release; fi
case "$CONFIGURATION" in debug|release) ;; *) echo "Configuration must be debug or release." >&2; exit 2;; esac
if [[ "$MODE" == --debug && "$CONFIGURATION" != debug ]]; then
  echo "LLDB requires a debug build. Release bundles never receive get-task-allow." >&2; exit 2
fi
if pgrep -x Freely >/dev/null; then
  pkill -TERM -x Freely
  for _ in {1..30}; do if ! pgrep -x Freely >/dev/null; then break; fi; sleep 0.1; done
  if pgrep -x Freely >/dev/null; then echo "Freely is still stopping; retry when it exits." >&2; exit 1; fi
fi
# The original mode is already held in MODE. Positional arguments safely represent
# an empty option list even in macOS Bash 3.2 with nounset enabled.
set --
if [[ -n "${FREELY_SWIFT_SCRATCH_PATH:-}" ]]; then
  set -- --scratch-path "$FREELY_SWIFT_SCRATCH_PATH"
fi
swift build "$@" -c "$CONFIGURATION" --arch arm64 --product Freely
BIN_DIR="$(swift build "$@" -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
APP_BUNDLE="$TASK_ROOT/dist/Freely.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/Freely" "$APP_BUNDLE/Contents/MacOS/Freely"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
BUILD_REVISION="$(git rev-parse --short=12 HEAD)"
BUILD_TREE=clean
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then BUILD_TREE=modified; fi
/usr/libexec/PlistBuddy -c "Add :FreelyBuildRevision string $BUILD_REVISION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FreelyBuildWorkingTree string $BUILD_TREE" "$APP_BUNDLE/Contents/Info.plist"
cp Freely/Resources/model-manifest.json "$APP_BUNDLE/Contents/Resources/model-manifest.json"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ditto Resources/Licenses "$APP_BUNDLE/Contents/Resources/Licenses"
if [[ -n "${FREELY_BUNDLE_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $FREELY_BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
fi
if [[ -n "${FREELY_OAUTH_CLIENT_ID:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Add :FreelyOAuthClientID string $FREELY_OAUTH_CLIENT_ID" "$APP_BUNDLE/Contents/Info.plist"
fi
# The app's own required resources use Bundle.main in the standard Resources directory.
# FluidAudio's optional TTS resources are retained for license/completeness; the ASR path
# loads only the explicitly verified model directory and does not access Bundle.module.
shopt -s nullglob
for bundle in "$BIN_DIR"/FluidAudio_*.bundle; do ditto "$bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"; done
SIGNING_ENTITLEMENTS=Resources/Freely.entitlements
if [[ "$MODE" == --debug ]]; then
  SIGNING_ENTITLEMENTS="$(mktemp -t freely-debug-entitlements)"
  trap 'rm -f "$SIGNING_ENTITLEMENTS"' EXIT
  cp Resources/Freely.entitlements "$SIGNING_ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$SIGNING_ENTITLEMENTS"
fi
codesign --force --sign "${FREELY_SIGN_IDENTITY:--}" --options runtime --entitlements "$SIGNING_ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
if [[ "$MODE" == --build-only ]]; then echo "$APP_BUNDLE"; exit 0; fi
if [[ "$MODE" == --debug ]]; then
  lldb -o run -- "$APP_BUNDLE/Contents/MacOS/Freely" --diagnostics --diagnostic-verbose
  exit $?
fi
if [[ "$MODE" == --diagnostics || "$MODE" == --telemetry ]]; then
  /usr/bin/open -n "$APP_BUNDLE" --args --diagnostics --diagnostic-verbose
else
  /usr/bin/open -n "$APP_BUNDLE"
fi
case "$MODE" in
  --verify) sleep 1; pgrep -x Freely ;;
  --logs) /usr/bin/log stream --info --style compact --predicate 'process == "Freely"' ;;
  --telemetry) /usr/bin/log stream --level debug --style compact --predicate 'subsystem == "local.freely.app"' ;;
esac
