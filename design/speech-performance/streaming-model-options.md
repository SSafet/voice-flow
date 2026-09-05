# Streaming dictation and model comparison

Researched and probed on 2026-09-05. This is an evaluation, not a production model switch. The installed app still uses the previously verified API file path, with the pre-paste transcript popup removed.

The expanded provider pass below adds xAI, Soniox, Groq, Mistral and Speechmatics. It changes the next-test shortlist: Soniox and xAI merit streaming trials before committing to OpenAI Live or ElevenLabs. Only OpenAI has been measured here.

The current `OPENAI_STT_MODEL` is `gpt-4o-mini-transcribe` (`voice_flow/config.py`). `BackendBridge.transcribe` sends the complete PCM recording after hotkey release. `OpenAITranscriber` converts that recording to WAV and uploads it to `/v1/audio/transcriptions`. SSE streams the **response text**, not microphone input. A longer recording therefore puts more upload and recognition work after release. Only the final completion can deliver text.

## What the live probes actually establish

The same synthetic English recording was submitted to real APIs. Its duration is 16.7 seconds; the 100.2-second stress fixture repeats it six times. File models each had two trials per duration, in reversed model order. Live audio was sent in 100 ms chunks at recording speed, followed by an explicit commit. OpenAI credentials stayed in memory; no production setting was edited.

| API path | 16.7 s audio: final wait | 100.2 s audio: final wait | Transcript observations |
|---|---:|---:|---|
| Current `gpt-4o-mini-transcribe`, whole file | 696 ms | 2,878 ms | Preserved all words and repetitions in these trials |
| New `gpt-transcribe`, whole file | 876 ms | 3,963 ms | Added a seventh repetition in both long trials; less sentence punctuation on the short fixture |
| `gpt-4o-transcribe`, whole file | 823 ms | 2,361 ms | Returned only one of six repetitions in both long trials |
| `gpt-live-transcribe`, live input, medium delay | 718 ms among 2 successes; 1 timeout | 626 ms, 1 trial | Successful transcripts preserved the fixture; one short trial did not complete within 30 seconds |

File timings are upload-start through final response. Live timings are last audio sent/commit through final response. They exclude the Swift recorder drain, bridge, and paste operation. The live probe connects before audio pacing starts; connection/session setup took 0.74–1.85 seconds on successful runs. A real implementation must record immediately and buffer while connecting. That integration has not been measured here.

The long live trial cut the API tail by 2.25 seconds, or 78%, relative to the current file median. This demonstrates potential, **not a production latency or reliability guarantee**. Short successful live runs were approximately tied with the current file path. A diagnostic repeat completed normally; it did not explain the earlier timeout. The failed trial remains in the evidence, and successful-only medians must never hide it.

This small, deliberately repetitive English fixture is not a language-quality benchmark. Normalized WER ignores punctuation, casing, Voice Flow spacing, and spoken versus written forms of the fixture's four-digit number. Scores are 0% for the successful live/current-mini samples, 16.7% for new `gpt-transcribe` long samples, and 83.3% for `gpt-4o-transcribe` long samples. Those errors reflect repeated material added/omitted, not broad estimates of model quality. Real English, Bulgarian, code switching, names, corrections, silence, and noisy microphone recordings remain untested in this comparison.

Reproduction:

```sh
PYTHONPATH=. uv run --no-project --with numpy --with websockets python tests/speech_performance/model_comparison.py
```

The script resumes existing trials; archive the output JSON to run a fresh set. The WAV fixture is retained, with its PCM SHA-256 in the output. The additional short diagnostic is marked `diagnostic_followup` in the JSON. Evidence: [all responses, timings and live event traces](evidence/model-comparison.json), [compact metrics](evidence/model-comparison-summary.json), [probe source](../../tests/speech_performance/model_comparison.py).

## Current prices and viable candidates

USD base API prices per hour, before tax, optional features, retry/fallback duplication, and discounts. OpenAI publishes estimated per-minute costs; these are multiplied by 60. Provider billing units/minimums differ, so this is not a final invoice forecast.

| Candidate | USD/hour | Assessment for Voice Flow |
|---|---:|---|
| Current OpenAI `gpt-4o-mini-transcribe` | $0.18 | Cheapest existing path; retain during evaluation |
| OpenAI `gpt-transcribe` | $0.27 | New file/committed-turn model; not a demonstrated speed/quality upgrade in this probe |
| OpenAI `gpt-4o-transcribe` | $0.36 | Older larger model; repeated-content omissions rule out an automatic switch |
| OpenAI `gpt-live-transcribe` | $1.02 | True live inference; existing credentials worked; measured long-tail benefit, unresolved timeout |
| ElevenLabs Scribe v2 Realtime | $0.39 | Multilingual streaming candidate; not measured here |
| Deepgram Nova-3 streaming | $0.288 mono / $0.348 multilingual | Current promotional PAYG rate; language-mode constraint below |
| AssemblyAI Universal-3.5 Pro Realtime | $0.45 | Current 18-language model; Bulgarian absent from the published set |

Sources: [OpenAI pricing](https://developers.openai.com/api/docs/pricing), [ElevenLabs pricing](https://elevenlabs.io/pricing/api), [Deepgram pricing](https://deepgram.com/pricing), [AssemblyAI pricing](https://www.assemblyai.com/pricing).

For ten hours of audio, the current path is approximately $1.80, new OpenAI file transcription $2.70, Scribe live $3.90, and OpenAI live $10.20. Scribe file transcription is also available at $0.22/hour. Optional ElevenLabs keyterm prompting is listed separately at $0.05/hour. Deepgram's regular streaming rates, after the current promotion, are $0.462/hour mono and $0.552/hour multilingual. Always check the selected account's billing terms before comparing actual spend.

OpenAI lists the current mini alias and `gpt-4o-transcribe` for removal on **February 26, 2027**. A longer-term replacement is needed even if mini wins today's small test. Both new models were accessible with this account during the probes. [Official deprecations](https://developers.openai.com/api/docs/deprecations).

Scribe supports 90+ languages and manual finalization. Its advertised ~150 ms latency describes streaming responsiveness, not a measured hotkey-release-to-paste time in Voice Flow. Its documentation also describes initial audio buffering and automatic commits around 36 seconds, so long sessions require ordered segment assembly. [Models](https://elevenlabs.io/docs/overview/models), [commit strategies](https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies).

Deepgram Nova-3 supports Bulgarian in a fixed-language mode; its published multilingual/code-switching set excludes Bulgarian. AssemblyAI's current 18-language realtime set also excludes Bulgarian. They remain candidates for supported-language use, but are less direct defaults if Bulgarian/English switching matters. [Deepgram language matrix](https://developers.deepgram.com/docs/models-languages-overview), [AssemblyAI model announcement](https://www.assemblyai.com/blog/universal-3-5-pro-realtime).

## Expanded provider pass: xAI, Soniox, Groq, Mistral, Speechmatics

These are official documentation and price checks, not measured latency or accuracy results. No credentials were requested, accounts created, or audio sent to these providers during this pass.

| Provider/API | File USD/hour | Live USD/hour | Integration and language considerations |
|---|---:|---:|---|
| xAI Speech to Text (Grok provider) | $0.10 | $0.20 | Dedicated REST and WebSocket STT; push-to-talk finalization, 16 kHz PCM, keyterm hints. Bulgarian is absent from its published language/formatting table, so support is unverified. |
| Soniox v5 | ~$0.10 | ~$0.12 | Native live STT, manual finalization; Bulgarian and English explicitly supported. Prices are token-based estimates. |
| Groq Whisper Large v3 Turbo | $0.04 | No native streaming STT documented in the reviewed API | Hosted file inference; 10-second minimum billed per request. Segmenting into tiny requests can erase some savings. |
| Groq Whisper Large v3 | $0.111 | Same file API constraint | Alternate accuracy/cost tradeoff to Turbo; compare both on identical fixtures. |
| Mistral Voxtral Transcribe 2 / Realtime | $0.18 | $0.36 | Hosted API meets API-only requirement; 13 published languages exclude Bulgarian. |
| Speechmatics | $0.24 Standard / $0.40 Enhanced | $0.24 Standard / $0.43 Enhanced | Bulgarian supported; Standard does not improve realtime turnaround versus Enhanced. Separate Melia batch model starts at $0.129/hour. |

Price/capability sources: [xAI model and pricing](https://docs.x.ai/developers/models/speech-to-text), [Soniox pricing](https://soniox.com/pricing), [Groq STT](https://console.groq.com/docs/speech-to-text), [Mistral API pricing](https://mistral.ai/pricing/api/), [Speechmatics pricing](https://www.speechmatics.com/pricing). Base prices exclude optional features/tax. Speechmatics also offers opt-in model-training and volume discounts; the table uses the displayed standard rates.

xAI is a particularly relevant counterexample to the idea that live STT must cost 5× more: $0.20/hour is only 11% above the current mini path, and one fifth of OpenAI Live's price. Its dedicated STT endpoint is distinct from its conversational voice API. The guide documents `audio.done` → `transcript.done` and an explicit push-to-talk finalize command. Its examples disagree on finalize message casing, so integration should verify the API reference/actual behavior rather than copy one example blindly. [xAI guide](https://docs.x.ai/developers/model-capabilities/audio/speech-to-text).

Soniox's ~33% lower estimated live cost than current mini, explicit Bulgarian support, and manual finalization make it the first multilingual streaming candidate to benchmark. Its price depends on audio/session duration and text/context tokens; keep connections scoped to capture and report real usage. [Languages](https://soniox.com/docs/stt/concepts/supported-languages), [WebSocket reference](https://soniox.com/docs/api-reference/stt/websocket-api), [current v5 models](https://soniox.com/docs/stt/models). This is a test-priority decision, not a claim that Soniox is more accurate or faster on Safet's dictation.

Grok/xAI and Groq are different providers. Groq's $0.04/hour Turbo is worth testing as a low-cost whole-file baseline or recovery path. Its advertised inference speed factor is not a measurement of network upload plus final response plus paste in Voice Flow. Mistral is a useful supported-language streaming comparator, but its documented language set does not establish Bulgarian coverage. [Mistral languages](https://mistral.ai/news/voxtral-transcribe-2/).

Revised next-test order: Soniox live for multilingual dictation, xAI streaming for supported-language dictation, and Groq Turbo/full Whisper for the file baseline. Keep ElevenLabs and OpenAI Live as comparators. Apply the same representative corpus, failure injection and release-to-paste measurements below; do not switch the installed app based on provider benchmark claims.

## Architecture decision

The objective is a complete, correct paste shortly after release, including long dictations. A visible interim transcript is not required. The user specifically rejected the brief preview above the pill.

| Approach | What it changes | Decision |
|---|---|---|
| Change only the file model | Same upload-after-release path | Insufficient: current measurements show no acceptable win |
| Compress or transport the completed file more efficiently | Reduces upload cost, leaves recognition after release | Useful secondary optimization; cannot move all work into recording time |
| Upload continuously but recognize only after one final commit | Hides upload time | Partial solution; recognition still scales with the whole turn |
| Send bounded segments at natural pauses while recording | Hides most recognition, can use a committed-turn model | Viable lower-cost alternative; must measure word-boundary errors, context loss, ordering and unfinished final segments |
| True live inference, commit on release, full-audio fallback | Upload and recognition overlap speech | Recommended architecture to validate; the long live probe supports its latency potential |
| Repeatedly resend the growing whole recording | Work grows with recording length | Reject: redundant API work, cost, corrections, and race conditions |

`gpt-transcribe` recognizes a Realtime turn only after commit; `gpt-live-transcribe` recognizes arriving audio continuously. A WebSocket alone therefore does not prove that the expensive work moved before release. [OpenAI realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription), [GPT-Transcribe](https://developers.openai.com/api/docs/models/gpt-transcribe).

Recommended implementation boundary: capture starts immediately; freeze provider/model and destination with the capture UUID; save every sample independently of the network; queue and drain audio while the socket connects; stream without blocking the recorder; finalize on hotkey release. Collect authoritative final segments by item ID and order, never arrival order. Paste once after all segments complete. On disconnect, missing completion, or provider error, use the saved recording through the file path with a bounded deadline. Discard late streaming finals once fallback wins. Cancellation invalidates both paths. No interim popup or incremental paste is needed.

Existing 16 kHz recorder audio needs conversion for OpenAI's 24 kHz PCM stream; ElevenLabs accepts 16 kHz PCM. Connection setup, buffering, conversion, finalization and fallback all need explicit timing spans. This evaluation adds no production provider dependency and does not change the installed binary.

The architecture choice is supported; a provider winner is not yet established. OpenAI live is the directly tested candidate. The expanded provider pass prioritizes Soniox and xAI streaming plus Groq file inference for the next comparison; Scribe remains a comparator. Keep mini as the temporary recovery path while testing a supported replacement ahead of its retirement.

## Evidence required before default rollout

Use the same human-recorded 5–15 s, 30–60 s, and 2–5 min corpus for each candidate, including English/Bulgarian, mixed speech, names, numbers and self-corrections. Record at least 30 paired trials per duration band across multiple sessions. Report all failures, p50/p95 release-to-paste, connection/setup time, fallback rate, billed usage, normalized WER and manual formatting/correction effort. Agree an acceptable quality margin before selecting the default.

Proposed latency acceptance: long-recording p95 below one second and at least a 50% reduction versus the current path, with short-recording latency no worse. This is a target, not an achieved result. Deterministic integration tests must prove no lost/duplicate paste under disconnect, delayed/missing final, out-of-order segment completion, immediate release before connection, cancellation, and overlapping captures. No default promotion until representative accuracy and failure behavior pass as well as latency.
