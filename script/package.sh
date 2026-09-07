#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
MEETINGCOPILOT_CONFIGURATION=release ./script/build_and_run.sh --build-only
APP="$TASK_ROOT/dist/MeetingCopilot.app"
ZIP="$TASK_ROOT/dist/MeetingCopilot-1.0.0-macOS-arm64.zip"
archive_app() {
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  zip -j -q "$ZIP" "$TASK_ROOT/LICENSE" "$TASK_ROOT/NOTICE"
}
codesign --verify --strict "$APP"
file "$APP/Contents/MacOS/MeetingCopilot"
archive_app
if [[ -n "${MEETINGCOPILOT_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${MEETINGCOPILOT_SIGN_IDENTITY:-}" || "$MEETINGCOPILOT_SIGN_IDENTITY" == - ]]; then
    echo 'Notarization requires a user-supplied Developer ID signing identity.' >&2
    exit 1
  fi
  xcrun notarytool submit "$ZIP" --keychain-profile "$MEETINGCOPILOT_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  archive_app
  echo 'Developer-ID signed, notarized, stapled and assessed artifact.'
else
  echo 'Local artifact only: NOT NOTARIZED. No Developer ID/notarization credential was supplied.'
fi
shasum -a 256 "$ZIP" > "$ZIP.sha256"
echo "$ZIP"
