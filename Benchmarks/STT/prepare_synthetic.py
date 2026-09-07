#!/usr/bin/env python3
"""Local deterministic controls plus supplemental system-voice technical speech."""
import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import numpy as np

BASE=Path(__file__).resolve().parent
TEXTS=[
    ('kotlin-flow','In Kotlin, how should StateFlow differ from SharedFlow when a Jetpack Compose screen resumes after cancellation?'),
    ('build-and-api','Can Gradle run a test for CoroutineScope, MutableStateFlow, and a REST API that streams JSON with server sent events?'),
    ('macos-frameworks','Should SwiftUI use an actor to own ScreenCaptureKit, AVFoundation, URLSession, and Keychain state on macOS?'),
    ('negation-correction','Should we cancel the old coroutine before saving? I meant, should we not cancel it until the save has completed?'),
    ('followup','How should the repository cache that response? What changes if the screen is paused? And should it keep the previous value?'),
]

def write_manifest(output,fixtures):
    (output/'corpus.json').write_text(json.dumps(fixtures,indent=2)+'\n')
    (output/'corpus.tsv').write_text('\n'.join(f"{f['id']}\t{(output/f['file']).resolve()}\t{f['duration']}\t{f['split']}\t{f['reference']}" for f in fixtures)+'\n')
    (output/'questions.tsv').write_text('')
    (output/'words.tsv').write_text('')

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--noise-only',action='store_true');args=parser.parse_args()
    rng=np.random.default_rng(20260907)
    noise=BASE/'.cache/noise-corpus-v1';noise.mkdir(exist_ok=True);fixtures=[];timeline=0
    for label,rms in [('digital-silence',0),('quiet-white',.0003),('moderate-noise-step',.00075),('room-noise-step',.002),('louder-room-noise-step',.01)]:
        samples=rng.normal(0,rms,30*16000).astype('<f4');samples[:32000]=0
        path=noise/f'{label}.f32';samples.tofile(path)
        fixtures.append({'id':label,'file':path.name,'duration':30,'sourceStart':timeline,'split':'synthetic-control','reference':'','words':[],'questions':[],'rmsAfterTwoSeconds':rms,'sha256':hashlib.file_digest(path.open('rb'),'sha256').hexdigest()});timeline+=30
    write_manifest(noise,fixtures)
    (BASE/'noise-fixture-manifest.json').write_text(json.dumps({'version':1,'seed':20260907,'sampleFormat':'monoFloat32littleEndian16000Hz','purpose':'Synthetic VAD/noise controls, not human accuracy evidence','fixtures':fixtures},indent=2)+'\n')
    if args.noise_only:
        print('Prepared five deterministic noise controls');return
    speech=BASE/'.cache/synthetic-speech-v1';speech.mkdir(exist_ok=True);spoken=[];timeline=0
    for label,text in TEXTS:
        aiff=speech/f'{label}.aiff';pcm=speech/f'{label}.f32'
        subprocess.run(['/usr/bin/say','-v','Samantha','-r','160','-o',str(aiff),text],check=True)
        subprocess.run(['ffmpeg','-v','error','-y','-i',str(aiff),'-ac','1','-ar','16000','-f','f32le',str(pcm)],check=True)
        duration=pcm.stat().st_size/64000
        # Reference here is synthetic text only; no human-timed word alignment is claimed.
        spoken.append({'id':label,'file':pcm.name,'duration':duration,'sourceStart':timeline,'split':'synthetic-regression','reference':text,'words':[],'questions':[],'sha256':hashlib.file_digest(pcm.open('rb'),'sha256').hexdigest()});timeline+=duration
    write_manifest(speech,spoken)
    (BASE/'synthetic-fixture-manifest.json').write_text(json.dumps({
        'version':1,'purpose':'Supplemental regression only; excluded from natural-corpus ranking and human accuracy claims',
        'voice':'Installed macOS Samantha en_US','synthesis':'/usr/bin/say -v Samantha -r160; ffmpeg16kHzmonoFloat32',
        'machineOS':'macOS26.6.2','provenance':'Project-authored synthetic text and seeded numerical controls; no human recording. Generated audio and Apple voice assets are not redistributed.',
        'noiseSeed':20260907,'noise':fixtures,'speech':spoken,
        'limitations':'Spoken negation correction does not guarantee that any engine will emit a late ASR revision. Follow-up semantics and generation fencing require domain/integration tests.'
    },indent=2)+'\n')
    print('Prepared five noise controls and five supplemental technical speech fixtures')

if __name__=='__main__':main()
