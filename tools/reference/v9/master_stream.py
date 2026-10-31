# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Bounded-memory peak protection after all crossfades and effect tails."""
from pathlib import Path
import json,math
import numpy as np
import soundfile as sf
from scipy import ndimage
from numba import njit

@njit(cache=True)
def smooth(target,previous,attack,release):
    out=np.empty(len(target),np.float32)
    for i in range(len(target)):
        c=attack if target[i]<previous else release
        previous=c*previous+(1-c)*target[i];out[i]=previous
    return out,previous

def protect(path,ceiling_dB=-2.2):
    path=Path(path);temporary=path.with_name(path.stem+'_limited.wav')
    info=sf.info(path);sr=info.samplerate;look=round(.005*sr);step=sr*2;gain_state=0.
    before=0.;after=0.;maximum_reduction=0.;frames_reduced=0;written=0
    with sf.SoundFile(path) as src,sf.SoundFile(temporary,'w',samplerate=sr,channels=2,subtype='PCM_24') as dst:
        for start in range(0,info.frames,step):
            src.seek(start);x=src.read(min(step+look,info.frames-start),dtype='float32');count=min(step,info.frames-start)
            peaks=np.max(abs(x),axis=1);before=max(before,float(peaks.max()))
            future=ndimage.maximum_filter1d(peaks,size=look+1,origin=-look//2,mode='nearest')[:count]
            target=np.minimum(0,20*np.log10(10**(ceiling_dB/20)/np.maximum(future,1e-12)))
            gain,gain_state=smooth(target.astype(np.float32),gain_state,math.exp(-1/(.0007*sr)),math.exp(-1/(.100*sr)))
            y=x[:count]*10**(gain[:,None]/20)
            assert np.isfinite(y).all();dst.write(y);written+=len(y)
            after=max(after,float(abs(y).max()));maximum_reduction=max(maximum_reduction,float(-gain.min()));frames_reduced+=int(np.sum(gain<-.1))
    assert written==info.frames
    assert 20*math.log10(after)<-2.,'Final mix exceeds headroom target'
    temporary.replace(path)
    stats=dict(frames=written,ceiling_dBFS=ceiling_dB,input_sample_peak_dBFS=20*math.log10(before),output_sample_peak_dBFS=20*math.log10(after),maximum_reduction_dB=maximum_reduction,fraction_frames_over_0_1dB_reduction=frames_reduced/written,maximum_buffer_frames=step+look,lookahead_ms=5,attack_ms=.7,release_ms=100)
    path.with_name(path.stem+'_master.json').write_text(json.dumps(stats,indent=2))
    return stats

if __name__=='__main__':
    import argparse
    a=argparse.ArgumentParser();a.add_argument('path',type=Path)
    print(json.dumps(protect(a.parse_args().path),indent=2),flush=True)
