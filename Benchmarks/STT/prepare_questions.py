#!/usr/bin/env python3
"""Add AMI manual question-end annotations without rewriting audio fixtures."""
import json
from pathlib import Path
import zipfile
import xml.etree.ElementTree as ET

BASE = Path(__file__).resolve().parent
CACHE = BASE / '.cache'

def main():
    questions = []
    with zipfile.ZipFile(CACHE / 'ami_public_manual_1.6.2.zip') as archive:
        for channel in 'ABCDE':
            sentence = []
            for token in ET.fromstring(archive.read(f'words/EN2001a.{channel}.words.xml')):
                if token.tag != 'w': continue
                text = (token.text or '').strip()
                if token.get('punc') == 'true':
                    if text == '?' and sentence and token.get('starttime'):
                        questions.append({'end': float(token.get('starttime')), 'text': ' '.join(sentence), 'channel': channel})
                    if text in ['.', '?', '!']: sentence = []
                else: sentence.append(text)
    for directory, name, channels in [
        ('corpus-v1', 'corpus', 'ABCDE'),
        ('paired-corpus-v1', 'localUser', 'A'),
        ('paired-corpus-v1', 'systemAudio', 'BCDE')]:
        fixtures = json.loads((CACHE / directory / f'{name}.json').read_text())
        for fixture in fixtures:
            start = fixture['sourceStart']
            fixture['questions'] = [q for q in questions if q['channel'] in channels and start <= q['end'] < start + fixture['duration']]
        for split in ['calibration', 'heldout']:
            selected = [f for f in fixtures if f['split'] == split]
            (CACHE / directory / f'{name}-endpoint-{split}.json').write_text(json.dumps(selected, indent=2) + '\n')
            (CACHE / directory / f'{name}-endpoint-{split}.tsv').write_text('\n'.join(
                f"{f['id']}\t{(CACHE/directory/f['file']).resolve()}\t{f['duration']}\t{f['split']}\t{f['reference']}" for f in selected) + '\n')
            (CACHE / directory / f'{name}-endpoint-{split}-questions.tsv').write_text('\n'.join(
                f"{q['end'] - selected[0]['sourceStart']}\t{q['text']}" for f in selected for q in f['questions']) + '\n')
            (CACHE / directory / f'{name}-endpoint-{split}-words.tsv').write_text('\n'.join(
                f"{w['start'] - selected[0]['sourceStart']}\t{w['end'] - selected[0]['sourceStart']}\t{w['text']}" for f in selected for w in f['words']) + '\n')
    print('Prepared endpoint manifests and', len([q for q in questions if q['end'] < 1500]), 'AMI question marks in first25min')

if __name__ == '__main__': main()
