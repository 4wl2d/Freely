#!/usr/bin/env python3
"""Prepare source-distinct AMI replay: headset A local, B-E mixed remote."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

BASE = Path(__file__).resolve().parent
CACHE = BASE / '.cache'

def download(channel):
    name = f'EN2001a.Headset-{channel}.wav'
    url = f'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/EN2001a/audio/{name}'
    path = CACHE / name
    if not path.exists():
        partial = path.with_suffix('.wav.partial')
        urllib.request.urlretrieve(url, partial)
        partial.replace(path)
    with path.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    return {'file': name, 'url': url, 'bytes': path.stat().st_size, 'sha256': digest}

def main():
    corpus = json.loads((CACHE / 'corpus-v1/corpus.json').read_text())
    with concurrent.futures.ThreadPoolExecutor(5) as pool:
        sources = list(pool.map(download, range(5)))
    output = CACHE / 'paired-corpus-v1'
    output.mkdir(exist_ok=True)
    for identity, channels in [('localUser', [0]), ('systemAudio', [1, 2, 3, 4])]:
        pcm = output / f'{identity}.f32'
        args = ['ffmpeg', '-v', 'error', '-y']
        for channel in channels:
            args += ['-t', '1500', '-i', str(CACHE / f'EN2001a.Headset-{channel}.wav')]
        if len(channels) > 1:
            args += ['-filter_complex', 'amix=inputs=4:duration=longest:normalize=1']
        args += ['-ac', '1', '-ar', '16000', '-f', 'f32le', str(pcm)]
        subprocess.run(args, check=True)
        fixtures = []
        with pcm.open('rb') as stream:
            for fixture in corpus:
                start = fixture['sourceStart']
                identifier = f"{identity}-{fixture['id']}"
                path = output / f'{identifier}.f32'
                stream.seek(start * 64000)
                data = stream.read(15 * 64000)
                path.write_bytes(data)
                selected = [w for w in fixture['words'] if (w['channel'] == 'A') == (identity == 'localUser')]
                fixtures.append({'id': identifier, 'file': path.name, 'duration': len(data) / 64000,
                                 'split': fixture['split'], 'reference': ' '.join(w['text'] for w in selected),
                                 'words': selected, 'sourceStart': start, 'sha256': hashlib.sha256(data).hexdigest()})
        (output / f'{identity}.json').write_text(json.dumps(fixtures, indent=2) + '\n')
    (BASE / 'dual-corpus-manifest.json').write_text(json.dumps({
        'version': 1, 'corpus': 'AMI EN2001a independent headset sources', 'license': 'CC-BY-4.0',
        'attribution': 'AMI Consortium, University of Edinburgh and partner institutions',
        'licenseEvidence': 'https://groups.inf.ed.ac.uk/ami/download/', 'sources': sources,
        'mappingEvidence': 'AMI manual annotations1.6.2 corpusResources/meetings.xml: EN2001a A=0 B=1 C=2 D=3 E=4',
        'sourceMapping': {'localUser': 'Headset0, annotation channelA', 'systemAudio': 'Normalized mix of Headsets1-4, annotation channelsB-E'},
        'secondsPerSource': 1500, 'calibrationSeconds': 1200, 'heldoutSeconds': 300,
        'scope': 'Synchronous naturally recorded independent microphones from one AMI meeting. Simulated source roles; acoustic bleed remains possible. No user device capture evidence.'
    }, indent=2) + '\n')
    print('Prepared paired localUser/systemAudio corpus at', output)

if __name__ == '__main__': main()
