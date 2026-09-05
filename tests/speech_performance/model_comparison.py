"""Exploratory live STT comparison; synthetic audio only, no app configuration changes.
Run: PYTHONPATH=. uv run --no-project --with numpy --with websockets python tests/speech_performance/model_comparison.py
Prices and model choice require separate verification. This is not a quality corpus.
"""
import asyncio,base64,hashlib,json,pathlib,re,subprocess,time,urllib.request,wave,sys
import numpy as np
from voice_flow.openai_transcriber import OpenAITranscriber
from websockets.asyncio.client import connect

ROOT=pathlib.Path('design/speech-performance/evidence')
OUT=ROOT/'model-comparison.json'
TEXT='Please move the Voice Flow design review to Thursday afternoon. Keep the existing customer data intact. Check keyboard navigation and confirm every recovery action. The final confirmation code is seven four two nine.'
MODELS=['gpt-4o-mini-transcribe','gpt-transcribe','gpt-4o-transcribe']

def canonical(s):
    s=re.sub(r'voice\s+flow','voiceflow',s.lower())
    s=re.sub(r'seven[\s-]+four[\s-]+two[\s-]+nine','7429',s)
    return re.findall(r'\w+',s)

def wer(a,b):
    ref,hyp=canonical(a),canonical(b);row=list(range(len(hyp)+1))
    for i,w in enumerate(ref,1):
        nxt=[i]
        for j,v in enumerate(hyp,1):nxt.append(min(nxt[-1]+1,row[j]+1,row[j-1]+(w!=v)))
        row=nxt
    return row[-1]/max(1,len(ref))

async def realtime(audio,key):
    t=time.monotonic();events=[];final=asyncio.Event();updated=asyncio.Event();done={};release=None
    async with connect('wss://api.openai.com/v1/realtime?intent=transcription',additional_headers={'Authorization':'Bearer '+key},max_size=8*1024*1024,open_timeout=15,close_timeout=2,proxy=None) as ws:
        print('Realtime socket connected',file=sys.stderr,flush=True)
        async def receive():
            async for raw in ws:
                event=json.loads(raw);kind=event.get('type','')
                if kind not in ('conversation.item.input_audio_transcription.delta',): print('Realtime event '+kind,file=sys.stderr,flush=True)
                events.append({'type':kind,'at_ms':(time.monotonic()-t)*1000, 'item_id':event.get('item_id')})
                if kind in ('session.updated','transcription_session.updated'):updated.set()
                if kind=='error':done['error']=event.get('error');updated.set();final.set();return
                if kind=='conversation.item.input_audio_transcription.delta' and 'first_delta_ms' not in done:done['first_delta_ms']=(time.monotonic()-t)*1000
                if kind=='conversation.item.input_audio_transcription.completed':
                    done['transcript']=event.get('transcript','');done['completed_at_ms']=(time.monotonic()-t)*1000;final.set();return
                if kind=='conversation.item.input_audio_transcription.failed':done['error']=event.get('error');final.set();return
        task=asyncio.create_task(receive())
        try:
            await ws.send(json.dumps({'type':'session.update','session':{'type':'transcription','audio':{'input':{'format':{'type':'audio/pcm','rate':24000},'transcription':{'model':'gpt-live-transcribe','delay':'medium'},'turn_detection':None}}}}))
            await asyncio.wait_for(updated.wait(),15)
            if done.get('error'):return done
            done['setup_ms']=(time.monotonic()-t)*1000
            began=time.monotonic();chunk=4800 # 100 ms of mono PCM16
            for offset in range(0,len(audio),chunk):
                await ws.send(json.dumps({'type':'input_audio_buffer.append','audio':base64.b64encode(audio[offset:offset+chunk]).decode()}))
                await asyncio.sleep(max(0,began+min(offset+chunk,len(audio))/48000-time.monotonic()))
            print('Realtime audio upload complete',file=sys.stderr,flush=True)
            release=time.monotonic()
            await ws.send(json.dumps({'type':'input_audio_buffer.commit'}))
            try:
                await asyncio.wait_for(final.wait(),30)
            except TimeoutError:
                done['error']='No terminal transcription event within 30 seconds of commit'
            done['release_to_final_ms']=(time.monotonic()-release)*1000
            done['first_text_before_release']=done.get('first_delta_ms',1e9)<(release-t)*1000
            done['events']=events
            return done
        finally:task.cancel()

def main():
    key=subprocess.run(['security','find-generic-password','-s','com.voiceflow.app','-a','openai_api_key','-w'],capture_output=True,check=True).stdout.decode().strip()
    path=ROOT/'model-probe-synthetic.wav'
    if not path.exists():
        req=urllib.request.Request('https://api.openai.com/v1/audio/speech',data=json.dumps(dict(model='gpt-4o-mini-tts',input=TEXT+'\n\n…',voice='coral',response_format='pcm')).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
        with urllib.request.urlopen(req,timeout=90) as r:pcm=r.read()
        with wave.open(str(path),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(24000);w.writeframes(pcm)
    with wave.open(str(path),'rb') as w:pcm=w.readframes(w.getnframes())
    result={'kind':'exploratory live API test; synthetic repeated English, not production quality evidence','reference':TEXT,'fixture_sha256':hashlib.sha256(pcm).hexdigest(),'fixture_seconds':len(pcm)/48000,'file':[],'realtime':[]}
    if OUT.exists():result=json.loads(OUT.read_text())
    def save():OUT.write_text(json.dumps(result,indent=2)+'\n')
    for repeat in [1,6]:
        audio=pcm*repeat;expected=' '.join([TEXT]*repeat)
        for trial in range(2):
            for model in (MODELS if trial==0 else list(reversed(MODELS))):
                if any(r['model']==model and r['trial']==trial and r['audio_seconds']==len(audio)/48000 for r in result['file']):continue
                first=[];start=time.monotonic();row={'model':model,'trial':trial,'audio_seconds':len(audio)/48000}
                try:
                    transcript=OpenAITranscriber(model_name=model).transcribe(np.frombuffer(audio,dtype='<i2').astype(np.float32)/32767,key,sample_rate=24000,on_delta=lambda text:first.append((time.monotonic()-start)*1000) if text and not first else None,max_attempts=1)
                    row.update(final_ms=(time.monotonic()-start)*1000,first_text_ms=first[0] if first else None,transcript=transcript,normalized_wer=wer(expected,transcript))
                except Exception as exc:row['error']=type(exc).__name__+': '+str(exc)
                result['file'].append(row);save();print({k:v for k,v in row.items() if k!='transcript'},flush=True)
        for trial in range(2 if repeat==1 else 1):
            if any(r['trial']==trial and r['audio_seconds']==len(audio)/48000 for r in result['realtime']):continue
            row={'model':'gpt-live-transcribe','delay':'medium','trial':trial,'audio_seconds':len(audio)/48000}
            try:
                run=subprocess.run([sys.executable,__file__,'--realtime-worker',str(repeat)],capture_output=True,text=True,timeout=len(audio)/48000+45)
                if run.returncode:raise RuntimeError(run.stderr[-1500:])
                row.update(json.loads(run.stdout))
                if 'transcript' in row:row['normalized_wer']=wer(expected,row['transcript'])
            except Exception as exc:row['error']=type(exc).__name__+': '+str(exc)
            result['realtime'].append(row);save();print({k:v for k,v in row.items() if k not in ('transcript','events')},flush=True)
if __name__=='__main__':
    if '--realtime-worker' in sys.argv:
        key=subprocess.run(['security','find-generic-password','-s','com.voiceflow.app','-a','openai_api_key','-w'],capture_output=True,check=True).stdout.decode().strip()
        with wave.open(str(ROOT/'model-probe-synthetic.wav'),'rb') as w:pcm=w.readframes(w.getnframes())
        print(json.dumps(asyncio.run(realtime(pcm*int(sys.argv[-1]),key))))
    else:main()
