#!/usr/bin/env python3
"""Fetch optional evaluation candidates at recorded revisions; verify Hub hashes."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import urllib.parse
import urllib.request

BASE = Path(__file__).resolve().parent

def tree(repository, revision, prefix):
    url = f'https://huggingface.co/api/models/{repository}/tree/{revision}/{prefix}?recursive=true&expand=false'
    result = []
    while url:
        with urllib.request.urlopen(url) as response:
            result.extend(json.load(response))
            match = re.search(r'<([^>]+)>;\s*rel="next"', response.headers.get('Link', ''))
            url = match.group(1) if match else None
    return [entry for entry in result if entry['type'] == 'file']

def fetch(repository, revision, entries, destination, strip=''):
    checked = []
    for entry in entries:
        relative = entry['path'][len(strip):]
        if '..' in Path(relative).parts or Path(relative).is_absolute():
            raise RuntimeError('Unsafe model path')
        path = destination / relative
        expected_sha = entry.get('lfs', {}).get('oid')
        expected_git = entry.get('oid') if not expected_sha else None
        def validate(file):
            if not file.is_file() or file.stat().st_size != entry['size']: return None
            sha = hashlib.sha256()
            git = hashlib.sha1(f"blob {entry['size']}\0".encode())
            with file.open('rb') as stream:
                while chunk := stream.read(1024 * 1024):
                    sha.update(chunk)
                    git.update(chunk)
            if expected_sha and sha.hexdigest() != expected_sha: return None
            if expected_git and git.hexdigest() != expected_git: return None
            return sha.hexdigest()
        digest = validate(path)
        url = f'https://huggingface.co/{repository}/resolve/{revision}/{urllib.parse.quote(entry["path"])}'
        if digest is None:
            path.parent.mkdir(parents=True, exist_ok=True)
            partial = path.with_suffix(path.suffix + '.partial')
            print('Fetching', repository, entry['path'], entry['size'], flush=True)
            urllib.request.urlretrieve(url, partial)
            digest = validate(partial)
            if digest is None: raise RuntimeError('Model checksum mismatch: ' + entry['path'])
            partial.replace(path)
        checked.append({'path': entry['path'], 'bytes': entry['size'], 'sha256': digest, 'url': url})
    return checked

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--engines', default='eou,whisperkit,mlx,whisper-cpp')
    args = parser.parse_args()
    info = json.loads((BASE / 'candidate-versions.json').read_text())
    versions = {row['engine']: row for row in info['models']}
    results = {}
    for engine in args.engines.split(','):
        model = versions[engine]
        repo, revision = model['repository'], model['revision']
        prefix = '320ms' if engine == 'eou' else 'openai_whisper-base.en' if engine == 'whisperkit' else ''
        entries = tree(repo, revision, prefix)
        if engine == 'eou':
            entries = [e for e in entries if e['path'].startswith(('320ms/streaming_encoder.mlmodelc/', '320ms/decoder.mlmodelc/', '320ms/joint_decision.mlmodelc/')) or e['path'] == '320ms/vocab.json']
            destination = BASE / '.cache/models/parakeet-eou-streaming/320ms'
        elif engine == 'whisperkit':
            destination = BASE / '.cache/whisperkit-models/models/argmaxinc/whisperkit-coreml/openai_whisper-base.en'
        elif engine == 'mlx':
            entries = [e for e in entries if e['path'].endswith(('.json', '.safetensors'))]
            destination = BASE / '.cache/mlx-model'
        else:
            entries = [e for e in entries if e['path'] == 'ggml-base.en.bin']
            destination = BASE / '.cache'
        if not entries:
            raise RuntimeError('Pinned candidate has no matching files: ' + engine)
        results[engine] = fetch(repo, revision, entries, destination, prefix + '/' if prefix else '')
        if engine == 'whisperkit':
            repo, revision = 'openai/whisper-base.en', '911407f4214e0e1d82085af863093ec0b66f9cd6'
            entries = [e for e in tree(repo, revision, '') if e['path'] in ['config.json', 'tokenizer.json', 'tokenizer_config.json']]
            results['whisperkit-tokenizer'] = fetch(repo, revision, entries, BASE / '.cache/whisperkit-models/models/openai/whisper-base.en')
    (BASE / 'candidate-file-checksums.json').write_text(json.dumps(results, indent=2) + '\n')
    print('All requested candidate files verified')

if __name__ == '__main__': main()
