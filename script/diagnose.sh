#!/usr/bin/env bash
# Collect only Freely's structured events by default. --sample adds a raw developer stack sample.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---logs}"
case "$MODE" in
  --help|-h) echo "Usage: $0 [--logs|--sample]"; exit 0 ;;
  --logs|--sample) ;;
  *) echo "Usage: $0 [--logs|--sample]" >&2; exit 2 ;;
esac
umask 077
mkdir -p "$TASK_ROOT/dist/diagnostics"
CAPTURE_DIR="$(mktemp -d "$TASK_ROOT/dist/diagnostics/capture-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
/usr/bin/log show --last 15m --info --debug --style ndjson \
  --predicate 'subsystem == "local.freely.app" && process == "Freely"' | \
  python3 "$TASK_ROOT/script/filter_diagnostics.py" > "$CAPTURE_DIR/events.ndjson"
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  sw_vers
  git -C "$TASK_ROOT" rev-parse HEAD
  if [[ -n "$(git -C "$TASK_ROOT" status --porcelain)" ]]; then echo "working_tree=modified"; else echo "working_tree=clean"; fi
} > "$CAPTURE_DIR/environment.txt"
if [[ "$MODE" == --sample ]]; then
  APP_PID="$(pgrep -x Freely || true)"
  if [[ -z "$APP_PID" || "$APP_PID" == *$'\n'* ]]; then
    echo "Start exactly one Freely process before sampling. Logs saved to $CAPTURE_DIR" >&2
    exit 1
  fi
  echo "Capturing five seconds of stacks. Raw samples may contain local paths; review before sharing."
  /usr/bin/sample "$APP_PID" 5 10 -file "$CAPTURE_DIR/stacks.txt"
fi
echo "$CAPTURE_DIR"
