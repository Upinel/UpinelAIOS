#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  Nova Upinel Chow, MSc, LLM, BBA, MENSA  ·  dev@upinel.com  ·  upinel.com
#  Copyright (c) 2026 Nova Upinel Chow. All rights reserved.
#
#  Upinel Personal Free License: free for personal use, and free for creators
#  (YouTubers, KOLs) to make content with - just email dev@upinel.com to say so.
#  Other commercial use needs written permission. Derivatives must credit the
#  author. Covers this project's own code only. See LICENSE.
#
#  "Make it work, make it right, make it fast - then measure it, because
#   the third one is only a claim until the numbers agree."
# ─────────────────────────────────────────────────────────────────────────────
"""The benchmark must not measure the cache and call it prefill.

A server caches the KV of a shared prefix. If every repeat sends the same
prompt, every run after the first is served from that cache, and the reported
prefill rate describes how fast the machine can look something up - not how
fast it can ingest a prompt.

This was not hypothetical. `mlx-q-35ba3b` was published at 32 t/s prefill,
which is ~47x below reality, and the same 8k prompt measured 1,519 t/s cold and
31,278 t/s warm in consecutive runs. `--repeats` took a median across both, so
the number depended on how many repeats you asked for.

These tests pin the fix: each repeat's prompt must differ, and must differ from
the very first token, because a nonce anywhere later leaves the cached prefix
intact and the cache still hits.

Runs offline - it builds prompts, it does not call a server.

Run:  python3 bench/verify-bench-prompt.py
"""

import importlib.util
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PASSED = 0
FAILED = 0


def check(label, got, want):
    global PASSED, FAILED
    if got == want:
        print(f"  [PASS] {label}")
        PASSED += 1
    else:
        print(f"  [FAIL] {label}\n         got  {got!r}\n         want {want!r}")
        FAILED += 1


def load_bench():
    """Import bench.py without running main()."""
    spec = importlib.util.spec_from_file_location(
        "aios_bench", os.path.join(HERE, "bench.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main():
    print("\n  Benchmark prompt isolation\n")
    bench = load_bench()
    pft = bench._prompt_for_tokens

    a = pft(8192)
    b = pft(8192)
    check("two plain prompts of the same size are identical (the old behaviour)",
          a == b, True)

    n1 = pft(8192, "ctx-0-1")
    n2 = pft(8192, "ctx-1-2")
    check("different nonces give different prompts", n1 != n2, True)

    # The prefix is what the cache matches on, so the nonce has to be at the
    # front. If it were appended, a server could still reuse everything before
    # it and the measurement would be just as wrong.
    first_line = n1.split("\n", 1)[0]
    check("the nonce is the very first line, so no prefix is shared",
          first_line.startswith("[run "), True)
    check("the nonce actually differs in the first line",
          n1.split("\n", 1)[0] != n2.split("\n", 1)[0], True)

    # Size must stay honest: a nonce that silently shortened the prompt by a
    # lot would change what is being measured.
    check("nonce keeps the prompt at roughly the requested size",
          abs(len(n1) - len(a)) < 40, True)

    # And the size scaling itself must not have broken.
    check("prompt size grows with the request", len(pft(8192)) > len(pft(512)), True)

    print("\n  Guards on the call site\n")
    src = open(os.path.join(HERE, "bench.py"), encoding="utf-8").read()

    check("run_case accepts a nonce", "def run_case(" in src and "nonce=" in src, True)
    check("the repeat loop passes a unique nonce per run",
          bool(re.search(r"nonce = f\"\{ctx\}-\{i\}-", src)), True)
    check("no repeat loop calls run_case without a nonce",
          bool(re.search(r"run_case\([^)]*quiet=args\.json\)\s*\n", src)), False)

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
