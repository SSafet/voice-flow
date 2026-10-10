# Measured Laya / Jev results

Synthetic smoke test on Safet's Apple M4 Pro, 48 GiB RAM. Local Laya uses MPS/float32; Jev uses OpenRouter. See [README](README.md) for methods, caveats, and commands.

26 bilingual short cases / 46 decisions, plus two separate long-input stress cases. No examples or expected labels were changed after seeing model outputs.

| Model | Correct | English | Bulgarian | Median request | Wrong at ≥90% probability |
|---|---:|---:|---:|---:|---:|
| jev | 45/46 (97.8%) | 23/23 | 22/23 | 367 ms | 0 |
| laya-multi | 23/46 (50.0%) | 11/23 | 12/23 | 20 ms | 12 |
| laya-typed | 31/46 (67.4%) | 19/23 | 12/23 | 32 ms | 0 |
| laya-en | 30/46 (65.2%) | 15/23 | 15/23 | 40 ms | 1 |

## By use case

| Model | Triage | Continuity | Intent | Score MAE ↓ | Boolean Brier ↓ |
|---|---:|---:|---:|---:|---:|
| jev | 29/30 | 8/8 | 8/8 | 0.118 | 0.002 |
| laya-en | 19/30 | 7/8 | 4/8 | 0.416 | 0.274 |
| laya-multi | 14/30 | 3/8 | 6/8 | 0.940 | 0.562 |
| laya-typed | 20/30 | 7/8 | 4/8 | 0.654 | 0.170 |

## Speed and startup

Timing is one pass over varied shapes after one warm-up; MPS may incur additional first-shape setup. Latency includes input processing/diagnostics; Jev additionally includes network time. No claim about tail latency or equal serving hardware.

| Model | Load (excludes warm-up) | Warm-up | One-question median | Three-question median |
|---|---:|---:|---:|---:|
| jev | hosted | 594 ms | 439 ms | 335 ms |
| laya-en | 21.3 s | 623 ms | 31 ms | 73 ms |
| laya-multi | 19.6 s | 182 ms | 17 ms | 31 ms |
| laya-typed | 17.8 s | 61 ms | 29 ms | 62 ms |

## Long-input stress

The same request is moved from the start to the end of a long log. Laya truncates the state to its configured input budget. These cases are excluded from the accuracy and speed tables above.

- jev, long-start: P(refund) = 0.9800.
- jev, long-end: P(refund) = 0.9800.
- laya-en, long-start: P(refund) = 0.8970; 2760 state tokens / 467 available.
- laya-en, long-end: P(refund) = 0.0367; 2760 state tokens / 467 available.
- laya-multi, long-start: P(refund) = 0.4113; 2510 state tokens / 979 available.
- laya-multi, long-end: P(refund) = 0.0305; 2510 state tokens / 979 available.
- laya-typed, long-start: P(refund) = 0.7086; 2760 state tokens / 979 available.
- laya-typed, long-end: P(refund) = 0.0667; 2760 state tokens / 979 available.

## Every short-input mistake

### jev

- `injection-bg/urgency`: expected `0`, got `0.54`; top-label probability 54.0%.

### laya-en

- `duplicate-en/urgency`: expected `1`, got `0.3023`; top-label probability 76.9%.
- `duplicate-bg/refund`: expected `True`, got `False`; top-label probability 88.5%.
- `duplicate-bg/urgency`: expected `1`, got `0.2598`; top-label probability 80.3%.
- `outage-en/refund`: expected `False`, got `True`; top-label probability 82.5%.
- `outage-bg/refund`: expected `False`, got `True`; top-label probability 91.3%.
- `pricing-en/department`: expected `sales`, got `other`; top-label probability 40.6%.
- `pricing-bg/department`: expected `sales`, got `other`; top-label probability 34.9%.
- `negation-en/refund`: expected `False`, got `True`; top-label probability 50.2%.
- `negation-bg/department`: expected `billing`, got `other`; top-label probability 37.0%.
- `injection-en/urgency`: expected `0`, got `0.7499`; top-label probability 49.5%.
- `injection-bg/department`: expected `billing`, got `sales`; top-label probability 38.2%.
- `followup-en/route`: expected `continue`, got `new`; top-label probability 68.4%.
- `explain-en/route`: expected `assistant`, got `clarify`; top-label probability 76.1%.
- `explain-bg/route`: expected `assistant`, got `clarify`; top-label probability 68.9%.
- `ambiguous-en/route`: expected `clarify`, got `assistant`; top-label probability 48.3%.
- `ambiguous-bg/route`: expected `clarify`, got `assistant`; top-label probability 38.9%.

### laya-multi

- `outage-en/refund`: expected `False`, got `True`; top-label probability 96.2%.
- `outage-bg/refund`: expected `False`, got `True`; top-label probability 99.6%.
- `outage-bg/urgency`: expected `2`, got `1.3823`; top-label probability 55.2%.
- `pricing-en/department`: expected `sales`, got `billing`; top-label probability 92.8%.
- `pricing-en/refund`: expected `False`, got `True`; top-label probability 51.3%.
- `pricing-en/urgency`: expected `0`, got `1.3845`; top-label probability 46.3%.
- `pricing-bg/department`: expected `sales`, got `billing`; top-label probability 95.5%.
- `pricing-bg/urgency`: expected `0`, got `1.3179`; top-label probability 55.7%.
- `negation-en/refund`: expected `False`, got `True`; top-label probability 95.2%.
- `negation-en/urgency`: expected `0`, got `1.2301`; top-label probability 63.8%.
- `negation-bg/refund`: expected `False`, got `True`; top-label probability 94.0%.
- `negation-bg/urgency`: expected `0`, got `1.2034`; top-label probability 73.0%.
- `injection-en/refund`: expected `False`, got `True`; top-label probability 99.1%.
- `injection-en/urgency`: expected `0`, got `1.3455`; top-label probability 57.1%.
- `injection-bg/refund`: expected `False`, got `True`; top-label probability 81.5%.
- `injection-bg/urgency`: expected `0`, got `1.3895`; top-label probability 55.0%.
- `followup-en/route`: expected `continue`, got `new`; top-label probability 95.5%.
- `followup-bg/route`: expected `continue`, got `new`; top-label probability 99.5%.
- `topic-switch-en/route`: expected `new`, got `continue`; top-label probability 71.0%.
- `correction-en/route`: expected `continue`, got `new`; top-label probability 88.5%.
- `correction-bg/route`: expected `continue`, got `new`; top-label probability 94.6%.
- `ambiguous-en/route`: expected `clarify`, got `assistant`; top-label probability 97.1%.
- `ambiguous-bg/route`: expected `clarify`, got `assistant`; top-label probability 92.3%.

### laya-typed

- `duplicate-bg/refund`: expected `True`, got `False`; top-label probability 83.9%.
- `outage-bg/refund`: expected `False`, got `True`; top-label probability 54.7%.
- `pricing-en/department`: expected `sales`, got `other`; top-label probability 54.3%.
- `pricing-bg/department`: expected `sales`, got `other`; top-label probability 34.1%.
- `pricing-bg/urgency`: expected `0`, got `1.102`; top-label probability 55.1%.
- `negation-bg/department`: expected `billing`, got `other`; top-label probability 35.6%.
- `negation-bg/urgency`: expected `0`, got `1.2145`; top-label probability 45.3%.
- `injection-en/urgency`: expected `0`, got `1.0193`; top-label probability 54.0%.
- `injection-bg/department`: expected `billing`, got `sales`; top-label probability 37.5%.
- `injection-bg/urgency`: expected `0`, got `1.245`; top-label probability 52.0%.
- `topic-switch-bg/route`: expected `new`, got `continue`; top-label probability 61.2%.
- `explain-en/route`: expected `assistant`, got `clarify`; top-label probability 47.7%.
- `explain-bg/route`: expected `assistant`, got `clarify`; top-label probability 45.4%.
- `ambiguous-en/route`: expected `clarify`, got `assistant`; top-label probability 40.5%.
- `ambiguous-bg/route`: expected `clarify`, got `assistant`; top-label probability 37.9%.

## Provenance

Input pack SHA-256: `440e104c866e1ad38fc53fc062f9dee3c312f66ae9ef8624630bcc7550780364`

- jev: 20260920T164257164075Z; returned typesafe/jev-1.13-20260917; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/20260920T164257164075Z-jev.json).
  Reported run cost, including warm-up: $0.000708.
- laya-en: 20260920T164508440082Z; returned laya-rl-agent; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/20260920T164508440082Z-laya-en.json).
  421,293,827 parameters; convaiinnovations/laya @ `1c5edc17a7acd8701df6fc341c0d179f1c62c982`, subfolder `(root)`; max_len=512, head_max_len=192.
- laya-multi: 20260920T164508440082Z; returned laya-rl-agent; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/20260920T164508440082Z-laya-multi.json).
  321,908,995 parameters; convaiinnovations/laya @ `1c5edc17a7acd8701df6fc341c0d179f1c62c982`, subfolder `multilingual`; max_len=1024, head_max_len=256.
- laya-typed: 20260920T164508440082Z; returned laya-rl-agent; raw [JSON](/Users/safet/repos/voice-flow/experiments/laya-jev/results/20260920T164508440082Z-laya-typed.json).
  421,293,827 parameters; convaiinnovations/laya @ `1c5edc17a7acd8701df6fc341c0d179f1c62c982`, subfolder `typed-decisions`; max_len=1024, head_max_len=256.
