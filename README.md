<!--
  Nova Upinel Chow, MSc, LLM, BBA, MENSA  ·  dev@upinel.com  ·  upinel.com
  Copyright (c) 2026 Nova Upinel Chow. All rights reserved.

  Upinel Personal Free License: free for personal use, and free for creators
  (YouTubers, KOLs) to make content with - just email dev@upinel.com to say so.
  Other commercial use needs written permission. Derivatives must credit the
  author. Covers this project's own code only. See LICENSE.

  "Make it work, make it right, make it fast - then measure it, because
   the third one is only a claim until the numbers agree."
-->
<h1 align="center">UpinelAIOS</h1>

<p align="center">
  <b>Up to 106 t/s decode — uncensored, 100% local, on your own Mac.</b><br>
  One-click AI agent server OS for Apple Silicon · <b>two engines</b>: GGUF (llama.cpp) and MLX (MTPLX)<br>
  <sub>Extreme performance optimisation for AI agent workflows.</sub><br>
  <sub>One command to install. One command to serve. Your data never leaves the LAN.</sub>
</p>

<p align="center">
  <sub>Built by <b>Nova Upinel Chow</b>, MSc, LLM, BBA, MENSA &nbsp;·&nbsp;
  <a href="mailto:upinel@me.com">upinel@me.com</a> &nbsp;·&nbsp;
  <a href="mailto:dev@upinel.com">dev@upinel.com</a> &nbsp;·&nbsp;
  <a href="https://upinel.com">upinel.com</a></sub><br>
  <sub>Free for personal use, and free for creators — YouTubers, KOLs, streamers
  and bloggers, and <b>you keep the money you make</b>: just email dev@upinel.com
  to say so, no reply needed. Other commercial use by written permission.
  Derivatives must credit the author. See <a href="LICENSE">LICENSE</a>.</sub>
</p>

---

**Just want it running?** On an Apple Silicon Mac with 32 GB or more:

```bash
git clone https://github.com/upinel/UpinelAIOS-GGUF && cd UpinelAIOS-GGUF
./install.sh      # scans your Mac, suggests settings, installs everything
./start.sh        # serves http://<your-lan-ip>:8000/v1
./chat.sh         # talk to it, right here in the terminal
```

That is the whole quick start. Everything below is detail you can come back to —
[Requirements](#requirements) if your Mac is small, [Configure it](#configure-it)
to pick a different model, [Benchmarks](#benchmarks) for the measured numbers.

---


> **Sister project: [UpinelAIOS-MLX](https://github.com/Upinel/UpinelAIOS-MLX)** —
> the same one-click agent server built on **MLX/MTPLX** rather than llama.cpp.
> That one drives Qwen through MTPLX's MTP speculative decoding; this one serves
> anything GGUF on llama.cpp, which is the only runtime that can run an
> uncensored Gemma 4 at all. Choose by what you want to serve — both are tuned
> as far as their runtime allows.

A portable, one-command **uncensored agent endpoint** for Apple Silicon Macs,
tuned for maximum tokens/sec. Two model families ship in the box:

| family | models | runtime |
|---|---|---|
| **Gemma 4** | `gguf-g-26ba4b` (default), `gguf-g-12b`, `gguf-g-31b`, `gguf-g-e2b`, `gguf-g-e4b` | llama.cpp |
| **Qwen 3.8** | `gguf-q-27b`, `gguf-q-9b`, `gguf-q-35ba3b` | llama.cpp |

Built and measured on an **M5 Pro / 20-core GPU / 64 GB**, serving
`OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF` through llama.cpp with
a companion MTP draft model:

```
106 t/s decode, 1.1 s TTFT     (uncensored MoE, ~4B active per token)
 99 t/s on the small E2B, if you want it snappier
256K context supported, 131K default
OpenAI-compatible API on your LAN, plus vision when you want it
```

Clone it, run `./install.sh`, run `./start.sh`. Nothing else.

---

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
  - [Chatting from the terminal](#chatting-from-the-terminal)
- [Configure it](#configure-it)
  - [Two engines, one server](#two-engines-one-server)
  - [Models: uncensored only](#models-uncensored-only)
    - [Gemma 4](#gemma-4)
    - [Qwen](#qwen)
    - [Why Q4_0 is the default quant](#why-q4_0-is-the-default-quant)
    - [Dense and MoE models are not comparable](#dense-and-moe-models-are-not-comparable)
  - [Thinking](#thinking)
  - [Vision costs 24%](#vision-costs-24)
- [Going deeper](#going-deeper)
  - [Why this is a separate project from UpinelAIOS-MLX](#why-this-is-a-separate-project-from-upinelaios-mlx)
  - [Speculative depth: the one speed knob that matters](#speculative-depth-the-one-speed-knob-that-matters)
  - [Thinking has a real token budget](#thinking-has-a-real-token-budget)
  - [Keep the prompt prefix stable](#keep-the-prompt-prefix-stable)
  - [Agents that write files](#agents-that-write-files)
- [Benchmarks](#benchmarks)
  - [Measured throughput](#measured-throughput)
    - [How prefill behaves as context grows](#how-prefill-behaves-as-context-grows)
    - [M5 Neural Accelerators: nearly 2x the prefill, free](#m5-neural-accelerators-nearly-2-the-prefill-free)
    - [On a smaller Mac](#on-a-smaller-mac)
  - [Measuring this yourself](#measuring-this-yourself)
    - [Tested and rejected](#tested-and-rejected)
- [Running it day to day](#running-it-day-to-day)
  - [Updating the code](#updating-the-code)
  - [Watching it work](#watching-it-work)
- [Credits and licences](#credits-and-licences)

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
| `gguf-g-e2b` | 3.4 GB | **4.2 GB** | 8 GB Mac |
| `gguf-g-e4b` | 5.3 GB | 6.8 GB | 16 GB Mac |
| `gguf-g-12b` | 7.4 GB | ~10 GB | 16 GB Mac |
| `gguf-g-31b` | 17.8 GB | ~22 GB | 32 GB Mac |

On an 8 GB Mac set `MODEL="e2b"`, `CONTEXT_WINDOW=8192` and
`MEMORY_LIMIT_GB=6`. macOS itself wants 3–4 GB, so leave it that room. On a
16 GB Mac, `gguf-g-e2b` is comfortable, `gguf-g-12b` is the largest model that fits, and the
default `gguf-g-26ba4b` does not — it wants ~19 GB with its context.

Disk: 4–20 GB per model, depending which you pick.

## Quick start

```bash
git clone https://github.com/upinel/UpinelAIOS-GGUF && cd UpinelAIOS-GGUF

./install.sh          # scans your Mac, suggests settings, installs everything
./start.sh            # serves http://<your-lan-ip>:8000/v1
./chat.sh             # talk to it right here in the terminal
./status.sh           # live dashboard
./restart.sh          # apply an env.conf change
./model_download.sh   # download another model
./stop.sh
```

Point any OpenAI-compatible client at the URL `./status.sh` prints.

**If you have more than one model downloaded, `start.sh` and `restart.sh` ask
which one to serve.** Press a number, or Enter for the default; with no answer
within five seconds the default from `env.conf` is used, so nothing ever waits
on you:

```
  Models on disk   5 downloaded - pick one to serve now

   1  e2b            3 GB
   2  26b-a4b       16 GB
   3  qwen-27b      17 GB
   4  26b-q4        14 GB  <- default
   5  qwen-9b        5 GB

  Number [1-5], or Enter for the default. Auto-selects in 5s:
```

It is a one-run choice and is not written back — `MODEL` in `env.conf` is still
the default. Pass `--model gguf-g-12b` to skip the question entirely, and note that it
is skipped automatically whenever there is no terminal to ask on (a pipe, CI,
`nohup`, launchd) or only one model is downloaded.

Only complete downloads are offered: a directory left behind by an interrupted
download is not listed, so the picker cannot hand you a model that fails to
load.

### Chatting from the terminal

`./chat.sh` is a streaming chat client for the server you already have running.
Nothing new is served and nothing is reconfigured — it just connects back to it.

```
you ▸ Explain what a mixture-of-experts model is, briefly.
ai  ▸ A mixture-of-experts model splits its feed-forward layers into many
      expert subnetworks and routes each token to only a few of them...
        106.4 t/s   prefill 98 t/s   1.1s
```

Replies stream as they are generated, thinking is shown dimmed behind a
`(thinking)` marker, and every turn ends with its own line of telemetry so you
can see what the server is actually doing.

```bash
./chat.sh                      # start chatting
./chat.sh --thinking on        # think before answering
./chat.sh --system "You are a terse assistant."
./chat.sh --temp 0.2           # tighter sampling
./chat.sh --no-stream          # wait for whole replies
```

In-session commands: `/help`, `/reset`, `/system <text>`, `/thinking on|off`,
`/temp <0..2>`, `/stats`, `/save <file>`, `/clear`, `/exit`. `Ctrl-C` stops a
reply without quitting; `Ctrl-D` leaves.

**Pasting works, and a paste is one message.** Paste a stack trace, a diff, or a
whole file and it is sent as a single turn rather than one turn per line, with
indentation intact. Lines inside a paste are never treated as commands, so
pasting a script that contains `/exit` sends it to the model instead of quitting
on you. A paste that is a single line still works as a command — `/help` on its
own runs, `/help` inside a pasted block is text. The client says which it did:

```
you ▸ <12 lines pasted here>
  pasted 12 lines, 431 chars - sending as one message
ai  ▸ ...
```

---

## Configure it

### Two engines, one server

UpinelAIOS serves through either of two runtimes, and **the engine follows the
model** — a GGUF checkpoint can only run on llama.cpp, an MTPLX pack can only
run on MTPLX. So choosing a model chooses the engine, and there is nothing else
to decide.

| | engine | what it is for | best decode |
|---|---|---|---:|
| ![GGUF](https://img.shields.io/badge/GGUF-llama.cpp-F2B93B?style=flat-square) | llama.cpp | Gemma 4 at peak speed, plus vision | **106 t/s** |
| ![MLX](https://img.shields.io/badge/MLX-MTPLX-B9A5FF?style=flat-square) | MLX / MTPLX | anything Qwen — up to **2.6×** llama.cpp on the same model | **79 t/s** |

`./install.sh` recommends a model for **each** engine and lets you choose:

```
  1  GGUF gguf-g-26ba4b     15 GB  uncensored MoE, 3B active - 106 t/s
  2  MLX  mlx-q-35ba3b      22 GB  35B MoE - fastest Qwen (~79 t/s)
  3  both                       install both engines and both models
  4  your                       your own Hugging Face repo (owner/name)
```

Pick 3 and you get both runtimes and both models; each is served by whatever
`./start.sh` or the `./model_download.sh` picker selects afterwards.

Pick 4 and you are asked for any `owner/name` repo. The engine is read off the
name (`…-GGUF` is llama.cpp, `…-MTPLX…` is MLX) and asked for only when the name
does not say — so a custom model works on either engine without you needing to
know the rule. The same thing works non-interactively:

```bash
./model_download.sh someone/some-uncensored-GGUF
./model_download.sh --engine mlx someone/some-MTPLX-pack
```

#### Aliases name their engine

Every alias is `{engine}-{family}-{size}`, so the runtime is visible at a glance
and a new model cannot be added without declaring one:

| alias | engine | model | decode |
|---|---|---|---:|
| **`gguf-g-26ba4b`** | GGUF | Gemma 4 26B-A4B Q4_0 QAT — **the default** | **106.4 t/s** |
| `gguf-g-e2b` | GGUF | Gemma 4 E2B — snappiest first token | 99.9 t/s |
| `gguf-g-12b` | GGUF | Gemma 4 12B — largest that fits a 16 GB Mac | 54.5 t/s |
| `gguf-g-31b` | GGUF | Gemma 4 31B heretic — highest quality dense | — |
| `gguf-g-e4b` | GGUF | Gemma 4 E4B — only if `26ba4b` will not fit | 63.9 t/s |
| **`mlx-q-35ba3b`** | **MLX** | Qwen 3.6 35B-A3B MoE — **the MLX default** | **79.4 t/s** |
| `mlx-q-27b-4bit` | MLX | Qwen 3.8 27B dense — the quality pick | 34.7 t/s |
| `mlx-q-9b` | MLX | Qwen 3.8 9B — only when memory is tight | 65.1 t/s |
| `gguf-q-27b` / `gguf-q-9b` / `gguf-q-35ba3b` | GGUF | the same Qwen models through llama.cpp | — |

Measured on an M5 Pro. Old aliases (`26b-q4`, `moe`, `4bit`, …) still work, with
a warning naming the replacement.

### Models: uncensored only

**Every model UpinelAIOS-GGUF ships or suggests is an uncensored fine-tune.**
There is no point being fast at something that will not answer.

You do not have to choose from these tables by hand. `install.sh` scans your Mac
and proposes a model and settings for it; if you would rather not have that one,
answer `n` at the prompt and it prints a numbered list of everything below, each
row marked with a verdict for *your* memory:

```
    #  ALIAS        SIZE   VERDICT              NOTE
    1  26b-q4       15 GB  RECOMMENDED          uncensored MoE, 3B active - the fastest 26B here
    2  26b-a4b      18 GB  fits comfortably     same MoE in Q4_K_M: about 20% slower, 3 GB bigger
    ...
    7  qwen-27b     19 GB  will not fit         dense 27B, ~14 t/s; its MTP head needs a build step
  Model number:
```

`RECOMMENDED` / `fits comfortably` / `tight - expect paging` / `will not fit` are
computed from your unified memory, the model's published size, and that model's
own KV cost per token — a full-attention Qwen costs several times more per token
than the sliding-window Gemma MoE, so the verdicts are per-model, not per-size.
Enter a number to use it, or press Enter to keep the config you already have.
Choosing something that will not fit is allowed; it warns, then does what you
asked.

#### Gemma 4

| alias | download | repo |
|---|---:|---|
| **`gguf-g-26ba4b`** | 15 GB | `OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF` — **default**, 106.4 t/s, Q4_0 QAT |
| `gguf-g-e2b` | 4 GB | `HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive` — 99.9 t/s. Smallest, fits 8 GB. |
| `gguf-g-e4b` | 6 GB | `HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive` — 63.9 t/s. Only if `gguf-g-26ba4b` will not fit. |
| `gguf-g-12b` | 8 GB | `HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced` — 54.5 t/s. Largest that fits a 16 GB Mac. |
| `gguf-g-31b` | 20 GB | `llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF` — highest quality dense model |

#### Qwen

| alias | download | repo |
|---|---:|---|
| `gguf-q-27b` | 19 GB | `HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF` |
| `gguf-q-9b` | 6 GB | `mradermacher/Qwen3.8-9B-heretic-uncensored-i1-GGUF` |
| `gguf-q-35ba3b` | 22 GB | `HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive` |

**Two things to know before you pick Qwen here.**

`gguf-q-35ba3b` is **3.6, not 3.8.** Qwen never released a 3.8 35B-A3B; the only repo
labelled 3.8 35B-A3B is a 3.6 distill carrying a single ROCm-format quant. It is
named for what it actually is rather than mislabelled.

`gguf-q-27b` MTP needs a **patched llama.cpp**, and the build is one command:

```bash
./lib/build-fastmtp.sh      # clones, patches, builds, wires it into env.conf
./start.sh --model gguf-q-27b # picks it up automatically for this model only
```

**7.6 t/s → ~14–15 t/s.** The patch only touches the Qwen35 architecture, and
pinning to its base commit costs Gemma about 2–3%, so the patched build is used
*only* for models whose draft head needs it — Gemma keeps the stock runtime.

Without the patch the server detects the head, runs autoregressive, and says
why, rather than exiting. Details and measurements:
[docs/GGUF-RUNTIME.md](docs/GGUF-RUNTIME.md).

#### Why Q4_0 is the default quant

The two 26B entries in the throughput table below are the same model in
different quants, and that comparison is the whole reason the default is what
it is:

| quant | size | decode |
|---|---:|---:|
| Q4_K_M &nbsp;(the same model, not shipped) | 16.8 GB | 72.5 t/s |
| **Q4_0 QAT &nbsp;(`gguf-g-26ba4b`)** | **14.25 GB** | **106.4 t/s** |

**~47% faster decode and 15% smaller, from the same weights.** Two things make
that safe rather than a quality gamble:

- llama.cpp's Metal kernels run Q4_0 markedly faster than K-quants. That shows
  up on any model — a 0.5B test model gains 25% on decode going Q4_K_M → Q4_0.
- It is Google's **quantization-aware-trained** Q4_0 checkpoint, not a naive
  post-hoc quantisation, so Q4_0 holds quality where it normally would not.

The existing MTP drafter works with it unchanged.

#### Dense and MoE models are not comparable

A dense 27B reads ~15 GB of weights for every token; that is what this memory
bandwidth supports, not a bug — which is why `gguf-q-27b` sits at 13.5 t/s while
the 26B Gemma, a mixture of experts with only ~4B active per token, reaches
106 t/s.

So **if Qwen speed is what you want, use
[UpinelAIOS-MLX](https://github.com/Upinel/UpinelAIOS-MLX)**: MTPLX's MTP
implementation works on Metal and llama.cpp's does not, which is the clearest
reason the two projects exist side by side.

**Only one quant is downloaded.** GGUF repos often publish every quant of the
same model, and the `gguf-g-31b` repo carries ten of them — 232 GB in total,
of which the 18.7 GB `Q4_K_M` is the one that fits a Mac. Fetching the repo
wholesale would cost twelve times the disk and hours of download, so
UpinelAIOS-GGUF picks a single quant (`MODEL_QUANT` in `env.conf`, default
`Q4_0`, matching the default model's QAT release) and skips the rest. If the
model you switch to does not publish that quant, the closest one at the same bit
width is used and `model_download.sh` says which. The sizes above are what
actually lands on disk: that quant, plus the vision projector and the MTP draft
head, which are separate artifacts rather than quants and are always fetched.

The default Gemma model does not publish its own MTP draft head, so that 250 MB
file is pulled from the companion repo that does
(`HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP`). Without it the
model still runs — just autoregressive, and roughly half the speed, with nothing
on screen to say why. Because of that, `./model_download.sh` re-checks the
companions even when the weights are already on disk, so an install made before
this existed gets repaired rather than left quietly slower.

```bash
./bench/verify-tools.sh            # check tool calling, measure a file write
./model_download.sh                # what is available, what you have
./model_download.sh gguf-g-12b            # download one
./model_download.sh --switch 12b   # download if needed, switch, restart
./start.sh --model gguf-g-12b             # serve a different model for one run
```

### Thinking

```conf
THINKING="off" | "minimal" | "low" | "medium" | "high"
THINKING_BUDGET_TOKENS=0        # 0 = use the level's tuned budget
THINKING_BUDGET_MESSAGE="..."   # injected as the budget runs out
```

Each level is a real token cap on the thought channel, applied with llama.cpp's
`--reasoning-budget`. `off` remains the default because on routine tool-calling
work the 26B reasons for only ~32 tokens anyway, so a budget buys nothing — see
[Thinking has a real token budget](#thinking-has-a-real-token-budget).

Reach for `low` or `medium` on genuinely hard work where you want the model to
think at length; for a one-off without editing the file:

```bash
THINKING=high THINKING_BUDGET_TOKENS=1024 ./restart.sh
```

Keep `THINKING_BUDGET_MESSAGE` set if you use a budget that actually binds —
a thought cut off mid-sentence can leave the model without a tool call.

### Vision costs 24%

Gemma 4 is multimodal, and the vision tower is **off by default**. It is not
free even for text-only requests:

| | decode (512 ctx) | first token |
|---|---:|---:|
| `ENABLE_VISION=1` | 67.8 t/s | 0.40 s |
| `ENABLE_VISION=0` | **88.7 t/s** | **0.05 s** |

Three repeats each, same model. Set `ENABLE_VISION=1` when you actually need
images; text quality is identical either way.

---

## Going deeper

### Why this is a separate project from UpinelAIOS-MLX

The MLX edition runs on **MTPLX** (MLX). Gemma 4 cannot, and the reason is
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

### Speculative depth: the one speed knob that matters

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

### Thinking has a real token budget

llama.cpp has `--reasoning-budget N` — a hard cap on the thought channel — plus
`--reasoning-budget-message` injected as the cap is reached. The levels in
`env.conf` are real budgets.

Measured on the default **26B-A4B**, eight agent tasks, greedy sampling:

| setting | budget | tokens/turn | thinking | correct |
|---|---:|---:|---:|---:|
| **`off`** (default) | — | **16** | 0 | 8/8 |
| unlimited | — | 58 | 32 | 8/8 |
| `minimal` + msg | 32 | 70 | 58 | 8/8 |
| `low` + msg | 128 | 58 | 32 | 8/8 |
| `medium` + msg | 512 | 58 | 32 | 8/8 |

**This model does not overthink tool-calling work.** It reasons for roughly 32
tokens and then acts, so a 32-token cap never binds and the budget message ends
up costing more than it saves (70 tokens against 58 uncapped). The 128 and 512
budgets never engage at all.

So the levels are there for genuinely hard work, not for trimming routine
turns — on routine turns `off` is 16 tokens against 58.

> **Correction.** An earlier version of this section reported a very different
> table, including a claim that a small budget beat thinking-off. Those numbers
> were measured **on the wrong model**: the benchmark resolved its model by
> taking the first directory under `models/`, so once a second model was
> downloaded it silently benchmarked a 2B model while the docs described a 26B
> one. Both bench scripts now resolve the model through `env.conf`, the same
> path `start.sh` uses. If you have older numbers from these tools, re-run them.

### Keep the prompt prefix stable

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
> shifting work. UpinelAIOS-GGUF deliberately does not set it.

### Agents that write files

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

---

## Benchmarks

### Measured throughput

**Measured on an M5 Pro (20-core GPU, 64 GB).** Decode is the rate once
generating; prefill is the rate ingesting the prompt; TTFT is time to first
token. Every model below is uncensored.

| model | decode | prefill | TTFT | when to use it |
|---|---:|---:|---:|---|
| **`gguf-g-26ba4b`** &nbsp;Gemma 4 26B-A4B Q4_0 QAT | **106.4 t/s** | 98 t/s | 1.1 s | **The default, and the fastest thing here.** MoE with ~4B active per token; this is the build the whole project is tuned around. |
| `gguf-g-e2b` &nbsp;Gemma 4 E2B | 99.9 t/s | 294 t/s | 1.7 s | The snappy one: fastest prefill, smallest footprint, for a small Mac or quick replies. |
| `gguf-q-35ba3b` &nbsp;Qwen 3.6 35B-A3B | 70.5 t/s | 180 t/s | 2.7 s | Works, but the [MLX project](https://github.com/Upinel/UpinelAIOS-MLX) runs this same model faster. |
| `gguf-g-e4b` &nbsp;Gemma 4 E4B | 63.9 t/s | 84 t/s | 0.4 s | Only when the Mac genuinely cannot fit `gguf-g-26ba4b`. |
| `gguf-g-12b` &nbsp;Gemma 4 12B | 54.5 t/s | 81 t/s | 2.6 s | The largest model that still fits a **16 GB** Mac. `gguf-g-e2b` is nearly twice as fast, so pick it for capability, not speed. |
| `gguf-q-9b` &nbsp;Qwen 3.8 9B | 44.3 t/s | 130 t/s | 4.1 s | Use the **MLX** build instead — ~47% faster there. |
| `gguf-q-27b` &nbsp;Qwen 3.8 27B | 13.5 t/s | 133 t/s | 9.1 s | Use the **MLX** build instead — ~2.6× faster there. |

**The default is also the fastest, which is the point.** `gguf-g-26ba4b` leads on decode
at 106 t/s while being a 26B parameter model: it is Google's quantization-aware
Q4_0 release of a mixture-of-experts checkpoint, so it reads only ~4B active
parameters per token and stays small enough (15 GB) to leave room for a long
context. Nothing else in this table wins on both counts.

> Prefill and TTFT above were measured on **short prompts**, where per-request
> overhead dominates the figure. They are indicative of responsiveness, not of
> long-context prefill — for that, see the scaling table below.

#### How prefill behaves as context grows

**M5 Pro, uncensored Gemma 4 26B MoE**, 512 prefill batches. Decode holds up;
prefill is what costs you at long context, and TTFT is made of it.

| context | decode | prefill | TTFT, cold | TTFT, warm |
|---:|---:|---:|---:|---:|
| 2k | 59 t/s | 1,058 t/s | 2.3 s | **0.35 s** |
| 8k | 53 t/s | 860 t/s | 8.9 s | **0.41 s** |
| 32k | **25 t/s** | 461 t/s | **63 s** | **0.68 s** |

The two right-hand columns are the ones that matter for an agent. A multi-turn
agent re-sends its whole growing history every turn; because the server reuses
that prefix from the KV cache, only the new tokens cost anything. Turn 2 of an
8k conversation returns in **0.41 s** where the cold first turn took **8.9 s** —
so the expensive event is the first turn of a session, not the twentieth.

> **Cold prefill is the real long-context cost, and it is architectural.** At 32k
> the first turn waits **63 seconds** before the first token. Prefill sits at
> ~420 t/s at 32k whether batches are 512 or 2048, because five of the thirty
> layers are full-attention and get quadratically more expensive with context
> (the other 25 use a 1024-token sliding window). Keep agent contexts under ~32k
> where the speed is, and let KV reuse carry the rest.

#### On a smaller Mac

Not measured here, but decode is memory-bandwidth-bound and an M1 MacBook Air
has roughly a quarter of an M5 Pro's bandwidth. Order-of-magnitude:

| model | estimated decode on M1 |
|---|---:|
| `gguf-g-e2b` | ~25 t/s |
| `gguf-g-e4b` | ~15 t/s |

Even the pessimistic end is a usable agent endpoint, and `gguf-g-e2b` at 4.2 GB is the
right pick for an 8 GB Air.

#### M5 Neural Accelerators: nearly 2× the prefill, free

Apple's **M5** puts a Neural Accelerator in every GPU core, reachable through
the **Metal 4 tensor API**. llama.cpp uses it automatically on M5 and later, and
because agents live and die on prefill — every cold session pays it before the
model can do anything — this is one of the larger wins in the whole bundle.

Measured here, 8,009-token prompt, cold first turn:

| tensor API | prefill | time to first token |
|---|---:|---:|
| **on** (M5 default) | **1,376 t/s** | **5.82 s** |
| off | 697 t/s | 11.48 s |

**~1.97× prefill, and decode is untouched** (119 vs 115 t/s, which is inside
run-to-run noise). It is a prefill win, not a decode one — worth being precise
about, because "M5 is 2× faster" would be the wrong claim.

`METAL_TENSOR_API` in `env.conf` controls it:

| value | what happens |
|---|---|
| `auto` | llama.cpp decides — **on** for M5/M6/A19/A20, **off** everywhere else. Default. |
| `on` | Force on. Warns on older chips. |
| `off` | Force off, for A/B measurement or if a driver regresses. |

**On M1–M4 this setting does nothing**, because those chips have no Neural
Accelerators. That is not a limitation of this project: llama.cpp gates the
tensor API by chip name precisely because its own measurements record it as
**~5% slower on M2 Ultra** and neutral on M4/M4 Max. Forcing it on older silicon
is a pessimisation, which is why `start.sh` warns if you try.

`./start.sh` prints the resolved state rather than the setting, since "auto"
means something different on an M5 than on an M3:

```
  tensor API   on (M5 Neural Accelerators, ~1.9x prefill)
```

> **The MLX project gets this too, automatically.** MTPLX's runtime ships
> separate `nax` (Neural Accelerator) kernel variants — 21,660 `matmul2d` entries
> in its metallib — and selects them by GPU architecture, with no setting to
> flip. On the MLX side there is nothing to configure; it is already on.

### Measuring this yourself

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

#### Tested and rejected

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

---

## Running it day to day

### Updating the code

This is a git checkout, so updating means pulling. There is no update script:
`./model_download.sh` is for models, and this is for code.

```bash
git pull
./restart.sh          # to run the new code
```

**If `git pull` refuses**, that is expected and easy to fix. `env.conf` is
tracked, and editing it is the whole point of the project, so git stops with:

```
error: Your local changes to the following files would be overwritten by merge:
        env.conf
```

Set your settings aside, pull, and put them back:

```bash
git stash push -m "my settings" -- env.conf
git pull
git stash pop
./restart.sh
```

If upstream changed the same lines you did, `git stash pop` reports a conflict
and leaves `<<<<<<<` markers in `env.conf`. **Do not leave it like that** —
`env.conf` is what every script sources, so a conflicted one breaks the whole
project. Take upstream's version and recover yours from the stash:

```bash
git checkout HEAD -- env.conf      # upstream's, known good
git stash show -p stash@{0}        # see what you had
git checkout stash@{0} -- env.conf # or just restore yours and edit it
git stash drop                     # once you are happy
./restart.sh
```

**To see what changed before you commit to it:**

```bash
git fetch origin
git log --oneline HEAD..origin/main         # what is coming
git diff --stat HEAD..origin/main           # which files
```

Your models are never touched by any of this. `models/`, `run/` and `outputs/`
are gitignored, so an update cannot disturb what you have downloaded — only
`./model_download.sh` changes those.

> **`./install.sh` is only needed when a requirement changed** — a new
> dependency or a new setup step. A code-only update just needs
> `./restart.sh`.

### Watching it work

`./status.sh` is a live dashboard. Press **`t`** to cycle the thinking level and
**`m`** to cycle downloaded models — each arms a 2-second countdown before it
applies, so repeated presses move through the options without committing to the
one you just passed. `Enter` applies now, `Esc` cancels.

## Credits and licences

### This project

**UpinelAIOS-GGUF is © 2026 Nova Upinel Chow, released under the
[Upinel Personal Free License](LICENSE).** In short:

| | |
|---|---|
| **Personal use** | Free. Use it, change it, share it. |
| **Creators — YouTubers, KOLs, streamers, bloggers** | Free — **you keep the money you make from the content**. Videos, streams, posts, articles, images, tutorials — and any text or images you generate with it and publish. Just email [dev@upinel.com](mailto:dev@upinel.com) to say you're doing it. **You do not need a reply and should not wait for one** — the permission takes effect the moment you hit send. |
| **Other commercial use** | Needs the author's written permission — email [dev@upinel.com](mailto:dev@upinel.com). This covers use inside a company, selling a product or service built on it, and hosting it for others as a paid service. |
| **Derivatives** | Must credit the author and keep this licence. Fork it, port it, improve it — just leave the name on it. |
| **Scope** | Covers this project's own code only. llama.cpp, MLX, MTPLX, Gemma 4, Qwen, and every model weight belong to other people and keep their own licences — see [section 3 of the licence](LICENSE) for the full list. |
| **Warranty** | None. It is a local inference server; you are responsible for what you run on it. |

So: making a video about it, reviewing it, or using it on stream to generate
content is free, forever, no permission needed — tell us and carry on. Selling
it, or selling something that runs on it, is the thing to ask about.

> **One licence file, both projects.** `LICENSE` is byte-identical in
> UpinelAIOS-GGUF and UpinelAIOS-MLX, and its scope clause covers both editions,
> so you never have to work out which terms apply to which repo. To confirm the
> two have not drifted:
>
> ```bash
> shasum -a 256 LICENSE
> # 0906eccc1ebc7e22f8de876997a4f33b7b85c3516d2c5a28796aad759fde7ff7
> ```

This is a **source-available** licence, not an open-source one: the
[OSI definition](https://opensource.org/osd) requires that a licence permit
commercial use, which this one deliberately does not. If you need a commercial
licence, or a different arrangement for your organisation, ask — the answer is
usually yes, and it is a short conversation.

The author is not a lawyer and this licence has not been reviewed by one. It is
written to be read and understood rather than to be maximally clever, but if you
are relying on it commercially, get your own advice.

### Third-party

- **[llama.cpp](https://github.com/ggml-org/llama.cpp)** — MIT. The runtime.
- **[Gemma 4](https://ai.google.dev/gemma)** — Google's model, Apache-2.0, and
  additionally subject to Google's
  [Prohibited Use Policy](https://ai.google.dev/gemma/prohibited_use_policy),
  which this project's licence neither grants nor overrides.
- **HauhauCS** — the uncensored Gemma 4 fine-tunes and their draft models.

Third-party components keep their own licences; this project's licence does not
cover them, and it covers no model weights at all.

### Does this licence conflict with what the project uses?

No, and the reasoning is worth stating rather than asserting:

- **Nothing third-party is redistributed here.** `install.sh` runs
  `brew install`, and the runtime is started as a separate process and spoken to
  over HTTP. MIT and Apache-2.0 impose obligations when you distribute their
  code; nothing is vendored, so nothing of theirs is relicensed, and their
  notices stay with them.
- **Everything upstream is permissive** — llama.cpp (MIT), MLX (MIT), MTPLX
  (Apache-2.0), Gemma 4 and Qwen (Apache-2.0). There is no copyleft anywhere in
  the dependency tree, which is precisely what makes it possible to license this
  project's own code restrictively.
- **Every Python import here is standard library.** There are no third-party
  Python packages to account for.

The one real incompatibility: because this licence forbids commercial use and
requires derivatives to stay no more permissive, this code **cannot be combined
into a GPL or AGPL project**. Both of those permit commercial use, so the terms
conflict in both directions. Nothing used here is GPL, so it costs nothing
today — but it does close that door.

Model weights carry their own upstream licences. Uncensored fine-tunes are
uncensored: you are responsible for how you use the endpoint, and for the fact
that you just exposed it to your LAN.
