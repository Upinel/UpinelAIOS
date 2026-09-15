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
# Troubleshooting

## First move, always

```bash
./status.sh                    # live dashboard: CPU, GPU, memory, activity
./status.sh --once             # same thing as a plain summary
./bench/verify-tools.sh        # is tool calling working, and how big is a call?
tail -n 60 run/server.log      # what the server actually said
```

## `invalid arguments: missing required property "file_path"`

**This is almost always a truncated tool call, not a broken schema.** Run the
diagnostic; it measures the real number instead of guessing:

```bash
./bench/verify-tools.sh
```

The mechanism: a file write carries the **entire file inside the tool call's
arguments**. A 1,500-character Python file is roughly 500 tokens of JSON. If the
client's `max_tokens` is smaller than that, the arguments are cut off mid-string,
the agent receives an incomplete object, and it reports the first required
property it cannot find — which is `file_path`, because that is the property it
looks for first.

Measured on the reference machine:

```
  3. Large tool call  (this is the one agents hit)
  [PASS] complete file write returned
         538 tokens used, 1467 chars of file content
         -> give agents at least 538 max_tokens for writes this size

  4. Reproducing the failure with a small budget
  [PASS] max_tokens=134 truncates the call (expected)
```

**The fix is client-side.** Raise your agent's `max_tokens`. Budget for the tool
call plus anything the model generates before it:

| what the agent writes | tool call costs | set `max_tokens` to |
|---|---:|---:|
| a one-line file | ~60 tokens | 512 |
| a short script | ~500 tokens | 2048 |
| a full module | ~1,500 tokens | 4096 |

`MAX_RESPONSE_TOKENS` in `env.conf` is the server's ceiling, not a floor. It does
not stop a client from asking for less, and it cannot rescue a call the client
already truncated.

Also worth setting `THINKING="off"`: thinking tokens come out of the same budget.

### The other variant: a field the model decided was optional

Same error message, **different cause**, and the fix is different too.

Some tool schemas require a field alongside the real payload — a `description`
next to a `command`, a boolean next to a path. Models routinely treat those as
optional metadata and simply skip them, even though the schema marks them
required. The call is well-formed JSON with a field missing, so it is not a
truncation and raising `max_tokens` will not help.

This is **not** specific to `description`, and it is **not** an ordering problem.
Rotating the same five-field schema so the dropped field sat first, second and
last produced the same omission at every position:

```
  Omitted field by SCHEMA POSITION (9 trials, field rotated each time):
    pos1/5 'capture_output': 3
    pos2/5 'capture_output': 3
    pos5/5 'capture_output': 3
```

The model honours the schema's *semantics* and ignores its `required` list. It
keeps what it needs to do the job (`command`, `file_path`) and silently discards
what it judges defaultable (`capture_output`, `timeout`, `workdir`). The more
required fields a harness declares, the more it loses — which is why a large
agent tool set fails far more often than a minimal test schema.

Measured on Gemma-4-26B-A4B, 9 trials each, on a five-field schema:

| approach | complete calls |
|---|---:|
| plain system prompt | 6/9 |
| *"Every tool call MUST include every required field."* | **3/9** ← actively worse |
| naming the required fields in the prompt | 9/9 |
| **`TOOL_TEMPLATE=1` (the shipped fix)** | **30/30** |

Note the middle row. A generic reminder makes it *worse*: it makes the model
deliberate about required-ness without telling it which fields are required.
Only naming the fields works.

**The fix is server-side and on by default.** `start.sh` reads the model's own
`tokenizer.chat_template` out of the GGUF, injects a short per-tool reminder
listing that tool's required fields, and passes the result to llama-server as
`--chat-template-file`:

```
All of the following fields are MANDATORY in every bash call and must never be
omitted, even when a value seems obvious or optional: command, description,
timeout, workdir, capture_output.
```

Because it is generated from the tool schemas in each request, it names the
right fields for whatever harness you point at it — no client changes, no
per-agent prompt engineering. It costs ~400 characters of system prompt and
nothing at runtime.

Controls, in `env.conf`:

```bash
TOOL_TEMPLATE=1     # 0 restores the model's stock template
```

`lib/tools-template.py` does the work and can also be run standalone; it exits
non-zero rather than writing a template it could not patch, so a startup failure
degrades to the stock template instead of a broken one. Check
`run/template.err` if the startup banner mentions it.

How to tell the two apart:

| symptom | `finish_reason` | cause | fix |
|---|---|---|---|
| arguments unparseable, ends mid-string | `length` | truncated | raise `max_tokens` |
| arguments valid JSON, a field absent | `tool_calls` | model omitted it | already handled by `TOOL_TEMPLATE=1`; name the fields in the prompt if you set it to 0 |

`./bench/verify-tools.sh` reports both: check 3 measures the budget a file write
needs, and check 4b runs five trials against an advisory required field.

## "internal server error" on a long prompt   (MLX)

Symptom: a request with a very large prompt returns HTTP 500 after several
minutes with

```json
{"error":{"message":"internal server error; see the MTPLX server log","type":"server_error"}}
```

Find the request id in the response and grep the log for it. If you see:

```
[METAL] Command buffer execution failed: Insufficient Memory
(00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory).
```

this is a **Metal command-buffer allocation failure, not a system RAM
shortage.** macOS caps how much a single Metal command buffer may allocate, and
a very long prefill can exceed it. Freeing system memory will not help; the
allocator ceiling is the constraint.

Levers, in order:

1. **Lower `PREFILL_CHUNK_TOKENS`** (try `1024`) so prefill runs in smaller
   Metal allocations instead of one large one. This is the direct fix. The
   setting is translated per engine - llama.cpp gets 512, MLX 2048 - and
   `auto` uses those.
2. **Raise `MEMORY_LIMIT_GB`.** Counterintuitive, but if MLX's own ceiling sits
   below what the prefilled batch needs, raising it gives Metal room. Do not
   push it past ~85% of physical RAM.
3. **Raise the macOS wired ceiling** with `WIRED_LIMIT_GB` - and read the
   warning in `env.conf` first. A hard-killed process can leak wired pages
   until reboot.

Observed on the reference machine (M5 Pro, 64 GB, desktop session running):
prompts up to ~93k tokens prefill successfully, a single ~131k-token prefill
fails with this error. **Incremental context growth works** - an agent that
builds a 128k conversation turn by turn is reusing cached prefixes, not
prefilling 131k in one go.

## Swap storm, or the machine becomes unresponsive   (MLX)

`vm_stat` shows `Pages wired down` approaching physical RAM and swap fills.
MTPLX's session bank is usually the cause: it auto-sizes to *half the
post-model RAM surplus* (16.6 GB on a 64 GB Mac with a 48 GB cap).

```conf
SESSION_BANK_GB=8      # was auto; 8 is a good balance
MLX_CACHE_LIMIT_GB=4   # tighten further if still swapping
MEMORY_LIMIT_GB=44     # or lower the overall ceiling
```

Restart with `./restart.sh`. **Always stop gracefully** - `SIGTERM`, not
`kill -9`. A process holding a large wired MLX allocation that is hard-killed
may leak those pages at the kernel level until the machine reboots.
`./stop.sh --force` exists, but it is a last resort.

## Everything is slower than the README numbers

Check, in order:

1. **`ENABLE_VISION=1`?** Loading the vision tower costs ~24% of decode speed
   and roughly 5x the first-token latency, even for text-only requests. Measured
   88.7 t/s off against 67.8 t/s on.
2. **Is `MTP_DEPTH` right?** Depth 1 is the measured optimum. Depth 3 looks
   faster on very short prompts and collapses past 8k context.
3. **How long is your context?** Decode is broadly flat once context is past a
   few thousand tokens, but prefill is not: 1,058 t/s at 2k against 461 t/s at
   32k, which is what makes the first turn of a long conversation slow. This is
   expected, not a misconfiguration.
4. **Is macOS under memory pressure?** `vm_stat | grep -i wired` and
   `sysctl vm.swapusage`. If `free` is under ~3 GB you are paging.
5. **Are you re-prefilling every turn?** llama.cpp caches prefixes, but only if
   the client keeps them stable. An agent that rewrites its system prompt or
   injects a timestamp every turn throws the cache away and pays full prefill.

## The dashboard shows "display error"

The dashboard reports a rendering fault instead of exiting and writes the
traceback to `run/dashboard.err`. This is deliberate: a bug in one panel should
not kill the tool you are using to watch a server. Include that file if you
report it. Restarting `./status.sh` clears it; nothing else is affected.

## The server will not start

```bash
./start.sh --print       # the exact command it would run
tail -n 40 run/server.log
```

| Symptom | Cause |
|---|---|
| `Port ... already in use` | Another server holds the port. `./stop.sh` finds and stops it. |
| `No model weights found` | Not downloaded. Run `./install.sh` or `./model_download.sh`. |
| `Insufficient Memory` | Lower `CONTEXT_WINDOW`, set `KV_QUANT="q4_0"`, or lower `BATCH_SIZE`. |
| `Plan needs ~X GB but this Mac has Y` | The memory check refused before loading. Lower the context. |

## Output loops, or the model will not stop

This is a known pathology of reasoning models on repetitive input.

```conf
THINKING="off"
```

## "The model cannot create or write files"   (both engines)

**Start here:** run the diagnostic.

```bash
./bench/verify-tools.sh
```

It checks everything an agent needs - non-streaming tool calls, streaming
tool-call deltas with indexes, argument JSON assembly, the multi-turn tool
result round-trip, and the Anthropic `/v1/messages` `tool_use` shape. If it
passes, the endpoint is fine and the problem is on the client side.

**Understand what the model can and cannot do.** A language model has no
filesystem. It cannot write a file; it can only *ask* the client to write one
by emitting a tool call. Something else - your agent harness - has to receive
that call and perform it. If you ask the model directly in a chat box to
"create a file", the correct behaviour is for it to describe the file, not to
create it. That is not a bug.

So when file writing does not work, the failure is almost always one of these:

| Check | How to confirm |
|---|---|
| The agent was never given a write tool | Look at the tools list in the agent's request. No `write_file`-style tool means nothing to call. |
| The agent is pointed at the wrong endpoint | It should be the base URL from `./status.sh`, ending in `/v1`, with the API key. |
| The agent only supports hosted providers | Some tools ignore tool calls from a local OpenAI-compatible endpoint. Check its provider docs. |
| The reply is being truncated | If the tool call is cut off, arguments arrive as invalid JSON. See below. |
| A middle layer strips tool calls | Proxies, gateways, and "OpenAI-compatible" shims sometimes drop `tool_calls`. |

### The truncation trap, which is the one that bites

Tool calls are emitted as tokens like any other output, and they are emitted
**after** any thinking block. With `THINKING="low"` a model can spend several
hundred tokens reasoning before it starts writing the call, and if the client's
`max_tokens` is small the call is cut off mid-JSON. The client then sees an
unparseable tool call and reports that the model "failed".

```conf
THINKING="off"
```

is the fix, and it is the right setting for a tool-calling loop anyway: it is
faster, and it removes the truncation risk. If you want to keep thinking on,
give the agent a generous `max_tokens` (2048+) instead.

The diagnostic prints this hint automatically when it sees a malformed
`arguments` string or a `finish_reason` other than `tool_calls`.

## Reporting a problem upstream

Include `llama-server --version`, your model, and the relevant part of
`run/server.log`. For tool-calling issues, the output of `./bench/verify-tools.sh`
contains everything needed.
