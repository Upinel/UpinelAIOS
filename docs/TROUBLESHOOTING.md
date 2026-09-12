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

### The other variant: `missing required property "description"`

Same error message, **different cause**, and the fix is different too.

Some tool schemas require a human-readable label alongside the real payload — a
`description` next to a `command`. Models routinely treat that as optional
metadata and simply skip it, even though the schema marks it required. The call
is well-formed JSON with a field missing, so it is not a truncation and raising
`max_tokens` will not help.

Measured on this machine, six runs each, asking for the same command:

| system prompt | `description` included |
|---|---:|
| *"You are a coding agent."* | **1/6** |
| *"Every tool call MUST include every required field."* | 5/6 |
| *"…always supply both `command` and `description`."* | **6/6** |

**Naming the fields explicitly in the agent's system prompt fixes it.** Marking
the label optional in the tool schema also resolves it, if you control the
schema.

How to tell the two apart:

| symptom | `finish_reason` | cause | fix |
|---|---|---|---|
| arguments unparseable, ends mid-string | `length` | truncated | raise `max_tokens` |
| arguments valid JSON, a field absent | `tool_calls` | model omitted it | name it in the prompt |

`./bench/verify-tools.sh` reports both: check 3 measures the budget a file write
needs, and check 4b runs five trials against an advisory required field.

## Everything is slower than the README numbers

Check, in order:

1. **`ENABLE_VISION=1`?** Loading the vision tower costs ~24% of decode speed
   and roughly 5x the first-token latency, even for text-only requests. Measured
   88.7 t/s off against 67.8 t/s on.
2. **Is `MTP_DEPTH` right?** Depth 1 is the measured optimum. Depth 3 looks
   faster on very short prompts and collapses past 8k context.
3. **How long is your context?** 88 t/s at 512 tokens, 66 at 8k, 39–50 at 32k.
   This is expected, not a misconfiguration.
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

## Reporting a problem upstream

Include `llama-server --version`, your model, and the relevant part of
`run/server.log`. For tool-calling issues, the output of `./bench/verify-tools.sh`
contains everything needed.
