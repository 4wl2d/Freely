"""Normalize annotation spelling without changing identifier case."""
import re

def annotation_acronyms(text):
    text=re.sub(r'\b(?:[A-Za-z]_){2,}[A-Za-z]?',lambda m:m.group().replace('_',''),text)
    return re.sub(r'\b[A-Za-z]\.(?:\s*[A-Za-z]\.)+',lambda m:re.sub(r'[.\s]','',m.group()),text)

def technical_tokens(text):
    return re.findall(r"[A-Za-z0-9]+(?:'[A-Za-z0-9]+)?",annotation_acronyms(text))

def question_tokens(text):
    text=annotation_acronyms(text).lower()
    text=re.sub(r'\bon[- ]line\b','online',text)
    text=re.sub(r'\boff[- ]line\b','offline',text)
    return re.findall(r"[a-z0-9]+(?:'[a-z0-9]+)?",text)

def recognizes_tail(text,reference):
    actual=question_tokens(text);expected=question_tokens(reference)[-2:]
    return bool(expected) and any(actual[i:i+len(expected)]==expected for i in range(len(actual)-len(expected)+1))
