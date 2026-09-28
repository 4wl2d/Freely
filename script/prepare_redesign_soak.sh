#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORPUS="$TASK_ROOT/.cache/redesign-soak-corpus"
command -v ffmpeg >/dev/null
mkdir -p "$CORPUS"
cat > "$CORPUS/local.txt" <<'TEXT'
I would keep one owner for each task. We can cancel the task and wait for it to finish. The result should carry a revision number. A late result from an old session must be discarded. The screen source is chosen explicitly. Hiding the panel should not stop transcription. I will explain the design with a short example. The application keeps a bounded queue and reports missing audio. These statements are synthetic test material.
TEXT
cat > "$CORPUS/remote.txt" <<'TEXT'
How would you prevent a late response from updating a closed session? What happens if the screen source disappears? Can you explain the difference between pausing audio and hiding the panel? How do you keep memory bounded during a long meeting? What tests would verify that a private panel does not appear in the presentation? Can you explain the cancellation sequence? What happens when an older transcript segment changes? These questions are synthetic test material.
TEXT
/usr/bin/say -v Samantha -r 150 -f "$CORPUS/local.txt" -o "$CORPUS/local.aiff"
/usr/bin/say -v Daniel -r 150 -f "$CORPUS/remote.txt" -o "$CORPUS/remote.aiff"
for stream in local remote; do
  ffmpeg -v error -y -i "$CORPUS/$stream.aiff" -af apad=pad_dur=4 -ar 16000 -ac 1 -f f32le "$CORPUS/$stream.f32"
done
python3 - "$CORPUS" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
root = Path(sys.argv[1])
for name, source in [('local', 'localUser'), ('remote', 'systemAudio')]:
    data = (root / (name + '.f32')).read_bytes()
    manifest = [{'file': name + '.f32', 'duration': len(data) / 64000, 'sha256': hashlib.sha256(data).hexdigest()}]
    (root / (source + '.json')).write_text(json.dumps(manifest, indent=2) + '\n')
PY
