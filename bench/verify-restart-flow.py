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

The scripts are killed as soon as the banner is out, before they load a model.
Two things that has to get right, both learned the hard way:

  * The kill goes to the whole process group. Killing only the shell leaves the
    server it spawned running, and that server inherits this process's stdout -
    so the pipe never closes and anything capturing this test's output hangs
    forever. That is a nasty failure mode for a suite that is supposed to be
    safe to run while you work.
  * A server that was already running when this started is left alone. Only one
    this test started is stopped again, checked against the pid file.

Run:  python3 bench/verify-restart-flow.py
"""

import os
import pty
import re
import select
import shutil
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
        reap(pid)
        try:
            os.close(fd)
        except OSError:
            pass
    return ANSI.sub("", buf)


def reap(pid, tries=40, pause=0.05):
    """Kill the child and its group, and never block waiting for it.

    os.waitpid(pid, 0) waits forever if the child cannot be reaped, and this
    test hung a whole verify-all run that way - stuck in __wait4 with the pty
    still open. A test that hangs is worse than one that fails: it takes the
    suite with it and leaves whoever ran it guessing.

    The group kill matters too, but for a different reason: a shell that has
    already reached "start" has a server under it, that server inherits our
    stdout, and a leaked one keeps the pipe open so anything capturing this
    output waits forever.
    """
    for sig in (signal.SIGKILL,):
        try:
            os.killpg(os.getpgid(pid), sig)
        except OSError:
            try:
                os.kill(pid, sig)
            except OSError:
                return
        for _ in range(tries):
            try:
                done, _ = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return
            except OSError:
                return
            if done:
                return
            time.sleep(pause)


def server_pid():
    """Pid of a running server, or None. Read through the real helper so this
    agrees with the scripts about what counts as running."""
    try:
        out = subprocess.run(
            ["bash", "-c",
             f'source {REPO}/lib/common.sh; load_config; '
             'pid_alive && cat "$PID_FILE"'],
            capture_output=True, text=True, timeout=30)
        return out.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def stop_if_we_started_it(was):
    """Leave the machine as we found it.

    Driving ./restart.sh can start a server if it gets past the banner before
    the kill lands. Stopping it matters for more than tidiness: the server
    inherits stdout, so a leaked one hangs whoever piped this test's output.
    """
    now = server_pid()
    if now and now != was:
        subprocess.run([f"{REPO}/stop.sh"], capture_output=True, timeout=120)
        time.sleep(1)
        return True
    return False


def main():
    print("\n  Model picker path in start/restart\n")
    before = server_pid()
    # Belt and braces: if anything here wedges, say so and exit rather than
    # taking the whole suite with it.
    signal.alarm(180)

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

    print("\n  picker timeout\n")
    # PICK_TIMEOUT_SECONDS. Worth testing because a bad value here is silent:
    # bash 3.2 rejects `read -t` with a non-integer by printing "invalid
    # timeout specification" and the picker takes the default instantly without
    # ever saying why - which looks like the menu being ignored.
    env_file = os.path.join(REPO, "env.conf")
    backup = env_file + ".ticktest"
    shutil.copyfile(env_file, backup)

    def resolve_with(edit):
        """Load config against env.conf transformed by edit(), and report."""
        src = open(backup, encoding="utf-8").read()
        with open(env_file, "w", encoding="utf-8") as fh:
            fh.write(edit(src))
        r = subprocess.run(
            ["bash", "-c",
             f'source {REPO}/lib/common.sh; load_config; '
             'printf "%s" "$PICK_TIMEOUT_SECONDS"'],
            capture_output=True, text=True, timeout=60)
        return r.stdout.strip(), r.stderr.strip()

    def set_value(v):
        return lambda src: re.sub(r"^PICK_TIMEOUT_SECONDS=.*$",
                                  f"PICK_TIMEOUT_SECONDS={v}", src, count=1, flags=re.M)

    def drop_key(src):
        # An env.conf written before this setting existed. Reverting the code
        # default to 5 only shows up here - with the key present, env.conf wins
        # and the code default is never consulted.
        return re.sub(r"^PICK_TIMEOUT_SECONDS=.*\n", "", src, count=1, flags=re.M)

    def legacy(src):
        src = re.sub(r"^PICK_TIMEOUT_SECONDS=.*$",
                     "MODEL_PICK_SECONDS=15", src, count=1, flags=re.M)
        return src

    try:
        got, _ = resolve_with(set_value(45))
        check("env.conf can set its own timeout", got, "45")

        got, _ = resolve_with(drop_key)
        check("an env.conf without the key gets the 30s default", got, "30")

        got, _ = resolve_with(legacy)
        check("the old MODEL_PICK_SECONDS name still works", got, "15")

        got, err = resolve_with(set_value("abc"))
        check("a non-numeric timeout falls back to 30", got, "30")
        check("and says so rather than silently ignoring the menu",
              "not a positive whole number" in err, True)

        got, _ = resolve_with(set_value(0))
        check("zero is rejected too", got, "30")
    finally:
        shutil.copyfile(backup, env_file)
        os.unlink(backup)

    print("\n  picker rendering\n")
    check("long repo names are truncated, not overrunning the column",
          bool(re.search(r"^\s*\d+\s+GGUF\s+\S{1,20}\s+\d+ GB", listing, re.M)), True)
    check("a model we do not ship is labelled as such",
          "not one we ship" in listing, True)

    if stop_if_we_started_it(before):
        print("  (stopped a server this test started)")

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


def _timeout(_sig, _frm):
    print("\n  [FAIL] the picker drive did not finish within 180s; exiting so the\n"
          "         rest of the suite can run.\n", flush=True)
    os._exit(1)


if __name__ == "__main__":
    signal.signal(signal.SIGALRM, _timeout)
    sys.exit(main())
