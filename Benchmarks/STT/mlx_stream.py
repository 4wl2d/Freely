#!/usr/bin/env python3
"""Isolated upstream Python streaming evaluation; never shipped in the app."""
import argparse
import json
import time
from pathlib import Path
import mlx.core as mx
import numpy as np
from parakeet_mlx import from_pretrained

def emit(data):
    print(json.dumps(data), flush=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("corpus", type=Path)
    p.add_argument("--model", default="mlx-community/parakeet-tdt-0.6b-v3")
    p.add_argument("--limit", type=float, default=60)
    p.add_argument("--step", type=float, default=1)
    p.add_argument("--pace", action="store_true")
    args = p.parse_args()
    start = time.monotonic()
    model = from_pretrained(args.model)
    emit({"event": "load", "engine": "parakeet-mlx", "seconds": time.monotonic() - start,
          "rightContextFrames": 8, "leftContextFrames": 64, "depth": 1})
    origin = time.monotonic()
    audio_seconds = 0
    for fixture in json.loads(args.corpus.read_text()):
        if audio_seconds >= args.limit:
            break
        samples = np.fromfile(args.corpus.parent / fixture["file"], dtype="<f4")
        count = min(len(samples), int((args.limit - audio_seconds) * 16000))
        previous = ""
        with model.transcribe_stream(context_size=(64, 8), depth=1) as stream:
            for pos in range(0, count, int(args.step * 16000)):
                end = min(count, pos + int(args.step * 16000))
                source_end = audio_seconds + end / 16000
                if args.pace:
                    time.sleep(max(0, origin + source_end - time.monotonic()))
                begin = time.monotonic()
                stream.add_audio(mx.array(samples[pos:end]))
                text = stream.result.text
                done = time.monotonic()
                emit({"event": "partial", "engine": "parakeet-mlx", "fixture": fixture["id"],
                      "sourceEnd": source_end, "fixtureEnd": end / 16000, "wallElapsed": done - origin,
                      "inferenceSeconds": done - begin, "backlogSeconds": max(0, begin - origin - source_end) if args.pace else 0,
                      "changed": text != previous, "text": text, "finalizedTokens": len(stream.finalized_tokens),
                      "draftTokens": len(stream.draft_tokens), "melBufferFrames": stream.mel_buffer.shape[1]})
                previous = text
            # Upstream has no explicit audio flush/finalize. Result includes draft tokens.
            emit({"event": "final", "engine": "parakeet-mlx", "fixture": fixture["id"],
                  "split": fixture["split"], "duration": count / 16000, "text": previous,
                  "reference": fixture["reference"], "completeFixture": count == len(samples),
                  "flushSeconds": 0, "containsDraft": True})
        audio_seconds += count / 16000
    emit({"event": "end", "engine": "parakeet-mlx", "audioSeconds": audio_seconds,
          "wallSeconds": time.monotonic() - origin, "peakMLXBytes": mx.get_peak_memory()})

if __name__ == "__main__":
    main()
