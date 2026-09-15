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
  <b>Up to 141 t/s decode — uncensored, 100% local, on your own Mac.</b><br>
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
git clone https://github.com/Upinel/UpinelAIOS && cd UpinelAIOS
./install.sh      # scans your Mac, suggests settings, installs everything
./start.sh        # serves http://<your-lan-ip>:8000/v1
./chat.sh         # talk to it, right here in the terminal
```

### Pick a profile: what should this Mac master?

`./start.sh` and `./restart.sh` ask which workload to master, and remember the
answer. They are different jobs rather than points on a scale, so the right one
depends on what you are doing today.

```
  Which workload should this Mac master?

   1  speed    Max t/s          peak decode; one client, thinking bounded
   2  agent    Max Agentic AI   tool loops; thinking off, 4 sessions, prefixes kept
   3  writer   Max Long Writer  long context; shallower drafts, long replies, one client
   4  custom   Custom           use env.conf exactly as written
```

| | for | what it changes |
|---|---|---|
| **Max t/s** | one client, fastest possible replies | tuned MTP depth, f16 KV, thinking bounded, one session holding the whole GPU |
| **Max Agentic AI** | a loop of tool calls | thinking **off** so a modest `max_tokens` cannot truncate a call, 4 concurrent sessions, prefix cache kept on disk, room for a full tool call |
| **Max Long Writer** | novels, long documents | shallower drafting (depth 1) so there is less to verify per cycle as the window fills, thinking off, 8192-token replies, one client |

Skip the question with `./start.sh --profile agent`, or set `EXPERT_PROFILE` in
`env.conf` and it stops asking. `custom` leaves every setting exactly as you
wrote it.

A profile only touches the settings it names — **your model, context window and
memory cap are always kept**, so switching profile never silently changes which
model you are running or how much memory it may use.

That is the whole quick start. Everything below is detail you can come back to —
[Requirements](#requirements) if your Mac is small, [Configure it](#configure-it)
to pick a different model, [Benchmarks](#benchmarks) for the measured numbers.

---


> **One repo, both engines.** This was the GGUF edition; the MLX edition
> ([UpinelAIOS-MLX](https://github.com/Upinel/UpinelAIOS-MLX)) has been folded
> into it, and that repo now redirects here. You get llama.cpp and MLX/MTPLX in
> the same install, and the engine follows the model you pick — a GGUF
> checkpoint runs on llama.cpp, an MTPLX pack runs on MTPLX, and nothing asks
> you to choose a runtime up front.

A portable, one-command **uncensored agent endpoint** for Apple Silicon Macs,
tuned for maximum tokens/sec. Two model families ship in the box, across two
runtimes:

| family | models | runtime |
|---|---|---|
| **Gemma 4** | `gguf-g-26ba4b` (default), `gguf-g-12b`, `gguf-g-31b`, `gguf-g-e2b`, `gguf-g-e4b` | llama.cpp |
| **Qwen 3.8** | `gguf-q-27b`, `gguf-q-9b`, `gguf-q-35ba3b` | llama.cpp |
| **Qwen 3.8 / 3.6** | `mlx-q-35ba3b`, `mlx-q-27b-4bit`, `mlx-q-27b-6bit`, `mlx-q-9b` | MLX / MTPLX |

Built and measured on an **M5 Pro / 20-core GPU / 64 GB**, across both engines:
`hawhyhb/Qwen3.6-35B-A3B-...-MTPLX-4bit` on MLX, and
`OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF` on llama.cpp with a
companion MTP draft model:

```
141 t/s decode, 4.6 s TTFT     (35B MoE, ~3B active, MLX, tuned)
106 t/s decode, 0.4 s TTFT     (26B MoE, ~4B active, llama.cpp)
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
- [Pick a profile: what should this Mac master?](#pick-a-profile-what-should-this-mac-master)
- [Configure it](#configure-it)
  - [Two engines, one server](#two-engines-one-server)
  - [What tuning actually bought](#what-tuning-actually-bought)
  - [Models: uncensored only](#models-uncensored-only)
    - [Gemma 4](#gemma-4)
    - [Qwen](#qwen)
    - [Why Q4_0 is the default quant](#why-q4_0-is-the-default-quant)
    - [Dense and MoE models are not comparable](#dense-and-moe-models-are-not-comparable)
  - [Thinking](#thinking)
  - [Vision costs 24%](#vision-costs-24)
- [Going deeper](#going-deeper)
  - [Why Gemma runs on llama.cpp and Qwen can run on either](#why-gemma-runs-on-llamacpp-and-qwen-can-run-on-either)
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
- [Documentation](#documentation)
- [Credits and licences](#credits-and-licences)

## Requirements

| | |
|---|---|
| **Minimum** | Apple Silicon Mac, **16 GB** unified memory, macOS 14+ |
| **Comfortable** | **32 GB** — the default model fits with room for a desktop |
| **Recommended** | **64 GB**, for 128K context on the 26B and room for a full desktop |

**16 GB is the floor this project is tuned for.** On a 16 GB Mac `gguf-g-e2b` is
comfortable and `gguf-g-12b` is the largest model that fits; the default
`gguf-g-26ba4b` does not, because it wants ~19 GB once its context is counted.

> ### ⚠️ 8 GB — supported, but use with caution
>
> **An 8 GB Mac still works, and you are welcome to run it.** It just is not
> what this is tuned for, and it is tight: the smallest model fits and nothing
> else, the context has to come down far enough that the model loses the start
> of a long conversation, and macOS is competing for the same memory the whole
> time.
>
> Expect paging, a slow first token, and less headroom than every other number
> in this README assumes. Set it up like this and it does work:

```conf
MODEL="gguf-g-e2b"
CONTEXT_WINDOW=8192
MEMORY_LIMIT_GB=6
```

macOS itself wants 3–4 GB, so leave it that room — that is what makes the
difference between slow and unusable. Everything above stands, but treat it as
a ceiling rather than a starting point.

The memory each option actually needs, measured as resident set size:

| model | file | RAM used | needs |
|---|---:|---:|---|
| `gguf-g-e2b` | 3.4 GB | **4.2 GB** | 8 GB, tightly |
| `gguf-g-e4b` | 5.3 GB | 6.8 GB | 16 GB |
| `gguf-g-12b` | 7.4 GB | ~10 GB | 16 GB |
| `gguf-g-26ba4b` *(default)* | 14.3 GB | ~19 GB | 32 GB |
| `gguf-g-31b` | 17.8 GB | ~22 GB | 32 GB |

Disk: 4–20 GB per model, depending which you pick.

## Quick start

```bash
git clone https://github.com/Upinel/UpinelAIOS && cd UpinelAIOS

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
  Models on disk   11 downloaded - pick one to serve now

   #  ENGINE ALIAS                  SIZE
   1  MLX   mlx-q-9b                5 GB
   2  GGUF  gguf-g-e2b              3 GB
   ...
   8  GGUF  gguf-g-26ba4b          14 GB  <- default
   9  MLX   mlx-q-35ba3b           22 GB
  10  MLX   mlx-q-27b-4bit         15 GB
  11  GGUF  gguf-q-9b               5 GB

  Number [1-11], or Enter for the default. Auto-selects in 30s:
```

The 30-second wait is `PICK_TIMEOUT_SECONDS` in `env.conf`; press Enter to take
the default immediately.

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
| ![GGUF](https://img.shields.io/badge/GGUF-llama.cpp-F2B93B?style=flat-square) | llama.cpp | Gemma 4, plus vision | **106 t/s** |
| ![MLX](https://img.shields.io/badge/MLX-MTPLX-B9A5FF?style=flat-square) | MLX / MTPLX | anything Qwen — up to **2.2×** llama.cpp on the same model | **141 t/s** |

`./install.sh` recommends one model from **each** engine — the fastest in that
engine this Mac can actually load — and lets you choose:

```
  1  GGUF gguf-g-26ba4b     15 GB  uncensored MoE, 3B active - 106 t/s
  2  MLX  mlx-q-35ba3b      22 GB  35B MoE - fastest here (141 t/s)
  3  both                       install both engines and both models
  4  your                       your own Hugging Face repo (owner/name)
```

Pick 3 and you get both runtimes and both models; each is served by whatever
`./start.sh` or the `./model_download.sh` picker selects afterwards.

An engine is only offered if something in it fits. On an 8 GB Mac - below the
recommended floor, but the clearest case - the menu collapses to the single
model that runs, and the other engine is explained rather than listed:

```
  1  GGUF  gguf-g-e2b              4 GB   smallest, and the fastest small model: fits an 8 GB Mac
  2  list  pick any model we ship            with a verdict for this Mac
  3  yours type a Hugging Face repo id            any uncensored owner/name

  No MLX model is offered: the smallest one, mlx-q-9b,
  needs about 9 GB and this Mac has 8 GB.
```

Offering a model that cannot load is not a choice. Suggested sizes are the
model plus its KV cache at the recommended context plus 3 GB of runtime
headroom, so "fits" means it fits with something left over, not merely that it
starts.

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

| alias | engine | model | decode | prefill |
|---|---|---|---:|---:|
| **`gguf-g-26ba4b`** | GGUF | Gemma 4 26B-A4B Q4_0 QAT — **the default** | **~89 t/s** | ~1,390 t/s |
| `gguf-g-e2b` | GGUF | Gemma 4 E2B — snappiest first token | 99.9 t/s | 294 t/s |
| `gguf-g-12b` | GGUF | Gemma 4 12B — largest that fits a 16 GB Mac | 54.5 t/s | 81 t/s |
| `gguf-g-31b` | GGUF | Gemma 4 31B heretic — highest quality dense | — | — |
| `gguf-g-e4b` | GGUF | Gemma 4 E4B — only if `26ba4b` will not fit | 63.9 t/s | 84 t/s |
| **`mlx-q-35ba3b`** | **MLX** | Qwen 3.6 35B-A3B MoE — **the MLX default** | **~141 t/s** | **~1,760 t/s** |
| `mlx-q-27b-4bit` | MLX | Qwen 3.8 27B dense — the quality pick | ~30 t/s `*` | ~330 t/s |
| `mlx-q-9b` | MLX | Qwen 3.8 9B — only when memory is tight | ~113 t/s | ~1,340 t/s |
| `gguf-q-27b` / `gguf-q-9b` / `gguf-q-35ba3b` | GGUF | the same Qwen models through llama.cpp | — | — |

Measured on an M5 Pro. **Every figure is at 8k context**, which is what an agent
actually pays, with the tuned defaults — except `mlx-q-27b-4bit`, which is
carried over from an earlier run and marked `*`. Decode is higher at short
context (`gguf-g-26ba4b` peaks at ~106 t/s at 512 tokens) and lower far out (58
t/s at 32k). Old aliases (`26b-q4`, `moe`, `4bit`, …) still work, with a warning
naming the replacement.

`*` `mlx-q-27b-4bit` has not been re-measured since the KV and depth changes, so
its number is a floor rather than a current figure. Its two smaller siblings both
improved by a third or more, so expect better than this.

> **Every MLX figure above was re-measured.** The tables used to report **32 t/s**
> prefill for `mlx-q-35ba3b`, roughly 47× too low. That was a measurement
> artifact, not a property of the engine: the benchmark reused one prompt, so
> every run after the first hit the server's prefix cache and measured the cache
> instead of the work. `bench.py --repeats` caused it and is fixed — each repeat
> now sends a unique prompt.
>
> Re-measuring with that fixed changed all three models, in both directions:
>
> | model | decode was | decode now | prefill was | prefill now |
> |---|---:|---:|---:|---:|
> | `mlx-q-35ba3b` | 79.4 | **~141** | 32 | **~1,760** |
> | `mlx-q-27b-4bit` | 34.7 | **~30** | — | **~330** |
> | `mlx-q-9b` | 65.1 | **~90** | — | **~1,390** |
>
> Prefill scales with prompt size — about 500 t/s at 512 tokens against 1,520 at
> 8k on the 35B — because a short batch cannot saturate the GPU. The figures
> here are at **8k context**, which is what an agent actually pays, with
> `max_tokens 128` and a cold (never-cached) prompt.
>
> The old numbers also overstated the engine gap: the best ratio measured
> against llama.cpp on the same model is **2.2×** (the 27B), not the 2.6× these
> docs used to claim. That claim is corrected throughout.

### What tuning actually bought

Measured on the two target models, before and after, at 8k context. Each figure
is the best of several runs, engines interleaved so thermal drift hits every
config equally.

| | decode | prefill | TTFT |
|---|---:|---:|---:|
| `mlx-q-35ba3b` before | 88.8 t/s | 1,652 t/s | 4.87 s |
| **`mlx-q-35ba3b` after** | **141.2 t/s** | **1,762 t/s** | **4.56 s** |
| `gguf-g-26ba4b` before | 85.8 t/s | 1,360 t/s | 5.91 s |
| **`gguf-g-26ba4b` after** | **89.0 t/s** | **1,388 t/s** | **5.79 s** |

At 8k the MLX gain is the headline and the GGUF gain is small — but 8k is not
where a long conversation lives. At 32k the GGUF improvement is the whole
point, and it is the same change that did it: f16 KV, whose per-token
dequantisation cost grows with the context it is spread over.

| at 32k context | before | after |
|---|---:|---:|
| `gguf-g-26ba4b` decode | 46.7 t/s | **58.4 t/s** (+25%) |
| `gguf-g-26ba4b` prefill | 742 t/s | 691 t/s |

That last row is the trade honestly stated: f16 buys decode at long context and
costs a little prefill. The `writer` profile is the one that cares.

Two changes did that. **MTP depth is now tuned per model** rather than fixed at
3 for everything: the 35B prefers depth 1 (worth 34% there), the Gemma prefers
depth 2. `./bench/bench.sh --tune` runs the sweep and saves the winner per
model; `./install.sh` runs it by default.

**The KV cache defaults to `f16`, not `q8`.** That inverts the usual
assumption: a smaller cache saves memory bandwidth but has to be dequantised on
every token, and here the dequantisation costs more than the bandwidth saves.
Leaving it unquantised measured faster on *both* engines:

| | q8 | f16 |
|---|---:|---:|
| `gguf-g-26ba4b` at 8k | 78.2 t/s | **93.0 t/s** (+19%) |
| `gguf-g-26ba4b` at 32k | 37.0 t/s | **52.9 t/s** (+43%) |
| `mlx-q-35ba3b` at 8k | 91.2 t/s | **106.9 t/s** (+17%) |

It costs about 1 GB at 128k for these models — see
[bench/kv-from-gguf.py](bench/kv-from-gguf.py) for why that is so small — so
`./install.sh` still picks `q8` on a 16 GB Mac.

**The M5 Neural Accelerators were already on, and are worth having.** Forcing
them off costs more than half the prefill:

| | prefill | TTFT at 8k |
|---|---:|---:|
| tensor API on (auto, M5) | **1,153 t/s** | **6.98 s** |
| tensor API off | 654 t/s | 12.30 s |

Decode is unaffected, which is the shape you expect: it is a prefill win. Below
M5 there is nothing to win and llama.cpp measures the same path as slightly
slower, which is why the setting stays `auto` and the code never forces it on.

> The numbers move a lot between runs — this is a working desktop, and other
> apps steal GPU time. Individual configs measured up to 25% apart across
> repeated loads. Everything above was compared within a single interleaved run,
> best-of rather than median: two *identical* control configs scored 80.6 and
> 69.6 by median but 85.5 and 83.6 by best, so best-of is what actually ranks
> them. Treat differences under about 10% as unresolved.

### Models: uncensored only

**Every model UpinelAIOS ships or suggests is an uncensored fine-tune.**
There is no point being fast at something that will not answer.

You do not have to choose from these tables by hand. `install.sh` scans your Mac
and proposes a model and settings for it; if you would rather not have that one,
answer `n` at the prompt and it prints a numbered list of everything below, each
row marked with a verdict for *your* memory:

```
  Pick a model   this Mac has 64 GB of unified memory

    #  ALIAS             SIZE   VERDICT              NOTE
  ---  ----------------- ------ -------------------- ------------------------------
    1  gguf-g-26ba4b     15 GB  RECOMMENDED          uncensored MoE, 3B active - the fastest 26B here
    2  gguf-g-12b        8 GB   fits comfortably     dense 12B - smaller and less capable, still quick
    3  gguf-g-31b        20 GB  fits comfortably     dense 31B abliterated - the highest quality
    ...
    6  gguf-q-27b        19 GB  fits comfortably     dense 27B, ~13.5 t/s; its MTP head needs a build step
    7  gguf-q-9b         6 GB   fits comfortably     dense 9B, ~44 t/s - the MLX build is about twice this
    ...
    9  mlx-q-35ba3b      22 GB  fits comfortably     35B MoE, ~3B active - fastest here (141 t/s)
   10  mlx-q-27b-4bit    19 GB  fits comfortably     dense 27B 4-bit - the quality pick (~30 t/s)
    ...
   14  mlx-q-9b          6 GB   fits comfortably     dense 9B (~90 t/s) - only when memory is tight
  Model number:
```

`RECOMMENDED` / `fits comfortably` / `tight - expect paging` / `will not fit` are
computed from your unified memory, the model's published size, and that model's
own KV cost per token. That last number is per-model and worth knowing: the
Gemma MoE grows at ~20 KB/token because only 5 of its 30 layers keep a
per-token cache, the Qwen models are hybrid too (~20-64 KB/token, since only
every 4th layer caches), so a verdict is never just a function of size. Enter a
number to use it, or press Enter to keep the config you already have. Choosing
something that will not fit is allowed; it warns, then does what you asked.

#### Gemma 4

| alias | download | repo |
|---|---:|---|
| **`gguf-g-26ba4b`** | 15 GB | `OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF` — **default**, Q4_0 QAT, 106 t/s at short context (89 at 8k) |
| `gguf-g-e2b` | 4 GB | `HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive` — 99.9 t/s. Smallest; the only one that runs on an 8 GB Mac, and tightly at that. |
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

So **if Qwen speed is what you want, let the MLX engine serve it**: MTPLX's MTP
implementation works on Metal and llama.cpp's does not. That is why both engines
ship in this one install rather than in separate repos.

**Only one quant is downloaded.** GGUF repos often publish every quant of the
same model, and the `gguf-g-31b` repo carries ten of them — 232 GB in total,
of which the 18.7 GB `Q4_K_M` is the one that fits a Mac. Fetching the repo
wholesale would cost twelve times the disk and hours of download, so
UpinelAIOS picks a single quant (`MODEL_QUANT` in `env.conf`, default
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
./model_download.sh --switch gguf-g-12b   # download if needed, switch, restart
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

### Why Gemma runs on llama.cpp and Qwen can run on either

The MLX engine runs on **MTPLX** (MLX). Gemma 4 cannot, and the reason is
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
> shifting work. UpinelAIOS deliberately does not set it.

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

## Documentation

| doc | what is in it |
|---|---|
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | every failure mode, both engines — Metal OOM on a long prompt, swap storms, truncated tool calls, "it cannot write files" |
| [docs/GGUF-RUNTIME.md](docs/GGUF-RUNTIME.md) | llama.cpp specifics: the FastMTP draft head, why some models need a patched runtime, Q4_0 vs K-quants |
| [docs/MLX-TUNING.md](docs/MLX-TUNING.md) | MTPLX specifics: profiles, batching presets, session bank, MTP depth, thinking effort |
| [docs/CLIENTS.md](docs/CLIENTS.md) | pointing Cursor, Aider, Continue and friends at the endpoint |
| [docs/RESEARCH-MLX-STACK.md](docs/RESEARCH-MLX-STACK.md) | the MTPLX/MLX measurements this project's MLX defaults come from |
| [docs/RESEARCH-LLAMACPP-MTP.md](docs/RESEARCH-LLAMACPP-MTP.md) | the llama.cpp MTP work, and why the patched runtime exists |
| [docs/RESEARCH.md](docs/RESEARCH.md) | the original survey that started this |

---

## Benchmarks

### Measured throughput

**Measured on an M5 Pro (20-core GPU, 64 GB).** Decode is the rate once
generating; prefill is the rate ingesting the prompt; TTFT is time to first
token. Every model below is uncensored.

Every figure at **8k context**, which is what an agent actually pays, with the
tuned defaults. Decode is higher at short context and lower far out — the peak
and the 32k figure are in the notes column.

| model | decode | prefill | TTFT | when to use it |
|---|---:|---:|---:|---|
| **`mlx-q-35ba3b`** &nbsp;Qwen 3.6 35B-A3B MoE | **141 t/s** | 1,760 t/s | 4.6 s | **The fastest decode measured**, and the number in the headline. A MoE reading ~3B active per token; peaks at 8k, which is unusual and is why it wins here. |
| **`gguf-g-26ba4b`** &nbsp;Gemma 4 26B-A4B Q4_0 QAT | **89 t/s** | 1,390 t/s | 5.8 s | **The default**, and the fastest *and* highest quality llama.cpp can serve here, with vision. Peaks at 106 t/s at 512 tokens; 58 t/s at 32k. |
| `mlx-q-9b` &nbsp;Qwen 3.8 9B | 113 t/s | 1,340 t/s | 5.9 s | Nearly the speed of the 35B at a quarter of the memory. |
| `gguf-g-e2b` &nbsp;Gemma 4 E2B | 99.9 t/s `*` | 294 t/s | 1.7 s | The snappy one: fastest prefill, smallest footprint, for a small Mac or quick replies. |
| `gguf-q-35ba3b` &nbsp;Qwen 3.6 35B-A3B | 70.5 t/s `*` | 180 t/s | 2.7 s | Works, but the **MLX engine** runs this same model faster. |
| `gguf-g-e4b` &nbsp;Gemma 4 E4B | 63.9 t/s `*` | 84 t/s | 0.4 s | Only when the Mac genuinely cannot fit `gguf-g-26ba4b`. |
| `gguf-g-12b` &nbsp;Gemma 4 12B | 54.5 t/s `*` | 81 t/s | 2.6 s | The largest model that still fits a **16 GB** Mac. `gguf-g-e2b` is nearly twice as fast, so pick it for capability, not speed. |
| `gguf-q-9b` &nbsp;Qwen 3.8 9B | 44.3 t/s `*` | 130 t/s | 4.1 s | Use the **MLX** build instead — `mlx-q-9b` is about twice this. |
| `gguf-q-27b` &nbsp;Qwen 3.8 27B | 13.5 t/s `*` | 133 t/s | 9.1 s | Use the **MLX** build instead — ~2.2× faster there. |

`*` measured before the KV and depth changes, on a short prompt. Those rows have
not been re-measured, so treat them as a floor: the two that *were* re-measured
both improved, one by 59%.

**The default is not the fastest, and that is deliberate.** `gguf-g-26ba4b` at
89 t/s gives up the top of the table to `mlx-q-35ba3b`, and takes it back on
everything else: it is Google's quantization-aware Q4_0 release of a
mixture-of-experts checkpoint, so it reads only ~4B active parameters per token
and stays small enough (15 GB) to leave room for a long context — with vision,
and with an MTP draft head that turns speculation on. `mlx-q-35ba3b` cannot do
vision and has no such margin.

> TTFT above is at 8k. At short prompts per-request overhead dominates the
> figure and it looks better; the scaling table below is the honest long-context
> picture.

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

Even the pessimistic end is a usable agent endpoint, and `gguf-g-e2b` at 4.2 GB
is the right pick for a 16 GB Air. On an 8 GB one it is still the right pick —
it is simply tight, and worth reading [Requirements](#requirements) first.

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

Everything checkable without a server, in one command:

```bash
./bench/verify-all.sh
```

That runs the offline regression suites — alias resolution, the model
suggestion rule at each memory size, the on-disk picker, quant selection and
draft selection — plus a syntax check on every shell file. No model, no server,
no network. `bench/verify-tools.py` is deliberately not included: it is a
diagnostic against a live endpoint, and belongs to `./bench/verify-tools.sh`.

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

```bash
git pull
./update_env.sh       # if pull could not update env.conf for you
./restart.sh          # to run the new code
```

**If `git pull` refuses**, that is expected. `env.conf` is tracked, and editing
it is the whole point of the project, so git stops with:

```
error: Your local changes to the following files would be overwritten by merge:
        env.conf
```

Let git have its way, then put your settings back on top:

```bash
git checkout -- env.conf    # take upstream's, known good
git pull
./update_env.sh             # your values, this version's file
./restart.sh
```

`./update_env.sh` takes the shipped `env.conf` — every new key, every new
comment, every changed default — and puts your values back into it:

```
  New settings this checkout adds (shipped defaults)
    EXPERT_PROFILE             "speed"

  Your settings (yours is kept either way)
    KV_QUANT                   "q8_0"  (this version ships "f16")
    MODEL                      "mlx-q-9b"  (this version ships "gguf-g-26ba4b")
    THINKING                   "medium"  (this version ships "low")
```

That second block is the reason the script exists. A setting whose *default*
changed keeps behaving the old way if you never hear about it — that is how a
machine ends up on the slower KV quantisation for months with nothing to show
for it. Yours is kept either way; you just get told.

It backs `env.conf` up first, is safe to run twice, and `--dry-run` shows the
diff without touching anything. If you would rather do it by hand, the old
recipe still works — but it can only restore the keys your file already had, so
anything added since is silently missing:

```bash
git stash push -m "my settings" -- env.conf
git pull
git stash pop       # conflict here means: take theirs, then re-apply yours
./restart.sh
```

> A conflicted `env.conf` with `<<<<<<<` markers in it breaks every script that
> sources it. If that happens, `git checkout HEAD -- env.conf` and start again
> with `./update_env.sh`.

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

**UpinelAIOS is © 2026 Nova Upinel Chow, released under the
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

> **One licence file, both engines.** `LICENSE` is byte-identical to the one
> the MLX edition carried before it was folded in, and its scope clause covers
> both engines, so you never have to work out which terms apply to which part
> of the install. To confirm it has not drifted:
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
