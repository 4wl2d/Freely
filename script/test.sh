#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
if [[ $# -eq 0 ]]; then
  exec "$TASK_ROOT/script/harness.py" run
fi
swift test --package-path Packages/FreelyCore
swift test --arch arm64 --no-parallel "$@"
