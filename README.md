<h1 align="center">UpinelAIOS-G</h1>

<p align="center"><b>Upinel's One-Click AI Agent Server OS for Mac — Gemma 4 edition</b><br>
A local, uncensored, OpenAI-compatible agent endpoint on your own Apple Silicon Mac.<br>
One command to install. One command to serve. Your data never leaves the LAN.</p>

---

A portable, one-command **Gemma 4 uncensored agent endpoint** for Apple Silicon
Macs, tuned for maximum tokens/sec.

Built and measured on an **M5 Pro / 20-core GPU / 64 GB**, serving
`HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP` through
llama.cpp with its companion draft model:

```
88 t/s short-context decode      (uncensored, MoE, ~4B active per token)
66 t/s at 8k context
128K context default
OpenAI-compatible API on your LAN, plus vision when you want it
```

Clone it, run `./install.sh`, run `./start.sh`. Nothing else.

---

## Why this is a separate project from UpinelAIOS

The Qwen edition runs on **MTPLX** (MLX). Gemma 4 cannot, and the reason is
structural rather than a preference.

Gemma 4 has no MTP head. MTPLX drives it through a **target/assistant pair** —
a `target/` verifier plus an `assistant/` drafter bound by `mtplx_pair.json` —
and the only such pair in existence is built from Google's **aligned** models.
Point a plain Gemma 4 MLX checkpoint at MTPLX and it refuses:

```
tier              no-MTP
support_level     gemma4-pair-bundle-required
can_run           False
runtime_compat    incomplete-assistant-pair
```

So uncensored Gemma 4 lives in **GGUF on llama.cpp**, where HauhauCS ships the
whole uncensored family *with* companion draft models. That is what this bundle
serves.

## Requirements

| | |
|---|---|
| **Minimum** | Apple Silicon Mac, **8 GB** unified memory, macOS 14+ |
| **Comfortable** | **16 GB** — any Mac, including an M1 MacBook Air |
| **Recommended** | **64 GB**, for 128K context on the 26B and room for a full desktop |

8 GB is genuinely enough, but only with the smallest model. The memory each
option actually needs, measured as resident set size:

| model | file | RAM used | fits |
|---|---:|---:|---|
| `e2b` | 3.4 GB | **4.2 GB** | 8 GB Mac |
| `e4b` | 5.3 GB | 6.8 GB | 16 GB Mac |
| `12b` | 7.4 GB | ~10 GB | 16 GB Mac |
| `26b-a4b` | 16.8 GB | 20.5 GB | 32 GB Mac |
| `31b-heretic` | 17.8 GB | ~22 GB | 32 GB Mac |

On an 8 GB Mac set `MODEL="e2b"`, `CONTEXT_WINDOW=8192` and
`MEMORY_LIMIT_GB=6`. macOS itself wants 3–4 GB, so leave it that room. On
16 GB, `e2b` and `12b` are both comfortable and `26b-a4b` is possible at a
reduced context.

Disk: 4–20 GB per model, depending which you pick.

## Measured throughput

**M5 Pro (20-core GPU, 64 GB)**, 256 tokens generated, no speculative decoding
for the small models because none of them ships a draft:

| model | 512 ctx | 8k ctx | RAM |
|---|---:|---:|---:|
| **`e2b`** | **107 t/s** | **102 t/s** | 4.2 GB |
| `26b-a4b` | 89 t/s | 66 t/s | 20.5 GB |
| `e4b` | 62 t/s | 58 t/s | 6.8 GB |

**`e2b` is the fastest model in the bundle** — quicker than the 26B MoE while
using a fifth of the memory, and it holds above 100 t/s out to 8k context.
`e4b` is the odd one out: bigger than `e2b` and slower than both it and the
26B MoE, so there is little reason to choose it.

### On an M1 MacBook Air

Not measured here — this was built on an M5 Pro — but the estimate is
straightforward, because decode is memory-bandwidth-bound and the M1 has
roughly a quarter of an M5 Pro's bandwidth:

| model | estimated decode on M1 |
|---|---:|
| `e2b` | ~25 t/s |
| `26b-a4b` | ~20–22 t/s |
| `e4b` | ~15 t/s |

Treat those as order-of-magnitude. Even the pessimistic end is a usable agent
endpoint, and `e2b` at 4.2 GB is the right pick for an 8 GB Air.

### How speed scales with context

**M5 Pro (20-core GPU, 64 GB), uncensored Gemma 4 26B-A4B**, shipped settings
(`MTP_DEPTH=3`, `THINKING=off`). Decode is the rate once generating; prefill is
the rate ingesting the prompt, and it is what time-to-first-token is made of.

| context | decode | prefill | TTFT, cold | TTFT, warm |
|---:|---:|---:|---:|---:|
| 2k | 59 t/s | 1,058 t/s | 2.3 s | **0.35 s** |
| 8k | 53 t/s | 860 t/s | 8.9 s | **0.41 s** |
| 32k | **25 t/s** | 461 t/s | **63 s** | **0.68 s** |

The model is a mixture of experts: 26B total but only about **4B active per
token**, which is why it is both fast and small.

The two right-hand columns are the ones that matter for an agent. A multi-turn
agent re-sends its whole growing history every turn; because the server reuses
that prefix from the KV cache, only the new tokens cost anything. Turn 2 of an
8k conversation returns in **0.41 s** where the cold first turn took **8.9 s** —
so the expensive event is the first turn of a session, not the twentieth.

> **Cold prefill is the real long-context cost, measured.** At 32k the first
> turn waits **63 seconds** before the first token. Prefill is architectural
> here, not tunable: at 32k it sits at ~420 t/s whether batches are 512 or
> 2048, because five of the thirty layers are full-attention and get
> quadratically more expensive with context (the other 25 use a 1024-token
> sliding window). Keep agent contexts under ~32k where the speed is, and let
> KV reuse carry the rest.

## Keep the prompt prefix stable

KV reuse is what makes multi-turn agents cheap, and it only works if the
prompt **only ever grows**. Measured at 8k of history:

| what the harness did | tokens reused | TTFT |
|---|---:|---:|
| appended a new turn | 10,079 | **0.16 s** |
| edited a message **early** in the history | 343 | **9.40 s** |
| edited a message **in the middle** | 343 | **9.76 s** |
| appended at the very end | 10,076 | 0.15 s |

A change anywhere except the very end discards the cache from that point on,
and in practice the whole prompt is re-prefilled: **61x the latency** for an
edit that may have changed one word. The tokens after the edit are
byte-identical, but llama.cpp cannot reuse them.

So harness behaviour matters as much as anything in `env.conf`:

- **Append, never rewrite.** Adding turns is nearly free; re-rendering old
  ones is not.
- **Truncating or eliding an old tool result is an edit** — it rewrites every
  token after it. Prefer dropping whole turns from the *front* (which keeps the
  recent suffix intact) over trimming the middle.
- **Compaction is the expensive one.** Rewriting history once costs a full
  re-prefill, so do it rarely and deliberately.

Run `python3 bench/cache-reuse-test.py` to see which of these your harness does.

> **`--cache-reuse` does not fix this — it makes it worse.** llama.cpp exposes
> it for reusing chunks past a divergence, so it looks like the obvious answer.
> Measured on the same 8k prompts: an early edit costs 9.40 s by default,
> **12.11 s at `--cache-reuse 64`** and **14.54 s at `--cache-reuse 256`** —
> and `cache_n` stays at 343 either way, so it buys no reuse at all, only KV
> shifting work. UpinelAIOS-G deliberately does not set it.

## Speculative depth — the one speed knob that matters

Gemma 4 ships a small companion drafter. It is a real win here, unlike the MTP
heads on the Qwen side. **Depth 3 is the default.**

Measured two ways. First greedy, on a counting task, best of two samples:

| depth | 2k ctx | 8k ctx | 16k ctx |
|---:|---:|---:|---:|
| 0 (off) | 62 t/s | 43 t/s | 36 t/s |
| 1 | 82 t/s | 58 t/s | 44 t/s |
| 2 | 89 t/s | 50 t/s | 42 t/s |
| **3** | **100 t/s** | **59 t/s** | **47 t/s** |
| 4 | 103 t/s | 55 t/s | 44 t/s |

That test is too kind to deep drafting — counting to 200 pins draft acceptance
at 100%. Repeating it against **realistic code generation**, interleaved A/B so
thermal drift hits both sides equally:

| ctx | depth 1 | depth 3 | acceptance 1 / 3 |
|---:|---:|---:|---:|
| 2k | 65 t/s | **82 t/s** (+27%) | 91% / 78% |
| 8k | 46 t/s | **48 t/s** (+5%) | 91% / 80% |
| 16k | 40 t/s | 39 t/s (~0%) | 91% / 78% |

**Depth 3 wins or ties everywhere.** Acceptance does fall with depth, which is
why this used to default to 1 — but acceptance is not the metric. Accepting two
extra tokens 78% of the time beats accepting one 91% of the time. The old claim
that depth 3 "collapses past ~8k" does not reproduce; at 8k it is 48 against 46.

`MTP_DEPTH="auto"` uses a per-model tuned value written by
`./bench/bench.sh --tune`, falling back to 3. `MTP_DEPTH=0` disables speculation.

ngram-based speculation was also measured and **rejected** — it was slower than
plain autoregressive (65 t/s against 70) on this workload.

## Thinking has a real token budget

**Correction to earlier versions of this file:** it claimed llama.cpp cannot cap
thinking, and that `minimal`/`low`/`high` were decorative labels all meaning
"on". That was wrong. llama.cpp has `--reasoning-budget N`, a hard cap on the
thought channel, plus `--reasoning-budget-message` injected as the cap is
reached. The levels below are real budgets.

Eight agent tasks, greedy sampling, median completion tokens per turn and
tool-call correctness:

| `THINKING` | budget | tokens/turn | correct |
|---|---:|---:|---:|
| `off` | — | 133 | 8/8 |
| **`minimal`** (default) | **32** | **72** | **8/8** |
| `low` | 128 | 170 | 7/8 |
| `medium` | 512 | 288 | 8/8 |
| `high` | unlimited | 288 | 8/8 |

`minimal` is the cheapest of all — **cheaper than turning thinking off**. With
no thought channel the model simply reasons inside its answer, which costs more;
given a small budget it plans briefly and then acts. It also keeps every task
correct.

**The budget message is not optional.** Every budgeted value tested *without* it
scored 7/8: the thought channel gets cut mid-sentence and the model never gets
round to emitting a tool call at all. With the message, every budget scored 8/8.
If you set a budget, keep a message.

> Budgets are sensitive to where the cut lands — 96 scored 7/8 while both 32 and
> 128 scored 8/8 — so these are measured points, not a formula. Re-run
> `bench/thinking-budget-test.py` after changing models or prompts.

## Measuring this yourself

Two tools, because the honest number for an agent is not the number a
throughput benchmark gives you.

```bash
python3 bench/agent-bench.py --depths 2048,8192,32768   # what an agent feels
python3 bench/sweep.py --ask code --temp 0.7            # compare launch flags
python3 bench/cache-reuse-test.py --depth 8192          # does your harness reuse?
python3 bench/thinking-budget-test.py                   # tune the thinking budget
python3 bench/verify-quant-select.py                    # offline, no server needed
```

`agent-bench.py` measures time-to-first-token, prefill and decode at real
context lengths, and reports **KV reuse** — a multi-turn agent re-sends a
growing prefix every turn, and if the server reuses it those turns cost almost
nothing. On the reference machine, turn 2 of an 8k conversation returns in
**0.41 s against the 8.87 s** the cold first turn takes.

Three traps to avoid, all of which produced wrong answers here before being
fixed:

- **Repeating an identical prompt measures the cache.** llama.cpp reuses the
  slot's KV for a shared prefix, so the second send reports `prompt_n=1` and a
  "prefill rate" for a single token. Vary the first words of the prompt.
- **Greedy sampling pins draft acceptance at 100%.** Real acceptance is ~78-91%.
  Fine for comparing launch flags, wrong for quoting a speedup.
- **A laptop throttles.** Ten configs back to back make the last ones look
  broken. Alternate the configs and re-measure the baseline at the end.

### Tested and rejected

Measured, not assumed — each of these is a plausible optimisation that does not
work here:

| change | result |
|---|---|
| `-ub 1024/2048`, `-b 4096/8192` | **no effect on long-context prefill** (397-420 t/s at 32k, all within noise) |
| `-ctk q4_0 -ctv q4_0` | **slower prefill** — 721 t/s at 8k against 867 for q8_0 |
| `--cache-reuse 64` / `256` | **slower** — 12.11 s / 14.54 s against 9.40 s, with no extra reuse |
| deeper MTP (depth 4) | no better than 3, more memory |
| ngram speculation | slower than plain autoregressive |

The batch-size result is the useful one: at 32k, prefill sits at ~420 t/s no
matter how the batches are arranged, so that cost is architectural — five of
thirty layers are full-attention and get quadratically more expensive — and not
something a flag will fix.

## Vision costs 24%

Gemma 4 is multimodal, and the vision tower is **off by default**. It is not
free even for text-only requests:

| | decode (512 ctx) | first token |
|---|---:|---:|
| `ENABLE_VISION=1` | 67.8 t/s | 0.40 s |
| `ENABLE_VISION=0` | **88.7 t/s** | **0.05 s** |

Three repeats each, same model. Set `ENABLE_VISION=1` when you actually need
images; text quality is identical either way.

## Agents that write files

If your agent reports **`invalid arguments: missing required property "x"`**,
there are two distinct causes and the fix differs. Run the diagnostic, which
identifies which one you have:

```bash
./bench/verify-tools.sh
```

A file write carries the **whole file inside the tool call's arguments**. On the
reference machine a 1,467-character Python file cost **538 tokens** of arguments.
If the client's `max_tokens` is smaller, the JSON is cut off mid-string, the
agent sees an incomplete object, and reports the first required property it
cannot find.

| what the agent writes | budget to allow |
|---|---:|
| a one-line file | 512 |
| a short script | 2048 |
| a full module | 4096 |

`MAX_RESPONSE_TOKENS` is the server's ceiling, not a floor — it cannot rescue a
call the client already truncated.

**The second cause is different.** If the missing field is a *label* — a
`description` next to a `command`, say — the call is valid JSON with a field the
model chose to skip. It is not truncated and more `max_tokens` will not help.
Measured here, six runs each:

| agent system prompt | label present |
|---|---:|
| *"You are a coding agent."* | 1/6 |
| *"…MUST include every required field."* | 5/6 |
| *"…always supply both `command` and `description`."* | **6/6** |

**Name the required fields in the agent's system prompt**, or mark the label
optional in the schema. How to tell them apart:

| arguments | `finish_reason` | cause | fix |
|---|---|---|---|
| unparseable, ends mid-string | `length` | truncated | raise `max_tokens` |
| valid JSON, field absent | `tool_calls` | model omitted it | name it in the prompt |

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Thinking

```conf
THINKING="off" | "minimal" | "low" | "medium" | "high"
THINKING_BUDGET_TOKENS=0        # 0 = use the level's tuned budget
THINKING_BUDGET_MESSAGE="..."   # injected as the budget runs out
```

Each level is a real token cap on the thought channel, applied with llama.cpp's
`--reasoning-budget`. `minimal` (32 tokens) is the default and measured cheaper
than `off`, while keeping every task correct — see
[Thinking has a real token budget](#thinking-has-a-real-token-budget).

**Keep `THINKING_BUDGET_MESSAGE` set.** Removing it costs accuracy: every
budgeted level scored 7/8 without it against 8/8 with it, because a thought cut
off mid-sentence leaves the model without a tool call.

Set `THINKING_BUDGET_TOKENS` to override a level without editing the mapping —
useful for a one-off hard task:

```bash
THINKING=high THINKING_BUDGET_TOKENS=1024 ./restart.sh
```

## Quick start

```bash
git clone https://github.com/upinel/UpinelAIOS-G && cd UpinelAIOS-G

./install.sh          # scans your Mac, suggests settings, installs everything
./start.sh            # serves http://<your-lan-ip>:8000/v1
./status.sh           # live dashboard
./restart.sh          # apply an env.conf change
./stop.sh
```

Point any OpenAI-compatible client at the URL `./status.sh` prints.

## Models — uncensored only

**Every model UpinelAIOS-G ships or suggests is an uncensored Gemma 4
fine-tune.** There is no point being fast at something that will not answer.

| alias | download | repo |
|---|---:|---|
| `26b-a4b` | 18 GB | `HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP` — **default**, MoE, fastest |
| `12b` | 8 GB | `HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced` |
| `31b-heretic` | 20 GB | `llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF` — highest quality |
| `e2b` | 4 GB | `HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive` — **fastest**, fits 8 GB |
| `e4b` | 7 GB | `HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive` — middle, and loses on both counts |

**Only one quant is downloaded.** GGUF repos often publish every quant of the
same model, and the `31b-heretic` repo carries ten of them — 232 GB in total,
of which the 18.7 GB `Q4_K_M` is the one that fits a Mac. Fetching the repo
wholesale would cost twelve times the disk and hours of download, so
UpinelAIOS-G picks a single quant (`MODEL_QUANT` in `env.conf`, default
`Q4_K_M`) and skips the rest. The sizes above are what actually lands on disk:
that quant, plus the vision projector and the MTP draft head, which are
separate artifacts rather than quants and are always fetched.

```bash
./bench/verify-tools.sh            # check tool calling, measure a file write
./model_download.sh                # what is available, what you have
./model_download.sh 12b            # download one
./model_download.sh --switch 12b   # download if needed, switch, restart
./start.sh --model 12b             # serve a different model for one run
```

## Watching it work

`./status.sh` is a live dashboard. Press **`t`** to cycle the thinking level and
**`m`** to cycle downloaded models — each arms a 2-second countdown before it
applies, so repeated presses move through the options without committing to the
one you just passed. `Enter` applies now, `Esc` cancels.

## Credits and licences

- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** — MIT. The runtime.
- **[Gemma 4](https://ai.google.dev/gemma)** — Google's model, Apache-2.0.
- **HauhauCS** — the uncensored Gemma 4 fine-tunes and their draft models.

Model weights carry their own upstream licences. Uncensored fine-tunes are
uncensored: you are responsible for how you use the endpoint, and for the fact
that you just exposed it to your LAN.
