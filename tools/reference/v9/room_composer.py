# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ryan Lefkowitz
# Development accelerated with Codex
"""Original phrase grammar: chord melody, shared gestures, and sectional subtraction.

This is a finite research renderer. It does not transcribe or sample the reference.
The templates are intentionally composed phrases, not a universal style model.
"""
import math, random, json
from pathlib import Path

PROFILES={
 'V08_A_Window_Seat':dict(tempo=78.,warmth=.78,chill=.78,space=.44,texture=.09,seed=81031,focus='guitar'),
 'V08_B_After_Hours':dict(tempo=74.,warmth=.84,chill=.90,space=.55,texture=.07,seed=81473,focus='piano'),
}
# Root, low close harmony, upper melodic consonances. Smooth inner voices matter
# more than maximizing the number of extensions. All MIDI pitches are concert.
CHORDS={
 'Fmaj9': (41,[53,57,60,64],[57,60,64,67]),
 'Em7': (40,[52,55,59,62],[55,59,62,64]),
 'Am9': (33,[52,55,59,60],[55,59,60,64]),
 'Dm9': (38,[53,57,60,64],[57,60,64,65]),
 'G6': (31,[50,55,59,64],[55,59,62,64]),
 'Cmaj9':(36,[52,55,59,62],[55,59,62,64]),
 'C69': (36,[52,55,57,62],[55,57,62,64]),
 'Bbmaj9':(34,[53,57,60,62],[57,60,62,65]),
 'Gm9':(31,[53,57,58,62],[53,57,62,65]),
 'C6': (36,[52,55,57,60],[55,57,60,64]),
}
FAMILIES=[
 dict(title='Window Seat',progression=['Fmaj9','Em7','Am9','Am9','Dm9','G6','Cmaj9','Cmaj9'],
      melody=[[64,60,57],[62,59],[60,59,55],[59,60],[60,57,64],[62,59],[59,62,64],[62,59]],
      counter=[57,55,59,55,57,55,55,59]),
 dict(title='Quiet Side Street',progression=['Am9','Am9','Fmaj9','Fmaj9','Cmaj9','Em7','Dm9','G6'],
      melody=[[60,59],[64,60,59],[60,64],[67,64,60],[62,59],[62,64,59],[64,60],[62,59]],
      counter=[55,52,57,53,55,52,57,55]),
 dict(title='After Hours',progression=['Bbmaj9','Bbmaj9','Am9','Am9','Gm9','C6','Fmaj9','Fmaj9'],
      melody=[[62,60,57],[60,62],[60,59,55],[59,60],[62,57],[60,57],[60,64,67],[64,60]],
      counter=[53,57,55,52,53,55,57,53]),
 dict(title='Small Hours',progression=['Fmaj9','Fmaj9','Dm9','Dm9','Bbmaj9','Bbmaj9','C6','C6'],
      melody=[[64,60],[67,64,60],[64,60],[60,57],[62,60],[65,62,60],[60,57],[64,60]],
      counter=[57,53,57,53,57,53,55,52]),
]

def make_plan(p,duration=200):
    rng=random.Random(p['seed']);beat=60/p['tempo'];events=[];songs=[]
    # 36-bar pieces overlap four bars. A common C6/9 bridge carries their tails.
    count=max(2,1+math.ceil(max(0,duration/beat-144)/128))
    focus=p['focus']; family_offset=0 if focus=='guitar' else 2
    def event(song,inst,note,b,d,vel,role,pan=0,rr=0,release=.25,art='normal'):
        events.append(dict(song=song,instrument=inst,note=note,beat=b,time=(songs[song]['start_beats']+b)*beat,
            local_time=b*beat,duration=d*beat,velocity=vel,role=role,pan=pan,round_robin=rr,
            release=release,articulation=art))
    for si in range(count):
        fam=FAMILIES[(family_offset+si)%len(FAMILIES)]
        start=si*128;songs.append(dict(id=si,title=fam['title'],start_beats=start,start_seconds=start*beat,end_seconds=(start+144)*beat))
        for bar in range(36):
            b=bar*4; cycle=bar//8; phase=bar%8
            bridge=bar>=32 or (si>0 and bar<4)
            ch='C69' if bridge else fam['progression'][phase]
            root,voicing,tops=CHORDS[ch]
            quiet=16<=bar<20
            arrival=bar<4
            gain=(.74 if quiet else .86 if arrival else 1.)
            # Shared two-bar contour and a take selection; no per-note timing dice.
            contour=[.92,1.00,1.03,.94][(bar//2)%4]
            rr=(bar+si+rng.randrange(4))%4
            chord_inst='guitar' if focus=='guitar' else 'piano'
            other_inst='piano' if focus=='guitar' else 'guitar'
            vel=(.62 if focus=='guitar' else .54)*gain*contour
            # Four-note, lightly rolled harmony occupies the middle register.
            # A repeated chord gets one quieter refresh, not four new loud attacks.
            prev='C69' if bar==0 or (si>0 and bar<=4) else fam['progression'][(bar-1)%8]
            refresh=(phase%2==0 or ch!=prev or bridge)
            if refresh or not quiet:
                for j,note in enumerate(voicing):
                    event(si,chord_inst,note,b+(.012+j*.012)/beat,3.65 if refresh else 2.8,
                          vel*[.76,.92,.88,1.][j]*(1 if refresh else .64),'chord',-.13 if focus=='guitar' else -.05,rr+j,.55,'soft')
            # Lower-level partner carries two common tones across the spaces.
            if refresh:
                for j,note in enumerate([voicing[0],voicing[2]]):
                    event(si,other_inst,note,b+(.042+j*.014)/beat,6.8 if phase%2==0 else 3.3,
                          (.32 if focus=='guitar' else .25)*gain,'support',.22,rr+j,.72,'soft')
            # Melody is the upper voice of the phrase, not an independent solo.
            notes=([62,57] if bridge else list(fam['melody'][phase]))
            if quiet:notes=notes[:1]
            if p['chill']>.85 and phase%2:notes=notes[:2]
            if cycle==1 and phase in (3,7):notes=notes[:1]  # let the response breathe
            if cycle==2 and phase in (4,6) and len(notes)>1:notes[-1]=tops[1]
            times=[0.,2.,3.] if len(notes)==3 else [0.,2.]
            for j,note in enumerate(notes):
                if arrival and bar%2 and j>0:continue
                at=times[j]
                # Keep strong tones on the quarter grid; groove belongs to the rhythm section.
                next_at=times[j+1] if j+1<len(notes) else 4
                event(si,chord_inst,note,b+at+.018/beat,max(.55,next_at-at-.06),
                      (.57 if focus=='guitar' else .48)*gain*contour*[1.,.83,.72][j],
                      'melody',-.13 if focus=='guitar' else -.05,rr+j,.30,'connected' if j else 'soft')
            # A short answer appears only at selected phrase endings, in a different register.
            if bar in (7,15,23,27) and not bridge:
                n=fam['counter'][phase]+12
                event(si,other_inst,n,b+3,.85,.19*gain,'answer',.28,rr,.65,'soft')
            # Soft legato bass, with root/fifth/octave movement at phrase boundaries.
            bass_vel=.58*gain
            if not (si>0 and bar<2):
                event(si,'bass',root,b+.006/beat,2.65 if bar%2==0 else 3.52,bass_vel,'bass',0,rr,.11)
                if bar%2==0 and not quiet:
                    follow=root+7 if bar%4==2 else root+12
                    event(si,'bass',follow,b+3,.72,bass_vel*.64,'bass',0,rr+1,.10)
            # Four two-bar cells, coupled dynamics, consistent backbeat, rare fills.
            # The handoff suppresses the outgoing rhythm before the incoming one starts.
            rhythm_active=not (si>0 and bar<2) and not (si<count-1 and bar>=34)
            if not rhythm_active:continue
            cell=(bar//2+si)%4
            kick_times=([0] if quiet else ([0,2.5] if bar%2==0 else [0,2.] if cell%2 else [0,2.75]))
            if bar%8==7 and not quiet:kick_times=[0,2.]
            for j,at in enumerate(kick_times):event(si,'kick',0,b+at,.4,(.62 if j==0 else .42)*gain,'drum',0,rr+j)
            for j,at in enumerate([1.,3.]):
                if quiet and j==1 and bar%2:continue
                event(si,'snare',1,b+at+.014/beat,.22,(.33 if j==0 else .29)*gain,'drum',.025,rr+j)
            # Quiet eighths give a bed underneath the melody, with fixed shallow swing.
            swing=.53
            for j in range(8):
                if quiet and j%2:continue
                if arrival and bar<2 and j%2:continue
                if p['chill']>.85 and j in (3,7):continue
                at=(j//2)+(swing if j%2 else 0.)
                v=[.20,.075,.145,.065,.18,.075,.13,.055][j]*gain
                event(si,'hat',0,b+at,.1,v,'drum',.18,rr+j)
            if bar%8==7 and not quiet:
                event(si,'snare',1,b+3.5,.1,.075,'ghost',-.06,rr+1)
            if cycle in (1,3) and bar%2:
                event(si,'shaker',0,b+2.54,.16,.095*gain,'drum',-.3,rr)
    # Suppress exact-pitch doubles inside a gesture; the melodic articulation wins.
    dedup={}
    for e in events:
        key=(e['song'],e['instrument'],e['note'],int(e['beat']+.08))
        if e['instrument'] in ('guitar','piano') and key in dedup:
            prior=dedup[key]
            if abs(prior['beat']-e['beat'])<.15:
                if e['role']=='melody':
                    e['velocity']=max(e['velocity'],prior['velocity']);e['duration']=max(e['duration'],prior['duration']);dedup[key]=e
                continue
        dedup[key if e['instrument'] in ('guitar','piano') else (len(dedup),)]=e
    events=sorted(dedup.values(),key=lambda e:e['time'])
    # A rearticulated pitch damps its predecessor instead of stacking duplicate voices.
    for si in range(count):
        for inst in ('guitar','piano','bass'):
            groups={}
            for e in events:
                if e['song']==si and e['instrument']==inst:groups.setdefault(e['note'] if inst!='bass' else 'mono',[]).append(e)
            for seq in groups.values():
                for a,b in zip(seq,seq[1:]):
                    a['duration']=max(.035,min(a['duration'],b['time']-a['time']-.028))
                    a['release']=min(a['release'],max(.025,b['time']-a['time']-a['duration']))
    # Pedal changes: incompatible tones finish before the new chord's attack.
    # Shared tones may continue; reverberation is deliberately not hard-gated.
    for e in events:
        if e['instrument'] not in ('piano','guitar'):continue
        si=e['song'];fam=FAMILIES[(family_offset+si)%len(FAMILIES)]
        for boundary in range(int(e['beat']//4)+1,36):
            elapsed=boundary*4*beat-e['local_time']
            if elapsed>=e['duration']+e['release']:break
            chord='C69' if boundary>=32 or (si>0 and boundary<4) else fam['progression'][boundary%8]
            root,voices,tops=CHORDS[chord];allowed={n%12 for n in [root]+voices+tops}
            if e['note']%12 not in allowed:
                e['duration']=max(.04,min(e['duration'],elapsed-.11));e['release']=max(.025,elapsed-e['duration']-.01);break
    return dict(revision=8,parameters=p,duration=duration,songs=songs,events=events,
        provenance='Original composed phrase grammar; reference used for aggregate analysis only')

if __name__=='__main__':
    for name,p in PROFILES.items():
        plan=make_plan(p);Path(__file__).with_name(name+'_plan.json').write_text(json.dumps(plan,indent=2))
        print(name,len(plan['events']),[(s['title'],round(s['start_seconds'],2)) for s in plan['songs']])
