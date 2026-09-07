#!/usr/bin/env python3
"""Download the pinned TDT evaluation model and verify every byte before use."""
import hashlib
import json
from pathlib import Path
import urllib.request

BASE = Path(__file__).resolve().parent

def valid(path, entry):
    if not path.is_file() or path.stat().st_size != entry['size']:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == entry['sha256']

def main():
    manifest = json.loads((BASE / 'tdt-model-manifest.json').read_text())
    destination = BASE / '.cache/parakeet-tdt-0.6b-v3'
    for entry in manifest['files']:
        path = destination / entry['path']
        if valid(path, entry): continue
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + '.partial')
        print('Fetching', entry['path'], entry['size'], 'bytes', flush=True)
        urllib.request.urlretrieve(entry['url'], temporary)
        if not valid(temporary, entry):
            raise RuntimeError('Checksum or size mismatch: ' + entry['path'])
        temporary.replace(path)
    print(f"Verified {len(manifest['files'])} files at {manifest['revision']}")

if __name__ == '__main__': main()
