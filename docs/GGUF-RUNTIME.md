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
# The GGUF runtime, and the FastMTP patch

UpinelAIOS runs everything through **llama.cpp**. That is a deliberate
constraint rather than a limitation we have not got around to: llama.cpp is the
only runtime that can serve an uncensored Gemma 4 at all, and it serves every
other GGUF equally well, which is why the Qwen family lives here too.

One thing needs saying plainly, because it costs a factor of three on the 27B.

## The Qwen 27B MTP head needs a patched llama.cpp

HauhauCS publishes `Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf`
as the MTP draft head for the 27B. It is a genuine speed win — the same model
through MTPLX in the sister project runs 2.6–3.4x faster with MTP than without.

It does **not** work on a stock llama.cpp. Its provenance file says so:

```
runtime_base:  ggerganov/llama.cpp@4df29be4f4c3673f428170fda944a5b19f743bb8
runtime_patch: HauhauCS-FastMTP-llama.cpp.patch
```

That 53-line patch adds a `d2t` tensor: the drafter's output vocabulary is
**trimmed** from 248,320 tokens to 32,768, and `d2t` remaps between them. Stock
llama.cpp does not know the tensor, compares the trimmed output against the full
vocabulary, and refuses:

```
error loading model: check_tensor_dims: tensor 'output.weight' has wrong shape;
  expected 5120, 248320, got 5120, 32768
```

**And llama-server treats a failed draft as fatal.** It does not fall back — it
exits. So attaching that head on a stock build does not cost you speed, it
stops the server booting.

### What UpinelAIOS does about it

It detects the `d2t` tensor in the draft's GGUF and, unless you tell it
otherwise, **skips the draft and runs autoregressive**, printing why:

```
warn Qwen3.8-27B-...-FastMTP-32K.gguf needs a patched llama.cpp (trimmed draft vocab).
warn Running autoregressive to keep the server up.
```

Detection is on the tensor, not the filename, so any future head built the same
way is caught too. `model_draft_gguf` and `draft_needs_patched_runtime` in
`lib/common.sh` do the work.

### What it actually buys, measured

Built 2026-08 on the reference machine and measured before and after. This is
the whole picture, including the part that is worse:

**Qwen 27B (`gguf-q-27b`), same prompts, greedy-ish, median of five:**

| runtime | draft | decode | acceptance |
|---|---|---:|---:|
| stock Homebrew | none | 7.6 t/s | — |
| patched | none | 8.4 t/s | — |
| **patched** | **FastMTP depth 1** | **15.4 t/s** | **77%** |
| patched | FastMTP depth 3 | 10.6 t/s | 53% |
| patched | FastMTP depth 5 | 8.1 t/s | 40% |

**Depth 1, not 3.** Acceptance collapses with depth (77% → 53% → 40%), so
drafting further costs more than it returns. That is the opposite of the
Gemma MTP head, where depth 3 wins — different head, different profile, and
worth re-measuring rather than assuming.

So the honest number is **2.0x, 7.6 → 15.4 t/s**, not the ~3x the MTPLX side
gets. Real, but short of what MTP achieves on Metal through MLX.

**Gemma 26B-A4B (`gguf-g-26ba4b`), `llama-bench`, same machine:**

| runtime | prefill | decode |
|---|---:|---:|
| stock Homebrew | 1924.7 t/s | **81.0 t/s** |
| patched | 1888.1 t/s | 78.7 t/s |

**The patched build makes Gemma slower** — about 2% on prefill, 3% on decode.
Expected in hindsight: the patch only touches `src/models/qwen35.cpp`, so it
gives Gemma nothing, while pinning the build to an older upstream commit
(build 10454 against the current 10809) loses whatever landed since.

So the two runtimes coexist rather than one replacing the other. `LLAMA_SERVER`
in `env.conf` points at the patched binary when you want it; leaving it empty
uses the Homebrew build, which is the right default for Gemma and for every
Qwen model without a FastMTP head.

### Turning it on


If you want the speed, build llama.cpp with the patch. One command does the
whole thing — clone, verify, patch, build, and record the result in `env.conf`:

```bash
./lib/build-fastmtp.sh
```

It refuses to build if the patch checksum does not match the provenance file
alongside it, and it works on a CommandLineTools-only machine (no full Xcode):
without the Metal compiler, shaders are compiled at runtime instead of embedded.

The patch ships inside the model repo you already downloaded:

```
models/HauhauCS--Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF/
  HauhauCS-FastMTP-llama.cpp.patch
  FastMTP-PROVENANCE.json
  HauhauCS-FastMTP-Ed25519-PUBLIC.pem
```

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
git checkout 4df29be4f4c3673f428170fda944a5b19f743bb8     # the patch's base
git apply /path/to/HauhauCS-FastMTP-llama.cpp.patch
git apply --check   # ...before applying for real, so a mismatch is loud
```

Verify the patch before trusting it — the repo signs it, and the signature is
worth checking rather than taking on faith:

```bash
shasum -a 256 HauhauCS-FastMTP-llama.cpp.patch
# compare against runtime_patch_sha256 in FastMTP-PROVENANCE.json
```

Then point the server at your build and tell it the draft is usable:

```bash
LLAMA_SERVER=/path/to/llama.cpp/build/bin/llama-server   # or put it on PATH
DRAFT_PATCHED_RUNTIME=1                                   # in env.conf
./restart.sh
```

`DRAFT_PATCHED_RUNTIME=1` only says "this head is loadable" — it does not build
anything. With it set on a stock runtime, the server will exit, exactly as it
does today when the head is attached by hand.

## Why this matters less than it sounds

The unpatched 27B runs at **7.6 t/s** here. That is not a bug: a dense 27B reads
about 15 GB of active weights per token, and ~7.6 t/s is what this memory
bandwidth supports. The Qwen 27B is a *dense* model — every parameter is active
on every token — unlike the Gemma 26B A4B, which is a mixture of experts with
only ~4B active and reaches 106 t/s for exactly that reason.

So the two families are not comparable on speed and should not be sold as if
they are:

| model | shape | active per token | decode here (GGUF) | MLX |
|---|---|---:|---:|---:|
| `gguf-g-26ba4b` (Gemma 4) | MoE, 8 of 128 experts | ~4B | **106.4 t/s** | — |
| `gguf-q-9b` | dense | 9B | 44.3 t/s | 65.1 t/s |
| `gguf-q-27b` | dense | 27B | 13.5 t/s | 34.7 t/s |

If you want Qwen 27B speed, the honest answer is the **MLX engine**: MTPLX's MTP
implementation works on Metal and llama.cpp's does not. Both engines ship in
this one install, so switching is a model change rather than a switch of repo.
