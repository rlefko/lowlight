# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Bounded, deterministic song planning around the accepted revision 8 sound.

Mood is an intended musical color, not a prediction of a listener's emotions.
No neural model or reference recording is used for generation.
"""
from dataclasses import dataclass,asdict,replace
from collections import deque
import hashlib,itertools,json,math,random
from room_composer import CHORDS as BASE_CHORDS,FAMILIES as ACCEPTED

@dataclass(frozen=True)
class Controls:
    energy:float=.35
    mood:float=.15
    warmth:float=.78
    space:float=.44
    texture:float=.09
    variation:float=.6
    tempo:float|None=None
    def validate(self):
        for k in ('energy','warmth','space','texture','variation'):
            if not 0<=getattr(self,k)<=1:raise ValueError(k+' must be in [0, 1]')
        if not -1<=self.mood<=1:raise ValueError('mood must be in [-1, 1]')
        if self.tempo is not None and not 60<=self.tempo<=100:raise ValueError('tempo must be in [60, 100]')
        return self

PRESETS={
 'Focus':Controls(.35,.15,.78,.44,.09,.55),
 'Relax':Controls(.10,.05,.88,.55,.07,.35),
 'Commute':Controls(.58,.35,.72,.42,.08,.60),
 'Workout':Controls(.88,.65,.63,.35,.06,.65),
 'Reflective':Controls(.27,-.80,.82,.50,.07,.5),
}
CHORDS={**BASE_CHORDS,
 'Cm9':(36,[51,55,58,62],[55,58,62,63]),
 'Fm9':(41,[53,56,60,63],[56,60,63,67]),
 'Abmaj9':(32,[55,58,60,63],[55,58,60,63]),
 'Ebmaj9':(39,[55,58,62,65],[55,58,62,65]),
 'Bb6':(34,[53,55,58,62],[55,58,62,65]),
 'Gm7':(31,[50,53,55,58],[53,55,58,62]),
}
MAJOR=[
 ['Fmaj9','Em7','Am9','Am9','Dm9','G6','Cmaj9','Cmaj9'],
 ['Cmaj9','Cmaj9','Am9','Am9','Fmaj9','Fmaj9','Dm9','G6'],
 ['Fmaj9','Fmaj9','Em7','Am9','Dm9','Dm9','G6','Cmaj9'],
 ['Am9','Am9','Fmaj9','G6','Cmaj9','Em7','Dm9','G6'],
 ['Cmaj9','Em7','Fmaj9','Fmaj9','Dm9','G6','Cmaj9','G6'],
 ['Dm9','G6','Cmaj9','Cmaj9','Fmaj9','Em7','Am9','Am9'],
 ['Fmaj9','G6','Em7','Am9','Dm9','G6','Cmaj9','Cmaj9'],
 ['Cmaj9','Am9','Dm9','G6','Em7','Am9','Fmaj9','G6'],
 ['Am9','Fmaj9','Cmaj9','Cmaj9','Dm9','Fmaj9','G6','G6'],
 ['Cmaj9','G6','Am9','Em7','Fmaj9','Cmaj9','Dm9','G6'],
 ['Em7','Am9','Dm9','G6','Fmaj9','Fmaj9','Cmaj9','Cmaj9'],
 ['Fmaj9','Dm9','Em7','Am9','G6','G6','Cmaj9','Cmaj9'],
]
MINOR=[
 ['Cm9','Cm9','Abmaj9','Abmaj9','Ebmaj9','Bb6','Fm9','Gm7'],
 ['Fm9','Bb6','Ebmaj9','Ebmaj9','Abmaj9','Abmaj9','Gm7','Cm9'],
 ['Cm9','Abmaj9','Fm9','Fm9','Bb6','Bb6','Ebmaj9','Gm7'],
 ['Abmaj9','Abmaj9','Cm9','Cm9','Fm9','Bb6','Gm7','Gm7'],
 ['Cm9','Gm7','Abmaj9','Bb6','Ebmaj9','Ebmaj9','Fm9','Gm7'],
 ['Ebmaj9','Bb6','Cm9','Cm9','Abmaj9','Fm9','Gm7','Gm7'],
 ['Fm9','Fm9','Abmaj9','Abmaj9','Cm9','Bb6','Gm7','Cm9'],
 ['Cm9','Cm9','Fm9','Bb6','Ebmaj9','Abmaj9','Fm9','Gm7'],
 ['Abmaj9','Bb6','Gm7','Cm9','Fm9','Bb6','Ebmaj9','Ebmaj9'],
 ['Cm9','Ebmaj9','Abmaj9','Abmaj9','Fm9','Fm9','Bb6','Gm7'],
 ['Ebmaj9','Abmaj9','Fm9','Bb6','Cm9','Cm9','Gm7','Gm7'],
 ['Cm9','Abmaj9','Ebmaj9','Bb6','Fm9','Abmaj9','Gm7','Cm9'],
]
CATALOG=[dict(id=f'M{i:02d}',mode='major',base_key=0,progression=p) for i,p in enumerate(MAJOR)]
CATALOG += [dict(id=f'm{i:02d}',mode='minor',base_key=0,progression=p) for i,p in enumerate(MINOR)]
CATALOG += [dict(id=f'F{i}',mode='major',base_key=5,progression=f['progression']) for i,f in enumerate(ACCEPTED[2:])]
CONTOURS=[[2,1,0,1,1,0,1,0],[0,0,1,2,2,1,1,0],[1,0,1,0,2,1,1,0],
 [0,1,1,2,1,0,1,0],[1,1,2,1,0,1,0,0],[1,2,1,1,2,1,0,1]]
NAMES=['Paper Lanterns','River Windows','Quiet Platforms','Sidewalk Light','Distant Rooms','Evening Letters','Small Gardens','Passing Clouds','Late Trains','Open Windows','Warm Pavement','Blue Notebooks']
KEY_NAMES=['C','D-flat','D','E-flat','E','F','G-flat','G','A-flat','A','B-flat','B']

def transpose_note(n,shift,low,high):
    n+=shift
    while n<low:n+=12
    while n>high:n-=12
    return n

def chord_data(name,shift):
    root,voices,tops=CHORDS[name]
    bass=transpose_note(root,shift,31,45)
    v=sorted(transpose_note(n,shift,50,66) for n in voices)
    top=sorted({transpose_note(n,shift,55,69) for n in tops})
    pcs=sorted({(n+shift)%12 for n in [root]+voices+tops})
    return dict(name=name,root=bass,voices=v,tops=top,pcs=pcs)

def scale_pcs(song):
    intervals=[0,2,4,5,7,9,11] if song['mode']=='major' else [0,2,3,5,7,8,10]
    return {(song['key']+v)%12 for v in intervals}

def bridge_between(a,b):
    common=scale_pcs(a)&scale_pcs(b)
    candidates=[]
    for root in sorted(common):
        tones=[root]
        for interval in [7,4,3,9,2,5]:
            pc=(root+interval)%12
            if pc in common and all(min((pc-q)%12,(q-pc)%12)>=2 for q in tones):tones.append(pc)
            if len(tones)==4:break
        score=len(tones)*3 + (2 if (root+7)%12 in tones else 0)+(1 if root==b['key'] else 0)
        candidates.append((score,-min((root-a['key'])%12,(a['key']-root)%12),-root,tones))
    tones=max(candidates)[3]
    root=transpose_note(36+tones[0],0,31,45)
    voices=sorted(transpose_note(48+t,0,50,66) for t in tones)
    while len(voices)<3:voices.append(voices[0]+12 if voices[0]+12<=67 else voices[0])
    voices=sorted(set(voices))
    return dict(name='shared pivot',root=root,voices=voices,tops=[n for n in voices if 55<=n<=69] or [voices[-1]],pcs=sorted(tones))

def ramp_seconds(beats,bpm0,bpm1,total_beats=16):
    if beats<=0:return 0.
    slope=(bpm1-bpm0)/total_beats
    return 60*beats/bpm0 if abs(slope)<1e-12 else 60*math.log1p(slope*beats/bpm0)/slope

def local_seconds(song,b):
    total=song['bars']*4;tempo=song['tempo'];prev=song.get('previous_tempo',tempo);nxt=song.get('next_tempo',tempo)
    first=min(max(b,0),16)
    value=ramp_seconds(first,prev,tempo)
    if b>16:value+=(min(b,total-16)-16)*60/tempo
    if b>total-16:value+=ramp_seconds(min(b,total)-(total-16),tempo,nxt)
    if b>total:value+=(b-total)*60/nxt
    return value

def _tuples(x):return tuple(_tuples(v) for v in x) if isinstance(x,list) else x

class SessionPlanner:
    def __init__(self,seed=91031,controls=None,baseline_first=False):
        self.rng=random.Random(seed);self.seed=seed;self.controls=(controls or Controls()).validate()
        self.recent_families=deque(maxlen=4);self.recent_signatures=deque(maxlen=64)
        self.index=0;self.baseline_first=baseline_first;self.current=self._draft(None)
        self.current.update(start_seconds=0.,previous_tempo=self.current['tempo'],in_bridge=None)

    def set_controls(self,controls):
        # Applies to the next unplanned song; already prepared notes are not rewritten.
        self.controls=controls.validate()

    def _draft(self,previous):
        c=self.controls; rng=self.rng;i=self.index
        for attempt in range(128):
            minor=rng.random()<(.5-.46*c.mood)
            pool=[f for f in CATALOG if (f['mode']=='minor')==minor and f['id'] not in self.recent_families]
            family=rng.choice(pool)
            if i==0 and self.baseline_first:family=CATALOG[0]
            keys=[0,2,3,5,7,10]
            if previous:
                related={(previous['key']+v)%12 for v in [0,5,7,3,9]}
                choices=[k for k in keys if k in related] or [previous['key']]
                key=rng.choice(choices) if rng.random()<.45*c.variation else previous['key']
            else:key=rng.choice(keys)
            if i==0 and self.baseline_first:key=0
            shift=(key-family['base_key']+6)%12-6
            energy=max(0,min(1,c.energy+rng.uniform(-.06,.06)*c.variation))
            target=c.tempo if c.tempo is not None else 64+34*energy
            tempo=target
            if previous:
                # Organic drift is bounded. Explicit preset changes may use the full
                # new target, still through one shared 16-beat tempo ramp.
                if previous['controls']['energy']==c.energy and previous['controls']['tempo']==c.tempo:
                    tempo=max(previous['tempo']-3,min(previous['tempo']+3,target))
            tempo=round(tempo,2)
            focus=(previous['focus'] if previous and rng.random()>.40 else rng.choice(['guitar','piano']))
            if i==0 and self.baseline_first:focus='guitar';tempo=78.
            bars=rng.choice([28,36,36,44])
            contour=rng.choice(CONTOURS);register=rng.choice([59,60,61,62])
            chords=[chord_data(n,shift) for n in family['progression']]
            melody=[];times=[];previous_note=61
            for bar,ch in enumerate(chords):
                target_note=register+contour[bar]
                candidates=[n for pc in ch['pcs'] for n in range(55,70) if n%12==pc]
                anchor=min(candidates,key=lambda n:abs(n-target_note)+.28*abs(n-previous_note))
                lower=sorted([n for n in candidates if anchor-5<=n<anchor],reverse=True)
                answer=rng.choice(lower[:2]) if lower else anchor
                ending=lower[-1] if lower else anchor
                count=2+(energy>.38 and bar%2==0)+(energy>.78 and bar%4==2)
                if energy<.22 and bar in (3,7):count=1
                ns=[anchor,answer,ending,answer][:count]
                ts={1:[0.],2:[0.,2.],3:[0.,2.,3.],4:[0.,1.,2.,3.]}[count]
                melody.append(ns);times.append(ts);previous_note=ns[-1]
            if i==0 and self.baseline_first:
                melody=ACCEPTED[0]['melody'];times=[[0.,2.,3.] if len(n)==3 else [0.,2.] for n in melody];bars=36
            # Ignore key, timbre, takes, tempo, and form length: those alone do not
            # count as new musical content for the recent-repetition guard.
            signature_data=dict(progression=family['progression'],melody=[[(n-key)%12 for n in ns] for ns in melody],times=times)
            signature=hashlib.sha256(json.dumps(signature_data,sort_keys=True).encode()).hexdigest()[:20]
            if signature not in self.recent_signatures:break
        else:raise RuntimeError('Could not find a fresh musical plan within bounded retries')
        self.recent_signatures.append(signature);self.recent_families.append(family['id']);self.index+=1
        return dict(id=i,title=f'{NAMES[i%len(NAMES)]} {i+1:02d}',signature=signature,family=family['id'],mode=family['mode'],key=key,key_name=KEY_NAMES[key],shift=shift,
            controls=asdict(c),energy=energy,tempo=tempo,bars=bars,focus=focus,chords=chords,melody=melody,melody_times=times,
            take_seed=rng.randrange(2**31),drum_cell=rng.randrange(6),bass_cell=rng.randrange(4),phrase_arc=rng.choice([[.92,1.,1.03,.94],[.95,1.02,.97,.90],[.90,.97,1.02,.96]]),
            parameters=dict(tempo=tempo,warmth=c.warmth,chill=1-energy,space=c.space,texture=c.texture,seed=self.seed+i,focus=focus))

    def next_song(self):
        song=self.current;nxt=self._draft(song);bridge=bridge_between(song,nxt)
        song.update(out_bridge=bridge,next_tempo=nxt['tempo'])
        song['duration_seconds']=local_seconds(song,song['bars']*4)
        song['outro_start_seconds']=song['start_seconds']+local_seconds(song,song['bars']*4-16)
        song['handoff_seconds']=song['start_seconds']+local_seconds(song,song['bars']*4-8)
        nxt.update(start_seconds=song['outro_start_seconds'],previous_tempo=song['tempo'],in_bridge=bridge)
        self.current=nxt
        return song

    def state(self):
        return dict(version=1,seed=self.seed,controls=asdict(self.controls),rng=self.rng.getstate(),recent_families=list(self.recent_families),recent_signatures=list(self.recent_signatures),index=self.index,baseline_first=self.baseline_first,current=self.current)

    @classmethod
    def restore(cls,state):
        if state['version']!=1:raise ValueError('Unsupported checkpoint')
        obj=cls.__new__(cls);obj.seed=state['seed'];obj.controls=Controls(**state['controls']).validate();obj.rng=random.Random();obj.rng.setstate(_tuples(state['rng']))
        obj.recent_families=deque(state['recent_families'],maxlen=4);obj.recent_signatures=deque(state['recent_signatures'],maxlen=64);obj.index=state['index'];obj.baseline_first=state['baseline_first'];obj.current=state['current'];return obj

def make_events(song):
    rng=random.Random(song['take_seed']);events=[];energy=song['energy'];bars=song['bars'];focus=song['focus']
    def emit(inst,note,beat,length,vel,role,pan=0,rr=0,release=.25,art='normal'):
        start=local_seconds(song,beat);end=local_seconds(song,beat+length)
        events.append(dict(instrument=inst,note=int(note),beat=beat,time=song['start_seconds']+start,local_time=start,duration=end-start,velocity=float(vel),role=role,pan=pan,round_robin=rr,release=release,articulation=art))
    bar_chords=[]
    for bar in range(bars):
        intro=song['in_bridge'] is not None and bar<4;outro=bar>=bars-4
        ch=song['in_bridge'] if intro else song['out_bridge'] if outro else song['chords'][bar%8]
        bar_chords.append(ch)
        phase=bar%8;cycle=bar//8;b=bar*4
        quiet=16<=bar<20 if bars>=36 else 12<=bar<16
        gain=.74 if quiet else .86 if bar<4 else 1.
        contour=song['phrase_arc'][(bar//2)%4];rr=(bar+rng.randrange(4))%4
        main=focus;other='piano' if main=='guitar' else 'guitar'
        vel=(.62 if focus=='guitar' else .54)*gain*contour
        refresh=bar==0 or phase%2==0 or ch['pcs']!=bar_chords[bar-1]['pcs'] or intro or outro
        if refresh or not quiet:
            for j,n in enumerate(ch['voices']):
                delay=.012+j*.012
                emit(main,n,b+delay*song['tempo']/60,3.65 if refresh else 2.8,vel*[.76,.92,.88,1.][min(j,3)]*(1 if refresh else .64),'chord',-.13 if main=='guitar' else -.05,rr+j,.55,'soft')
        if refresh:
            for j,n in enumerate([ch['voices'][0],ch['voices'][min(2,len(ch['voices'])-1)]]):
                emit(other,n,b+(.042+j*.014)*song['tempo']/60,6.8 if phase%2==0 else 3.3,(.32 if main=='guitar' else .25)*gain,'support',.22,rr+j,.72,'soft')
        if intro or outro:
            notes=ch['tops'][-2:][::-1];ts=[0.,2.][:len(notes)]
        else:notes=list(song['melody'][phase]);ts=list(song['melody_times'][phase])
        if quiet:notes=notes[:1];ts=ts[:1]
        if cycle%3==1 and phase in (3,7):notes=notes[:1];ts=ts[:1]
        if cycle%3==2 and phase in (4,6) and len(notes)>1 and not(intro or outro):notes[-1]=min(ch['tops'],key=lambda n:abs(n-notes[-1]))
        for j,(n,at) in enumerate(zip(notes,ts)):
            if bar<4 and bar%2 and j>0:continue
            end=ts[j+1] if j+1<len(ts) else 4
            emit(main,n,b+at+.018*song['tempo']/60,max(.55,end-at-.06),(.57 if main=='guitar' else .48)*gain*contour*[1.,.83,.72,.68][j],'melody',-.13 if main=='guitar' else -.05,rr+j,.30,'connected' if j else 'soft')
        if phase==7 and not(intro or outro) and not quiet:
            emit(other,ch['tops'][-1],b+3,.85,.19*gain,'answer',.28,rr,.65,'soft')
        rhythm=not(song['id']>0 and bar<2) and bar<bars-2
        if not rhythm:continue
        bass_vel=.58*gain;root=ch['root']
        extra=bar%2==0 and not quiet and energy>.22
        emit('bass',root,b+.006*song['tempo']/60,2.65 if extra else 3.52,bass_vel,'bass',0,rr,.11)
        if extra:
            follow=root+(7 if (bar+song['bass_cell'])%4==2 else 12)
            emit('bass',follow,b+3,.72,bass_vel*.64,'bass',0,rr+1,.10)
        if energy>.76 and bar%8==5 and not quiet:
            # Articulation is damped in the monophonic pass below.
            emit('bass',root+7,b+2,.65,bass_vel*.48,'bass',0,rr+2,.09)
        cell=(bar//2+song['drum_cell'])%6
        kpatterns=[[0,2.5],[0,2.],[0,2.75],[0,2.5],[0,2.],[0,2.75]]
        kick=[0] if quiet or energy<.16 else list(kpatterns[(cell+bar%2)%6])
        if energy>.76 and bar%4==2:kick=[0,1.75,2.5]
        for j,t in enumerate(kick):emit('kick',0,b+t,.4,(.62 if j==0 else .42)*gain,'drum',0,rr+j)
        for j,t in enumerate([1.,3.]):
            if quiet and j==1 and bar%2:continue
            emit('snare',1,b+t+.014*song['tempo']/60,.22,(.33 if j==0 else .29)*gain,'drum',.025,rr+j)
        for j in range(8):
            if (quiet or energy<.22) and j%2:continue
            if energy<.42 and j in(3,7):continue
            if bar<2 and j%2:continue
            at=j//2+(.53 if j%2 else 0.)
            emit('hat',0,b+at,.1,[.20,.075,.145,.065,.18,.075,.13,.055][j]*gain,'drum',.18,rr+j)
        if phase==7 and energy>.32 and not quiet:emit('snare',1,b+3.5,.1,.075,'ghost',-.06,rr+1)
        if cycle%2 and bar%2 and energy>.48:emit('shaker',0,b+2.54,.16,.095*gain,'drum',-.3,rr)
    # Deduplicate simultaneous harmonic/melodic notes, then model repeated-pitch
    # damping and harmonic boundary releases as in the accepted prototype.
    unique={}
    for e in events:
        key=(e['instrument'],e['note'],int(e['beat']+.08)) if e['instrument'] in ('guitar','piano') else (len(unique),)
        if key in unique and abs(unique[key]['beat']-e['beat'])<.15:
            if e['role']=='melody':e['velocity']=max(e['velocity'],unique[key]['velocity']);e['duration']=max(e['duration'],unique[key]['duration']);unique[key]=e
            continue
        unique[key]=e
    events=sorted(unique.values(),key=lambda e:e['local_time'])
    for inst in ('guitar','piano','bass'):
        groups={}
        for e in events:
            if e['instrument']==inst:groups.setdefault(e['note'] if inst!='bass' else 'mono',[]).append(e)
        for seq in groups.values():
            for a,b in zip(seq,seq[1:]):
                a['duration']=max(.035,min(a['duration'],b['local_time']-a['local_time']-.028));a['release']=min(a['release'],max(.025,b['local_time']-a['local_time']-a['duration']))
    for e in events:
        if e['instrument'] not in ('piano','guitar'):continue
        for b in range(int(e['beat']//4)+1,bars):
            elapsed=local_seconds(song,b*4)-e['local_time']
            if elapsed>=e['duration']+e['release']:break
            if e['note']%12 not in bar_chords[b]['pcs']:
                e['duration']=max(.04,min(e['duration'],elapsed-.11));e['release']=max(.025,elapsed-e['duration']-.01);break
    return events

if __name__=='__main__':
    planner=SessionPlanner(baseline_first=True)
    for _ in range(8):
        s=planner.next_song();print(s['id'],s['title'],s['family'],s['key_name'],s['mode'],s['tempo'],s['bars'],round(s['start_seconds'],2),s['signature'])
