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
# Bring env.conf up to date with the version this checkout ships.
#
#   ./update_env.sh              show what would change, then ask
#   ./update_env.sh --dry-run    show what would change and stop
#   ./update_env.sh --yes        apply without asking
#
# Why this exists: `git pull` only updates env.conf when you have not edited it.
# Edit one setting and you get a conflict, resolve it by keeping your file, and
# from then on you silently miss every setting added since - including the ones
# whose DEFAULTS changed, which is how a machine keeps running the slower KV
# quantisation for months with nothing to show for it.
#
# Your values are kept. New settings arrive with the shipped defaults, new
# comments arrive with them, and every addition is reported rather than applied
# behind your back. Nothing is inferred: a setting you never had takes the
# default this checkout was measured with, because guessing a value for someone
# else's Mac is not this script's job.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) show_usage "$0"; exit 0 ;;
    *)         die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

require_bin python3 "python3 is required."

# The shipped file, straight from git. Reading it from the working tree would
# compare the user's file with itself once they have edited it.
TEMPLATE="$(mktemp -t aios-env-template.XXXXXX)"
MERGED="$(mktemp -t aios-env-merged.XXXXXX)"
trap 'rm -f "$TEMPLATE" "$MERGED"' EXIT

if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$REPO_DIR" show HEAD:env.conf > "$TEMPLATE" 2>/dev/null || true
fi
if [[ ! -s "$TEMPLATE" ]]; then
  # Not a git checkout, or env.conf is untracked. The working copy is all there
  # is, which makes the comparison meaningless - say so rather than pretend.
  die "Cannot read env.conf from git. Run this from a git checkout of the project."
fi

step "UpinelAIOS env.conf update"

REPORT="$(python3 "$REPO_DIR/lib/merge_env.py" "$ENV_FILE" "$TEMPLATE" --out "$MERGED")" \
  || die "The merge failed; env.conf is untouched."

read_field() {
  printf '%s' "$REPORT" | python3 -c "
import json, sys
d = json.load(sys.stdin)
v = d.get('$1')
print('\n'.join(v) if isinstance(v, list) else (v or ''))
"
}

ADDED="$(read_field added)"
REMOVED="$(read_field removed)"
NOT_IN_TEMPLATE="$(read_field not_in_template)"
CUSTOMISED="$(read_field kept_customised)"
RENAMED="$(printf '%s' "$REPORT" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('renamed', {})))")"
NO_FILE="$(read_field had_no_file)"

if diff -q "$ENV_FILE" "$MERGED" >/dev/null 2>&1; then
  ok "env.conf is already current - nothing to change."
  exit 0
fi

log ""
if [[ "$NO_FILE" == "True" ]]; then
  info "No env.conf found; the shipped one will be written."
fi

if [[ -n "$ADDED" ]]; then
  log "  ${C_BOLD}New settings this checkout adds${C_RESET} ${C_DIM}(shipped defaults)${C_RESET}"
  printf '%s\n' "$ADDED" | while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    v="$(grep -m1 "^${k}=" "$MERGED" 2>/dev/null | cut -d= -f2- || true)"
    printf '    %-26s %s\n' "$k" "$v"
  done
  log ""
fi

if [[ -n "$CUSTOMISED" ]]; then
  # Shown with the shipped value beside it, because the point of this script is
  # the settings whose DEFAULTS changed - a machine left on the old value keeps
  # behaving the old way, and nothing anywhere says so. Reporting both is the
  # difference between keeping your settings and being stuck on them.
  log "  ${C_BOLD}Your settings${C_RESET} ${C_DIM}(yours is kept either way)${C_RESET}"
  printf '%s\n' "$CUSTOMISED" | while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    # `|| true` on both: a key can be legitimately absent - PICK_TIMEOUT_SECONDS
    # is, when the file still uses the old name - and under `set -e` with
    # pipefail a failing command substitution exits the script. That is how this
    # list stopped after two entries the first time it ran.
    mine="$(grep -m1 "^${k}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
    # A renamed setting has no line under the new name in the user's file. Read
    # the old one and say where it came from, or the report shows a blank value
    # for something that is being carried across perfectly well.
    from_old=""
    if [[ -z "$mine" ]]; then
      old_name="$(printf '%s' "$RENAMED" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for old, new in d.items():
    if new == '$k': print(old); break
" 2>/dev/null || true)"
      if [[ -n "$old_name" ]]; then
        mine="$(grep -m1 "^${old_name}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
        [[ -n "$mine" ]] && from_old=" ${C_DIM}(from ${old_name})${C_RESET}"
      fi
    fi
    theirs="$(grep -m1 "^${k}=" "$TEMPLATE" 2>/dev/null | cut -d= -f2- || true)"
    if [[ "$mine" == "$theirs" ]]; then
      printf '    %-26s %s\n' "$k" "$mine"
    else
      # Double quotes so the colour codes expand. Single quotes make printf
      # print the literal text ${C_DIM} - the same trap the install menu had.
      printf "    %-26s %s%s  %s(this version ships %s)%s\\n" \
        "$k" "$mine" "$from_old" "$C_DIM" "$theirs" "$C_RESET"
    fi
  done
  log ""
fi

if [[ -n "$REMOVED" ]]; then
  log ""
  warn "No longer used, and dropped: $(printf '%s' "$REMOVED" | tr '\n' ' ')"
  warn "Nothing reads them, so leaving them in was a setting that did nothing."
fi

if [[ -n "$NOT_IN_TEMPLATE" ]]; then
  log ""
  warn "In your file but not in this version: $(printf '%s' "$NOT_IN_TEMPLATE" | tr '\n' ' ')"
  warn "Kept - if a setting is gone from the shipped file it is usually renamed."
fi

log ""
log "  ${C_DIM}The result is the shipped file - comments, keys and defaults - with${C_RESET}"
log "  ${C_DIM}your values put back. Your comments are not carried across.${C_RESET}"
log ""

if (( DRY_RUN )); then
  diff -u "$ENV_FILE" "$MERGED" | head -60 || true
  log ""
  info "--dry-run given; env.conf is untouched."
  exit 0
fi

if (( ! ASSUME_YES )); then
  if [[ ! -c /dev/tty ]]; then
    info "No terminal attached; nothing changed. Re-run with --yes to apply."
    exit 0
  fi
  printf '  Apply this to env.conf? [Y/n] '
  reply=""
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    n|N|no|NO) info "Nothing changed."; exit 0 ;;
  esac
fi

BACKUP="$ENV_FILE.bak-$(date +%Y%m%d-%H%M%S)"
cp "$ENV_FILE" "$BACKUP" 2>/dev/null || true
cp "$MERGED" "$ENV_FILE"
ok "env.conf updated. Backup at $(basename "$BACKUP")"
log ""
log "  ${C_DIM}Apply it to a running server with ./restart.sh.${C_RESET}"
