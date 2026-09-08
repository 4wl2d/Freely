#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
APP="$TASK_ROOT/.cache/CaptureFixture.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 6 -parse-as-library -target arm64-apple-macos15.0 "$TASK_ROOT/Tests/Fixtures/CaptureFixture.swift" -o "$APP/Contents/MacOS/CaptureFixture"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>CaptureFixture</string><key>CFBundleIdentifier</key><string>local.freely.capture-fixture</string><key>CFBundleName</key><string>CaptureFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ $# -gt 0 ]]; then
  AUDIO_FILE="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  [[ -f "$AUDIO_FILE" ]] || { echo 'Audio fixture file is unavailable.' >&2; exit 1; }
  open -n "$APP" --args --audio-file "$AUDIO_FILE"
else
  open -n "$APP"
fi
