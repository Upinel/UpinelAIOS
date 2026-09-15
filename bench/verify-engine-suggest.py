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
"""Regression tests for the per-engine model suggestion in ./install.sh.

install.sh offers one GGUF model and one MLX model, each the fastest in its
engine that this Mac can actually load. An engine whose whole ladder fails the
memory test must drop out of the menu entirely - offering a 9 GB model to an
8 GB machine is not a suggestion, it is a trap the user cannot see.

Two things here were real bugs on the way in and are pinned so they cannot
come back:

  * model_repo_for("") dies. The single-engine path leaves one engine's alias
    empty, so resolving it unconditionally took the whole installer down.
  * The menu rows used single-quoted printf formats, so the terminal printed
    the literal text ${C_BOLD} instead of switching colour.

Runs offline. Memory sizes are injected, so this does not care what Mac it is
run on.

Run:  python3 bench/verify-engine-suggest.py
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Walks the same ladders install.sh uses, at an injected memory size, and
# prints one line per RAM value. REC_CONTEXT/REC_KV mirror recommend_config().
SHIM = r'''
source "$1/lib/common.sh"
load_config
source "$1/lib/preflight.sh"
ram="$2"
HW_RAM_GB="$ram"
if   (( ram >= 128 )); then REC_CONTEXT=262144; REC_KV=q8_0
elif (( ram >= 96 ));  then REC_CONTEXT=262144; REC_KV=q8_0
elif (( ram >= 56 ));  then REC_CONTEXT=131072; REC_KV=q8_0
elif (( ram >= 40 ));  then REC_CONTEXT=65536;  REC_KV=q8_0
elif (( ram >= 30 ));  then REC_CONTEXT=32768;  REC_KV=q8_0
elif (( ram >= 16 ));  then REC_CONTEXT=16384;  REC_KV=q8_0
else                        REC_CONTEXT=8192;   REC_KV=q8_0
fi
REC_ALL_TOO_BIG=0
REC_ALIAS="$(alias_for_repo "$REC_MODEL")" 2>/dev/null || REC_ALIAS=""
recommend_engines
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "$REC_SUGGEST" "$REC_GGUF_ALIAS" "$REC_GGUF_VERDICT" \
  "$REC_MLX_ALIAS" "$REC_MLX_VERDICT" \
  "$REC_GGUF_MINNAME" "$REC_GGUF_MINNEED" \
  "$REC_MLX_MINNAME" "$REC_MLX_MINNEED"
'''

# Which model each engine should offer, and whether the engine is offered at
# all, at each memory size a Mac actually ships with.
EXPECTED = {
    #   RAM   suggest   gguf alias        mlx alias
    6:  ("both", "gguf-g-e2b", "mlx-q-9b"),      # nothing fits; smallest of each
    8:  ("gguf", "gguf-g-e2b", None),            # only GGUF survives
    16: ("both", "gguf-g-12b", "mlx-q-9b"),
    18: ("both", "gguf-g-26ba4b", "mlx-q-9b"),
    24: ("both", "gguf-g-26ba4b", "mlx-q-27b-4bit"),
    32: ("both", "gguf-g-26ba4b", "mlx-q-35ba3b"),
    48: ("both", "gguf-g-26ba4b", "mlx-q-35ba3b"),
    64: ("both", "gguf-g-26ba4b", "mlx-q-35ba3b"),
    96: ("both", "gguf-g-26ba4b", "mlx-q-35ba3b"),
    128: ("both", "gguf-g-26ba4b", "mlx-q-35ba3b"),
}

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


def suggest(ram):
    r = subprocess.run(["bash", "-c", SHIM, "shim", REPO, str(ram)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"shim failed at {ram} GB:\n{r.stderr}")
    fields = r.stdout.strip().split("\n")[-1].split("|")
    keys = ("suggest", "gguf", "gguf_verdict", "mlx", "mlx_verdict",
            "gguf_min", "gguf_minneed", "mlx_min", "mlx_minneed")
    return dict(zip(keys, fields))


def main():
    print("\n  Per-engine model suggestion tests\n")
    install = open(os.path.join(REPO, "install.sh"), encoding="utf-8").read()
    preflight = open(os.path.join(REPO, "lib", "preflight.sh"),
                     encoding="utf-8").read()

    for ram, (want_suggest, want_gguf, want_mlx) in sorted(EXPECTED.items()):
        s = suggest(ram)
        check(f"{ram} GB: offers the expected engines", s["suggest"], want_suggest)
        check(f"{ram} GB: GGUF suggestion", s["gguf"], want_gguf)
        check(f"{ram} GB: MLX suggestion", s["mlx"] or None, want_mlx)

        # The whole point of the ladder: never offer something that will not
        # load, unless nothing at all loads.
        if want_suggest == "both" and ram >= 8:
            check(f"{ram} GB: GGUF suggestion is loadable",
                  s["gguf_verdict"] == "will not fit", False)
            check(f"{ram} GB: MLX suggestion is loadable",
                  s["mlx_verdict"] == "will not fit", False)

        # An engine that dropped out must still be able to explain itself.
        if not want_mlx:
            check(f"{ram} GB: names the MLX model it dropped",
                  bool(s["mlx_min"]) and s["mlx_minneed"].isdigit(), True)

    # The 6 GB case is the defensive branch: no Apple Silicon Mac ships below
    # 8 GB, but an empty menu would be worse than an honest over-ask.
    s6 = suggest(6)
    check("6 GB: falls back to the smallest of each rather than nothing",
          (s6["gguf"], s6["mlx"]), ("gguf-g-e2b", "mlx-q-9b"))

    print("\n  Guards for bugs this change fixed\n")

    # model_repo_for("") dies, and the single-engine path leaves an empty alias.
    check("recommend_engines never resolves an empty alias",
          bool(re.search(r'if \[\[ -n "\$REC_GGUF_ALIAS" \]\]; then\s*\n\s*REC_GGUF_REPO=',
                         preflight)), True)
    check("recommend_engines never resolves an empty MLX alias",
          bool(re.search(r'if \[\[ -n "\$REC_MLX_ALIAS" \]\]; then\s*\n\s*REC_MLX_REPO=',
                         preflight)), True)

    # Single-quoted printf would print the literal ${C_BOLD}.
    row = re.search(r"menu_row\(\)\s*\{(.*?)\n\}", install, re.S)
    check("menu_row exists", row is not None, True)
    if row:
        body = row.group(1)
        check("menu_row uses double-quoted formats so colours expand",
              "'  ${C_BOLD}" not in body and '"  %s%s%s' in body, True)
    check("no install.sh menu row still prints a literal ${C_BOLD}",
          bool(re.search(r"printf '\s+\$\{C_BOLD\}", install)), False)

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
