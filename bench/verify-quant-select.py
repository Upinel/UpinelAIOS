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
"""Regression tests for the quant selector in lib/fetch-model.sh.

Why this exists
---------------
Two bugs have shipped from this one function, both silent and both expensive:

  1. The size audit compared the raw API listing, so a correct single-quant
     download was reported as incomplete.
  2. The selector matched only exact quant tags. The Gemma 4 E2B repo publishes
     Q4_K_P, not Q4_K_M, so nothing matched and the fallback took "the largest
     file in the repo" - it fetched Q8_K_P, the opposite of the request, and
     1.6 GB more than asked for.

Neither was caught because verifying them meant hitting the network and
downloading gigabytes. These run offline against small recorded listings, so
they can run on every commit.

Run:  python3 bench/verify-quant-select.py
"""

import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
# The GGUF fetcher specifically. lib/fetch-model.sh is now a dispatcher that
# picks a fetcher by engine, so the quant-selection logic this suite tests
# lives in the GGUF implementation beside it.
FETCH = os.path.join(REPO, "lib", "fetch-model-gguf.sh")


def gb(x):
    return int(x * 1e9)


# ── recorded repo listings (sizes are the real ones) ─────────────────────────
# Only the fields the selector reads, so these stay small and readable.
def repo(*files):
    return {"siblings": [{"rfilename": n, "size": s} for n, s in files]}


REPOS = {
    # Publishes only _P siblings - the case that broke.
    "e2b": repo(
        ("Gemma-4-E2B-Q8_K_P.gguf", gb(5.04)),
        ("Gemma-4-E2B-Q6_K_P.gguf", gb(3.87)),
        ("Gemma-4-E2B-Q5_K_P.gguf", gb(3.66)),
        ("Gemma-4-E2B-Q4_K_P.gguf", gb(3.45)),
        ("Gemma-4-E2B-Q3_K_P.gguf", gb(3.22)),
        ("Gemma-4-E2B-IQ3_M.gguf", gb(3.13)),
        ("Gemma-4-E2B-Q2_K_P.gguf", gb(3.01)),
        ("mmproj-Gemma-4-E2B-f16.gguf", gb(0.99)),
        ("README.md", 100),
    ),
    # Publishes both _M and _P for the same family - must fetch exactly one.
    "e4b": repo(
        ("Gemma-4-E4B-Q8_K_P.gguf", gb(8.13)),
        ("Gemma-4-E4B-Q6_K_P.gguf", gb(6.25)),
        ("Gemma-4-E4B-Q5_K_P.gguf", gb(5.81)),
        ("Gemma-4-E4B-Q5_K_M.gguf", gb(5.76)),
        ("Gemma-4-E4B-Q4_K_P.gguf", gb(5.37)),
        ("Gemma-4-E4B-Q4_K_M.gguf", gb(5.34)),
        ("mmproj-Gemma-4-E4B-f16.gguf", gb(0.99)),
    ),
    # Two Q4_K siblings, plus a split model to prove parts stay together.
    "31b": repo(
        ("heretic-BF16.gguf", gb(61.41)),
        ("heretic-Q8_0.gguf", gb(32.64)),
        ("heretic-Q5_K_M.gguf", gb(21.85)),
        ("heretic-Q4_K_M.gguf", gb(18.69)),
        ("heretic-Q4_K_S.gguf", gb(17.76)),
        ("mmproj-BF16.gguf", gb(1.20)),
    ),
    "split": repo(
        ("big-Q4_K_M-00001-of-00003.gguf", gb(6.0)),
        ("big-Q4_K_M-00002-of-00003.gguf", gb(6.0)),
        ("big-Q4_K_M-00003-of-00003.gguf", gb(6.0)),
        ("big-Q8_0.gguf", gb(30.0)),
        ("mmproj-f16.gguf", gb(0.5)),
    ),
    # Untagged single-quant repo: take it rather than fail.
    "untagged": repo(
        ("model.gguf", gb(4.0)),
        ("mmproj.gguf", gb(0.5)),
    ),
}

FAILED = 0
PASSED = 0


def check(label, got, want):
    global FAILED, PASSED
    if got == want:
        print(f"  [PASS] {label}")
        PASSED += 1
    else:
        print(f"  [FAIL] {label}\n         got  {got}\n         want {want}")
        FAILED += 1


def select(listing, pref):
    """Run the real selector out of fetch-model.sh. Returns (tag, files, gb)."""
    tag, files, total, _ = select_note(listing, pref)
    return tag, files, total


def select_note(listing, pref):
    """As select(), but also returns the severity-tagged note.

    The note is "<severity>\\t<message>" on stderr, where severity is "info"
    when the substitution kept the bit width and "warn" when it did not.
    """
    src = open(FETCH).read()
    if "<<'PY'" not in src:
        raise SystemExit(f"{FETCH} no longer contains the selector block this "
                         f"suite tests - update FETCH in {os.path.abspath(__file__)}")
    block = src.split("<<'PY'")[1].split("\nPY\n")[0]
    with tempfile.TemporaryDirectory() as td:
        mpath = os.path.join(td, "m.json")
        qpath = os.path.join(td, "q")
        json.dump(listing, open(mpath, "w"))
        script = os.path.join(td, "sel.py")
        open(script, "w").write(block)
        r = subprocess.run([sys.executable, script, mpath, pref, qpath],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        tag = open(qpath).read() if os.path.exists(qpath) else ""
        rows = [l.split("\t") for l in r.stdout.strip().split("\n") if l.strip()]
        files = [x[1] for x in rows if x[1].endswith(".gguf")]
        total = sum(int(x[0]) for x in rows) / 1e9
        note = r.stderr.strip().split("\t")
        sev = note[0] if len(note) == 2 else ""
        return tag, files, round(total, 2), sev


def main():
    print("\n  Quant selector regression tests\n")

    # The reported bug: _P family, requested _M.
    tag, files, total = select(REPOS["e2b"], "Q4_K_M")
    check("e2b Q4_K_M picks the Q4 sibling, not Q8", tag, "Q4_K_P")
    check("e2b fetches one quant plus the projector", len(files), 2)
    check("e2b downloads ~4.4 GB, not ~6 GB", total, 4.44)
    check("e2b never fetches the Q8 file",
          any("Q8" in f for f in files), False)

    # Same family, several members: exactly one may be chosen.
    tag, files, total = select(REPOS["e4b"], "Q4_K_M")
    check("e4b Q4_K_M prefers the exact tag", tag, "Q4_K_M")
    check("e4b fetches one quant plus the projector", len(files), 2)
    check("e4b does not pull both Q4 siblings", round(total, 2), 6.33)

    tag, files, total = select(REPOS["31b"], "Q4_K_M")
    check("31b Q4_K_M prefers the exact tag over Q4_K_S", tag, "Q4_K_M")
    check("31b does not pull both Q4 siblings", round(total, 2), 19.89)

    # An explicit request must be honoured when published.
    check("31b honours an explicit Q5_K_M", select(REPOS["31b"], "Q5_K_M")[0],
          "Q5_K_M")
    check("31b honours an explicit Q8_0", select(REPOS["31b"], "Q8_0")[0],
          "Q8_0")

    # Split models: every part of the chosen quant, and only that quant.
    tag, files, total = select(REPOS["split"], "Q4_K_M")
    check("split model keeps all 3 parts", len([f for f in files if "0000" in f]), 3)
    check("split model excludes the other quant",
          any("Q8" in f for f in files), False)

    # Untagged single-quant repo should still work.
    tag, files, _ = select(REPOS["untagged"], "Q4_K_M")
    check("untagged repo still fetches its single weight", len(files), 2)

    # ── note severity ────────────────────────────────────────────────────────
    # A substitution that keeps the bit width is what the request meant, so it
    # must not be reported as a warning: the shipped default model is a Q4_0
    # QAT release, and shipping MODEL_QUANT=Q4_K_M made every fresh install
    # print a scare about the model it had just picked. Only a change in bit
    # width is worth a warning.
    tag, _, _, sev = select_note(REPOS["split"], "Q4_K_M")
    check("exact match produces no note at all", sev, "")
    tag, _, _, sev = select_note(REPOS["e2b"], "Q4_K_M")
    check("Q4_K -> Q4_K_P sibling is informational", sev, "info")
    tag, _, _, sev = select_note(REPOS["split"], "Q8_0")
    check("exact Q8_0 match produces no note", sev, "")
    tag, _, _, sev = select_note(REPOS["untagged"], "Q3_K_M")
    check("bit-width change is still a warning", sev, "warn")

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
