#!/usr/bin/env python3
"""Measure calibration speech coverage for candidate energy floors, with no ASR."""
import ctypes as c
import json
from pathlib import Path
import time

BASE = Path(__file__).resolve().parent

class State(c.Structure):
    _fields_ = [(key,c.c_int) for key in ['sample_count','speech_samples','silence_samples','can_decode','should_finalize','maximum_reached']] + [(key,c.c_double) for key in ['start_time','represented_end','speech_end']]

def library():
    lib=c.CDLL(str(BASE/'.cache/libEndpointVAD.dylib'))
    lib.gate_vad_create_config.argtypes=[c.c_float,c.c_int];lib.gate_vad_create_config.restype=c.c_void_p
    lib.gate_vad_append.argtypes=[c.c_void_p,c.POINTER(c.c_float),c.c_int,c.c_double];lib.gate_vad_append.restype=c.c_int
    lib.gate_vad_state.argtypes=[c.c_void_p];lib.gate_vad_state.restype=State
    lib.gate_vad_reset.argtypes=[c.c_void_p];lib.gate_vad_destroy.argtypes=[c.c_void_p]
    return lib

def profile(lib,samples,floor,minimum=2560):
    pointer=lib.gate_vad_create_config(floor,minimum)
    if not pointer:raise RuntimeError('VAD allocation failed')
    windows=[];decode_count=0;last_decode=0;started=time.monotonic()
    try:
        for pos in range(0,len(samples),320):
            count=min(320,len(samples)-pos)
            ptr=c.cast(int(samples.ctypes.data)+pos*4,c.POINTER(c.c_float))
            if not lib.gate_vad_append(pointer,ptr,count,pos/16000):raise RuntimeError('VAD rejected frame')
            state=lib.gate_vad_state(pointer)
            end=(pos+count)/16000
            final=state.should_finalize or (pos+count==len(samples) and state.sample_count>0)
            if state.can_decode and (final or end-last_decode>=.32-.000001):decode_count+=1;last_decode=end
            if final:
                windows.append({'start':state.start_time,'end':end,'decoded':bool(state.can_decode)})
                lib.gate_vad_reset(pointer);last_decode=end
    finally:lib.gate_vad_destroy(pointer)
    return {'floor':floor,'minimumSpeechSamples':minimum,'windows':windows,'inferenceCalls':decode_count,'analysisWallSeconds':time.monotonic()-started}

def main():
    import numpy as np
    lib=library();results=[]
    for source in ['localUser','systemAudio']:
        manifest=BASE/f'.cache/paired-corpus-v1/{source}-endpoint-calibration.json'
        fixtures=json.loads(manifest.read_text())
        samples=np.concatenate([np.fromfile(manifest.parent/f['file'],dtype='<f4') for f in fixtures])
        words=[w for f in fixtures for w in f['words']]
        for floor in [.004,.002,.001,.0005]:
            row=profile(lib,samples,floor);ranges=[r for r in row['windows'] if r['decoded']]
            covered=sum(any(r['start']<=w['start']<r['end'] for r in ranges) for w in words)
            fully=sum(any(r['start']<=w['start'] and w['end']<=r['end'] for r in ranges) for w in words)
            row.update({'source':source,'referenceWords':len(words),'wordStartCoverage':covered/len(words),'fullWordAudioCoverage':fully/len(words),'endpointCount':len(row['windows']),'decodedSeconds':sum(r['end']-r['start'] for r in ranges)})
            del row['windows'];results.append(row)
    rng=np.random.default_rng(20260907)
    for label,rms in [('digitalSilence',0),('quietWhiteNoise',.0003),('moderateNoiseStep',.00075),('roomNoiseStep',.002),('louderRoomNoiseStep',.01)]:
        samples=rng.normal(0,rms,30*16000).astype('float32');samples[:32000]=0
        for floor in [.004,.002,.001,.0005]:
            row=profile(lib,samples,floor);row.update({'source':'syntheticControl','control':label,'RMS':rms,'audioSeconds':30,'endpointCount':len(row['windows'])});del row['windows'];results.append(row)
    (BASE/'results/vad-calibration-coverage.json').write_text(json.dumps(results,indent=2)+'\n')
    for row in results:print({k:v for k,v in row.items() if k not in ['analysisWallSeconds','minimumSpeechSamples']})

if __name__=='__main__':main()
