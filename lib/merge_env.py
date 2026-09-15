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
"""Merge a user's env.conf values onto the shipped env.conf.

git pull updates env.conf only when the user has not edited it. Anyone who has
touched a setting gets a conflict, resolves it by keeping their file, and then
quietly misses every setting added since - including the ones whose *defaults*
changed, which is how a machine ends up running the slower KV quantisation for
months without anyone noticing.

So this takes the shipped file as the structure - new keys, new comments, new
defaults - and puts the user's values back into it. Their settings survive; the
documentation and the new keys arrive.

Deliberately not clever: values are carried across by name and nothing is
inferred. A setting the user never had takes the shipped default, which is the
only defensible choice, and every one of those is reported rather than applied
in silence.

Usage:
    merge_env.py <user-env.conf> <shipped-env.conf> [--out FILE]
Prints a JSON report on stdout.
"""

import json
import re
import sys

LINE = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")

# Names this project has used for the same setting. Applied only when the new
# name is absent, so a file that has both keeps the current one.
RENAMED = {
    "MODEL_PICK_SECONDS": "PICK_TIMEOUT_SECONDS",
}

# Settings that were removed. Reported so the user can delete them; left out of
# the result, since a key nothing reads is a trap rather than a setting.
REMOVED = {"NGRAM_PREWARM"}


def parse(text):
    """KEY -> raw value, exactly as written including any quotes."""
    out = {}
    for line in text.splitlines():
        m = LINE.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def merge(user_text, shipped_text):
    shipped_vals = parse(shipped_text)
    user_vals = parse(user_text)

    renamed = {}
    for old, new in RENAMED.items():
        if old in user_vals and new not in user_vals:
            user_vals[new] = user_vals.pop(old)
            renamed[old] = new

    removed = sorted(k for k in user_vals if k in REMOVED)
    for k in removed:
        user_vals.pop(k, None)

    out_lines = []
    kept, added, changed = [], [], []

    for line in shipped_text.splitlines():
        m = LINE.match(line)
        if not m:
            out_lines.append(line)
            continue
        key, shipped_value = m.group(1), m.group(2)

        if key in user_vals:
            value = user_vals[key]
            out_lines.append(f"{key}={value}")
            kept.append(key)
            if value != shipped_value:
                changed.append({"key": key, "was": shipped_value, "now": value})
        else:
            # A setting this file has never seen: take the shipped default, and
            # say so. Guessing a value for someone else's machine is not this
            # script's job.
            out_lines.append(line)
            added.append(key)

    shipped_keys = set(shipped_vals)
    dropped = sorted(k for k in user_vals if k not in shipped_keys and k not in REMOVED)

    return "\n".join(out_lines) + ("\n" if shipped_text.endswith("\n") else ""), {
        "kept": sorted(kept),
        "added": sorted(added),
        "kept_customised": sorted(c["key"] for c in changed),
        "customised": changed,
        "renamed": renamed,
        "removed": removed,
        "not_in_template": dropped,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out_path = None
    if "--out" in sys.argv:
        out_path = sys.argv[sys.argv.index("--out") + 1]
        args = [a for a in args if a != out_path]

    if len(args) != 2:
        print(json.dumps({"error": "usage: merge_env.py <user> <shipped> [--out FILE]"}))
        return 2

    user_path, shipped_path = args
    try:
        user_text = open(user_path, encoding="utf-8").read()
    except OSError:
        # No env.conf at all: the shipped one is the answer, and there is
        # nothing of the user's to preserve.
        user_text = ""

    shipped_text = open(shipped_path, encoding="utf-8").read()
    merged, report = merge(user_text, shipped_text)
    report["had_no_file"] = not user_text

    if out_path:
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(merged)

    print(json.dumps(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
