"""Reproducible, resumable OpenRouter benchmark. Never writes credentials."""
import argparse
import hashlib
import html
import json
import math
import statistics
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

import requests
from comprehensive_cases import MODELS, all_cases, case, noul
from probe import api_key, evaluate, ENDPOINTS


def digest(obj):
    return hashlib.sha256(json.dumps(obj,ensure_ascii=False,separators=(",",":")).encode()).hexdigest()


def score(c, response):
    answers=response.get("answers")
    if not isinstance(answers,dict) or set(answers)!=set(c["questions"]):
        raise ValueError("Missing, extra, or malformed answer keys")
    out={}
    for key,q in c["questions"].items():
        answer=answers[key];expected=c["expected"][key]
        if answer.get("type")=="refusal":
            out[key]={"correct":False,"refusal":True,"expected":expected};continue
        d=evaluate(q,answer,expected)
        if q["type"]=="noul":
            p=float(answer["noul"]);expected_p=p if expected else 1-p
        else:
            probs={k:float(v) for k,v in answer["probabilities"].items()}
            expected_p=probs[str(expected)]
            if q["type"]=="score":
                weighted=sum(int(k)*v for k,v in probs.items())
                if abs(weighted-float(answer["score"]))>.02:
                    raise ValueError("Score disagrees with probability-weighted rubric")
        d["nll"]= -math.log(max(expected_p,1e-12));d["type"]=q["type"]
        if q["type"]=="score":d["modal_level"]=int(max(answer["probabilities"],key=answer["probabilities"].get))
        out[key]=d
    return out


def request(session,key,model,c):
    row={"case_id":c["id"],"model":model,"suite":c["suite"],"category":c["category"],
         "language":c["language"],"expected_count":len(c["expected"]),"attempts":[],
         "started_at":datetime.now(timezone.utc).isoformat()}
    body={"model":MODELS[model],"state":c["state"],"questions":c["questions"]}
    for attempt in range(2):
        t=time.perf_counter();a={}
        try:
            r=session.post(ENDPOINTS["openrouter"],json=body,timeout=(10,45))
            a["latency_ms"]=(time.perf_counter()-t)*1000;a["status"]=r.status_code
            try:a["response"]=r.json()
            except ValueError:a["error"]="Non-JSON response"
            if r.ok:
                row["response"]=a.get("response",{})
                row["decisions"]=score(c,row["response"])
            else:a["error"]=f"HTTP {r.status_code}"
        except Exception as e:
            a["latency_ms"]=(time.perf_counter()-t)*1000
            a["error"]=str(e).replace(key,"[REDACTED]")[:600]
        # Response bodies normally do not echo authentication, but redact before saving anyway.
        a=json.loads(json.dumps(a).replace(key,"[REDACTED]"));row["attempts"].append(a)
        if "decisions" in row:break
        if attempt==0 and (a.get("status") in [429,500,502,503,504,524,529] or "status" not in a):
            time.sleep(1);continue
        break
    row["latency_ms"]=sum(a["latency_ms"] for a in row["attempts"])
    if "decisions" not in row:row["error"]=row["attempts"][-1].get("error","Invalid response")
    # Include retry delay in user-visible end-to-end latency.
    if len(row["attempts"])>1:row["latency_ms"]+=1000
    return row


def quantile(values,q):
    if not values:return None
    return sorted(values)[max(0,math.ceil(len(values)*q)-1)]


def metrics(rows):
    ds=[d for r in rows for d in r.get("decisions",{}).values()]
    expected=sum(r["expected_count"] for r in rows)
    lat=[r["latency_ms"] for r in rows if "decisions" in r]
    high=[d for d in ds if d.get("top_probability",0)>=.9]
    costs=[a.get("response",{}).get("usage",{}).get("cost") for r in rows for a in r["attempts"]]
    nums=[x for x in costs if isinstance(x,(int,float))]
    return {"requests":len(rows),"valid_requests":sum("decisions" in r for r in rows),
            "decisions":expected,"correct":sum(d["correct"] for d in ds),
            "valid_decisions":len(ds),"errors":sum("error" in r for r in rows),
            "refusals":sum(d.get("refusal",False) for d in ds),
            "exact_case_passes":sum(len(r.get("decisions",{}))==r["expected_count"] and all(d["correct"] for d in r.get("decisions",{}).values()) for r in rows),
            "p50_ms":statistics.median(lat) if lat else None,"p95_ms":quantile(lat,.95),
            "high_confidence_count":len(high),"high_confidence_errors":sum(not d["correct"] for d in high),
            "high_confidence_coverage":len(high)/expected if expected else None,
            "binary_brier":statistics.mean([d["brier"] for d in ds if "brier" in d]) if any("brier" in d for d in ds) else None,
            "nll":statistics.mean([d["nll"] for d in ds if "nll" in d]) if any("nll" in d for d in ds) else None,
            "score_mae":statistics.mean([d["absolute_error"] for d in ds if "absolute_error" in d]) if any("absolute_error" in d for d in ds) else None,
            "reported_cost_usd":sum(nums),"attempts_without_cost":len(costs)-len(nums),
            "returned_models":sorted(set(r["response"].get("model","") for r in rows if "response" in r))}


def summarize(manifest,rows):
    result={"case_hash":manifest["case_hash"],"models":{},"pairs":{},"failures":[]}
    byid={c["id"]:c for c in manifest["cases"]}
    for model in manifest["models"]:
        rs=[r for r in rows if r["model"]==model]
        result["models"][model]={"all":metrics(rs),"suites":{},"core_categories":{},"core_languages":{}}
        for field,name,onlycore in [("suite","suites",False),("category","core_categories",True),("language","core_languages",True)]:
            groups=defaultdict(list)
            for r in rs:
                if not onlycore or r["suite"]=="core":groups[r[field]].append(r)
            result["models"][model][name]={k:metrics(v) for k,v in groups.items()}
        indexed={r["case_id"]:r for r in rs};matched=changed=missing=0
        for c in manifest["cases"]:
            if "paired_with" not in c:continue
            a=indexed.get(c["id"],{}).get("decisions",{});b=indexed.get(c["paired_with"],{}).get("decisions",{})
            for key in c["expected"]:
                if key not in a or key not in b:missing+=1;continue
                matched+=1
                changed+=(a[key].get("modal_level",a[key].get("predicted"))!=b[key].get("modal_level",b[key].get("predicted")))
        result["pairs"][model]={"compared_decisions":matched,"changed_labels":changed,"missing":missing}
        for r in rs:
            if "error" in r:result["failures"].append({"model":model,"case":r["case_id"],"suite":r["suite"],"error":r["error"]})
            for q,d in r.get("decisions",{}).items():
                if not d["correct"]:result["failures"].append({"model":model,"case":r["case_id"],"suite":r["suite"],"question":q,**d})
    return result


def report(path,manifest,result):
    esc=lambda x:html.escape(str(x))
    parts=["<!doctype html><meta charset='utf-8'><title>Jev · Luna · Decider</title><style>body{font:16px/1.55 system-ui;max-width:1150px;margin:45px auto;padding:0 24px;color:#18212b;background:#f8fafc}table{border-collapse:collapse;width:100%;margin:20px 0}td,th{border-bottom:1px solid #ccd5df;padding:10px;text-align:left}th{background:#e9eef4}pre{white-space:pre-wrap;font-size:13px}h1,h2{line-height:1.2}code{font-size:13px}details{margin:12px 0}</style>",
           "<h1>Jev vs GPT-6 Luna Decisions vs Decider V1</h1>",
           f"<p>Run started {esc(manifest['started_at'])}. OpenRouter Decisions API; synthetic inputs only. Fixed labels; case SHA-256 <code>{esc(manifest['case_hash'])}</code>.</p>",
           "<p>Core accuracy includes failed requests as unsuccessful decisions. Capability suites are separate: a large easy batch cannot inflate the core ranking. Network timing is measured from this Mac, with persistent sessions, one request at a time and rotating model order. Warmups excluded from accuracy and timings; all reported charges included in total cost.</p>"]
    def table(headers,data):
        parts.append('<table><tr>'+''.join('<th>'+esc(h)+'</th>' for h in headers)+'</tr>')
        for row in data:parts.append('<tr>'+''.join('<td>'+esc(v)+'</td>' for v in row)+'</tr>')
        parts.append('</table>')
    def fmt(x,nd=1):return '—' if x is None else f'{x:.{nd}f}'
    def acc(m):return f"{m['correct']}/{m['decisions']} ({m['correct']/m['decisions']:.1%})" if m['decisions'] else '—'
    parts.append('<h2>Shared core quality</h2>')
    data=[]
    for model,d in result['models'].items():
        m=d['suites'].get('core')
        if m:data.append([model,acc(m),f"{m['exact_case_passes']}/{m['requests']}",fmt(m['p50_ms']),fmt(m['p95_ms']),m['errors'],m['high_confidence_errors'],fmt(m['binary_brier'],4),fmt(m['score_mae'],4)])
    table(['Model','Correct','Cases all correct','P50 ms','P95 ms','API/schema errors','Wrong at ≥90%','Binary Brier ↓','Ordinal MAE ↓'],data)
    parts.append('<h2>Core categories</h2>')
    cats=sorted({k for d in result['models'].values() for k in d['core_categories']})
    table(['Category']+list(result['models']),[[cat]+[acc(d['core_categories'][cat]) if cat in d['core_categories'] else '—' for d in result['models'].values()] for cat in cats])
    parts.append('<h2>Separate capability and robustness suites</h2>')
    table(['Suite','Model','Correct','P50 ms','P95 ms','Errors'],[[suite,model,acc(m),fmt(m['p50_ms']),fmt(m['p95_ms']),m['errors']] for model,d in result['models'].items() for suite,m in d['suites'].items() if suite not in ['core','warmup']])
    parts.append('<h2>Cost and versions</h2>')
    table(['Model','All reported USD','Attempts missing cost','Returned model versions'],[[model,fmt(d['all']['reported_cost_usd'],8),d['all']['attempts_without_cost'],', '.join(d['all']['returned_models'])] for model,d in result['models'].items()])
    parts.append('<h2>Option and question reordering</h2><pre>'+esc(json.dumps(result['pairs'],indent=2))+'</pre>')
    parts.append('<h2>Limits of this experiment</h2><p>These are authored synthetic cases, not a representative production benchmark. Translations, counterfactual pairs and questions sharing a state are correlated. No statistical superiority or production calibration is established. A probability threshold is an analysis filter, not a validated authorization gate. Context tests report actual input token counts in raw responses and do not prove the maximum advertised window. No audio/video ingestion is claimed. Vision must pass image-only counterfactuals plus the no-image control before its accuracy is interpretable. Model routing and versions can change on a rerun.</p>')
    parts.append('<h2>All failures</h2>')
    for f in result['failures']:parts.append('<details><summary>'+esc(f['model']+' · '+f['case']+' · '+f.get('question',f.get('error','')))+'</summary><pre>'+esc(json.dumps(f,indent=2,ensure_ascii=False))+'</pre></details>')
    parts.append('<p>Files: <a href="manifest.json">fixed cases and run manifest</a> · <a href="responses.jsonl">raw responses and attempts</a> · <a href="summary.json">full metrics</a></p>')
    path.write_text('\n'.join(parts))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--models',nargs='+',choices=list(MODELS),default=list(MODELS))
    p.add_argument('--suite',nargs='+',help='Optional subset, e.g. core vision context_shared')
    p.add_argument('--quick',action='store_true',help='First two core cases per category; inexpensive integration smoke')
    p.add_argument('--output',type=Path,default=Path('results')/('comprehensive-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')))
    p.add_argument('--voiceflow-keychain',action='store_true')
    p.add_argument('--prepare',action='store_true',help='Freeze cases without making API calls')
    p.add_argument('--report-only',action='store_true')
    p.add_argument('--max-reported-cost',type=float,default=.50,help='Stop before next request after this reported USD total; not a provider hard cap')
    args=p.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    manifest_path=args.output/'manifest.json';responses=args.output/'responses.jsonl'
    if args.report_only:
        manifest=json.loads(manifest_path.read_text())
    else:
        cs=all_cases(args.output/'fixtures')
        if args.suite:cs=[c for c in cs if c['suite'] in args.suite]
        if args.quick:
            counts=Counter();selected=[]
            for c in cs:
                if c['suite']=='core' and counts[c['category']]<2:selected.append(c);counts[c['category']]+=1
            cs=selected
        if not cs:p.error('No cases selected')
        source_hashes={name:hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest() for name in ['comprehensive.py','comprehensive_cases.py','probe.py','cases.py','uv.lock']}
        manifest={'started_at':datetime.now(timezone.utc).isoformat(),'case_hash':digest(cs),'models':args.models,
                  'endpoint':ENDPOINTS['openrouter'],'source_hashes':source_hashes,'cases':cs}
        if manifest_path.exists():
            saved=json.loads(manifest_path.read_text())
            if saved['case_hash']!=manifest['case_hash'] or saved['models']!=manifest['models'] or saved['source_hashes']!=source_hashes:
                p.error('Existing run differs from current inputs/code; choose a new --output directory')
            manifest=saved
        else:manifest_path.write_text(json.dumps(manifest,indent=2,ensure_ascii=False))
    rows=[json.loads(line) for line in responses.read_text().splitlines()] if responses.exists() else []
    if not args.prepare and not args.report_only:
        key=api_key('openrouter',args.voiceflow_keychain)
        sessions={m:requests.Session() for m in args.models}
        for s in sessions.values():s.headers.update({'Authorization':'Bearer '+key,'Content-Type':'application/json'})
        done={(r['model'],r['case_id']) for r in rows}
        warm=case('warmup','warmup',{'active':True},{'active':noul('Is active true?')},{'active':True},suite='warmup')
        schedule=[]
        for i,c in enumerate([warm]+manifest['cases']):
            order=args.models[i%len(args.models):]+args.models[:i%len(args.models)]
            schedule.extend((m,c) for m in order if m in c.get('models',args.models) and (m,c['id']) not in done)
        try:
            for i,(model,c) in enumerate(schedule):
                total=sum(metrics([r])['reported_cost_usd'] for r in rows)
                if total>=args.max_reported_cost:print('Reported cost stop reached',flush=True);break
                row=request(sessions[model],key,model,c)
                # JSON roundtrip redacts every field, including row.response.
                row=json.loads(json.dumps(row).replace(key,'[REDACTED]'));rows.append(row)
                with responses.open('a') as f:f.write(json.dumps(row,ensure_ascii=False)+'\n');f.flush()
                good=sum(d['correct'] for d in row.get('decisions',{}).values())
                print(f"{i+1}/{len(schedule)} {model:7} {c['id']:35} {good}/{row['expected_count']} {row['latency_ms']:.0f}ms {row.get('error','')}",flush=True)
        finally:
            for s in sessions.values():s.close()
    result=summarize(manifest,rows)
    expected_requests=sum(sum(m in c.get('models',manifest['models']) for m in manifest['models']) for c in manifest['cases'])
    result['completion']={'expected_nonwarmup_requests':expected_requests,'actual_nonwarmup_requests':sum(r['suite']!='warmup' for r in rows)}
    (args.output/'summary.json').write_text(json.dumps(result,indent=2,ensure_ascii=False))
    report(args.output/'report.html',manifest,result)
    print(json.dumps({'cases':len(manifest['cases']),'decisions_per_suite':dict(Counter({s:sum(len(c['questions']) for c in manifest['cases'] if c['suite']==s) for s in {c['suite'] for c in manifest['cases']}})), 'output':str(args.output),'completion':result['completion']},indent=2))


if __name__=='__main__':main()
