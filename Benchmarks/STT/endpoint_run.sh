#!/bin/bash
set -euo pipefail
STT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$STT_ROOT"
export STT_GATE_SYSTEM_RMS_FLOOR="${STT_GATE_SYSTEM_RMS_FLOOR:-0.001}"
export STT_GATE_MIC_RMS_FLOOR="${STT_GATE_MIC_RMS_FLOOR:-0.004}"
mode="${1:-calibration}"
case "$mode" in
  calibration) split=calibration; seconds=1200; paced=0 ;;
  calibration-short) split=calibration; seconds=300; paced=0 ;;
  calibration-paced) split=calibration; seconds=120; paced=1 ;;
  heldout) split=heldout; seconds=300; paced=1 ;;
  *) echo 'Usage: endpoint_run.sh {calibration|calibration-short|calibration-paced|heldout}' >&2; exit 2 ;;
esac
suffix="${STT_GATE_RUN_SUFFIX:+-$STT_GATE_RUN_SUFFIX}"
corpus="$STT_ROOT/.cache/paired-corpus-v1"
/usr/bin/time -l .build/release/stt-gate fluid-tdt "$corpus/localUser-endpoint-$split.json" .cache/models "$seconds" "$paced" .32 dual "$corpus/systemAudio-endpoint-$split.json" --endpoint > "results/fluid-tdt-paired-endpoint-$mode$suffix.jsonl" 2> ".cache/fluid-tdt-paired-endpoint-$mode$suffix.stderr"
/usr/bin/time -l .cache/whisper-endpoint .cache/ggml-base.en.bin "$corpus/localUser-endpoint-$split.tsv" "$corpus/localUser-endpoint-$split-questions.tsv" "$corpus/localUser-endpoint-$split-words.tsv" "$seconds" "$paced" .32 dual "$corpus/systemAudio-endpoint-$split.tsv" "$corpus/systemAudio-endpoint-$split-questions.tsv" "$corpus/systemAudio-endpoint-$split-words.tsv" > "results/whisper-cpp-paired-endpoint-$mode$suffix.jsonl" 2> ".cache/whisper-cpp-paired-endpoint-$mode$suffix.stderr"
