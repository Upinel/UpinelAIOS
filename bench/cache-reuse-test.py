#!/usr/bin/env python3
"""Measure KV reuse when an agent's prompt diverges instead of appending.

Why this matters
----------------
bench/agent-bench.py covers the happy path: every turn appends, the prefix is
identical, and the server reuses the whole thing (tens of thousands of tokens
of cache hit, sub-second TTFT). Real harnesses are messier. Any of these
changes something *early* in the prompt while leaving the rest identical:

  - a system prompt that gains or loses a line (a tool appears, a mode flips)
  - history that gets re-rendered with different ordering or spacing
  - a tool result that is truncated, edited, or elided once it grows
  - a compaction pass that rewrites the oldest messages

When that happens llama.cpp can only reuse the cache up to the first differing
token; everything after it is re-prefilled even though the text is byte-for-byte
the same. `--cache-reuse N` lets it keep matching chunks past the divergence
and re-prefill only the changed region.

This measures four shapes against the running server:

  append     nothing changed, new content at the end   (the happy path)
  early      one word changed near the start
  middle     one word changed around the middle
  late       one word changed near the end

cache_n is the number of prompt tokens the server reused. If `early` and
`middle` show small cache_n, the server is re-prefilling most of the prompt.

Usage
-----
    python3 bench/cache-reuse-test.py --depth 8192
    python3 bench/cache-reuse-test.py --depth 8192 --json /tmp/cache.json
"""

import argparse
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

_spec = importlib.util.spec_from_file_location(
    "agent_bench", os.path.join(HERE, "agent-bench.py"))
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)


def perturb(messages, where):
    """Change one word in the history, leaving the length roughly identical."""
    msgs = [dict(m) for m in messages]
    # Only touch the conversation body, never the system prompt: a system change
    # is a different experiment (it invalidates everything by design).
    body = [i for i, m in enumerate(msgs) if m["role"] != "system"]
    if not body:
        return msgs

    if where == "early":
        i = body[0]
    elif where == "middle":
        i = body[len(body) // 2]
    elif where == "late":
        i = body[-1]
    else:
        return msgs

    text = msgs[i]["content"]
    # Swap a common word for a same-length-ish one so token counts barely move.
    if "the" in text:
        text = text.replace("the", "a", 1)
    else:
        text = text + " (revised)"
    msgs[i]["content"] = text
    return msgs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--key-file", default=os.path.join(REPO, "run", "api-key"))
    ap.add_argument("--model", default="Upinel-AIOS-G")
    ap.add_argument("--depth", type=int, default=8192)
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--json")
    args = ap.parse_args()

    key = open(args.key_file).read().strip()
    url = args.base
    base_msgs, approx = ab.build_messages(args.depth, 0)

    print(f"\n  KV reuse under prompt divergence   (~{approx} tokens of history)")
    print("  ------------------------------------------------------------")
    print("  shape     prompt_n   reused    TTFT s   prefill t/s")

    results = []
    for where in ("append", "early", "middle", "late"):
        # Re-prime the slot with the base prompt before every variant, using a
        # fresh nonce so the priming is itself a genuine cold prefill. Without
        # this, each variant is compared against the *previous variant*, so the
        # measured divergence is just whichever pair happens to differ first -
        # which says nothing about where the edit actually landed.
        nonce = f"{where}-{os.getpid()}-{int(time.time() * 1000) % 1000000}"
        cold_msgs, _ = ab.build_messages(args.depth, 0, nonce)
        try:
            ab.measure(url, key, args.model, cold_msgs, 4, 600, greedy=True)
        except Exception as e:                                  # noqa: BLE001
            print(f"  {where:9s} priming failed: {type(e).__name__}")
            continue

        if where == "append":
            msgs = cold_msgs + [{"role": "user",
                                 "content": "One more question: summarise."}]
        else:
            msgs = perturb(cold_msgs, where)
        try:
            r = ab.measure(url, key, args.model, msgs,
                           args.max_tokens, 600, greedy=True)
        except Exception as e:                                  # noqa: BLE001
            print(f"  {where:9s} ERROR {type(e).__name__}: {e}")
            continue
        r["shape"] = where
        results.append(r)
        print(f"  {where:9s} {r['prompt_n']:8d}   {r['cache_n']:7d}   "
              f"{r['ttft_s']:7.2f}   {r['prompt_s']:9.1f}")

    if results:
        app = next((r for r in results if r["shape"] == "append"), None)
        worst = max(results, key=lambda r: r["ttft_s"], default=None)
        print()
        if app and worst and worst["shape"] != "append":
            print(f"  appending costs {app['ttft_s']:.2f}s TTFT; "
                  f"editing the {worst['shape']} part of the history costs "
                  f"{worst['ttft_s']:.2f}s "
                  f"({worst['ttft_s'] / max(app['ttft_s'], 1e-6):.0f}x more).")
        if worst and worst["cache_n"] < approx * 0.3:
            print("  Prompt edits are NOT being reused past the change. "
                  "If the harness does this often, raise cache-reuse "
                  "(CACHE_REUSE in env.conf).")

    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=2)
        print(f"\n  raw -> {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
