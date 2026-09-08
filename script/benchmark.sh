#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TASK_ROOT"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
MODE="${1:---core}"
case "$MODE" in
  --core) swift run -c release --package-path Packages/FreelyCore FreelyCoreBenchmarks --output "$TASK_ROOT/Benchmarks/results/core-replay-4h.json" ;;
  --stt-build) Benchmarks/STT/run.sh build ;;
  --stt-initial) Benchmarks/STT/run.sh initial ;;
  --stt-dual) Benchmarks/STT/run.sh dual "${2:-1200}" ;;
  --soak)
    export FREELY_SOAK=1
    export FREELY_SOAK_SECONDS="${2:-14400}"
    swift test -c release --filter IntegratedSoakTests
    ;;
  *) echo 'Usage: script/benchmark.sh [--core|--stt-build|--stt-initial|--stt-dual [seconds]|--soak [seconds]]' >&2; exit 2 ;;
esac
