#!/usr/bin/env python3
"""Report separate system-voice regression results; never feed backend ranking."""
import json
import re
from pathlib import Path
from analyze import words,edit_distance

BASE=Path(__file__).resolve().parent
TERMS=['Kotlin','StateFlow','SharedFlow','Compose','Gradle','CoroutineScope','MutableStateFlow','REST','API','JSON','SwiftUI','ScreenCaptureKit','AVFoundation','URLSession','Keychain','macOS']

def count(text,term):
    return len(re.findall(r'(?<![A-Za-z0-9_])'+re.escape(term)+r'(?![A-Za-z0-9_])',text))

def main():
    results=[]
    for engine in ['fluid-tdt','whisper-cpp']:
        path=BASE/f'results/{engine}-synthetic-regression.jsonl'
        rows=[json.loads(line) for line in path.read_text().splitlines()]
        finals=[r for r in rows if r['event']=='final']
        reference=' '.join(r['reference'] for r in finals);hypothesis=' '.join(r['text'] for r in finals)
        expected=sum(count(reference,t) for t in TERMS);predicted=sum(count(hypothesis,t) for t in TERMS)
        correct=sum(min(count(reference,t),count(hypothesis,t)) for t in TERMS)
        results.append({'engine':rows[0]['engine'],'syntheticOnly':True,'excludedFromSelection':True,
                        'voice':'macOS Samantha en_US','audioSeconds':sum(r['duration'] for r in finals),
                        'fixtures':len(finals),'referenceWords':len(words(reference)),
                        'WER':edit_distance(words(reference),words(hypothesis))/len(words(reference)),
                        'caseSensitiveIdentifierRecall':correct/expected if expected else None,
                        'caseSensitiveIdentifierPrecision':correct/predicted if predicted else None,
                        'identifierReferenceOccurrences':expected,'identifiers':TERMS,
                        'negationCorrectionContainsNot':any('not' in words(r['text']) for r in finals if r['fixture']=='negation-correction'),
                        'perFixture':[{'id':r['fixture'],'reference':r['reference'],'hypothesis':r['text']} for r in finals],
                        'limitations':'System-voice regression, not human framework-name accuracy. The spoken correction does not prove a particular late ASR revision or correct automatic generation; those have separate domain tests.'})
    (BASE/'results/synthetic-regression-summary.json').write_text(json.dumps(results,indent=2)+'\n')
    for r in results:print({k:v for k,v in r.items() if k not in ['identifiers','perFixture','limitations']})

if __name__=='__main__':main()
