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
"""update_env.sh must move an old env.conf forward without losing anything.

git pull updates env.conf only when the user has not edited it. Edit one
setting, resolve the conflict by keeping your file, and from then on you miss
every setting added since - including the ones whose DEFAULTS changed. That is
the failure this exists to prevent, so the properties worth testing are:

  * a value the user set is still there afterwards, unchanged
  * a setting the file has never seen arrives, with the shipped default
  * a setting that was renamed arrives under the new name WITH ITS VALUE
  * a setting nothing reads any more is dropped rather than left looking live
  * the result loads, and running it twice changes nothing the second time

The script edits the real env.conf, so this saves and restores it - a test that
leaves the user's configuration different is the bug, not the fix.

Run:  python3 bench/verify-env-migration.py
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
ENV = os.path.join(REPO, "env.conf")

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


def value_of(path, key):
    for line in open(path, encoding="utf-8"):
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return None


def make_stale(shipped):
    """A plausible file from a few versions back.

    Carries: customised settings, a setting that did not exist yet, a setting
    that was renamed, and one that is no longer read at all.
    """
    s = shipped
    s = re.sub(r"^PICK_TIMEOUT_SECONDS=.*\n", "", s, count=1, flags=re.M)
    s = re.sub(r"^EXPERT_PROFILE=.*\n", "", s, count=1, flags=re.M)
    s = re.sub(r"^MODEL=.*$", 'MODEL="mlx-q-9b"', s, count=1, flags=re.M)
    s = re.sub(r"^KV_QUANT=.*$", 'KV_QUANT="q8_0"', s, count=1, flags=re.M)
    s = re.sub(r"^THINKING=.*$", 'THINKING="medium"', s, count=1, flags=re.M)
    s += "\nNGRAM_PREWARM=0\nMODEL_PICK_SECONDS=12\n"
    return s


def main():
    print("\n  env.conf migration\n")

    backup = ENV + ".verify-backup"
    shutil.copyfile(ENV, backup)
    shipped = subprocess.run(["git", "-C", REPO, "show", "HEAD:env.conf"],
                             capture_output=True, text=True).stdout

    try:
        # ── the merge itself, without touching the real file ───────────────
        stale_path = ENV + ".verify-stale"
        merged_path = ENV + ".verify-merged"
        with open(stale_path, "w", encoding="utf-8") as fh:
            fh.write(make_stale(shipped))

        r = subprocess.run(
            ["python3", os.path.join(REPO, "lib", "merge_env.py"),
             stale_path, os.path.join(REPO, "env.conf.verify-shipped"),
             "--out", merged_path],
            capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            # The shipped copy has to exist on disk for the merge to read it.
            with open(os.path.join(REPO, "env.conf.verify-shipped"), "w",
                      encoding="utf-8") as fh:
                fh.write(shipped)
            r = subprocess.run(
                ["python3", os.path.join(REPO, "lib", "merge_env.py"),
                 stale_path, os.path.join(REPO, "env.conf.verify-shipped"),
                 "--out", merged_path],
                capture_output=True, text=True, timeout=60)
        rep = json.loads(r.stdout)

        check("a setting the user changed is preserved",
              value_of(merged_path, "MODEL"), '"mlx-q-9b"')
        check("a second one too", value_of(merged_path, "KV_QUANT"), '"q8_0"')
        check("a third one too", value_of(merged_path, "THINKING"), '"medium"')
        check("a setting the file never had arrives",
              value_of(merged_path, "EXPERT_PROFILE"), '"speed"')
        check("and the report says it was added",
              "EXPERT_PROFILE" in rep["added"], True)

        # The renamed one is the interesting case: it must arrive under the new
        # name carrying the old value, not silently reset to the default.
        check("a renamed setting keeps its value under the new name",
              value_of(merged_path, "PICK_TIMEOUT_SECONDS"), "12")
        check("and the rename is reported",
              rep["renamed"], {"MODEL_PICK_SECONDS": "PICK_TIMEOUT_SECONDS"})

        check("a setting nothing reads is dropped",
              value_of(merged_path, "NGRAM_PREWARM"), None)
        check("and reported as dropped", rep["removed"], ["NGRAM_PREWARM"])

        # ── and the result has to actually load ────────────────────────────
        subprocess.run(["cp", merged_path, ENV], check=True)
        out = subprocess.run(
            ["bash", "-c",
             f'source {REPO}/lib/common.sh >/dev/null 2>&1; load_config && '
             'printf "%s|%s|%s" "$MODEL" "$KV_QUANT" "$PICK_TIMEOUT_SECONDS"'],
            capture_output=True, text=True, timeout=60)
        check("the migrated file loads, with the user's values",
              out.stdout.strip(), "mlx-q-9b|q8_0|12")

        # ── running it again must be a no-op ──────────────────────────────
        before = open(ENV, encoding="utf-8").read()
        r2 = subprocess.run([os.path.join(REPO, "update_env.sh"), "--yes"],
                            capture_output=True, text=True, timeout=120, cwd=REPO)
        check("a second run reports nothing to do",
              "already current" in r2.stdout, True)
        check("and leaves the file byte-identical",
              open(ENV, encoding="utf-8").read() == before, True)

        # ── the shipped file must be current with itself ──────────────────
        subprocess.run(["cp", backup, ENV], check=True)
        r3 = subprocess.run([os.path.join(REPO, "update_env.sh"), "--dry-run"],
                            capture_output=True, text=True, timeout=120, cwd=REPO)
        check("the shipped env.conf is already current",
              "already current" in r3.stdout, True)

        for p in (stale_path, merged_path, os.path.join(REPO, "env.conf.verify-shipped")):
            if os.path.exists(p):
                os.unlink(p)
    finally:
        shutil.copyfile(backup, ENV)
        os.unlink(backup)
        for extra in (ENV + ".verify-stale", ENV + ".verify-merged",
                      os.path.join(REPO, "env.conf.verify-shipped")):
            if os.path.exists(extra):
                os.unlink(extra)
        # update_env.sh makes a timestamped backup of its own; the test does not
        # need to leave one in the working tree.
        for f in os.listdir(REPO):
            if f.startswith("env.conf.bak-"):
                os.unlink(os.path.join(REPO, f))

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
