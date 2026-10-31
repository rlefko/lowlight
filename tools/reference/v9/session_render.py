# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Render and overlap one song at a time; audio memory does not grow with the session."""
from pathlib import Path
from dataclasses import replace,asdict
import argparse,hashlib,json,math,resource,subprocess,time
import numpy as np
from scipy import ndimage
import soundfile as sf
import pyloudnorm as pyln
import render_room as tone
import instruments as ins
from session_planner import SessionPlanner,Controls,PRESETS,make_events,local_seconds
from master_stream import protect

FS=32000;BASE=Path(__file__).resolve().parent;OUT=BASE.parent/'output';OUT.mkdir(exist_ok=True)
METER=pyln.Meter(FS)

def render_song(song):
    p=song['parameters'];duration=song['duration_seconds'];n=round((duration+5)*FS)
    keys=['guitar','piano','bass','kick','snare','hat','shaker']
    stems={k:np.zeros((n,2),np.float32) for k in keys};events=make_events(song)
    for e in events:
        inst=e['instrument']
        if inst in ('guitar','piano'):tone.place(stems[inst],tone.voice(e,p),e['local_time'])
        elif inst=='bass':tone.place(stems[inst],tone.bass_voice(e),e['local_time'])
        else:ins.add_note(stems[inst],inst,e['note'],e['local_time'],e['duration'],e['velocity'],e['pan'],e['round_robin'],release_seconds=e['release'])
    t=np.arange(n)/FS;out_start=local_seconds(song,song['bars']*4-16);out_end=duration
    tonal_fade=1-np.clip((t-out_start)/(out_end-out_start),0,1)
    if song['in_bridge'] is not None:tonal_fade*=np.clip(t/local_seconds(song,16),0,1)
    for inst in ('guitar','piano'):stems[inst]*=tonal_fade[:,None]
    # Old rhythm tails release just before the midpoint, leaving one active kit/bass.
    handoff=local_seconds(song,song['bars']*4-8)
    rhythm_fade=1-np.clip((t-handoff+.075)/.075,0,1)
    for inst in ('bass','kick','snare','hat','shaker'):stems[inst]*=rhythm_fade[:,None]
    guitar=stems['guitar']*(1 if song['focus']=='guitar' else .85)
    piano=stems['piano']*(.94 if song['focus']=='guitar' else 1.08)
    tonal,compression=tone.glue(guitar+piano)
    wet=tone.room(tonal,1.65+.85*p['space'],p['warmth'])*(.60+.8*p['space'])
    tonal=tonal*.92+wet
    energy=song['energy'];drum_gain=.85+.45*energy
    drums=(ins.filt(stems['kick'],280)*.50+ins.filt(stems['snare'],1050,order=2)*.44)*drum_gain
    drums+=ins.filt(stems['hat'],1450,order=2)*.42*(.9+.35*energy)
    drums+=ins.filt(stems['shaker'],1200,order=2)*.24
    bass=stems['bass']*1.20*(.98+.06*energy)
    duck=np.ones(n,np.float32)
    for e in events:
        if e['instrument']!='kick':continue
        a=round(e['local_time']*FS);length=min(round(.28*FS),n-a)
        if length>0:duck[a:a+length]=np.minimum(duck[a:a+length],1-.055*np.exp(-np.arange(length)/FS/.105))
    mix=(tonal+bass)*duck[:,None]+drums
    rng=np.random.default_rng(song['take_seed']+91)
    for ch in (0,1):
        air=ins.filt(ins.filt(rng.standard_normal(n).astype(np.float32),160,'highpass'),800)
        air*=p['texture']*.00065/max(float(np.sqrt(np.mean(air*air))),1e-9)
        mix[:,ch]+=air*(.8+.12*np.sin(2*np.pi*t/19+ch)+.08*np.sin(2*np.pi*t/7.1+2*ch))*tonal_fade
    mix=ins.filt(mix,32,'highpass')
    # Normalize an entire body with one gain; never normalize individual bars.
    lo=round(local_seconds(song,16)*FS);hi=round(out_start*FS)
    measured=METER.integrated_loudness(mix[lo:hi]);gain=-20.5-measured
    mix*=10**(gain/20)
    peak=np.max(abs(mix),axis=1);look=round(.005*FS)
    future=ndimage.maximum_filter1d(peak,size=look+1,origin=-look//2,mode='nearest')
    target=np.minimum(0,20*np.log10(10**(-5/20)/np.maximum(future,1e-12)))
    g=tone.smooth_gain_db(target.astype(np.float32),math.exp(-1/(.0007*FS)),math.exp(-1/(.100*FS)))
    mix*=10**(g[:,None]/20)
    assert np.isfinite(mix).all()
    stats=dict(events=len(events),source_body_LUFS=float(measured),fixed_gain_dB=float(gain),peak_reduction_max_dB=float(-g.min()),peak_reduction_fraction_over_1dB=float(np.mean(g<-1)),harmonic_compression_max_dB=compression,
        rendered_sample_peak_dBFS=float(20*np.log10(abs(mix).max()+1e-15)),buffer_frames=len(mix),max_rss_MiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024)
    return mix,stats

def encode_array(x,path,title):
    raw=path.with_suffix('.wav');sf.write(raw,x,FS,subtype='PCM_24')
    encode_file(raw,path,title,len(x)/FS)

def encode_file(raw,path,title,seconds):
    temporary=path.with_name(path.stem+'_encoding.m4a')
    cmd=['ffmpeg','-nostdin','-y','-v','error','-i',str(raw),'-ar','44100','-c:a','aac','-b:a','160k','-movflags','+faststart','-metadata','title='+title,'-metadata','artist=Ryan Lefkowitz','-metadata','comment=Original procedural music; development accelerated with Codex; no reference audio included',str(temporary)]
    subprocess.run(cmd,check=True,capture_output=True)
    probe=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_entries','format=duration,size','-of','json',str(temporary)]))
    assert abs(float(probe['format']['duration'])-seconds)<.05,'Encoded duration is incorrect'
    temporary.replace(path)

def render_session(name,seconds=7200,controls=None,seed=91031,baseline_first=False,changes=None):
    controls=(controls or PRESETS['Focus']).validate();planner=SessionPlanner(seed,controls,baseline_first)
    path=OUT/(name+'.m4a');target_frames=round(seconds*FS);began=time.perf_counter()
    raw=path.with_suffix('.wav')
    writer=sf.SoundFile(raw,mode='w',samplerate=FS,channels=2,subtype='PCM_24')
    carry=np.zeros((0,2),np.float32);cursor=0;records=[];levels=[];meter_tail=np.zeros((0,2),np.float32);peak=0.;join_deltas=[];last_sample=None
    while cursor<target_frames:
        if changes and planner.index in changes:planner.set_controls(changes[planner.index])
        song=planner.next_song();start=round(song['start_seconds']*FS)
        assert start==cursor,'Planner and stream buffer disagree'
        x,stats=render_song(song)
        if len(carry)<len(x):carry=np.pad(carry,((0,len(x)-len(carry)),(0,0)))
        carry[:len(x)]+=x
        flush=min(round(song['outro_start_seconds']*FS),target_frames)-cursor
        assert 0<flush<=len(carry)
        chunk=carry[:flush].copy();indices=np.arange(cursor,cursor+flush)
        chunk*=np.minimum(1,indices/(.4*FS))[:,None]
        chunk*=np.clip((target_frames-indices)/(2.8*FS),0,1)[:,None]
        if last_sample is not None:join_deltas.append(float(np.max(abs(chunk[0]-last_sample))))
        last_sample=chunk[-1].copy();peak=max(peak,float(abs(chunk).max()))
        assert np.isfinite(chunk).all() and abs(chunk).max()<.99
        writer.write(chunk)
        sample=np.concatenate([meter_tail,chunk]);hop=FS//4;count=len(sample)//hop
        bins=np.sqrt(np.mean(sample[:count*hop].reshape(count,hop,2)**2,axis=(1,2)))
        levels.extend(float(v) for v in bins);meter_tail=sample[count*hop:].copy()
        cursor+=flush;carry=carry[flush:].copy()
        record={**song,'render_stats':stats};records.append(record)
        (OUT/(name+'_session.json')).write_text(json.dumps(dict(revision=9,seconds_requested=seconds,frames_written=cursor,songs=records),indent=2))
        (OUT/(name+'_checkpoint.json')).write_text(json.dumps(planner.state()))
        print(f"{cursor/FS:8.1f}s | song {song['id']+1:02d} | {song['focus']:6s} {song['key_name']:6s} {song['mode']:5s} {song['tempo']:5.1f} BPM | {song['family']} | peak reduction {stats['peak_reduction_max_dB']:.1f} dB",flush=True)
    writer.close()
    assert sf.info(raw).frames==target_frames,'PCM export is incomplete'
    master=protect(raw)
    encode_file(raw,path,name.replace('_',' '),seconds)
    summary=dict(revision=9,filename=path.name,seconds=seconds,songs_rendered=len(records),unique_signatures=len({s['signature'] for s in records}),families_used=len({s['family'] for s in records}),keys_used=sorted({s['key_name'] for s in records}),modes_used=sorted({s['mode'] for s in records}),
        render_wall_seconds=time.perf_counter()-began,maximum_sample_peak_before_final_protection_dBFS=20*math.log10(peak),maximum_rss_MiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1024,
        max_piece_buffer_frames=max(s['render_stats']['buffer_frames'] for s in records),max_stream_join_adjacent_sample_delta=max(join_deltas or [0]),byte_size=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        target_body_LUFS=-20.5,quarter_second_RMS_before_final_peak_protection=levels,final_peak_protection=master,notes='Song bodies use fixed loudness gains; metadata memory grows only in this diagnostic exporter. The planner stores one pending song and bounded recent-history queues. Python speed and RSS are not iPhone battery measurements.')
    (OUT/(name+'_verification.json')).write_text(json.dumps(summary,indent=2));print(json.dumps({k:v for k,v in summary.items() if not k.startswith('quarter_second_RMS')}),flush=True)
    return path

if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--seconds',type=float,default=7200);a.add_argument('--preset',choices=list(PRESETS),default='Focus');a.add_argument('--seed',type=int,default=91031);a.add_argument('--name',default='V09_Continuous_Focus_2_Hours');a.add_argument('--baseline-first',action='store_true')
    for k in ('energy','mood','warmth','space','variation','tempo'):a.add_argument('--'+k,type=float)
    args=a.parse_args();c=PRESETS[args.preset]
    for k in ('energy','mood','warmth','space','variation','tempo'):
        if getattr(args,k) is not None:c=replace(c,**{k:getattr(args,k)})
    if args.seconds<10:raise ValueError('At least 10 seconds required')
    render_session(args.name,args.seconds,c,args.seed,args.baseline_first)
