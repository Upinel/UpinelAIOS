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
"""The chip decides which kernels run, and the code must agree.

Neural Accelerators arrived with M5. Above that line llama.cpp's Metal tensor
API is worth about 2x prefill and MLX uses its `*_nax` kernels; below it the
hardware does not have the units at all, and llama.cpp measures its tensor API
as ~5% SLOWER on M2 Ultra and neutral on M4. So this is a gate, and getting it
wrong costs either the feature or the speed.

Two things had drifted:

  * `chip_has_neural_accelerator` read sysctl directly instead of the chip the
    rest of the code had already detected, so the same question had two
    answers depending on which script asked, and neither could be tested.
  * The MLX banner printed "on (M5; MLX selects NAX kernels automatically)" on
    every machine, including M1-M4 where there is nothing to select.

Everything here runs with an injected chip, so it is meaningful on any Mac.

Run:  python3 bench/verify-chip-tier.py
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

SHIM = r'''
source "$1/lib/common.sh"
load_config
# Applied AFTER load_config on purpose: env.conf is the configuration, and it
# would otherwise overwrite an injected value with its own METAL_TENSOR_API.
if [[ -n "${2:-}" ]]; then METAL_TENSOR_API="$2"; fi
echo "family=$(chip_family)"
if chip_has_neural_accelerator; then echo "accel=yes"; else echo "accel=no"; fi
echo "state=$(neural_accelerator_state)"
load_engine gguf >/dev/null 2>&1
echo "tensor=$(gguf_tensor_state)"
# Which env vars the engine actually sets, since llama.cpp reads them at
# device init and exporting the wrong one is silent.
"$1/lib/engines/gguf.sh" >/dev/null 2>&1 || true
echo "env=${GGML_METAL_TENSOR_ENABLE:-none}/${GGML_METAL_TENSOR_DISABLE:-none}"
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


def probe(chip, tensor_api=None, apply=False):
    env = dict(os.environ, HW_CHIP=chip)
    script = SHIM
    if apply:
        script += '\nload_engine gguf >/dev/null 2>&1\nengine_apply_settings\n'
        script += 'echo "exported=${GGML_METAL_TENSOR_ENABLE:-none}/${GGML_METAL_TENSOR_DISABLE:-none}"\n'
    r = subprocess.run(["bash", "-c", script, "shim", REPO, tensor_api or ""],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       text=True, env=env)
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out


def main():
    print("\n  Chip tier\n")

    # Family extraction, across the shapes Apple actually reports.
    for chip, want in [("Apple M1", "M1"), ("Apple M1 Max", "M1"),
                       ("Apple M2 Ultra", "M2"), ("Apple M3 Pro", "M3"),
                       ("Apple M4", "M4"), ("Apple M5 Pro", "M5"),
                       ("Apple M6 Max", "M6")]:
        check(f"{chip!r} -> {want}", probe(chip)["family"], want)

    # The gate itself, including one generation past anything that exists, so
    # a list-based implementation would fail here rather than in two years.
    for chip, want in [("Apple M1 Max", "no"), ("Apple M2 Ultra", "no"),
                       ("Apple M3 Pro", "no"), ("Apple M4", "no"),
                       ("Apple M5", "yes"), ("Apple M5 Pro", "yes"),
                       ("Apple M6 Max", "yes")]:
        check(f"{chip}: neural accelerators -> {want}",
              probe(chip)["accel"], want)

    print("\n  It is reported honestly, not assumed\n")
    # The M1 line names M5 while explaining it is absent, so the test has to be
    # about the claim (does it say "on"), not about the substring.
    check("an M1 does not claim the kernels are on",
          probe("Apple M1 Max")["state"].startswith("on"), False)
    check("an M1 says accelerators are off",
          "off" in probe("Apple M1 Max")["state"], True)
    check("an M5 says accelerators are on",
          "on" in probe("Apple M5 Pro")["state"], True)
    check("the state names the actual chip, not a hardcoded one",
          "M6" in probe("Apple M6 Max")["state"], True)

    check("GGUF on M5 reports the tensor API on",
          "on" in probe("Apple M5 Pro")["tensor"], True)
    check("GGUF on M1 reports it off",
          "off" in probe("Apple M1 Max")["tensor"], True)
    check("forcing it off on an M5 says what that costs",
          "left on the table" in probe("Apple M5 Pro", "off")["tensor"], True)
    check("forcing it on below M5 says it will not help",
          "no gain" in probe("Apple M1 Max", "on")["tensor"], True)

    print("\n  auto must not export anything\n")
    # llama.cpp enables the tensor API itself by device name on M5/M6/A19/A20.
    # Setting the variables here would override that detection and, below M5,
    # force on a path measured as slower.
    for chip in ("Apple M1 Max", "Apple M4 Pro", "Apple M5 Pro", "Apple M6 Max"):
        got = probe(chip, "auto", apply=True).get("exported", "")
        check(f"{chip}: auto exports neither variable", got, "none/none")

    check("M5 + on exports ENABLE",
          probe("Apple M5 Pro", "on", apply=True)["exported"].split("/")[0], "1")
    check("M1 + off exports DISABLE",
          probe("Apple M1 Max", "off", apply=True)["exported"].split("/")[1], "1")

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
