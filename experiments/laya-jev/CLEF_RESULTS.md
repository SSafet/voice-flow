# Measured decision-model comparison

Synthetic smoke test run from Safet's Mac. Hosted models use OpenRouter; any local Laya results use MPS/float32. See [README](README.md) for methods, caveats, and commands.

26 bilingual short cases / 46 decisions, plus two separate long-input stress cases. No examples or expected labels were changed after seeing model outputs.

| Model | Correct | English | Bulgarian | Median request | Wrong at ≥90% probability |
|---|---:|---:|---:|---:|---:|
| jev | 46/46 (100.0%) | 23/23 | 23/23 | 258 ms | 0 |
| clef | 45/46 (97.8%) | 22/23 | 23/23 | 539 ms | 0 |
| clef-flash | 45/46 (97.8%) | 22/23 | 23/23 | 212 ms | 0 |

## By use case

| Model | Triage | Continuity | Intent | Score MAE ↓ | Boolean Brier ↓ |
|---|---:|---:|---:|---:|---:|
| clef-flash | 30/30 | 8/8 | 7/8 | 0.091 | 0.025 |
| clef | 30/30 | 8/8 | 7/8 | 0.058 | 0.000 |
| jev | 30/30 | 8/8 | 8/8 | 0.120 | 0.002 |

## Speed and startup

Timing is one pass after one warm-up, with models run sequentially. Hosted timings include network and provider processing; local timings include input processing/diagnostics and possible first-shape MPS setup. No claim about tail latency or equal serving hardware. These short, correlated examples cannot establish general accuracy or a stable speed ranking.

| Model | Load (excludes warm-up) | Warm-up | One-question median | Three-question median |
|---|---:|---:|---:|---:|
| clef-flash | hosted | 308 ms | 193 ms | 284 ms |
| clef | hosted | 1538 ms | 576 ms | 539 ms |
| jev | hosted | 488 ms | 272 ms | 256 ms |

## Long-input stress

The same request is moved from the start to the end of a long log. These cases are excluded from the accuracy and speed tables above. Laya logs its configured truncation budget; hosted providers may also truncate input.

OpenRouter's [Clef](https://openrouter.ai/cloudflare/clef) and [Flash](https://openrouter.ai/cloudflare/clef-flash) descriptions warn that the current Workers AI route reads roughly the first 2K text-state tokens, despite the advertised 65,536-token model context. Both models passed our start/end cases (~2.7K billed input tokens per request); this run therefore does not reproduce or establish an exact truncation boundary.

- clef-flash, long-start: P(refund) = 0.9641.
- clef-flash, long-end: P(refund) = 0.9478.
- clef, long-start: P(refund) = 0.9934.
- clef, long-end: P(refund) = 0.9932.
- jev, long-start: P(refund) = 0.9800.
- jev, long-end: P(refund) = 0.9800.

## Every short-input mistake

### clef-flash

- `ambiguous-en/route`: expected `clarify`, got `assistant`; top-label probability 61.5%.

### clef

- `ambiguous-en/route`: expected `clarify`, got `assistant`; top-label probability 54.0%.

### jev

None in this run.

## Separate image-route probe

A Clef Flash probe sent a synthetic red PNG, a blue PNG, and a no-image control using a top-level `images` extension. All three responses returned identical probabilities for ‘no image available’ and identical input-token counts. The extension appears to have been ignored on this route. This does not test Clef's underlying vision quality; image input remains unverified in our OpenRouter integration. The current [SDK request schema](https://github.com/OpenRouterTeam/typescript-sdk/blob/main/src/models/decisionsrequest.ts) does not expose an images field.

[Raw probe responses](/Users/safet/repos/voice-flow/experiments/laya-jev/results/clef-comparison/image-route-probe.json). Excluded from the text accuracy and cost tables.

## Provenance

Input pack SHA-256: `440e104c866e1ad38fc53fc062f9dee3c312f66ae9ef8624630bcc7550780364`

- clef-flash: 20261005T212958818668Z; returned cloudflare/clef-flash; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/clef-comparison/20261005T212958818668Z-clef-flash.json).
  Reported run cost, including warm-up: $0.001140.
- clef: 20261005T212958818668Z; returned cloudflare/clef; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/clef-comparison/20261005T212958818668Z-clef.json).
  Reported run cost, including warm-up: $0.003039.
- jev: 20261005T212958818668Z; returned typesafe/jev-1.13-20260917; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/clef-comparison/20261005T212958818668Z-jev.json).
  Reported run cost, including warm-up: $0.000708.
