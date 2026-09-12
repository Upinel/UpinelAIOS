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

## Measured throughput

**M5 Pro (20-core GPU, 64 GB), uncensored Gemma 4 26B-A4B, speculative depth 1:**

| context | decode | prefill |
|---:|---:|---:|
| 512 | **88 t/s** | 7,500–10,000 t/s |
| 8,192 | **66 t/s** | ~1,200 t/s |
| 32,768 | ~39–50 t/s | ~690 t/s |
| 131,072 | possible | **~136 t/s** — see the warning below |

The model is a mixture of experts: 26B total but only about **4B active per
token**, which is why it is both fast and small. Nothing else here changes the
order of magnitude.

> **Long-context warning, measured.** Prefill degrades sharply with context —
> from ~1,200 t/s at 8k to **~136 t/s at 131k**, i.e. about 16 minutes to ingest
> one full-context prompt. The default is 128K because it is a *capability*, not
> because every request will use it. Keep agent contexts under ~32k where the
> speed is, and let prompt caching do the rest.

## Speculative depth — the one speed knob that matters

Gemma 4 ships a small companion drafter. It is a real win here, unlike the MTP
heads on the Qwen side. Measured on the reference machine:

| depth | 512 ctx | 8k ctx |
|---:|---:|---:|
| 0 (off) | 70 t/s | 65 t/s |
| **1** | **83 t/s** | **76 t/s** |
| 2 | 84 t/s | 75 t/s |
| 3 | 93 t/s | 66 t/s |
| 4 | 75 t/s | 66 t/s |

Depth 3 peaks on short prompts and **collapses past ~8k**. Since agents live at
long context, **depth 1 is the default**. `MTP_DEPTH="auto"` uses a per-model
tuned value written by `./bench/bench.sh --tune`.

ngram-based speculation was also measured and **rejected** — it was slower than
plain autoregressive (65 t/s against 70) on this workload.

## Vision costs 24%

Gemma 4 is multimodal, and the vision tower is **off by default**. It is not
free even for text-only requests:

| | decode (512 ctx) | first token |
|---|---:|---:|
| `ENABLE_VISION=1` | 67.8 t/s | 0.40 s |
| `ENABLE_VISION=0` | **88.7 t/s** | **0.05 s** |

Three repeats each, same model. Set `ENABLE_VISION=1` when you actually need
images; text quality is identical either way.

## Thinking

```conf
THINKING="off" | "minimal" | "low" | "high"
```

Measured on "reply with exactly: endpoint ok":

| setting | completion tokens | of which reasoning |
|---|---:|---:|
| `off` | **3** | 0 |
| `minimal` | 98 | ~70 |

**llama.cpp cannot cap thinking.** Unlike MTPLX there is no token budget here —
the setting only turns the thinking block on or off through the chat template.
So `minimal`, `low` and `high` all behave as "on", and **`off` is the only
setting that actually reduces thinking**. Use it for agent and tool work; it is
the cheapest large win available.

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

| alias | size | repo |
|---|---:|---|
| `26b-a4b` | 17 GB | `HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP` — **default**, MoE, fastest |
| `12b` | 8 GB | `HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced` |
| `31b-heretic` | 18 GB | `llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF` — highest quality |
| `e2b` | 4 GB | `HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive` — **fastest**, fits 8 GB |
| `e4b` | 6 GB | `HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive` — middle, and loses on both counts |

```bash
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
