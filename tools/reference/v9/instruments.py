# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Shared sample-playback primitives, no neural model.

This is an offline Python reference render, not the production iOS audio engine.
Sampled individual notes are composed into new arrangements; no song loops used.
"""
from pathlib import Path
from functools import lru_cache
from fractions import Fraction
import json, math, re, time
import numpy as np
import soundfile as sf
from scipy import signal
from numba import njit

BASE=Path(__file__).resolve().parent
OUT=BASE.parent/'output'; OUT.mkdir(exist_ok=True)
FS=32000
DURATION=200.0
MIX_GAINS={'keys':1.50,'lead':.96,'bass':1.05,'drums':1.0,'percussion':1.0}
MANIFEST=json.loads((BASE/'sample_manifest.json').read_text())
ASSETS={}
for entry in MANIFEST:
    x,s=sf.read(BASE/entry['asset'],dtype='float32',always_2d=True)
    assert s==FS and np.isfinite(x).all()
    name=Path(entry['asset']).name
    entry['velocity_layer']=int(re.search(r'_v(?:l)?(\d)',name)[1]) if re.search(r'_v(?:l)?(\d)',name) else 1
    ASSETS.setdefault(entry['instrument'],[]).append((entry,x))

def filt(x,hz,kind='lowpass',order=2):
    return signal.sosfilt(signal.butter(order,hz,btype=kind,fs=FS,output='sos'),x,axis=0).astype(np.float32)

@lru_cache(maxsize=1000)
def pitched(inst,note,layer,rr=0):
    pool=ASSETS['piano' if inst=='piano_lead' else inst]
    if inst=='piano_lead':
        # These close pitch anchors have clearer, more consistent attacks than
        # the lower piano and soft mallet recordings. No new sample is invented.
        pool=[q for q in pool if q[0]['root_midi'] in [68,72,76]]
    if inst in ['hat','snare','kick','shaker']:
        if inst=='hat':
            pool=[q for q in pool if ('_HitO_' in q[0]['asset'])==(note==1)]
            if note==0: pool=[q for q in pool if q[0]['velocity_layer']==layer]
        if inst=='snare': pool=[q for q in pool if ('_stick_' in q[0]['asset'])==(note==1)]
        e,x=pool[rr%len(pool)]; rate=1.0
    else:
        root=min((q[0]['root_midi'] for q in pool), key=lambda k:abs(k-note))
        pool=[q for q in pool if q[0]['root_midi']==root]
        closest=min(abs(q[0]['velocity_layer']-layer) for q in pool)
        pool=[q for q in pool if abs(q[0]['velocity_layer']-layer)==closest]
        e,x=pool[rr%len(pool)]; rate=2**((note-root)/12)
    if abs(rate-1)>1e-7:
        if inst in ['piano','piano_lead','bass']:
            ratio=Fraction(1/rate).limit_denominator(2048)
            x=signal.resample_poly(x,ratio.numerator,ratio.denominator,axis=0).astype(np.float32)
        else:
            # Linear fallback for any future non-pitched percussion transposition.
            if rate>1.01: x=filt(x,min(14500/rate,14500),order=4)
            pos=np.arange(0,len(x)-1,rate); ix=pos.astype(np.int64); f=(pos-ix).astype(np.float32)
            x=x[ix]*(1-f[:,None])+x[ix+1]*f[:,None]
    else: x=x.copy()
    if inst=='bass': x=filt(x,1800)
    if inst=='hat': x=filt(x,6500)
    if inst=='snare': x=filt(x,4300 if note==0 else 3200)
    if inst=='pluck': x=filt(x,3800)
    if inst=='kick':
        t=np.arange(int(FS*.52))/FS
        f=48+46*np.exp(-t/.025); phase=np.cumsum(f)/FS*2*np.pi
        sine=np.sin(phase)*np.exp(-t/.115)*(1-np.exp(-t/.0015))
        natural=np.zeros_like(sine); n=min(len(x),len(natural)); natural[:n]=x[:n].mean(1)
        x=(.82*sine+.18*filt(natural,260))[:,None].astype(np.float32)
    return np.asarray(x,dtype=np.float32)

@lru_cache(maxsize=160)
def responsive_piano(inst,note,layer):
    """Calibrate recorded timbre independently from musical note intensity.

    Existing recorded layers are selected between notes, never crossfaded
    phase-incoherently within a note. Their first 30-280 ms sets the response.
    Natural tuning, attack shape and decay are otherwise retained.
    """
    x=pitched(inst,note,layer).copy()
    rms=float(np.sqrt(np.mean(x[int(.03*FS):int(.28*FS)]**2)))
    if inst=='piano_lead':
        target=.23
    else:
        ref=pitched(inst,note,1)
        target=float(np.sqrt(np.mean(ref[int(.03*FS):int(.28*FS)]**2)))
    gain=float(np.clip(target/max(rms,1e-8),.65,1.45))
    return x*gain


def bass_voice(note,duration,release,rr):
    """Natural pluck/body plus a bounded, tuned low-frequency sustain.

    The recorded body is high-passed so a second independent fundamental does
    not fight the synthetic foundation. Four low harmonics need no new assets.
    This is an intentional hybrid voice, not a realism claim for a pure upright.
    """
    n=round((duration+release)*FS)
    natural=pitched('bass',int(note),1,rr)
    body=filt(natural,140,'highpass')[:,0]
    y=np.zeros(n,np.float32);count=min(n,len(body));y[:count]=.95*body[:count]
    t=np.arange(n,dtype=np.float64)/FS;f=440*2**((note-69)/12)
    envelope=(1-np.exp(-t/.012))*np.exp(-t/2.3)
    low=sum(a*np.sin(2*np.pi*f*k*t) for k,a in [(1,.30),(2,.065),(3,.026),(4,.012)])
    y+=(low*envelope).astype(np.float32)
    return y[:,None]


def add_note(buf,inst,note,t,duration,velocity,pan,rr=0,release_seconds=None,layer_override=None):
    layer=layer_override if layer_override is not None else (1 if velocity<.72 else 2)
    x=(responsive_piano(inst,int(note),layer) if inst in ('piano','piano_lead') else
       bass_voice(note,duration,release_seconds or .12,rr) if inst=='bass' else pitched(inst,int(note),layer,rr))
    if inst in ['piano','piano_lead','fm','vibes','bass','pluck']:
        release=release_seconds if release_seconds is not None else {'piano':.32,'piano_lead':.16,'fm':.25,'vibes':.48,'bass':.10,'pluck':.18}[inst]
        hold=int(max(.04,duration)*FS); n=min(len(x),hold+int(release*FS)); x=x[:n].copy()
        if n>hold:
            phase=np.linspace(0,1,n-hold,dtype=np.float32)
            envelope=np.cos(phase*np.pi/2)**2 if inst in ('piano','piano_lead') else np.linspace(1,0,n-hold,dtype=np.float32)**1.7
            x[hold:]*=envelope[:,None]
        attack=min(int(.002*FS),len(x)); x[:attack]*=np.linspace(0,1,attack)[:,None]
    elif inst=='hat' and note==0:
        x=x[:int(.13*FS)].copy(); x*=np.exp(-np.arange(len(x))/FS/.052)[:,None]
    elif inst=='hat' and note==1:
        x=x[:max(1,min(len(x),round(duration*FS)))].copy()
        fade=min(len(x),round(.006*FS));x[-fade:]*=np.linspace(1,0,fade)[:,None]
    elif inst=='snare':
        x=x.copy(); x*=np.exp(-np.arange(len(x))/FS/(.12 if note==0 else .085))[:,None]
    if x.shape[1]==1: x=np.repeat(x,2,axis=1)
    # Retain natural piano stereo but narrow it so the mix folds down sensibly.
    mid=x.mean(axis=1); side=(x[:,0]-x[:,1])*.24
    y=np.column_stack((mid+side,mid-side))
    y*=np.array([math.cos((pan+1)*math.pi/4),math.sin((pan+1)*math.pi/4)],dtype=np.float32)*math.sqrt(2)
    gains={'piano':.205,'piano_lead':.235,'fm':.17,'vibes':.145,'bass':.26,'hat':.27,'snare':.25,'kick':.31,'shaker':.11,'pluck':.27}
    y*=gains[inst]*velocity**1.25
    a=round(t*FS); skip=max(0,-a); a=max(0,a); n=min(len(y)-skip,len(buf)-a)
    if n>0: buf[a:a+n]+=y[skip:skip+n]

@njit(cache=True)
def comb(x,delay,feedback,damping):
    buf=np.zeros(delay,np.float32); y=np.zeros(len(x),np.float32); state=0.
    for i in range(len(x)):
        j=i%delay; z=buf[j]; state=(1-damping)*z+damping*state
        buf[j]=x[i]+feedback*state; y[i]=z
    return y

@njit(cache=True)
def allpass(x,delay,g):
    buf=np.zeros(delay,np.float32); y=np.zeros(len(x),np.float32)
    for i in range(len(x)):
        j=i%delay; z=buf[j]; out=z-g*x[i]; buf[j]=x[i]+g*out; y[i]=out
    return y

def room(x,decay=.85):
    mono=x.mean(1); wet=np.zeros_like(x)
    for ch in range(2):
        y=np.zeros(len(x),np.float32)
        for ms in [29.7,37.1,41.1,43.7]:
            d=int((ms+ch*1.13)*FS/1000); fb=10**(-3*d/FS/decay)
            y+=comb(mono,d,fb,.37)*.21
        for ms in [5.0,1.7]: y=allpass(y,int((ms+ch*.23)*FS/1000),.55)
        wet[:,ch]=y
        for ms,g in [(13.1,.13),(21.7,.11),(31.9,.07)]:
            d=int((ms+ch*2)*FS/1000); wet[d:,ch]+=mono[:-d]*g
    return filt(filt(wet,250,'highpass'),4400)

def saturation(x,drive):
    # 2x oversampling is an offline sound reference, not an energy claim.
    hi=signal.resample_poly(x,2,1,axis=0)
    y=np.tanh(hi*drive)/drive
    return signal.resample_poly(y,1,2,axis=0)[:len(x)].astype(np.float32)

