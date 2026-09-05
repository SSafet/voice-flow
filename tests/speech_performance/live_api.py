"""Small live API probe. Key stays in memory; only synthetic text/audio is sent.
Records byte arrival times once, compares buffer policies on the SAME response,
and round-trips generated PCM through the production transcriber.
"""
import argparse, json, pathlib, statistics, subprocess, time, urllib.request
import numpy as np
from voice_flow.openai_transcriber import OpenAITranscriber

TEXT = 'Voice Flow should start speaking promptly and preserve every word. The final code is seven four two nine.'

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=pathlib.Path,required=True);parser.add_argument('--runs',type=int,default=5);args=parser.parse_args()
    key=subprocess.run(['security','find-generic-password','-s','com.voiceflow.app','-a','openai_api_key','-w'],capture_output=True,check=True).stdout.decode().strip()
    rows=[]
    for i in range(args.runs):
        request=urllib.request.Request('https://api.openai.com/v1/audio/speech',data=json.dumps(dict(model='gpt-4o-mini-tts',input=TEXT+'\n\n…',voice='coral',response_format='pcm',speed=1)).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
        start=time.monotonic(); pcm=bytearray(); trace=[]
        with urllib.request.urlopen(request,timeout=60) as response:
            while True:
                chunk=response.read1(4096)
                if not chunk:break
                pcm.extend(chunk);trace.append([round((time.monotonic()-start)*1000,3),len(pcm)])
        # Model only the controller buffer decision; actual device scheduling
        # is measured separately by benchmark.py's Swift controller probe.
        def threshold(n):return next((t for t,size in trace if size>=n),trace[-1][0])
        row=dict(ttfb_ms=trace[0][0],old_500ms_buffer_ready_ms=threshold(24000),new_120ms_buffer_ready_ms=threshold(5760),complete_ms=trace[-1][0],audio_seconds=len(pcm)/48000,trace=trace)
        # Replay arrival trace against consumption at realtime speed to count
        # starvation events after each startup policy (not physical xruns).
        for name,limit in [('old',24000),('new',5760)]:
            available=0.;last=threshold(limit);stalls=0;previous=0
            for at,size in trace:
                if at<last: available=size/48;previous=size;continue
                elapsed=at-last
                if elapsed>available+20 and previous:stalls+=1
                available=max(0,available-elapsed)+(size-previous)/48
                previous=size;last=at
            row[name+'_trace_starvations']=stalls
        if i==0:
            audio=np.frombuffer(pcm,dtype='<i2').astype(np.float32)/32767
            stt_start=time.monotonic()
            row['roundtrip_transcript']=OpenAITranscriber().transcribe(audio,key,sample_rate=24000)
            row['stt_api_ms']=(time.monotonic()-stt_start)*1000
        rows.append(row)
        print(f'Live speech probe {i+1}/{args.runs} complete',flush=True)
    result=dict(kind='live API byte arrivals; same-response buffer comparison, not acoustic latency',input=TEXT,model='gpt-4o-mini-tts',runs=rows,median_buffer_saving_ms=statistics.median(r['old_500ms_buffer_ready_ms']-r['new_120ms_buffer_ready_ms'] for r in rows))
    args.output.write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
