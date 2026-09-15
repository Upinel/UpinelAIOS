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
"""The model picker path in start.sh and restart.sh.

These two scripts offer a numbered list when more than one model is on disk,
and the list is the least-tested way into the server - every other test drives
them with --model, which skips the picker entirely. That gap let three bugs
through at once, all on the picker path and all fatal or silently wrong:

  * ``choose_model_on_disk`` sets MODEL_REPO and MODEL_DIR but not MODEL_ALIAS,
    so restart.sh reading $MODEL_ALIAS afterwards died with "unbound variable" -
    and lib/common.sh turns on set -u for every script, so that is fatal.
  * start.sh read the same stale alias to pick the engine, so choosing an MLX
    model while env.conf named a GGUF one launched llama.cpp against an MTPLX
    pack.
  * restart.sh loaded the engine inside a command substitution, so engine_name
    and engine_resolved_profile were undefined by the time the banner called
    them - printing "command not found" and a blank profile.

The third bug only exists because the banner runs after the picker, so nothing
here can be checked by reading the source alone. This drives the real scripts
through a pty, answers the picker, and inspects what they printed.

The scripts are killed as soon as the banner is out, before they load a model,
so this stays fast and does not start a server.

Run:  python3 bench/verify-restart-flow.py
"""

import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PASSED = 0
FAILED = 0
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def check(label, got, want):
    global PASSED, FAILED
    if got == want:
        print(f"  [PASS] {label}")
        PASSED += 1
    else:
        print(f"  [FAIL] {label}\n         got  {got!r}\n         want {want!r}")
        FAILED += 1


def drive(script, answer, stop_marker, timeout=90):
    """Run a script under a pty, answer the picker, return clean output.

    Killed as soon as stop_marker appears: the banner is printed before any
    weights load, so there is no reason to wait for a server.
    """
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", "-c", f"cd {REPO} && exec {script}"])
        os._exit(127)

    buf = ""
    sent = False
    deadline = time.time() + timeout
    try:
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    chunk = os.read(fd, 4096).decode("utf-8", "replace")
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
                if not sent and "Number [" in buf:
                    time.sleep(0.3)
                    os.write(fd, (answer + "\n").encode())
                    sent = True
                if stop_marker and stop_marker in ANSI.sub("", buf):
                    break
            if "unbound variable" in buf or "command not found" in buf:
                break
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        except OSError:
            pass
        try:
            os.close(fd)
        except OSError:
            pass
    return ANSI.sub("", buf)


def main():
    print("\n  Model picker path in start/restart\n")

    # One drive of restart.sh with the picker showing. --print is not usable
    # here: it skips the picker, so the output carries no model rows and the
    # rendering checks below would have nothing to look at.
    listing = drive("./restart.sh", "1", "network")
    print("  restart.sh, interactive picker\n")
    check("no unbound variable", "unbound variable" in listing, False)
    check("no command not found", "command not found" in listing, False)
    check("it reached the banner", "Starting with:" in listing, True)
    check("the banner names an engine", "engine     " in listing, True)
    check("the chosen model is shown with its alias",
          bool(re.search(r"\(\S+\)", listing)), True)
    # The profile line is what called engine_resolved_profile from a subshell.
    check("the profile line resolved", bool(re.search(r"profile\s+\S", listing)), True)

    # Which number is an MLX model here? Read it from the list rather than
    # assuming an order, so this works on any set of downloaded models.
    mlx_idx = None
    for line in listing.splitlines():
        m = re.match(r"\s*(\d+)\s+MLX\s+\S+", line)
        if m:
            mlx_idx = m.group(1)
            break
    if mlx_idx is None:
        print("  [SKIP] no MLX model on disk; cannot test the engine switch")
    else:
        print(f"\n  (MLX entry is #{mlx_idx} on this machine)\n")
        print("  start.sh, interactive picker\n")
        # env.conf names a GGUF model, so resolving MLX proves the alias was
        # re-derived from the pick rather than left stale.
        out2 = drive("./start.sh", mlx_idx, "Engine:")
        check("no unbound variable", "unbound variable" in out2, False)
        check("no command not found", "command not found" in out2, False)
        check("the engine follows the pick, not env.conf",
              "Engine: MLX" in out2, True)

    print("\n  picker rendering\n")
    check("long repo names are truncated, not overrunning the column",
          bool(re.search(r"^\s*\d+\s+GGUF\s+\S{1,20}\s+\d+ GB", listing, re.M)), True)
    check("a model we do not ship is labelled as such",
          "not one we ship" in listing, True)

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
