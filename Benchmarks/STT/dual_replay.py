#!/usr/bin/env python3
"""Real-time dual decoder replay in one process with observed RSS/CPU."""
import argparse
import json
from pathlib import Path
import subprocess
import time

BASE = Path(__file__).resolve().parent

def main():
    p = argparse.ArgumentParser()
    p.add_argument('engine', choices=['fluid-tdt', 'fluid-eou', 'whisperkit', 'whisper.cpp'])
    p.add_argument('--seconds', type=float, default=1200)
    p.add_argument('--step', type=float, default=.32)
    args = p.parse_args()
    corpus = BASE / '.cache/corpus-v1'
    label = f"{args.engine}-dual-{int(args.seconds)}s-{args.step}s"
    output = BASE / 'results'
    output.mkdir(exist_ok=True)
    processes = []
    handles = []
    for source in ['dual']:
        if args.engine == 'whisper.cpp':
            command = [str(BASE / '.cache/whisper-native'), str(BASE / '.cache/ggml-base.en.bin'),
                       str(corpus / 'corpus.tsv'), str(args.seconds), '1', str(args.step), 'dual']
        else:
            command = [str(BASE / '.build/release/stt-gate'), args.engine, str(corpus / 'calibration.json'),
                       str(BASE / ('.cache/whisperkit-models' if args.engine == 'whisperkit' else '.cache/models')),
                       str(args.seconds), '1', str(args.step), source]
        stdout = (output / f'{label}-{source}.jsonl').open('w')
        stderr = (BASE / '.cache' / f'{label}-{source}.stderr').open('w')
        handles += [stdout, stderr]
        processes.append(subprocess.Popen(command, stdout=stdout, stderr=stderr))
    monitoring = (output / f'{label}-resources.jsonl').open('w')
    start = time.monotonic()
    try:
        while any(process.poll() is None for process in processes):
            alive = [process.pid for process in processes if process.poll() is None]
            result = subprocess.run(['ps', '-o', 'pid=,%cpu=,rss=', '-p', ','.join(map(str, alive))], capture_output=True, text=True)
            observations = []
            for line in result.stdout.splitlines():
                pid, cpu, rss = line.split()
                observations.append({'pid': int(pid), 'cpuPercent': float(cpu), 'rssBytes': int(rss) * 1024})
            monitoring.write(json.dumps({'elapsedSeconds': time.monotonic() - start, 'processes': observations,
                                         'totalRSSBytes': sum(r['rssBytes'] for r in observations)}) + '\n')
            monitoring.flush()
            time.sleep(1)
    finally:
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait()
        monitoring.close()
        for handle in handles: handle.close()
    statuses = [process.returncode for process in processes]
    (output / f'{label}-status.json').write_text(json.dumps({
        'engine': args.engine, 'secondsPerSource': args.seconds, 'stepSeconds': args.step,
        'exitCodes': statuses, 'processIsolation': False,
        'scope': 'Both independent decoders receive the same licensed mixed-meeting fixture concurrently at wall-clock pace. This doubles compute load but is not a recording of independent local and remote speakers.',
        'memoryMethod': 'ps RSS sampled each second for one process containing two independently constructed decoders',
        'hardwareCounterLimit': 'No GPU/ANE utilization or joules measured; Core ML use does not establish ANE execution'
    }, indent=2) + '\n')
    if any(statuses): raise SystemExit(1)
    print(label + ' complete', flush=True)

if __name__ == '__main__': main()
