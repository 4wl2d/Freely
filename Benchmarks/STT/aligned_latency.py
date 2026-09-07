#!/usr/bin/env python3
"""Reference-word-aligned paced latency; no inference-dispatch clock substitution.

Exact matching blocks of at least two normalized words anchor partials to AMI's
manual word timings. Coverage is reported because ASR mistakes and ambiguous
single words cannot establish a reliable represented-speech timestamp.
"""
import argparse
from collections import defaultdict
import difflib
import json
from pathlib import Path
from analyze import words, percentile

def aligned_matches(reference, hypothesis, minimum_block=2):
    matcher = difflib.SequenceMatcher(a=reference, b=hypothesis, autojunk=False)
    return {i for block in matcher.get_matching_blocks() if block.size >= minimum_block
            for i in range(block.a, block.a + block.size)}

def measure(rows, corpus):
    fixtures = {r['id']: r for r in corpus}
    groups = defaultdict(list)
    for row in rows:
        if row['event'] == 'partial':
            groups[(row.get('source', 'systemAudio'), row['fixture'])].append(row)
    first_latencies, stable_latencies = [], []
    eligible_count = 0
    negative_samples = 0
    per_fixture = []
    for (source, identity), partials in groups.items():
        fixture = fixtures[identity]
        expanded = [(token, word['end'] - fixture['sourceStart'])
                    for word in fixture['words'] for token in words(word['text'])]
        partials.sort(key=lambda r: r['fixtureEnd'])
        first, stable = {}, {}
        audio_offset = partials[0]['sourceEnd'] - partials[0]['fixtureEnd']
        eligible = [(i, token, end) for i, (token, end) in enumerate(expanded)
                    if end <= partials[-1]['fixtureEnd']]
        eligible_count += len(eligible)
        for row in partials:
            available = [(i, token, end) for i, token, end in eligible if end <= row['fixtureEnd']]
            matches = aligned_matches([token for _, token, _ in available], words(row['text']))
            indices = {available[i][0] for i in matches}
            for index, token, end in available:
                if index in indices:
                    latency = row['wallElapsed'] - (audio_offset + end)
                    if latency < -0.001:
                        negative_samples += 1
                        continue
                    first.setdefault(index, latency)
                    stable.setdefault(index, latency)
                else:
                    stable.pop(index, None)
        first_latencies.extend(first.values())
        stable_latencies.extend(stable.values())
        per_fixture.append({'source': source, 'fixture': identity, 'referenceWords': len(eligible),
                            'firstMatchedWords': len(first), 'finalStableMatchedWords': len(stable)})
    return {
        'method': 'AMI manual word-end timestamps; exact normalized matching blocks >=2 words within available audio; paced monotonic emission clock. Includes cadence and processing. Repeated words may align ambiguously.',
        'referenceWords': eligible_count, 'matchedWords': len(first_latencies),
        'coverage': len(first_latencies) / eligible_count if eligible_count else None,
        'firstCorrectWordLatencyP50Seconds': percentile(first_latencies, .5),
        'firstCorrectWordLatencyP95Seconds': percentile(first_latencies, .95),
        'stableCorrectWordLatencyP50Seconds': percentile(stable_latencies, .5),
        'stableCorrectWordLatencyP95Seconds': percentile(stable_latencies, .95),
        'negativeSamplesRejected': negative_samples,
        'notMeasured': 'Remote utterance-end to application final event. Fixed 15-second window flushes do not test the application VAD finalization policy.',
        'perFixture': per_fixture,
    }

def main():
    p = argparse.ArgumentParser()
    p.add_argument('samples', type=Path)
    p.add_argument('corpus', type=Path)
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    result = measure([json.loads(line) for line in args.samples.read_text().splitlines()], json.loads(args.corpus.read_text()))
    text = json.dumps(result, indent=2) + '\n'
    if args.output: args.output.write_text(text)
    else: print(text, end='')

if __name__ == '__main__': main()
