# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Sample-based offline sound study, rebuilt around the uploaded reference's balance.

No audio from the reference is used here. The Python renderer is not an iOS
energy benchmark. Parameters are coupled musical controls, not arbitrary EQ.
"""
from pathlib import Path
from functools import lru_cache
from fractions import Fraction
import argparse, json, math, time
import numpy as np
import soundfile as sf
from scipy import signal, ndimage
from numba import njit
import instruments as ins
from room_composer import make_plan, PROFILES

BASE=Path(__file__).resolve().parent;OUT=BASE.parent/'output';OUT.mkdir(exist_ok=True)
FS=32000
ENTRIES=json.loads((BASE/'electric_guitar_manifest.json').read_text())['entries']
BANK={(e['root_midi'],e['round_robin']):sf.read(BASE/e['asset'],dtype='float32')[0] for e in ENTRIES}

def stereo(x,pan=0,width=.65):
    if x.ndim==1:x=np.column_stack((x,x))
    mid=x.mean(1);side=(x[:,0]-x[:,1])*.5*width
    y=np.column_stack((mid+side,mid-side))
    y*=np.array([math.cos((pan+1)*np.pi/4),math.sin((pan+1)*np.pi/4)],np.float32)*math.sqrt(2)
    return y

@lru_cache(maxsize=200)
def guitar(note,rr,warmth):
    root=min({k[0] for k in BANK},key=lambda n:abs(n-note));x=BANK[root,rr%4].copy()
    if root!=note:
        f=Fraction(2**((root-note)/12)).limit_denominator(2048)
        x=signal.resample_poly(x,f.numerator,f.denominator).astype(np.float32)
    # A darker amplifier voice; the fundamental/body stays present.
    x=ins.filt(ins.filt(x,100,'highpass'),1300-600*warmth,order=4)
    body=float(np.sqrt(np.mean(x[int(.12*FS):int(.9*FS)]**2)))
    x*=np.clip(.13/max(body,1e-8),.45,3.2)
    return x

@lru_cache(maxsize=100)
def piano(note,warmth):
    x=ins.pitched('piano',note,1).copy()
    x=ins.filt(ins.filt(x,90,'highpass'),1200-500*warmth,order=4)
    body=float(np.sqrt(np.mean(x[int(.12*FS):int(.9*FS)]**2)))
    x*=np.clip(.14/max(body,1e-8),.35,4.)
    # Preserve the recording's attack and decay but lessen the hammer/body jump.
    t=np.arange(len(x))/FS;x*=(.60+.40*(1-np.exp(-t/.060)))[:,None]
    return x

def voice(e,p):
    inst=e['instrument'];warm=round(p['warmth'],2)
    x=(guitar(e['note'],e['round_robin'],warm) if inst=='guitar' else piano(e['note'],warm)).copy()
    hold=round(e['duration']*FS);n=min(len(x),hold+round(e['release']*FS));x=x[:n]
    env=np.ones(n,np.float32)
    a=min(n,round((.009 if inst=='piano' else .014)*FS))
    env[:a]=np.sin(np.linspace(0,np.pi/2,a))**2
    if n>hold:env[hold:]*=np.cos(np.linspace(0,np.pi/2,n-hold))**2
    # Connected notes keep their body at a softer intensity rather than becoming
    # a loud new pluck. No periodic pitch wobble or pitch-class snapping in audio.
    gain=(.235 if inst=='guitar' else .23)*e['velocity']**1.05
    if e['articulation']=='connected':gain*=.9
    if x.ndim==1:x*=env*gain
    else:x*=env[:,None]*gain
    return stereo(x,e['pan'],.75 if inst=='piano' else .0)

def place(buf,x,seconds):
    a=round(seconds*FS);skip=max(0,-a);a=max(0,a);n=min(len(x)-skip,len(buf)-a)
    if n>0:buf[a:a+n]+=x[skip:skip+n]

def room(x,decay,warmth):
    mid=x.mean(1);side=(x[:,0]-x[:,1])*.5;out=np.zeros_like(x)
    for ch in (0,1):
        excitation=mid+side*(.55 if ch==0 else -.55);y=np.zeros(len(x),np.float32)
        for ms in [29.7,34.7,37.1,41.1,43.7,47.9,53.3,59.3]:
            d=round((ms+ch*1.39)*FS/1000);fb=10**(-3*d/FS/decay)
            y+=ins.comb(excitation,d,fb,.50)*.105
        for ms in [5.,1.7,.73]:y=ins.allpass(y,round((ms+ch*.19)*FS/1000),.58)
        d=round(.012*FS);out[d:,ch]=y[:-d]
        for ms,g in [(19.3,.10),(37.1,.065),(61.9,.045)]:
            d=round((ms+ch*3.13)*FS/1000);out[d:,ch]+=excitation[:-d]*g
    return ins.filt(ins.filt(out,145,'highpass'),1700-700*warmth,order=2)

def bass_voice(e):
    # Rounded electric-style bass body; a very quiet recorded pluck supplies touch.
    # The former strong synthetic sub foundation is no longer the dominant bed.
    n=round((e['duration']+e['release'])*FS);t=np.arange(n)/FS;f=440*2**((e['note']-69)/12)
    env=(1-np.exp(-t/.016))*np.exp(-t/2.6)
    tone=.21*np.sin(2*np.pi*f*t)+.105*np.sin(4*np.pi*f*t)+.037*np.sin(6*np.pi*f*t)
    natural=ins.pitched('bass',e['note'],1,e['round_robin']).mean(1)
    natural=ins.filt(ins.filt(natural,180,'highpass'),650)
    body=np.zeros(n,np.float32);m=min(n,len(natural));body[:m]=natural[:m]*.08
    y=(tone*env+body)*.24*e['velocity']**1.10
    hold=round(e['duration']*FS)
    if n>hold:y[hold:]*=np.cos(np.linspace(0,np.pi/2,n-hold))**2
    return stereo(y.astype(np.float32))

@njit(cache=True)
def smooth_gain_db(target,attack,release):
    y=np.empty(len(target),np.float32);state=0.
    for i in range(len(target)):
        c=attack if target[i]<state else release
        state=c*state+(1-c)*target[i];y[i]=state
    return y

def glue(x):
    # Linked stereo, 25 ms RMS detector, soft knee, 2.3:1, bounded reduction.
    # This operates on the combined musical gesture, not independently per note.
    env=np.sqrt(np.maximum(ndimage.uniform_filter1d(np.mean(x*x,axis=1),round(.025*FS)),0)+1e-14)
    over=20*np.log10(env/.024);knee=6.;slope=1-1/2.3
    reduction=np.where(over<-knee/2,0,np.where(over>knee/2,slope*over,slope*(over+knee/2)**2/(2*knee)))
    target=-np.minimum(reduction,5.)
    g=smooth_gain_db(target.astype(np.float32),math.exp(-1/(.012*FS)),math.exp(-1/(.22*FS)))
    return x*(10**(g/20))[:,None],float(-g.min())

def render(name,p,duration=200,save_stems=False):
    began=time.perf_counter();plan=make_plan(p,duration);beat=60/p['tempo'];size=round(duration*FS)
    keys=['guitar','piano','bass','kick','snare','hat','shaker']
    stems={k:np.zeros((size,2),np.float32) for k in keys}
    for song in plan['songs']:
        n=math.ceil((144*beat+7)*FS);local={k:np.zeros((n,2),np.float32) for k in keys}
        for e in plan['events']:
            if e['song']!=song['id']:continue
            inst=e['instrument']
            if inst in ('guitar','piano'):place(local[inst],voice(e,p),e['local_time'])
            elif inst=='bass':place(local[inst],bass_voice(e),e['local_time'])
            else:ins.add_note(local[inst],inst,e['note'],e['local_time'],e['duration'],e['velocity'],e['pan'],e['round_robin'],release_seconds=e['release'])
        t=np.arange(n)/FS
        for k,x in local.items():
            if song['id']<len(plan['songs'])-1:
                a,b=((135.8*beat,136*beat) if k not in ('guitar','piano') else (128*beat,144*beat))
                ramp=np.clip((t-a)/(b-a),0,1)
                x*=(1-ramp if k in ('guitar','piano') else np.cos(ramp*np.pi/2))[:,None]
            if song['id']>0 and k in ('guitar','piano'):
                # Similar bridge chords can be correlated: linear amplitude fades
                # avoid assuming an equal-power law is right for all material.
                x*=np.clip(t/(16*beat),0,1)[:,None]
            place(stems[k],x,song['start_seconds'])
    # The supported harmonic range is the bed; drums and bass sit inside it.
    guitar_mix=stems['guitar']*(1.00 if p['focus']=='guitar' else .85)
    piano_mix=stems['piano']*(.94 if p['focus']=='guitar' else 1.08)
    tonal,compression=glue(guitar_mix+piano_mix)
    wet=room(tonal,1.65+.85*p['space'],p['warmth'])*(.60+.8*p['space'])
    tonal=tonal*.92+wet
    kick=ins.filt(stems['kick'],280)*.50
    snare=ins.filt(stems['snare'],1050,order=2)*.44
    hats=ins.filt(stems['hat'],1450,order=2)*.42
    shaker=ins.filt(stems['shaker'],1200,order=2)*.24
    drums=kick+snare+hats+shaker
    bass=stems['bass']*1.20
    # A fraction of a decibel of shared breath, coupled to actual kick events.
    duck=np.ones(size,np.float32)
    for e in plan['events']:
        if e['instrument']!='kick':continue
        a=round(e['time']*FS);n=min(round(.28*FS),size-a)
        if n>0:duck[a:a+n]=np.minimum(duck[a:a+n],1-.055*np.exp(-np.arange(n)/FS/.105))
    tonal*=duck[:,None];bass*=duck[:,None]
    mix=tonal+drums+bass
    # Very quiet, slowly moving air. It is synthetic, not a field recording.
    rng=np.random.default_rng(p['seed']+91);t=np.arange(size)/FS
    for ch in (0,1):
        air=ins.filt(ins.filt(rng.standard_normal(size).astype(np.float32),160,'highpass'),800)
        air*=p['texture']*.00065/max(float(np.sqrt(np.mean(air*air))),1e-9)
        mix[:,ch]+=air*(.8+.12*np.sin(2*np.pi*t/19+ch)+.08*np.sin(2*np.pi*t/7.1+2*ch))
    mix=ins.filt(mix,32,'highpass')
    mix[:round(.4*FS)]*=np.sin(np.linspace(0,np.pi/2,round(.4*FS)))[:,None]**2
    mix[-round(2.8*FS):]*=np.cos(np.linspace(0,np.pi/2,round(2.8*FS)))[:,None]**2
    assert np.isfinite(mix).all()
    sf.write(OUT/(name+'_raw.wav'),mix,FS,subtype='FLOAT')
    if save_stems:
        d=OUT/(name+'_stems');d.mkdir(exist_ok=True)
        for k,x in [('guitar',guitar_mix),('piano',piano_mix),('room',wet),('drums',drums),('bass',bass)]:sf.write(d/(k+'.flac'),x,FS,subtype='PCM_24')
    stats_start=round(min(20,duration*.1)*FS);stats_end=round(min(70,duration*.9)*FS)
    stats=dict(revision=8,parameters=p,render_seconds=time.perf_counter()-began,raw_peak=float(abs(mix).max()),
       stem_rms_dBFS={k:round(float(20*np.log10(np.sqrt(np.mean(x[stats_start:stats_end]**2))+1e-12)),2) for k,x in [('guitar',guitar_mix),('piano',piano_mix),('room',wet),('drums',drums),('bass',bass)]},
       harmonic_bus_max_gain_reduction_dB=compression,reference_audio_used_in_render=False,reference_audio_access=True)
    (BASE/(name+'_plan.json')).write_text(json.dumps(plan,indent=2))
    (BASE/(name+'_render.json')).write_text(json.dumps(stats,indent=2))
    print(json.dumps(stats),flush=True)

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--profile',default='all',choices=['all']+list(PROFILES));a.add_argument('--duration',default=200,type=float);a.add_argument('--stems',action='store_true')
    for k in ('tempo','warmth','chill','space','texture'):a.add_argument('--'+k,type=float)
    a.add_argument('--seed',type=int);a.add_argument('--name')
    args=a.parse_args()
    if args.name and args.profile=='all':a.error('--name requires one profile')
    if args.duration<10 or args.duration>600:a.error('Duration must be 10-600 seconds for this research renderer')
    for name,default in PROFILES.items():
        if args.profile not in ('all',name):continue
        p=dict(default)
        for k in ('tempo','warmth','chill','space','texture','seed'):
            if getattr(args,k) is not None:p[k]=getattr(args,k)
        if not 55<=p['tempo']<=95:a.error('Tempo must be 55-95 BPM')
        if not all(0<=p[k]<=1 for k in ('warmth','chill','space','texture')):a.error('Macro parameters must be in [0, 1]')
        render(args.name or name,p,args.duration,args.stems)
