# Laya, Jev, and Clef: small decision-model comparison

## Expanded Jev / GPT-6 Luna Decisions / Decider V1 comparison — 7 October 2026

[Full report: results, modalities, costs, versions and failures](LUNA_DECIDER_RESULTS.html).

The shared 202-decision suite scored **Decider 201/202**, **Jev 196/202**, and
**Luna 182/202**. Median network-inclusive request times were 313, 323 and 294 ms,
respectively. This is an authored diagnostic suite, not a representative ranking.
All three passed the earlier 46-decision smoke cases; the expanded arithmetic,
logic, negation and permission cases exposed the differences.

Luna and Decider both passed **35/35 vision decisions** with the verified flat
content-part encoding below. Jev's image controls returned missing evidence.
Decider's live image support contradicts the text-only warning on its OpenRouter
model page. Neither nested chat messages nor top-level `images` should be assumed
equivalent to the tested format.

```sh
# Uses the existing OpenRouter Keychain entry; no key appears in output.
./compare-decisions.sh --quick
./compare-decisions.sh                         # complete suite, all three models
./compare-decisions.sh --models luna decider --suite vision
./compare-decisions.sh --suite core --models jev decider

# Freeze/inspect inputs without calls; raw output folders default to timestamps.
./compare-decisions.sh --prepare
uv run --locked python -m unittest test_probe.py test_comprehensive.py

# Rebuild the combined dated report from the saved runs, without API calls.
uv run --locked python comparison_report.py
```

The full evidence consists of 519 requests including setup/probes, **1,611 scored
decisions** excluding warmups and modality-discovery probes, and **$0.183484402**
in reported charges. Capacity and repeated variants are reported separately from
core quality. Raw evidence lives in `results/luna-decider-main/`,
`results/luna-decider-vision/`, `results/vision-encodings/`, and
`results/vision-text-only-models/`. These generated files are gitignored.

`comprehensive_cases.py` defines the fixed labels and fixtures. `comprehensive.py`
persists every attempt, checks response schemas/probability distributions, counts
failed requests in the denominator, rotates model order, and permits one retry
for transient failures. It uses a $0.50 reported-cost stop between requests,
not a provider-enforced hard spending cap. Resume with the same `--output` only
while inputs and source hashes match; choose a fresh folder after code changes.
`--report-only --output ...` regenerates a report without calling the API.

Verified image request shape (same endpoint, Luna or Decider model ID):

```json
{
  "model": "openai/gpt-6-luna-decisions",
  "state": [
    {"type": "text", "text": "Inspect this screenshot."},
    {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
  ],
  "questions": {"mic_on": {"type": "noul", "instructions": "Is the microphone ON?"}}
}
```

The [capability snapshot](decision_capabilities.json) records sources and
discrepancies. Advertised contexts: Jev 32,000, Luna 1,050,000, Decider 262,144.
Actual billed token counts differ by provider and question count. At 128 questions
in one request, the measured costs were Jev $0.000199, Luna $0.002125, and Decider
$0.006395. Decider offers downloadable Apache-2.0 weights; this comparison only
uses its hosted API and does not download or run its roughly 49 GiB checkpoint.

## Jev / Clef / Clef Flash through OpenRouter — 6 October 2026

All three were tested using the same unchanged 26 English/Bulgarian short cases (46 decisions), plus two long-input checks. Jev scored **46/46**, Clef **45/46**, and Clef Flash **45/46**. Median request latency including the network was **258 ms**, **539 ms**, and **212 ms**, respectively. Each run used one warm-up followed by one pass; models ran sequentially. This is a small smoke comparison, not a robust ranking. Both Clef models assigned the vague English command “Do that.” to the assistant instead of asking for clarification. All three passed both long-input checks. No short-input mistakes had top-label probability ≥90%.

The complete text comparison reported **$0.00488724** in API charges including warm-ups. Credentials were read from the existing macOS Keychain entry into memory, never saved to reports. [Full comparison, probabilities, versions, and raw evidence](CLEF_RESULTS.md).

```sh
# Run from this directory. Same OpenRouter account and decisions endpoint for all three.
./run.sh hosted --voiceflow-keychain --output results/clef-comparison
python3 summarize.py --input results/clef-comparison --output CLEF_RESULTS.md

# Or select just one model / try your own text.
./run.sh clef-flash --voiceflow-keychain --text 'Направи екранна снимка.' --task intent
```

The model IDs are `typesafe/jev-1.13`, `cloudflare/clef`, and `cloudflare/clef-flash`, using `https://openrouter.ai/api/alpha/decisions`. The previous `all` command retains its Laya-plus-Jev meaning; `hosted` selects Jev and both Clef models. The earlier Laya results below remain the September run, not a new comparison with current hosted latency.

**Vision is not verified through this integration.** A separate Flash probe passed red/blue synthetic PNGs through a top-level `images` extension; both returned the same “no image available” distribution and token counts as a no-image control. The extension appears ignored. This tests request handling, not the model's vision quality, and is excluded from the text scores. The [current OpenRouter SDK schema](https://github.com/OpenRouterTeam/typescript-sdk/blob/main/src/models/decisionsrequest.ts) does not expose `images`. Raw responses are saved alongside the comparison results.

OpenRouter's Clef descriptions warn of roughly 2K-token text-state truncation on the Workers AI route, despite the advertised 65,536-token model window. Our two ~2.7K billed-input-token checks passed on both models, so we have **not reproduced or established the exact truncation boundary**. Do not infer the usable context limit from those two checks. [Clef model page](https://openrouter.ai/cloudflare/clef) · [Flash model page](https://openrouter.ai/cloudflare/clef-flash).

## Earlier Laya comparison

These models make **decisions from text**: choose one of your labels, estimate an ordinal score, or give a yes/no probability. They do not dictate audio, write replies, invent new labels, or operate your computer. Your application defines the choices and acts on the result. A well-formed answer can still be wrong.

Laya is an independent open implementation of the same broad idea as TypeSafe Jev, not Jev's released weights or an established equivalent. Both use the term RLCD for training toward calibrated decisions; that shared label does not establish equal architecture, data, quality, or actual calibration.

**Measured verdict:** Laya runs successfully on this Mac, but these untouched checkpoints are not a reliable replacement for Jev on our small task set. Jev got 45/46 short decisions correct; Laya typed-decisions 31/46, English 30/46, and multilingual 23/46. Multilingual made 12 errors at ≥90% top-label probability. It is a candidate for narrow local tasks with domain training and a larger labeled evaluation, not something we should put in charge of general routing based on these results. [Full results and individual mistakes](RESULTS.md).

One failing multilingual case (English pricing inquiry) was also rerun on CPU: the entire answer dictionaries matched the MPS run exactly, including its incorrect billing label. This checks that particular failure; it is not a full cross-device equivalence test.

## Run

From this directory (or use the absolute path to `run.sh`):

```sh
# Local multilingual model; no API key, downloaded weights reused.
./run.sh laya-multi --offline

# Jev using the existing Voice Flow OpenRouter credential from macOS Keychain.
./run.sh jev --voiceflow-keychain

# All three Laya checkpoints plus Jev, with identical test inputs.
./run.sh all --voiceflow-keychain

# Try your own message; results are unscored.
./run.sh laya-multi --text 'Таксуваха ме два пъти. Искам парите си обратно днес.'
./run.sh jev --voiceflow-keychain --task intent --text 'Read this paragraph aloud.'

# List the test cases and expected answers, without running a model.
./run.sh --list

# Rebuild the readable table from the latest complete, matching runs.
python3 summarize.py
```

`uv` installs an isolated Python environment using `uv.lock`. No Voice Flow dependencies or application behavior change. First model startup takes longer; inference timings exclude model loading and one warm-up request. `--offline` applies to local model downloads, not to an explicitly selected Jev API call. Drop it to download on another computer. CPU is available with `--device cpu`; Apple Silicon uses MPS by default. `./run.sh local --download-only` downloads all Laya checkpoints, about 2.36 GB including tokenizers, into the normal Hugging Face cache.

You can use `OPENROUTER_API_KEY` instead of Keychain. For direct TypeSafe access, set `TYPESAFE_API_KEY` in your shell and run `./run.sh jev --provider typesafe`. Credentials stay in memory and are never written to reports. Only the synthetic test text (or the text you explicitly supply) is sent to the chosen provider. The full default Jev run makes 29 requests, including warm-up, with no automatic retries.

OpenRouter uses `POST https://openrouter.ai/api/alpha/decisions`, model `typesafe/jev-1.13`, **not chat completions**. The report records the returned model version. TypeSafe uses `POST https://api.typesafe.ai/v1/systemone`, model `jev-1.13.0`. Override with `--jev-model` when intentionally changing versions.

## What is tested

26 short synthetic inputs produce 46 scored decisions. Each English case has a Bulgarian equivalent; question instructions stay in English for both models. The examples and expected answers were written before inference, with no tuning after viewing results.

| Test | Decisions | What to inspect |
|---|---:|---|
| Support triage | 30 | Department, explicit refund request, urgency rubric; includes negation and embedded instruction attempts |
| Conversation continuity | 8 | Follow-up/correction versus a new topic |
| Voice-command routing | 8 | Speech, screenshot, assistant, or clarification |
| Long-input stress | 2, reported separately | Same refund request at the start versus end of a long log; detects silent truncation |

Reports save input, full question schema, expected answer, raw probabilities, returned version, device, package versions, latency, and errors in `results/*.json`. All models receive the same state/questions. Laya explicitly logs available state-token budgets and truncation. Its internal tokenization still differs from Jev's. Short-input timings mix one-question and three-question requests and include tokenization, Laya input diagnostics, and (for Jev) network overhead. These are observed application timings, not GPU-kernel comparisons or reliable tail-latency estimates.

Boolean classification uses P(yes) >= 0.5. Choice uses the returned option. Score accuracy uses the highest-probability ordinal level; score MAE separately measures the probability-weighted value. We report wrong answers with top-label probability >= 90%, rather than treating each vendor's `confidence` field as interchangeable. Ten boolean examples are insufficient to establish calibration; Brier is descriptive only. Stress cases do not enter short-input accuracy. Runtime errors are counted separately and cause a nonzero exit, not silently scored as successes.

This is a **smoke test**, not a representative benchmark or a production acceptance gate. The translated pairs and multiple questions per message are correlated. A high result here is a reason to try more real labeled examples; a failure tells us a concrete limitation now.

## Checkpoints and practical differences

| | Laya English | Laya multilingual | Laya typed-decisions | Jev |
|---|---|---|---|---|
| Runner name | `laya-en` | `laya-multi` | `laya-typed` | `jev` |
| Encoder | ModernBERT large | mmBERT base | ModernBERT large | Proprietary |
| Where it runs | This Mac | This Mac | This Mac | Hosted API |
| Downloaded weights | 843 MB | 644 MB | 843 MB | No public weights in the cited release |
| Main distinction | English base | Multilingual base | Specialized decision fine-tune | General hosted decision model |
| Custom weights | Yes | Yes | Yes | No customer fine-tuning API documented |

All local weights are frozen to `convaiinnovations/laya` revision `1c5edc17a7acd8701df6fc341c0d179f1c62c982`, using root, `multilingual/`, and `typed-decisions/` respectively. This avoids the SDK router choosing a different model invisibly. The older separate `laya-multilingual` repository and the current bundled subfolder should not be assumed identical; this experiment records the exact files used.

Laya's configured inference window is far shorter than its encoder's theoretical maximum. The report saves actual `max_len` and `head_max_len`; state is truncated to what remains after instructions/options. “Supports 100+ languages” describes the multilingual checkpoint's scope, not guaranteed accuracy. Its shipped config has unfitted temperature values of 1.0. Local inference avoids per-call API charges but still uses memory, compute, and power.

In the inspected Laya implementation, each question is formatted with its own copy of the state and these sequences are batched through the encoder. TypeSafe documents a shared state with questions evaluated in parallel. The interfaces look similar, but this is another reason not to assume the computation or scaling is identical.

TypeSafe currently documents a 64k aggregate request budget and 32k state-plus-longest-question limit, text-only inputs, and $0.042 per million input tokens for Jev 1.13. English is its strongest language. The current Laya README acknowledges that some Jev comparisons use third-party published results with different samples/prompts; those tables do not establish a head-to-head win. Our small experiment uses identical inputs instead.

Sources checked 20 September 2026:

- [Laya source and current evaluation caveats](https://github.com/NandhaKishorM/laya)
- [Exact Hugging Face model revision](https://huggingface.co/convaiinnovations/laya/tree/1c5edc17a7acd8701df6fc341c0d179f1c62c982)
- [TypeSafe models, pricing, context, languages](https://docs.typesafe.ai/models)
- [TypeSafe API contract](https://docs.typesafe.ai/api)
- [Jev's documented limitations](https://docs.typesafe.ai/model-jaggedness/jev-1.13)
- [OpenRouter's Jev lab example](https://openrouter.ai/labs/jev/compile)
- [OpenRouter SDK decisions endpoint](https://github.com/OpenRouterTeam/typescript-sdk/blob/main/src/funcs/alphaDecisionsCreate.ts)

Scoring checks: `uv run --locked python -m unittest test_probe.py`.
