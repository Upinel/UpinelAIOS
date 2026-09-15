#!/usr/bin/env bash
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
# Every offline regression suite, in one command.
#
#   ./bench/verify-all.sh          all of them
#   ./bench/verify-all.sh --quick  skip the ones that shell out to bash a lot
#
# The suites in here need no model, no server and no network - they check the
# code's own decisions (which model gets picked, which alias resolves where,
# what the installer offers at a given memory size). So they are safe to run
# after any edit, and this is what CI would run if there were CI.
#
# NOT in here: verify-tools.py. It talks to a live endpoint and is a
# diagnostic, not a regression suite - run it via ./bench/verify-tools.sh with
# the server up. Including it would make this script fail on every machine
# with nothing running, which is how a test runner gets ignored.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

# Ordered cheapest-first so an obvious break shows up in the first second.
SUITES="
bench/verify-legacy-aliases.py
bench/verify-engine-suggest.py
bench/verify-bench-prompt.py
bench/verify-kv-table.py
bench/verify-model-picker.py
bench/verify-quant-select.py
bench/verify-draft-select.py
bench/verify-paste.py
"

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=""

printf '\n  UpinelAIOS offline regression suites\n\n'

for suite in $SUITES; do
  if [[ ! -f "$suite" ]]; then
    printf '  %-38s %s\n' "$(basename "$suite")" "MISSING"
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    FAILED_SUITES="$FAILED_SUITES $suite"
    continue
  fi

  out="$(python3 "$suite" 2>&1)"
  rc=$?

  # Every suite prints "<n> passed, <m> failed"; read it rather than trusting
  # the exit code alone, so a suite that dies early is still visible.
  line="$(printf '%s\n' "$out" | grep -E '[0-9]+ passed,' | tail -1)"
  if [[ -z "$line" ]]; then
    printf '  %-38s %s\n' "$(basename "$suite")" "NO SUMMARY (rc=$rc)"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
    TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
    FAILED_SUITES="$FAILED_SUITES $suite"
    continue
  fi

  n_pass="$(printf '%s' "$line" | sed -n 's/^ *\([0-9]*\) passed.*/\1/p')"
  n_fail="$(printf '%s' "$line" | sed -n 's/.*, *\([0-9]*\) failed.*/\1/p')"
  TOTAL_PASS=$(( TOTAL_PASS + ${n_pass:-0} ))
  TOTAL_FAIL=$(( TOTAL_FAIL + ${n_fail:-0} ))

  if (( ${n_fail:-0} > 0 )) || (( rc != 0 )); then
    printf '  %-38s %s\n' "$(basename "$suite")" "FAIL  ($line)"
    # Show what broke - a count with no detail is not actionable.
    printf '%s\n' "$out" | grep -A2 '\[FAIL\]' | head -20 | sed 's/^/      /'
    FAILED_SUITES="$FAILED_SUITES $suite"
  else
    printf '  %-38s %s\n' "$(basename "$suite")" "ok    ($line)"
  fi
done

# A syntax error in any shell file breaks everything at once, and no Python
# suite would necessarily notice.
SYNTAX_BAD=0
for f in "$REPO_DIR"/*.sh "$REPO_DIR"/lib/*.sh "$REPO_DIR"/lib/engines/*.sh; do
  [[ -f "$f" ]] || continue
  if ! bash -n "$f" 2>/dev/null; then
    printf '  %-38s %s\n' "$(basename "$f")" "SYNTAX ERROR"
    SYNTAX_BAD=$(( SYNTAX_BAD + 1 ))
  fi
done
if (( SYNTAX_BAD == 0 )); then
  printf '  %-38s %s\n' "shell syntax (all .sh)" "ok"
else
  TOTAL_FAIL=$(( TOTAL_FAIL + SYNTAX_BAD ))
fi

printf '\n  %s passed, %s failed' "$TOTAL_PASS" "$TOTAL_FAIL"
if [[ -n "$FAILED_SUITES" ]]; then
  printf '   - failing:%s' "$FAILED_SUITES"
fi
printf '\n\n'

(( TOTAL_FAIL == 0 )) || exit 1
