"""Test candidate OpenRouter image encodings; API acceptance is not vision proof.

The linked Multimodal Decisions guide returned 404 on 2026-10-07. These
encodings are integration probes, not claims that OpenRouter documents them.
"""
import argparse
import json
from copy import deepcopy
from pathlib import Path
import requests
from comprehensive import request, metrics
from comprehensive_cases import image_cases, MODELS
from probe import api_key


def transform(state,encoding):
    state=deepcopy(state)
    if encoding=='chat_parts':return state
    if encoding=='native_messages':
        parts=[{'type':'input_text','text':p['text']} if p['type']=='text' else
               {'type':'input_image','image_url':p['image_url']['url']} for p in state]
        return [{'role':'user','content':parts}]
    if encoding=='chat_messages':return [{'role':'user','content':state}]
    raise ValueError(encoding)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',type=Path,default=Path('results/vision-encodings'))
    p.add_argument('--models',nargs='+',choices=list(MODELS),default=['luna'])
    p.add_argument('--encodings',nargs='+',default=['native_messages','chat_parts','chat_messages'])
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    cs=image_cases(args.output/'fixtures');controls=cs[:4]+cs[4:6]+cs[-1:]
    key=api_key('openrouter',True);s=requests.Session();s.headers['Authorization']='Bearer '+key
    rows=[]
    for model in args.models:
        for encoding in args.encodings:
            for original in controls:
                c=deepcopy(original);c['state']=transform(c['state'],encoding)
                r=request(s,key,model,c);r['encoding']=encoding;rows.append(r)
                print(model,encoding,c['id'],r.get('response',{}).get('answers',r.get('error')),flush=True)
                (args.output/'responses.json').write_text(json.dumps(rows,indent=2))
    s.close();print(json.dumps(metrics(rows),indent=2))


if __name__=='__main__':main()
