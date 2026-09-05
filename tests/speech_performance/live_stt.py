"""Paired completed-file vs SSE calls, using synthetic speech and no user data."""
import argparse,json,pathlib,re,statistics,subprocess,time,urllib.request
import numpy as np
from voice_flow.openai_transcriber import OpenAITranscriber

TEXT = ('Please move the design review to Thursday afternoon and invite the product team. '
'We need to discuss the new navigation, confirm the delivery date, and check the remaining accessibility issues. '
'The first milestone is a working prototype. The second milestone is a complete test with keyboard navigation. '
'Keep the existing customer data intact and make sure every error has a clear recovery action. '
'After the review, write a short summary with the decisions, the owners, and the next steps. '
'Do not send the release announcement until the final checks pass. '
'The project name is Voice Flow. The final confirmation code is seven four two nine.')

def normalized(text):
    text=re.sub(r'voice\s+flow','voiceflow',text.lower())
    text=text.replace('seven four two nine','7429')
    return re.findall(r'[a-z0-9]+',text)


def word_error_rate(reference, actual):
    ref, hyp = normalized(reference), normalized(actual)
    row = list(range(len(hyp)+1))
    for i, word in enumerate(ref, 1):
        nxt = [i]
        for j, other in enumerate(hyp, 1):
            nxt.append(min(nxt[-1]+1, row[j]+1, row[j-1]+(word != other)))
        row = nxt
    return row[-1] / max(1, len(ref))


def main():
    ap=argparse.ArgumentParser();ap.add_argument('--output',type=pathlib.Path,required=True);ap.add_argument('--runs',type=int,default=3);args=ap.parse_args()
    key=subprocess.run(['security','find-generic-password','-s','com.voiceflow.app','-a','openai_api_key','-w'],capture_output=True,check=True).stdout.decode().strip()
    req=urllib.request.Request('https://api.openai.com/v1/audio/speech',data=json.dumps(dict(model='gpt-4o-mini-tts',input=TEXT+'\n\n…',voice='coral',response_format='pcm')).encode(),headers={'Authorization':'Bearer '+key,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=90) as response:pcm=response.read()
    audio=np.frombuffer(pcm,dtype='<i2').astype(np.float32)/32767
    rows=[]
    for i in range(args.runs):
        for stream in ([False,True] if i%2==0 else [True,False]):
            first=[];start=time.monotonic()
            def delta(text):
                if text and not first:first.append((time.monotonic()-start)*1000)
            text=OpenAITranscriber().transcribe(audio,key,sample_rate=24000,on_delta=delta if stream else None)
            elapsed=(time.monotonic()-start)*1000
            assert word_error_rate(TEXT,text) <= .04 and '7429' in normalized(text), 'Synthetic transcript quality failed: '+text
            rows.append(dict(pair=i,mode='stream' if stream else 'batch',first_text_ms=first[0] if first else elapsed,final_ms=elapsed,transcript=text,word_count=len(text.split()),normalized_exact_match=normalized(text)==normalized(TEXT),normalized_wer=word_error_rate(TEXT,text)))
            print(f'STT pair {i+1} {"stream" if stream else "batch"}: first={rows[-1]["first_text_ms"]:.0f}ms final={elapsed:.0f}ms',flush=True)
    result=dict(kind='live API, alternating paired requests; synthetic English only',audio_seconds=len(pcm)/48000,input=TEXT,runs=rows)
    for mode in ['batch','stream']:
        result[mode+'_first_text_median_ms']=statistics.median(r['first_text_ms'] for r in rows if r['mode']==mode)
        result[mode+'_final_median_ms']=statistics.median(r['final_ms'] for r in rows if r['mode']==mode)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':main()
