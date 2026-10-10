"""Build the dated combined report from saved evidence without API calls."""
import html
import json
from pathlib import Path
from comprehensive import metrics

ROOT=Path(__file__).parent


def main():
    read=lambda path:json.loads((ROOT/path).read_text())
    main_data=read('results/luna-decider-main/summary.json')
    vision=read('results/luna-decider-vision/summary.json')
    caps=read('decision_capabilities.json')
    main_rows=[json.loads(x) for x in (ROOT/'results/luna-decider-main/responses.jsonl').read_text().splitlines()]
    vision_rows=[json.loads(x) for x in (ROOT/'results/luna-decider-vision/responses.jsonl').read_text().splitlines()]
    probes=read('results/vision-encodings/responses.json')+read('results/vision-text-only-models/responses.json')
    preflight=read('results/luna-decider/preflight.json')+read('results/luna-decider/vision-preflight.json')
    cost=metrics(main_rows+vision_rows+probes)['reported_cost_usd']+sum(r['response']['usage']['cost'] for r in preflight)
    count=sum(len(r['attempts']) for r in main_rows+vision_rows+probes)+len(preflight)
    esc=lambda x:html.escape(str(x))
    parts=["<!doctype html><html lang='en'><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Decision models · October 2026</title>",
      "<style>body{font:16px/1.55 system-ui;max-width:1120px;margin:48px auto;padding:0 24px;color:#18212b;background:#f8fafc}h1{font-size:36px;line-height:1.15}h2{margin-top:38px}table{border-collapse:collapse;width:100%;margin:20px 0;font-size:15px}td,th{border-bottom:1px solid #ccd5df;padding:11px;text-align:left}th{background:#e8edf3}.lead{font-size:20px;max-width:920px}.callout{background:#e6f3ed;padding:18px 24px;border-left:4px solid #31825a}code{font-size:13px}pre{white-space:pre-wrap;background:#e8edf3;padding:16px}a{color:#185da9}.small{color:#566475;font-size:14px}.scroll{overflow:auto}</style>",
      "<p class='small'>LIVE OPENROUTER TEST · 7 OCTOBER 2026</p><h1>Jev vs GPT-6 Luna Decisions<br>vs Perplexity Decider V1</h1>",
      "<p class='lead'>Decider was strongest on this expanded text suite. Jev handled large question batches economically. Luna's strengths here were image decisions and fast retrieval from long inputs; it struggled on several short arithmetic and logic tests.</p>",
      f"<p>{count} API requests including setup and modality probes; total reported charge <strong>${cost:.8f}</strong>. Credentials came from the existing Keychain entry and stayed in process memory. Production Voice Flow code was not changed.</p>"]
    def table(headers,rows):
        parts.append('<div class="scroll"><table><tr>'+''.join('<th>'+esc(x)+'</th>' for x in headers)+'</tr>')
        for row in rows:parts.append('<tr>'+''.join('<td>'+esc(x)+'</td>' for x in row)+'</tr>')
        parts.append('</table></div>')
    def pct(m):return f"{m['correct']}/{m['decisions']} · {m['correct']/m['decisions']:.1%}"
    names={'jev':'Jev 1.13','luna':'GPT-6 Luna Decisions','decider':'Decider V1 27B'}
    parts.append('<h2>Shared text and JSON test</h2><p>102 inputs produce 202 decisions per model. Every model sees the same frozen states, questions and labels. Failed API or schema responses count as unsuccessful; none occurred in the scored runs. No retries were needed.</p>')
    table(['Model','Correct','Median / P95 request','Wrong at ≥90% probability','Core charge'],[
        [names[k],pct(d['suites']['core']),f"{d['suites']['core']['p50_ms']:.0f} / {d['suites']['core']['p95_ms']:.0f} ms",d['suites']['core']['high_confidence_errors'],f"${d['suites']['core']['reported_cost_usd']:.6f}"]
        for k,d in main_data['models'].items()])
    categories=list(main_data['models']['jev']['core_categories'])
    table(['Test category']+list(names.values()),[[cat]+[f"{main_data['models'][k]['core_categories'][cat]['correct']}/{main_data['models'][k]['core_categories'][cat]['decisions']}" for k in names] for cat in categories])
    parts.append('<p>All three passed the original 46-decision smoke test. The expanded cases separated them: Luna got only 1/12 refund arithmetic questions right, while Jev and Decider got 12/12. Jev failed an embedded classifier-override example in both English and Bulgarian. Decider’s one core error was allowing “email the report to Eva” when the user had only said “send the report to her,” leaving the recipient unresolved.</p>')
    parts.append('<p>Bulgarian subset: Jev 37/39; Luna 37/39; Decider 39/39. Instructions remained English. These paired cases do not establish broad multilingual quality. Reversing question and choice order changed none of the 36 compared labels for any model, including Luna’s wrong arithmetic labels.</p>')
    parts.append('<h2>Modalities: tested behavior versus documentation</h2>')
    table(['Model','OpenRouter inputs verified','Advertised context','Input $/M','Question batch tested'],[
        [names[k], 'Text, JSON' if k=='jev' else 'Text, JSON, images',f"{caps['models'][k]['advertised_context_tokens']:,}",caps['models'][k]['advertised_input_usd_per_million'],128 if k!='luna' else 200] for k in names])
    parts.append('<p>All three return typed probabilities, labels and ordinal scores; advertised output-token price is zero. These calls do not generate prose or execute tools. No direct audio/video ingestion was tested. For Voice Flow, audio first needs transcription; screenshots can go directly to the two verified image routes.</p>')
    table(['Vision model','Correct','Median / P95 request','Charge'],[[names[k],pct(d['suites']['vision']),f"{d['suites']['vision']['p50_ms']:.0f} / {d['suites']['vision']['p95_ms']:.0f} ms",f"${d['suites']['vision']['reported_cost_usd']:.6f}"] for k,d in vision['models'].items()])
    parts.append('<p>The 23 vision inputs cover four colors, four OCR words, four charts, two image-order cases, four invoices, four synthetic microphone-status screens, and a no-image control. Identical text with changed pixels verifies that the image affects the decision. Jev’s separate image controls consistently reported missing evidence; those are unsupported-modality probes, not a vision-quality score.</p>')
    parts.append('<div class="callout"><strong>Documentation discrepancy:</strong> Decider’s OpenRouter description says images are unsupported, but the live route passed every image control and all 35 vision decisions. The linked OpenRouter multimodal guide returned 404. Use the verified flat content-part format below; nested chat messages returned HTTP 200 but failed image-consumption controls.</div>')
    parts.append('<pre>'+esc(json.dumps({'model':'openai/gpt-6-luna-decisions','state':[{'type':'text','text':'Inspect this screenshot.'},{'type':'image_url','image_url':{'url':'data:image/png;base64,...'}}],'questions':{'mic_on':{'type':'noul','instructions':'Is the microphone shown as ON?'}}},indent=2))+'</pre>')
    parts.append('<h2>Context and batching change latency and cost</h2><p>Retrieval tests place a randomly selected lane in a unique target record at the start, middle or end among many distinct distractors. All models passed 24/24 shared retrieval decisions. Luna and Decider both passed the 12 extra decisions on the longest states; Jev was excluded because these exceed its advertised window. This tests retrieval, not reasoning over every record.</p>')
    selected=[r for r in main_rows if r['case_id'] in ['context-6500-start-teal','batch-128','batch-200']]
    table(['Test','Model','Reported input tokens','Request time','Reported cost'],[[r['case_id'],names[r['model']],f"{r['response']['usage']['input_tokens']:,}",f"{r['latency_ms']/1000:.3f} s",f"${r['response']['usage']['cost']:.7f}"] for r in selected])
    parts.append('<p>Across all six longest-context requests, median latency was 0.692 s for Luna and 12.578 s for Decider. The identical states produced roughly 98K billed input tokens for Luna and 274K for Decider with two questions. Usage counts can aggregate repeated state across questions: they are billing measurements, not a direct measurement of usable context. Maximum advertised windows were not exhaustively tested.</p>')
    parts.append('<p>At 128 questions, Jev cost about 11× less than Luna and 32× less than Decider in this example. All 128 answers were correct for each; Luna also passed 200/200. Each also matched the correct label in eight separate tests with 8, 32, 64 and 128 choices. One batch at each size is a capability check, not a throughput benchmark.</p>')
    parts.append('<h2>Practical choice</h2><p><strong>Start with Decider for a quality-focused pilot</strong> on narrow decisions, then validate against real labeled Voice Flow examples. Keep Jev as a useful baseline, especially when many questions share the same state. Luna is worth considering for long-input or image-heavy paths, but its short arithmetic and logic errors here argue against a blanket replacement.</p>')
    parts.append('<p>Decider publishes Apache-2.0 weights and an inference example; its model card identifies a Qwen3.8-27B fine-tune. The vendor example calls for Python 3.12+ and CUDA, with roughly 49 GiB of weights plus working memory. That gives you a downloadable starting checkpoint for adaptation; this experiment neither downloads those weights nor verifies a full training recipe or scaling procedure. Jev and Luna were tested as hosted models.</p>')
    parts.append('<h2>How to rerun</h2><pre>cd /Users/safet/repos/voice-flow/experiments/laya-jev\n./compare-decisions.sh --quick       # small integration smoke\n./compare-decisions.sh               # full text, capacity and vision pack\n./compare-decisions.sh --models luna decider --suite vision\nuv run --locked python -m unittest test_probe.py test_comprehensive.py</pre>')
    parts.append('<p>Each run gets a timestamped output folder with an HTML report, frozen cases, SHA-256 hashes, expected answers, raw provider responses, costs, versions and per-attempt timing. Use the same output folder to resume only if code and inputs are unchanged. The $0.50 reported-cost stop acts between requests; it is not a provider-enforced hard cap.</p>')
    parts.append('<h2>Evidence and limitations</h2><p>This is a synthetic, authored diagnostic suite, not a representative benchmark. Translations, paired states and multi-question cases are correlated. No thresholds were tuned against these results; high-probability error counts do not establish production calibration. Core network timing came from one pass on this Mac; some image-format exploration overlapped a portion of it. Small latency differences should not be treated as a stable ranking. The full vision run followed the main run.</p>')
    parts.append('<p><a href="results/luna-decider-main/report.html">Full text/capacity report and all failures</a> · <a href="results/luna-decider-vision/report.html">Vision report and raw evidence</a> · <a href="decision_capabilities.json">Capability snapshot and source links</a> · <a href="results/vision-encodings/responses.json">Image-format probes</a> · <a href="results/vision-text-only-models/responses.json">Jev/Decider modality probes</a></p>')
    table(['Model','Returned version'],[[names[k],', '.join(v['all']['returned_models'])] for k,v in main_data['models'].items()])
    parts.append('<p>Sources checked 7 October 2026: '+ ' · '.join(f'<a href="{url}">{esc(label)}</a>' for label,url in [
        ('Jev OpenRouter','https://openrouter.ai/typesafe/jev-1.13'),('Luna OpenRouter','https://openrouter.ai/openai/gpt-6-luna-decisions'),
        ('Decider OpenRouter','https://openrouter.ai/perplexity/pplx-decider-v1-27b'),('OpenAI Decisions input contract','https://developers.openai.com/api/reference/resources/decisions/methods/create'),
        ('Decider weights and vendor inference example','https://huggingface.co/perplexity-ai/pplx-decider-v1-27b')])+'</p></html>')
    path=ROOT/'LUNA_DECIDER_RESULTS.html';path.write_text('\n'.join(parts))
    print(json.dumps({'report':str(path),'requests':count,'reported_cost_usd':cost,'scored_decisions_excluding_warmup':sum(r['expected_count'] for r in main_rows+vision_rows if r['suite']!='warmup')},indent=2))


if __name__=='__main__':main()
