#!/usr/bin/env python3
"""Score whole-source reference so VAD omissions remain word errors."""
import argparse
import json
from pathlib import Path
import re
from analyze import words, edit_distance, percentile
from text_metrics import technical_tokens, recognizes_tail

TERMS = ['XML', 'API', 'Java', 'database', 'interface', 'specification', 'prototype', 'annotation']

def score(path):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    result = []
    for ending in [r for r in rows if r['event'] == 'end']:
        source = ending['source']
        own = [r for r in rows if r.get('source') == source]
        final = [r for r in own if r['event'] == 'final']
        partial = [r for r in own if r['event'] == 'partial']
        questions = [r for r in own if r['event'] == 'questionFinal']
        reference = ending['reference']
        hypothesis = ' '.join(r['text'] for r in final)
        a, b = words(reference), words(hypothesis)
        case_words = technical_tokens
        expected = sum(case_words(reference).count(t) for t in TERMS)
        predicted = sum(case_words(hypothesis).count(t) for t in TERMS)
        correct = sum(min(case_words(reference).count(t), case_words(hypothesis).count(t)) for t in TERMS)
        # Reconcile the bounded transcript across final windows (including empty
        # VAD windows), rather than assuming a question fits one ASR segment.
        for question in questions:
            prior=' '.join(r['text'] for r in final if r['sourceEnd'] < question['sourceEnd'] - .000001)
            question['recognizedTailRaw']=question['recognizedTail']
            covering=next((r for r in final if abs(r['sourceEnd']-question['sourceEnd'])<.000001),None)
            context=' '.join(prior.split()[-20:])+' '+(covering['text'] if covering else '')
            question['recognizedTail']=bool(covering and covering['decoded'] and covering['text'].strip() and question['questionEnd']>=covering['windowStart'] and recognizes_tail(context,question['questionReference']))
        recognized = [q for q in questions if q['recognizedTail']]
        delays = [q['delaySeconds'] for q in recognized if q['delaySeconds'] >= 0] if ending['paced'] else []
        utterance_delays = [r['finalizationFromReferenceSeconds'] for r in final if r['reason'] == 'silence' and r['decoded'] and r['text'].strip() and r.get('finalizationFromReferenceSeconds') is not None and r['finalizationFromReferenceSeconds'] >= 0] if ending['paced'] else []
        result.append({
            'engine': ending['engine'], 'source': source, 'input': str(path), 'paced': ending['paced'],
            'metricVersion':2,
            'audioSeconds': ending['audioSeconds'], 'frames20ms': ending['frames20ms'],
            'referenceWords': len(a), 'wordErrors': edit_distance(a,b), 'WER': edit_distance(a,b) / len(a) if a else None,
            'technicalTerms': TERMS, 'technicalReferenceOccurrences': expected,
            'technicalRecall': correct / expected if expected else None,
            'technicalPrecision': correct / predicted if predicted else None,
            'technicalF1': 2*correct/(expected+predicted) if expected+predicted else None,
            'segments': len(final), 'silenceEndpoints': sum(r['reason']=='silence' for r in final),
            'maximumWindowEndpoints': sum(r['reason']=='maximumWindow' for r in final),
            'skippedShortWindows': sum(not r['decoded'] for r in final),
            'processingRTF': sum(r['inferenceSeconds'] for r in partial) / ending['audioSeconds'],
            'VADProcessingRTF': ending['vadCPUSeconds'] / ending['audioSeconds'],
            'maxBacklogSeconds': max((r['backlogSeconds'] for r in partial),default=0),
            'annotatedQuestions': ending['annotatedQuestionCount'], 'questionTailsRecognized': len(recognized),
            'questionTailRecall': len(recognized)/ending['annotatedQuestionCount'] if ending['annotatedQuestionCount'] else None,
            'questionFinalLatencyP50Seconds': percentile(delays,.5), 'questionFinalLatencyP95Seconds': percentile(delays,.95),
            'silenceFinalReferenceLatencyP50Seconds': percentile(utterance_delays,.5), 'silenceFinalReferenceLatencyP95Seconds': percentile(utterance_delays,.95),
            'questionSamples': questions,
            'limitations': 'Question recognition is an exact final two-word tail proxy, not semantic correctness. Whole-source WER counts VAD-omitted reference words. Paired headset reference targets its annotated speaker; audible bleed can inflate local-source WER. Unpaced runs have no valid wall-clock latency.'
        })
    return result

def main():
    p=argparse.ArgumentParser();p.add_argument('inputs',nargs='+',type=Path);p.add_argument('--output',type=Path);args=p.parse_args()
    value=[r for path in args.inputs for r in score(path)]
    text=json.dumps(value,indent=2)+'\n'
    if args.output:args.output.write_text(text)
    else:print(text,end='')

if __name__=='__main__':main()
