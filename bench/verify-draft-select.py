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
"""Regression tests for speculative draft-head selection in lib/common.sh.

Why this exists
---------------
Picking the wrong draft head does not degrade the server, it kills it. The
HauhauCS heads are a second network that predicts the target's next tokens, so
a head built for a different model aborts inside llama.cpp:

    GGML_ASSERT(ggml_can_mul_mat(a, b)) failed
    llama_model_gemma4_assistant::graph

That is what happened when the on-disk model picker offered Gemma 4 E2B: the
26B head was borrowed for a 2B target and the server died on startup, for a
model that runs perfectly well without MTP.

The cross-directory borrow itself is correct and load-bearing - the default
`26b-q4` repo ships no draft of its own and uses the 26B head from the sibling
`26b-a4b` directory - so the rule cannot simply be "same directory only". It has
to compare what each file actually IS.

These build a throwaway models/ tree out of empty files, so they run offline in
a fraction of a second and need no downloads.

Run:  python3 bench/verify-draft-select.py
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

SHIM = r'''
source "$1/lib/common.sh"
load_config
MODELS_DIR="$2"
out="$(model_draft_gguf "$3")"
echo "${out:+$(basename "$out")}"
'''

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


def build(root, layout):
    """layout: {"dir-name": ["file", ...]}"""
    for d, files in layout.items():
        os.makedirs(os.path.join(root, d), exist_ok=True)
        for f in files:
            open(os.path.join(root, d, f), "w").close()


def draft_for(root, d):
    r = subprocess.run(["bash", "-c", SHIM, "shim", REPO, root, os.path.join(root, d)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return r.stdout.strip()


E2B = "HauhauCS--Gemma-4-E2B-Uncensored-HauhauCS-Aggressive"
T26 = "OS-Software--gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF"
T26MTP = "HauhauCS--Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP"
Q27 = "HauhauCS--Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF"

E2B_W = "Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf"
T26_W = "gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-Q4_0.gguf"
MTP26 = "mtp-gemma-4-26B-A4B-it.gguf"
Q27_W = "Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf"
Q27_D = "Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf"
MTP_QWEN_26 = "mtp-qwen-26B-A4B.gguf"


def main():
    print("\n  Draft-head selection regression tests\n")
    root = tempfile.mkdtemp(prefix="draftsel-")
    try:
        build(root, {
            E2B: [E2B_W],
            T26: [T26_W],
            T26MTP: [MTP26, "Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-Q4_K_M.gguf"],
            Q27: [Q27_W, Q27_D],
        })

        # The bug: a 2B target must never be handed the 26B head.
        check("2B target does not borrow the 26B head", draft_for(root, E2B), "")

        # ...but the default model still has to find its head, or MTP and the
        # ~119 t/s that depends on it silently disappear.
        check("26B target borrows the matching 26B head",
              draft_for(root, T26), MTP26)

        # A head sitting in the model's own directory wins.
        check("local draft is preferred over a borrowed one",
              draft_for(root, T26MTP), MTP26)
        check("Qwen uses its own FastMTP head", draft_for(root, Q27), Q27_D)

        # Family still matters: same designation, different family.
        build(root, {"HauhauCS--Gemma-4-26B-A4B-Bare": ["gemma-4-26B-A4B-it.gguf"]})
        shutil.rmtree(os.path.join(root, T26MTP))
        shutil.rmtree(os.path.join(root, T26))
        build(root, {"Qwen-only--26B-A4B": [MTP_QWEN_26]})
        check("Gemma target does not take a same-size Qwen head",
              draft_for(root, "HauhauCS--Gemma-4-26B-A4B-Bare"), "")

        # An unparseable local name is still trusted: many drafts ship as
        # "draft.gguf" with no size token at all.
        build(root, {"Custom--Model": ["model.gguf", "draft.gguf"]})
        check("a locally shipped draft with no size token is used",
              draft_for(root, "Custom--Model"), "draft.gguf")

        # An unparseable name must NOT be borrowed across directories.
        build(root, {"Other--Thing": ["weights.gguf"]})
        check("an unparseable head is never borrowed across directories",
              draft_for(root, "Other--Thing"), "")

        # A model with nothing at all is simply autoregressive.
        build(root, {"Empty--Nothing": ["weights-Q4_0.gguf"]})
        check("no draft anywhere means no draft", draft_for(root, "Empty--Nothing"), "")

        print(f"\n  {PASSED} passed, {FAILED} failed\n")
        return 1 if FAILED else 0
    finally:
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
