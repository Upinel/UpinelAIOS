#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Nova Upinel Chow, MSc, LLM, BBA, MENSA  ·  upinel@me.com  ·  upinel.com
#  Copyright (c) 2026 Nova Upinel Chow. All rights reserved.
#
#  Upinel Personal Free License: free for personal use, commercial use by
#  written permission, and anything built from this must credit the author.
#  See LICENSE.
#
#  "Make it work, make it right, make it fast - then measure it, because
#   the third one is only a claim until the numbers agree."
# ─────────────────────────────────────────────────────────────────────────────
"""Agent-realistic benchmark for UpinelAIOS-GGUF.

Why not bench/bench.sh
---------------------
A raw throughput benchmark measures a short prompt and a long generation. An
agent does neither: it sends a large tool-laden system prompt, a long history
of tool results, and then generates a *short* tool call. Almost all of its
wall-clock time is prefill, and prefill is the thing that degrades with
context length.

So this measures what an agent actually experiences:

  ttft      time to first token - what the user waits for
  prefill   prompt tokens/second, the dominant cost at long context
  decode    tokens/second once generating
  cache_n   tokens reused from the slot's KV cache, i.e. work not repeated

A multi-turn agent re-sends the same growing prefix every turn. If the server
reuses it, turn N does not repay the cost of turns 1..N-1. That reuse is the
single biggest lever on agent latency, so this measures it explicitly.

Usage
-----
    python3 bench/agent-bench.py --model Upinel-AIOS-GGUF
    python3 bench/agent-bench.py --depths 2048,8192,32768 --turns 3
    python3 bench/agent-bench.py --json out.json
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

# ── a realistic agent tool set ───────────────────────────────────────────────
# Not decorative: a real harness ships a couple of dozen schemas, and their
# size is part of the prompt an agent pays for on every single turn.

def _tool(name, desc, props, required):
    return {"type": "function", "function": {
        "name": name, "description": desc,
        "parameters": {"type": "object",
                       "properties": {k: v for k, v in props},
                       "required": required}}}


_S = {"type": "string"}
_I = {"type": "integer"}
_B = {"type": "boolean"}

TOOLS = [
    _tool("read_file", "Read a file from disk and return its contents.",
          [("file_path", _S), ("offset", _I), ("limit", _I)], ["file_path"]),
    _tool("write_file", "Write content to a file, creating it if needed.",
          [("file_path", _S), ("content", _S), ("encoding", _S), ("overwrite", _B)],
          ["file_path", "content"]),
    _tool("edit_file", "Replace an exact string in a file.",
          [("file_path", _S), ("old_string", _S), ("new_string", _S), ("replace_all", _B)],
          ["file_path", "old_string", "new_string"]),
    _tool("bash", "Run a shell command and return its output.",
          [("command", _S), ("description", _S), ("timeout", _I), ("workdir", _S)],
          ["command"]),
    _tool("glob", "Find files whose paths match a glob pattern.",
          [("pattern", _S), ("path", _S)], ["pattern"]),
    _tool("grep", "Search file contents with a regular expression.",
          [("pattern", _S), ("path", _S), ("include", _S)], ["pattern"]),
    _tool("list_dir", "List the entries of a directory.",
          [("path", _S), ("recursive", _B)], ["path"]),
    _tool("web_search", "Search the web and return result URLs.",
          [("queries", {"type": "array", "items": _S})], ["queries"]),
    _tool("web_fetch", "Fetch a URL and return it as text.",
          [("url", _S)], ["url"]),
    _tool("todo_write", "Record or update the task list.",
          [("todos", {"type": "array", "items": {"type": "object"}})], ["todos"]),
    _tool("git_status", "Show the working tree status.",
          [("path", _S)], []),
    _tool("git_diff", "Show changes in the working tree.",
          [("path", _S), ("staged", _B)], []),
    _tool("git_commit", "Commit staged changes.",
          [("message", _S), ("files", {"type": "array", "items": _S})], ["message"]),
    _tool("run_tests", "Run the project's test suite.",
          [("path", _S), ("filter", _S)], []),
    _tool("lint", "Run the linter over a path.",
          [("path", _S), ("fix", _B)], []),
    _tool("python_repl", "Evaluate Python and return the result.",
          [("code", _S)], ["code"]),
]

SYSTEM = (
    "You are a coding agent working in a repository. Use the tools available "
    "to inspect and modify files. Prefer reading before writing. Keep replies "
    "short. When you have finished the task, state what changed.\n"
)

# Text that tokenises like real agent context: prose, code, logs and tool
# results interleaved, rather than one repeated word (which would compress
# unrealistically and flatter both prefill and decode).
_FILLER = (
    "The previous command completed successfully. Output follows.\n"
    "src/handlers/request.py:142: in handle_request\n"
    "    result = await dispatch(ctx, payload)\n"
    "  File \"/app/src/core/dispatch.py\", line 88, in dispatch\n"
    "    return await route(handler, ctx)\n"
    "ValueError: unexpected payload key 'retry_after'\n"
    "Checked 412 files, 37 test cases, 0 failures, 2 skipped in 4.31s.\n"
    "Reading configuration from /etc/upinel/service.toml\n"
    "    [server]\n    host = \"0.0.0.0\"\n    port = 8000\n"
    "The function iterates over each record, validating the schema before\n"
    "appending it to the output buffer. Records failing validation are\n"
    "collected separately and reported at the end of the pass so that a\n"
    "single bad row does not abort the whole batch.\n"
)


def build_messages(target_tokens, turns, nonce=""):
    """Approximate an agent conversation of roughly target_tokens.

    `nonce` is prepended to the system message. It must be unique per sample:
    llama.cpp reuses the slot's KV cache for a shared prefix, so re-sending an
    identical prompt measures a cache hit (prompt_n=1) and reports a prefill
    rate for a single token. A one-word change at the front invalidates the
    whole prefix and forces a genuine cold prefill.
    """
    # ~4 characters per token is close enough for sizing the fixture.
    budget = max(0, target_tokens - len(SYSTEM) // 4)
    head = (f"Session {nonce}.\n" if nonce else "") + SYSTEM
    msgs = [{"role": "system", "content": head + "\n" + agent_tools_text()}]
    used = len(msgs[0]["content"]) // 4

    turn = 0
    while used < budget and turn < 200:
        msgs.append({"role": "user", "content":
                     f"Continue the task. Step {turn + 1}. " + _FILLER})
        msgs.append({"role": "assistant", "content":
                     "I will inspect the relevant files and report back. " + _FILLER})
        used += (len(_FILLER) * 2) // 4
        turn += 1

    # A short final instruction: agents end with a small ask and a small reply.
    msgs.append({"role": "user", "content":
                 "Summarise what you found in one line."})
    return msgs, used


# Deterministic, self-sustaining output. A short reply makes the decode rate a
# measurement of 30 tokens and nothing else; a counting task produces a stable
# 200, so the rate means something.
#
# Caveat: counting is *extremely* predictable, so a draft model accepts almost
# every token and deep MTP looks better than it is. Use CODE_ASK when the
# question is "how much does depth actually buy on real output".
LONG_ASK = ("Write the integers from 1 to 200, one per line, with no other "
            "text, no numbering beyond the number itself, and no commentary.")

CODE_ASK = (
    "Write a Python module implementing a small LRU cache class. It should "
    "support get, put, and a max_size constructor argument, evict the least "
    "recently used entry when full, and use a doubly linked list for O(1) "
    "operations. Include docstrings and type hints. Output only the code."
)


def build_long_messages(target_tokens, nonce="", ask=None):
    """A large prompt that asks for a long, deterministic generation."""
    msgs, used = build_messages(target_tokens, 0, nonce)
    msgs[-1] = {"role": "user", "content": ask or LONG_ASK}
    return msgs, used


def agent_tools_text():
    """The tool declarations as they appear in an agent's system prompt."""
    out = ["Available tools:"]
    for t in TOOLS:
        fn = t["function"]
        req = fn["parameters"]["required"]
        out.append(f"- {fn['name']}: {fn['description']} "
                   f"required={','.join(req) if req else 'none'}")
    return "\n".join(out)


def call(base, key, body, timeout):
    req = urllib.request.Request(
        base + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": "Bearer " + key})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.loads(r.read())
    return d, time.time() - t0


def measure(base, key, model, messages, max_tokens, timeout,
            greedy=True, temp=None):
    # Greedy by default. Speculative decoding acceptance depends on what the
    # model actually emits, so random sampling makes every throughput number
    # move by 10-20% between runs and makes configs look different when they
    # are not. Greedy makes a comparison meaningful.
    #
    # But greedy also makes draft acceptance 100%, which flatters deep MTP.
    # Pass temp to sample realistically; the seed stays fixed so runs remain
    # comparable.
    body = {"model": model, "max_tokens": max_tokens, "messages": messages}
    if greedy:
        body.update({"temperature": 0, "top_k": 1, "top_p": 1, "seed": 1})
    elif temp is not None:
        body.update({"temperature": temp, "seed": 1})
    d, wall = call(base, key, body, timeout)
    tm = d.get("timings") or {}
    return {
        "prompt_n": tm.get("prompt_n", 0),
        "cache_n": tm.get("cache_n", 0),
        "prompt_s": tm.get("prompt_per_second") or 0.0,
        "decode_s": tm.get("predicted_per_second") or 0.0,
        "predicted_n": tm.get("predicted_n", 0),
        "ttft_s": (tm.get("prompt_ms") or 0) / 1000.0,
        "wall_s": wall,
        "draft_n": tm.get("draft_n", 0),
        "draft_ok": tm.get("draft_n_accepted", 0),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default=os.environ.get(
        "UPINEL_BASE", "http://127.0.0.1:8000/v1"))
    ap.add_argument("--key-file", default="run/api-key")
    ap.add_argument("--model", default=os.environ.get("UPINEL_MODEL", "Upinel-AIOS-GGUF"))
    ap.add_argument("--depths", default="2048,8192,32768")
    ap.add_argument("--turns", type=int, default=2,
                    help="extra turns per depth, to measure KV reuse")
    ap.add_argument("--max-tokens", type=int, default=48)
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--json", help="write raw results here")
    args = ap.parse_args()

    key = open(args.key_file).read().strip()
    depths = [int(x) for x in args.depths.split(",") if x.strip()]
    results = []

    print(f"\n  Agent benchmark   model={args.model}   base={args.base}")
    print(f"  tools={len(TOOLS)}   max_tokens={args.max_tokens}   "
          f"turns/depth={args.turns + 1}\n")
    print("  target     actual   prefill t/s   TTFT s    decode t/s   reused")
    print("  --------   ------   -----------   -------   ----------   ------")

    for depth in depths:
        msgs, approx = build_messages(depth, args.turns)
        # Turn 0 is cold-ish; later turns re-send the same prefix plus a little.
        for turn in range(args.turns + 1):
            if turn:
                msgs = msgs + [
                    {"role": "assistant", "content":
                     "The dispatch layer rejects unexpected keys. " + _FILLER[:400]},
                    {"role": "user", "content": f"Turn {turn}: continue."},
                ]
            try:
                r = measure(args.base, key, args.model, msgs,
                            args.max_tokens, args.timeout)
            except Exception as e:                              # noqa: BLE001
                print(f"  ERROR at depth {depth} turn {turn}: {type(e).__name__}: {e}")
                break
            r.update({"target": depth, "turn": turn})
            results.append(r)
            tag = f"  {depth:8d}" if turn == 0 else "          "
            print(f"{tag}   {r['prompt_n']:6d}   {r['prompt_s']:11.1f}   "
                  f"{r['ttft_s']:7.2f}   {r['decode_s']:10.1f}   {r['cache_n']:6d}"
                  + ("   <- turn %d" % turn if turn else ""))

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=2)
        print(f"\n  raw results -> {args.json}")

    # A short verdict, so the number people act on is unambiguous.
    if results:
        first = results[0]
        worst = max(results, key=lambda r: r["ttft_s"])
        print(f"\n  worst turn: {worst['ttft_s']:.2f}s TTFT at "
              f"{worst['prompt_n']} prompt tokens "
              f"({worst['prompt_s']:.0f} t/s prefill)")
        reused = [r for r in results if r["cache_n"] > 0]
        if reused:
            print(f"  KV reuse working: {len(reused)}/{len(results)} turns "
                  f"reused a prefix (best {max(r['cache_n'] for r in reused)} tokens)")
        else:
            print("  KV reuse: NO reuse observed - every turn re-prefills "
                  "from scratch. This is the dominant agent cost.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
