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
"""The merge must not silently serve a different model.

Two projects became one, and both sets of aliases were renamed to say which
engine they belong to. Renaming is only safe if every old name still resolves
to exactly the repo it resolved to before - otherwise an existing install's
env.conf, or a script someone wrote, quietly starts serving something else.

``27b-4bit`` is the case that would actually bite. Before the merge it meant
the barozp build; the itrejomx build was plain ``4bit``. Two aliases, two
different repos, one word apart. Get that wrong and nothing errors - you just
get different weights.

The expected values below are transcribed from the two pre-merge repos'
model_repo_for(), so this is a compatibility record rather than a restatement
of the current code.

Runs offline. Reads the registry only.

Run:  python3 bench/verify-legacy-aliases.py
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

SHIM = r'''
source "$1/lib/common.sh"
model_repo_for "$2"
'''

# alias -> repo, exactly as the two pre-merge editions resolved them.
GGUF_ERA = {
    "26b-q4":      "OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF",
    "12b":         "HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced",
    "31b-heretic": "llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF",
    "e4b":         "HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive",
    "e2b":         "HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive",
    "qwen-27b":    "HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF",
    "qwen-9b":     "mradermacher/Qwen3.8-9B-heretic-uncensored-i1-GGUF",
    "qwen-35b":    "HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive",
}

# The MLX edition's aliases, which is where the subtle collisions live.
MLX_ERA = {
    "4bit":     "itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-4bit",
    "6bit":     "itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-6bit",
    "27b-3bit": "barozp/Qwen3.8-27B-Uncensored-MTPLX-3bit",
    "27b-4bit": "barozp/Qwen3.8-27B-Uncensored-MTPLX-4bit",
    "9b":       "Foresee/Qwen3.8-9B-heretic-uncensored-4bit-MTPLX",
    "moe":      "hawhyhb/Qwen3.6-35B-A3B-Uncensored-Heretic-MTPLX-4bit-FP16",
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


def run(alias):
    return subprocess.run(["bash", "-c", SHIM, "shim", REPO, alias],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def resolve(alias):
    r = run(alias)
    return r.stdout.strip(), r.returncode


def stderr_of(alias):
    return run(alias).stderr


def main():
    print("\n  Pre-merge alias compatibility\n")

    for alias, want in sorted(GGUF_ERA.items()):
        got, rc = resolve(alias)
        check(f"GGUF-era '{alias}' still resolves", (got, rc), (want, 0))

    for alias, want in sorted(MLX_ERA.items()):
        got, rc = resolve(alias)
        check(f"MLX-era '{alias}' still resolves", (got, rc), (want, 0))

    # The collision, asserted directly: these two are one word apart and were
    # always different repos. If the merge ever collapses them, say so loudly.
    fourbit, _ = resolve("4bit")
    twentyseven, _ = resolve("27b-4bit")
    check("'4bit' and '27b-4bit' still mean different repos",
          fourbit != twentyseven, True)
    check("'4bit' is the itrejomx build", "itrejomx" in fourbit, True)
    check("'27b-4bit' is the barozp build", "barozp" in twentyseven, True)

    # 26b-a4b pointed at the alias removed for being slower and larger. It
    # must fail loudly AND name the replacement - a migrating user who is told
    # only "not a known alias" goes looking for a typo that is not there.
    got, rc = resolve("26b-a4b")
    check("removed alias '26b-a4b' still fails", rc != 0, True)
    check("removed alias '26b-a4b' resolves to no repo", got, "")
    err = stderr_of("26b-a4b")
    check("removed alias says it was removed, not misspelled",
          "removed" in err, True)
    check("removed alias names the replacement it wants",
          "gguf-g-26ba4b" in err, True)

    # A renamed alias must still be usable through the new name too.
    check("new name 'mlx-q-35ba3b' matches old 'moe'",
          resolve("mlx-q-35ba3b")[0], resolve("moe")[0])

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
