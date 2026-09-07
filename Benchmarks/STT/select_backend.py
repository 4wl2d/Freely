#!/usr/bin/env python3
"""Apply the previously frozen rubric; report close scores and missing evidence."""
import json
from pathlib import Path

BASE=Path(__file__).resolve().parent

def main():
    rubric=json.loads((BASE/'endpoint-selection-criteria.json').read_text())
    heldout=json.loads((BASE/'results/paired-heldout-summary.json').read_text())
    cancellation={r['engine']:r for r in json.loads((BASE/'results/candidate-cancellation-summary.json').read_text())}
    results=[]
    for engine,prefix in [('fluid-tdt','fluid-tdt'),('whisper.cpp','whisper-cpp')]:
        row=next(r for r in heldout if r['engine']==engine and r['source']=='systemAudio')
        memory=json.loads((BASE/f'results/{prefix}-dual-resource-summary.json').read_text())
        dual=json.loads((BASE/f'results/{prefix}-dual-summary.json').read_text())[0]
        cancel=cancellation[engine]
        # Frozen accounting formula is a ranking proxy; individual categories
        # and RSS remain separately available and must not be called total RAM.
        memory_proxy=memory['physicalFootprintPeakBytes']+memory.get('neuralPeakBytes',0)
        values=[row['WER'],row['technicalF1'],row['questionTailRecall'],row['questionFinalLatencyP95Seconds']]
        eligible=dual['complete'] and dual['summedProcessingSecondsPerSourceTimelineSecond']<=.8 and dual['maximumPacedBacklogSeconds']<=2 and memory_proxy<=4294967296 and cancel['p95Seconds']<=.5
        score=None
        components={}
        if all(v is not None for v in values) and eligible:
            components={
                'wordError':.35*row['WER'], 'technicalError':.15*(1-row['technicalF1']),
                'questionTailMiss':.15*(1-row['questionTailRecall']),
                'questionFinalDelay':.25*min(row['questionFinalLatencyP95Seconds']/1.2,4),
                'memoryProxy':.08*memory_proxy/4294967296,
                'cancellation':.02*cancel['p95Seconds']/.5}
            score=sum(components.values())
        results.append({'engine':engine,'eligibleForRanking':eligible,'score':score,'components':components,
                        'memoryRankingProxyBytes':memory_proxy,'remoteHeldoutWER':row['WER'],
                        'technicalF1':row['technicalF1'],'questionTailRecall':row['questionTailRecall'],
                        'heldoutQuestionTailSamples':row['questionTailsRecognized'],
                        'heldoutAnnotatedQuestions':row['annotatedQuestions'],
                        'heldoutTechnicalOccurrences':row['technicalReferenceOccurrences']})
    ranked=sorted((r for r in results if r['score'] is not None),key=lambda r:r['score'])
    close=len(ranked)==2 and abs(ranked[0]['score']-ranked[1]['score'])<=.02
    selected=None
    rationale='Insufficient measured components for a selection.'
    if len(ranked)==2 and close:
        # The current qualitative tie is supported by simultaneous accuracy and
        # memory advantages, without sacrificing measured question/term recall.
        preferred=[r for r in ranked if all(
            r['engine']==other['engine'] or (
                r['remoteHeldoutWER']<other['remoteHeldoutWER'] and
                r['memoryRankingProxyBytes']<other['memoryRankingProxyBytes'] and
                r['technicalF1']>=other['technicalF1'] and
                r['questionTailRecall']>=other['questionTailRecall']) for other in ranked)]
        if len(preferred)==1:
            selected=preferred[0]['engine']
            rationale=f"Scores are within the frozen0.02 tie band. {selected} has lower remote heldout WER and measured memory without lower measured question-tail or technical F1. Both showed adequate throughput and fast cancellation. cpp has faster first-word delivery and cancellation; selection follows accuracy/resource evidence, not integration convenience."
        else:
            rationale='Scores are within the qualitative tie band with conflicting advantages; explicit review is required. No automatic winner.'
    elif len(ranked)==2:
        selected=ranked[0]['engine']
        rationale='The lower frozen weighted score lies outside the qualitative tie band.'
    report={'rubric':'endpoint-selection-criteria.json','frozenAt':rubric['finalPolicyFrozenBeforePairedHeldout'],
            'results':results,'withinQualitativeTieBand':close,
            'selectedBackend':selected,
            'rationale':rationale,
            'requiredLimitations':['One real meeting; heldout contains onlyone recognized substantivequestion and3technical-term occurrences; no populationp95 guarantee.',
                                   'Both miss initial question-end finalization objective: ongoing remote speech delays the source VAD endpoint by about3.3seconds.',
                                   'Initial first-correct-word p95 objective not met in the fixed-window stress test.',
                                   '20min STT-only replay does not prove four-hour integrated retention, live capture, or provider latency.',
                                   'Memory ranking formula is a proxy from separate accounting categories, not exact total resident application memory.']}
    (BASE/'results/backend-selection.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
