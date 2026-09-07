#!/usr/bin/env python3
"""Build deterministic 25-minute AMI CC BY 4.0 corpus; never use user recordings."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request
import zipfile
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parent
CACHE = BASE / ".cache"
SOURCES = {
    "EN2001a.Mix-Headset.wav": "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/EN2001a/audio/EN2001a.Mix-Headset.wav",
    "ami_public_manual_1.6.2.zip": "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip",
}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true")
    args = parser.parse_args()
    CACHE.mkdir(exist_ok=True)
    provenance = []
    for name, url in SOURCES.items():
        path = CACHE / name
        if not path.exists():
            if not args.download:
                raise SystemExit(f"Missing {path}; rerun --download")
            partial = path.with_suffix(path.suffix + ".partial")
            urllib.request.urlretrieve(url, partial)
            partial.replace(path)
        provenance.append({"file": name, "url": url, "bytes": path.stat().st_size,
                           "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest()})
    words = []
    with zipfile.ZipFile(CACHE / "ami_public_manual_1.6.2.zip") as archive:
        for name in sorted(archive.namelist()):
            if name.startswith("words/EN2001a.") and name.endswith(".words.xml"):
                for word in ET.fromstring(archive.read(name)):
                    if word.tag == "w" and word.get("punc") != "true" and word.get("starttime"):
                        words.append({"start": float(word.get("starttime")), "end": float(word.get("endtime")),
                                      "text": word.text or "", "channel": name.split(".")[1]})
    words.sort(key=lambda w: (w["start"], w["channel"]))
    corpus = CACHE / "corpus-v1"
    corpus.mkdir(exist_ok=True)
    fixtures = []
    # Continuous meeting audio, including original silence, crosstalk, and noise.
    # Fixed boundaries deliberately expose truncation to every candidate equally.
    for start in range(0, 1500, 15):
        identifier = f"EN2001a-{start:04d}-{start + 15:04d}"
        path = corpus / f"{identifier}.f32"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", str(start), "-t", "15", "-i",
                        str(CACHE / "EN2001a.Mix-Headset.wav"), "-ac", "1", "-ar", "16000",
                        "-f", "f32le", str(path)], check=True)
        selected = [w for w in words if start <= w["start"] < start + 15]
        fixtures.append({"id": identifier, "file": path.name, "duration": path.stat().st_size / 64000,
                         "split": "calibration" if start < 1200 else "heldout",
                         "reference": " ".join(w["text"] for w in selected), "words": selected,
                         "sourceStart": start, "sha256": hashlib.file_digest(path.open("rb"), "sha256").hexdigest()})
    (corpus / "corpus.json").write_text(json.dumps(fixtures, indent=2) + "\n")
    (corpus / "calibration.json").write_text(json.dumps(fixtures[:80], indent=2) + "\n")
    (corpus / "heldout.json").write_text(json.dumps(fixtures[80:], indent=2) + "\n")
    (corpus / "corpus.tsv").write_text("\n".join(f"{f['id']}\t{corpus / f['file']}\t{f['duration']}\t{f['split']}\t{f['reference']}" for f in fixtures) + "\n")
    (corpus / "heldout.tsv").write_text("\n".join(f"{f['id']}\t{corpus / f['file']}\t{f['duration']}\t{f['split']}\t{f['reference']}" for f in fixtures[80:]) + "\n")
    (BASE / "corpus-manifest.json").write_text(json.dumps({
        "version": 1, "corpus": "AMI Meeting Corpus EN2001a", "license": "CC-BY-4.0",
        "attribution": "AMI Consortium; University of Edinburgh and partner institutions",
        "licenseEvidence": "https://groups.inf.ed.ac.uk/ami/download/",
        "sources": provenance, "audioSeconds": sum(f["duration"] for f in fixtures),
        "calibrationSeconds": 1200, "heldoutSeconds": 300,
        "referencePolicy": "Manual annotation words ordered by source start time and channel; punctuation-only annotations excluded. Words assigned by start timestamp; overlap produces interleaved references.",
        "limitations": ["One naturally recorded technical meeting, not a representative population of meetings",
                       "Fixed 15-second boundaries can cut words; all engines receive identical cuts",
                       "Modern framework names and consented user meeting fixtures remain additional required coverage"],
        "fixtures": [{k: v for k, v in f.items() if k not in ("words", "reference")} for f in fixtures]
    }, indent=2) + "\n")
    print(f"Prepared {len(fixtures)} fixtures; 1500 seconds; {corpus / 'corpus.json'}")

if __name__ == "__main__":
    main()
