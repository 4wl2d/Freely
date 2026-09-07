#!/usr/bin/env python3
"""Summarize actual JSONL samples; distinguish cadence/dispatch from speech latency."""
import argparse
import difflib
import json
import math
from pathlib import Path
import re
from text_metrics import technical_tokens

def words(text):
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)?", text.lower())

def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        current = [i]
        for j, y in enumerate(b, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (x != y)))
        previous = current
    return previous[-1]

def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(fraction * len(values)) - 1)] if values else None

def summarize(path):
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    partials = [r for r in rows if r['event'] == 'partial']
    finals = [r for r in rows if r['event'] == 'final' and r.get('completeFixture')]
    ending = next((r for r in rows if r['event'] == 'end'), None)
    loaded_sources = {r.get('source', 'systemAudio') for r in rows if r['event'] == 'load'}
    ended_sources = {r.get('source', 'systemAudio') for r in rows if r['event'] == 'end'}
    total_words = sum(len(words(r['reference'])) for r in finals)
    errors = sum(edit_distance(words(r['reference']), words(r['text'])) for r in finals)
    durations = [r['inferenceSeconds'] for r in partials]
    audio = sum(r['duration'] for r in finals)
    revisions = 0
    previous = {}
    for r in partials:
        key = (r.get('source', 'systemAudio'), r['fixture'])
        before = previous.get(key, [])
        after = words(r['text'])
        prefix = 0
        for x, y in zip(before, after):
            if x != y: break
            prefix += 1
        revisions += len(before) - prefix
        previous[key] = after
    technical_terms = ['XML', 'API', 'Java', 'database', 'interface', 'specification', 'prototype', 'annotation']
    def case_words(text):
        return technical_tokens(text)
    expected = sum(case_words(r['reference']).count(t) for r in finals for t in technical_terms)
    predicted = sum(case_words(r['text']).count(t) for r in finals for t in technical_terms)
    recovered = sum(min(case_words(r['reference']).count(t), case_words(r['text']).count(t)) for r in finals for t in technical_terms)
    source_durations = {}
    for row in finals:
        source = row.get('source', 'systemAudio')
        source_durations[source] = source_durations.get(source, 0) + row['duration']
    return {
        'input': str(path), 'engine': rows[0]['engine'] if rows else None,
        'complete': bool(loaded_sources) and loaded_sources == ended_sources,
        'loadedSources': sorted(loaded_sources), 'endedSources': sorted(ended_sources), 'metricVersion': 2,
        'fixtures': len(finals), 'audioSeconds': audio, 'referenceWords': total_words, 'wordErrors': errors,
        'WER': errors / total_words if total_words else None,
        'normalization': "Lowercase; ASCII alphanumeric words; internal apostrophes retained; punctuation/hyphens split; fillers/repetitions retained. No numeric expansion.",
        'caseSensitiveTechnicalTermRecall': recovered / expected if expected else None,
        'caseSensitiveTechnicalTermPrecision': recovered / predicted if predicted else None,
        'technicalNormalization': 'AMI acronym spellings X_M_L_ and X. M. L. map to XML; identifier case preserved; punctuation removed.',
        'technicalTermOccurrences': expected, 'technicalTerms': technical_terms,
        'partialUpdates': len(partials), 'replacedHypothesisWords': revisions,
        'processingRTF': (sum(durations) + sum(r.get('flushSeconds', 0) for r in finals)) / audio if audio else None,
        'sourceAudioSeconds': source_durations,
        'summedProcessingSecondsPerSourceTimelineSecond': sum(durations) / max(source_durations.values()) if source_durations else None,
        'dispatchSecondsP50': percentile(durations, .5), 'dispatchSecondsP95': percentile(durations, .95),
        'maximumPacedBacklogSeconds': max((r.get('backlogSeconds', 0) for r in partials), default=None),
        'loadSeconds': next((r['seconds'] for r in rows if r['event'] == 'load'), None),
        'cleanupSeconds': ending.get('cleanupSeconds') if ending else None,
        'speechAlignedPartialLatency': None, 'speechAlignedFinalizationLatency': None,
        'limitations': 'Dispatch duration excludes capture cadence and lookahead; speech-aligned latency is unmeasured. Technical-term recall is literal surface form and sparse in one meeting. Overlapping AMI references interleave concurrent speakers.'
    }

def main():
    p = argparse.ArgumentParser()
    p.add_argument('inputs', nargs='+', type=Path)
    p.add_argument('--output', type=Path)
    args = p.parse_args()
    result = [summarize(path) for path in args.inputs]
    text = json.dumps(result, indent=2) + '\n'
    if args.output: args.output.write_text(text)
    else: print(text, end='')

if __name__ == '__main__': main()
