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
"""The expert profiles must actually change the launch, and must not abort.

Three profiles pick between jobs rather than points on a scale, so "it ran" is
not enough - each has to produce a different command line, and each has to
produce a valid one. Both halves have failed here:

  * ``(( expr )) && assign`` returns 1 when the test is false. lib/common.sh
    turns on set -e, so two of the three profiles aborted the script the moment
    they ran - silently, exit 1, no message, and only visible because
    ``--print`` showed a profile line and then nothing.
  * A profile that sets nothing is indistinguishable from a typo, so each is
    checked for a concrete effect on the command line rather than just for
    having been accepted.

The interesting assertions are "the launch command differs" and "the function
returns success for every profile", because those are the two ways this feature
can look like it works while doing nothing.

Run:  python3 bench/verify-profiles.py
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PROFILES = ["speed", "agent", "writer"]

SHIM = r'''
source "$1/lib/common.sh"
load_config
EXPERT_PROFILE="$2"
# Start from deliberately wrong values so anything the profile sets shows up,
# and anything it leaves alone is visibly left alone.
KV_QUANT="q4_0"; MTP_DEPTH="9"; THINKING="high"; MAX_RESPONSE_TOKENS=128
PARALLEL_SLOTS=9; MAX_CONCURRENT=9; PREFILL_CHUNK_TOKENS=99999
apply_expert_profile
echo "rc=0"
echo "kv=$KV_QUANT"
echo "depth=$MTP_DEPTH"
echo "thinking=$THINKING"
echo "resp=$MAX_RESPONSE_TOKENS"
echo "slots=$PARALLEL_SLOTS"
echo "chunk=$PREFILL_CHUNK_TOKENS"
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


def applied(profile):
    """Apply a profile to a known-bad config and report the result."""
    r = subprocess.run(["bash", "-c", SHIM, "shim", REPO, profile],
                       capture_output=True, text=True, timeout=60)
    out = {}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    out["_rc"] = r.returncode
    out["_err"] = r.stderr.strip()
    return out


def print_args(profile):
    """The command start.sh says it would run, with the profile applied."""
    r = subprocess.run([f"{REPO}/start.sh", "--print", "--profile", profile],
                       capture_output=True, text=True, timeout=180, cwd=REPO)
    lines = [l.strip().rstrip("\\").strip() for l in r.stdout.splitlines()]
    return [l for l in lines if l], r.returncode


def main():
    print("\n  Expert profiles\n")

    # 1. Every profile must return success. This is the set -e trap.
    for p in PROFILES + ["custom"]:
        got = applied(p)
        check(f"{p}: apply_expert_profile succeeds", got.get("_rc"), 0)
        if got.get("_rc") != 0:
            print(f"         stderr: {got.get('_err', '')[:120]}")

    # 2. Every profile must actually set something, except custom which by
    #    definition sets nothing.
    for p in PROFILES:
        got = applied(p)
        changed = [
            k for k in ("kv", "depth", "thinking", "resp", "slots", "chunk")
            if got.get(k) != {"kv": "q4_0", "depth": "9", "thinking": "high",
                              "resp": "128", "slots": "9", "chunk": "99999"}[k]
        ]
        check(f"{p}: changes at least three settings", len(changed) >= 3, True)

    custom = applied("custom")
    check("custom leaves every setting exactly as written",
          [custom.get(k) for k in ("kv", "depth", "thinking", "resp", "slots", "chunk")],
          ["q4_0", "9", "high", "128", "9", "99999"])

    # 3. The concrete differences that make the three worth having.
    speed, agent, writer = applied("speed"), applied("agent"), applied("writer")
    check("agent runs more parallel slots than speed",
          int(agent["slots"]) > int(speed["slots"]), True)
    check("agent turns thinking off", agent["thinking"], "off")
    check("writer turns thinking off", writer["thinking"], "off")
    check("agent reserves room for a tool call",
          int(agent["resp"]) >= 4096, True)
    check("writer reserves room for a long reply",
          int(writer["resp"]) >= 8192, True)
    # speed defers to the per-model tuned depth; writer pins a shallower one
    # because deeper drafting has more context to verify on every cycle.
    check("speed defers depth to the per-model tuner", speed["depth"], "auto")
    check("writer pins a shallow depth", writer["depth"], "1")
    check("f16 KV in all three, since it won at every context measured",
          {speed["kv"], agent["kv"], writer["kv"]}, {"f16"})

    # 4. And the launch commands really differ, which is the thing a user sees.
    print("\n  the launch commands differ\n")
    commands = {p: print_args(p) for p in PROFILES}
    for p, (lines, rc) in commands.items():
        check(f"{p}: --print produced a command", rc, 0)
    # Both sides must be non-empty as well as different: an empty command
    # differs from a real one, so the plain inequality passed while the profile
    # was aborting before printing anything.
    check("speed and writer produce different, non-empty commands",
          bool(commands["speed"][0]) and bool(commands["writer"][0])
          and commands["speed"][0] != commands["writer"][0], True)
    check("writer and agent produce different, non-empty commands",
          bool(commands["writer"][0]) and bool(commands["agent"][0])
          and commands["writer"][0] != commands["agent"][0], True)

    # 5. A bad name must say so rather than silently doing nothing.
    bad = subprocess.run(["bash", "-c",
                          f'source {REPO}/lib/common.sh; load_config; '
                          'EXPERT_PROFILE=nonsense; apply_expert_profile'],
                         capture_output=True, text=True, timeout=60)
    check("an unknown profile is rejected", bad.returncode != 0, True)
    check("and names the valid ones", "speed" in bad.stderr and "writer" in bad.stderr, True)

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
