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
"""Both engines must implement the same contract, and only it.

The dual-engine design puts every runtime difference behind a set of functions
that lib/engines/*.sh implement: how to install the runtime, how to build the
command line, what counts as a complete model. Shared scripts call those and
never branch on the engine name themselves.

That only holds if the contract is actually complete. A function implemented by
gguf.sh and missing from mlx.sh does not fail until the moment a user runs the
MLX path, which is the worst time to find out. This checks the surface instead.

It also checks the reverse, which is where a real bug lived: shared scripts
reaching past the contract into one engine's helpers. model_download.sh called
model_draft_gguf() for every model regardless of engine, so every MLX pack was
told it had no draft file and would "run autoregressive only" - a warning about
a file MLX never uses, on models whose MTP worked.

Run:  python3 bench/verify-engine-contract.py
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# Every function a shared script may call on an engine. Kept explicit rather
# than inferred: this list is the contract, and extending it should be a
# deliberate act.
CONTRACT = [
    "engine_present",
    "engine_name",
    "engine_version",
    "engine_install",
    "engine_install_hint",
    "engine_model_ok",
    "engine_main_file",
    "engine_model_summary",
    "engine_build_args",
    "engine_export_env",
    "engine_apply_settings",
    "engine_banner",
    "engine_binary",
    "engine_tunable",
    "engine_serve_word",
    "engine_post_fetch_notes",
    "engine_status_extras",
    "engine_resolved_profile",
]

# Helpers that belong to exactly one engine. Calling one of these from a shared
# script is the bug this file exists to prevent.
ENGINE_PRIVATE = {
    "model_main_gguf": "gguf",
    "model_mmproj_gguf": "gguf",
    "model_draft_gguf": "gguf",
    "draft_needs_patched_runtime": "gguf",
    "model_dir_gb": "mlx",
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


def defined_in(path):
    src = open(path, encoding="utf-8").read()
    return set(re.findall(r"^([a-z_][a-z0-9_]*)\s*\(\)\s*\{", src, re.M))


def main():
    print("\n  Engine contract\n")

    gguf = os.path.join(REPO, "lib", "engines", "gguf.sh")
    mlx = os.path.join(REPO, "lib", "engines", "mlx.sh")
    g, m = defined_in(gguf), defined_in(mlx)

    for fn in CONTRACT:
        check(f"gguf implements {fn}", fn in g, True)
        check(f"mlx implements {fn}", fn in m, True)

    # Implementing something the contract does not name is how the two engines
    # drift: a caller cannot use it without branching on engine, so it should
    # either join the contract or move into the shared library.
    check("gguf adds nothing outside the contract",
          sorted(n for n in g if n.startswith("engine_") and n not in CONTRACT), [])
    check("mlx adds nothing outside the contract",
          sorted(n for n in m if n.startswith("engine_") and n not in CONTRACT), [])

    print("\n  Shared scripts stay out of engine internals\n")

    shared = ["install.sh", "model_download.sh", "start.sh", "stop.sh",
              "restart.sh", "status.sh", "service.sh", "chat.sh",
              "lib/preflight.sh", "lib/fetch-model.sh", "lib/dashboard.py"]
    for name in shared:
        path = os.path.join(REPO, name)
        if not os.path.exists(path):
            continue
        src = open(path, encoding="utf-8").read()
        for helper, owner in sorted(ENGINE_PRIVATE.items()):
            # A shared script may not call it at all; the engine's own module
            # and common.sh (which defines some of them) are checked separately.
            hit = re.search(rf"\b{helper}\s+\"", src)
            if hit:
                line = src[:hit.start()].count("\n") + 1
                print(f"  [FAIL] {name}:{line} calls {helper}() ({owner}-only)")
                FAILED_GLOBAL[0] += 1
            else:
                check(f"{name} avoids {helper}()", True, True)

    print(f"\n  {PASSED} passed, {FAILED + FAILED_GLOBAL[0]} failed\n")
    return 1 if (FAILED or FAILED_GLOBAL[0]) else 0


FAILED_GLOBAL = [0]

if __name__ == "__main__":
    sys.exit(main())
