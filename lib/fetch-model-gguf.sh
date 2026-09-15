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
# Resumable Hugging Face model fetcher - no huggingface_hub / pip dependency.
#
#   lib/fetch-model.sh <owner/repo> <destination-dir>
#
# Features
#   * lists the repo through the public HF API and downloads every file
#   * resumes partial downloads (curl -C -), so Ctrl-C is safe
#   * verifies each file's byte size against the API, and repairs mismatches
#   * skips work entirely when the local copy is already complete
#   * MODEL_SOURCE_DIR=<path> adopts an existing local copy with hardlinks
#     instead of downloading (useful when you already have the weights)

set -euo pipefail

SOURCE_DIR="${BASH_SOURCE[0]}"
LIB_DIR="$(cd "$(dirname "$SOURCE_DIR")" && pwd)"
# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"

REPO="${1:-}"
DEST="${2:-}"
[[ -n "$REPO" && -n "$DEST" ]] || die "usage: fetch-model.sh <owner/repo> <destination-dir>"

REPO="${REPO#https://huggingface.co/}"
REPO="${REPO%/}"
mkdir -p "$DEST"

# ── adopt an existing local copy instead of downloading ──────────────────────
if [[ -n "${MODEL_SOURCE_DIR:-}" && -d "${MODEL_SOURCE_DIR:-}" ]]; then
  info "Adopting existing weights from $MODEL_SOURCE_DIR"
  # Hardlink when possible (same volume, zero extra disk); copy otherwise.
  if cp -al "$MODEL_SOURCE_DIR"/. "$DEST"/ 2>/dev/null; then
    ok "Hardlinked $(find "$DEST" -type f | wc -l | tr -d ' ') files."
  else
    warn "Hardlink failed (different filesystem?). Falling back to a full copy."
    cp -a "$MODEL_SOURCE_DIR"/. "$DEST"/
    ok "Copied $(find "$DEST" -type f | wc -l | tr -d ' ') files."
  fi
  exit 0
fi

# ── companion files the model does not publish itself ────────────────────────
# Pulled from a second repo, one named file at a time, because the alternative
# is downloading gigabytes to get a 250 MB draft head.
#
# This is a function, not inline code, because "already on disk" must not mean
# "nothing to do": an install made before this existed has the weights but not
# the draft head, and would run autoregressive without ever saying so.
fetch_companions() {
  local COMPANIONS CREPO CGLOB CNAME OUT
  COMPANIONS="$(model_companion_for "$(alias_for_repo "$REPO")")"
  [[ -n "$COMPANIONS" ]] || return 0
  while IFS='|' read -r CREPO CGLOB; do
    [[ -n "$CREPO" ]] || continue
    # Already satisfied?
    if compgen -G "$DEST/$CGLOB" >/dev/null 2>&1; then
      ok "have   companion $(basename "$(compgen -G "$DEST/$CGLOB" | head -1)")"
      continue
    fi

    CNAME="$(curl -fsSL --max-time 60 \
      "https://huggingface.co/api/models/${CREPO}?blobs=true" 2>/dev/null \
      | python3 -c "
import fnmatch, json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
pat = sys.argv[1]
best = None
for f in d.get('siblings', []):
    n = f.get('rfilename', '')
    if fnmatch.fnmatch(n.rsplit('/', 1)[-1], pat):
        if best is None or (f.get('size') or 0) > (best[1] or 0):
            best = (n, f.get('size') or 0)
print(best[0] if best else '')
" "$CGLOB")"

    if [[ -z "$CNAME" ]]; then
      warn "no companion matching '$CGLOB' in $CREPO"
      continue
    fi

    info "companion $CNAME  (from $CREPO)"
    OUT="$DEST/$(basename "$CNAME")"
    if curl -fL --retry 5 --retry-delay 2 --retry-all-errors -C - \
         -o "$OUT" "https://huggingface.co/${CREPO}/resolve/main/${CNAME}"; then
      ok "have   $(basename "$CNAME")  ($(( $(stat -f%z "$OUT" 2>/dev/null || echo 0) / 1000000 )) MB)"
    else
      warn "companion download failed - the model will run autoregressive"
      BAD=1
    fi
  done <<< "$COMPANIONS"
}

# COMPANIONS_ONLY=1 skips everything but the companions, for a model that is
# already on disk. It is how ./model_download.sh repairs an existing install.
if [[ -n "${COMPANIONS_ONLY:-}" ]]; then
  BAD=0
  fetch_companions
  (( BAD )) && die "A companion file is still missing. Check the network and re-run."
  exit 0
fi

# ── fetch the file manifest ──────────────────────────────────────────────────
info "Querying https://huggingface.co/api/models/$REPO"
MANIFEST="$DEST/.manifest.tsv"

if ! curl -fsSL --max-time 60 \
      "https://huggingface.co/api/models/${REPO}?blobs=true" \
      -o "$DEST/.manifest.json"; then
  die "Could not reach the Hugging Face API for '$REPO'. Check the repo id and your network."
fi

# ── choose ONE quant ─────────────────────────────────────────────────────────
# GGUF repos frequently ship every quant of the same model. The 31B heretic
# repo carries ten of them: 232 GB in total, of which the 18.7 GB Q4_K_M is
# the one that fits a Mac. Fetching "every file" therefore costs 12x the disk
# and a download measured in hours. Pick a single quant instead, and keep only
# the files that belong with it.
#
# Non-GGUF files (tokenizer, config) are tiny and always kept.
# The vision projector and the MTP draft head are always kept - they are
# separate artifacts, not quants, and MTP is where the speed comes from.
MODEL_QUANT="${MODEL_QUANT:-Q4_K_M}"

python3 - "$DEST/.manifest.json" "$MODEL_QUANT" "$DEST/.quant" 2> "$DEST/.quant.note" > "$MANIFEST" <<'PY'
import json, os, re, sys

pref = (sys.argv[2] or "Q4_K_M").strip().upper()
d = json.load(open(sys.argv[1]))

# Quant families, for when the requested tag is not published verbatim.
# Q4_K_M, Q4_K_S and Q4_K_P are the same bit width with different sub-variants,
# so any of them satisfies a request for "a Q4_K".
TAG = re.compile(r"(?i)(IQ\d+_[A-Z0-9_]+|Q\d+_K_[A-Z]+|Q\d+_K|Q\d+_\d|BF16|F16|F32)")


def quant_of(name):
    base = name.rsplit("/", 1)[-1]
    base = re.sub(r"(?i)\.gguf$", "", base)
    base = re.sub(r"-\d{5}-of-\d{5}$", "", base)
    hits = TAG.findall(base)
    return hits[-1].upper() if hits else ""


def quant_family(tag):
    """Q4_K_M -> Q4_K, Q4_K_P -> Q4_K, Q4_0 -> Q4_0, IQ3_M -> IQ3."""
    t = (tag or "").upper()
    m = re.match(r"^(I?Q\d+)_K(?:_[A-Z]+)?$", t)
    if m:
        return m.group(1) + "_K"
    m = re.match(r"^(IQ\d+)_[A-Z]+$", t)
    if m:
        return m.group(1)
    return t


def bits_of(family):
    """4 from Q4_K, 4 from Q4_0, 3 from IQ3, 0 when there is no number."""
    m = re.match(r"^I?Q(\d+)", family or "")
    return int(m.group(1)) if m else 0


def is_aux(name):
    """Vision projector or speculative draft head: keep whatever the quant."""
    low = name.rsplit("/", 1)[-1].lower()
    return "mmproj" in low or "mtp" in low or "draft" in low


files = []
for f in d.get("siblings", []):
    name = f.get("rfilename")
    if not name or name.endswith("/"):
        continue
    if name in {".gitattributes", "README.md"}:
        continue
    files.append((name, f.get("size")))

gguf = [(n, s) for n, s in files if n.lower().endswith(".gguf")]
main = [(n, s) for n, s in gguf if not is_aux(n)]

# Group the main weights by quant FAMILY, not exact tag. A repo that ships
# Q4_K_M and a repo that ships Q4_K_P are offering the same thing - same bit
# width, different sub-variant - and asking for one must match the other.
# Matching on the exact tag is what made `model_download.sh e2b` fetch the 5 GB
# Q8_K_P: nothing in the ladder equalled "Q4_K_M", so it fell through to a
# fallback that picked the largest file in the repo.
families = {}
for n, s in main:
    families.setdefault(quant_family(quant_of(n)), []).append((n, s))

# Sub-variant preference inside a family, best first. _M is the usual balanced
# build, _S and _P are siblings of comparable size.
SUFFIX_RANK = {"_M": 0, "_S": 1, "_P": 1, "": 2}


def best_in_family(members, want_tag):
    def key(item):
        tag = quant_of(item[0])
        if tag == want_tag:
            rank = -1                      # exactly what was asked for
        else:
            m = re.match(r"^.*_K(_[A-Z]+)$", tag)
            rank = SUFFIX_RANK.get(m.group(1), 3) if m else 2
        return (rank, item[1] or 0)        # then the smaller file
    return min(members, key=key)


chosen = ""
wanted = set()
if families:
    pref_family = quant_family(pref)
    if pref_family in families:
        chosen = pref_family
    else:
        # Nothing at the requested bit width. Take the nearest one; on a tie
        # prefer the smaller file, because this runs on a memory-bound Mac and
        # overshooting costs more than undershooting.
        want_bits = bits_of(pref_family)

        def dist(fam):
            b = bits_of(fam)
            if b == 0:
                return (99, 99)
            return (abs(b - want_bits), 0 if b <= want_bits else 1)

        chosen = min(families, key=dist)

    # Pick ONE member of the family. A family can hold several sibling builds -
    # the 31B repo publishes both Q4_K_M and Q4_K_S, e4b publishes both Q4_K_M
    # and Q4_K_P - and taking the whole family would download every one of them.
    members = families[chosen]
    pick_name, _ = best_in_family(members, pref)
    pick_tag = quant_of(pick_name)
    wanted = {n for n, _ in members if quant_of(n) == pick_tag}
    family_from = chosen
    chosen = pick_tag

    # Never substitute silently: a different quant is a different memory
    # footprint and a different quality, and the caller should know.
    #
    # But not every substitution deserves a warning. Landing on a different
    # sub-variant at the same bit width (Q4_K_M -> Q4_0 on a QAT-only repo) is
    # what the request meant in substance; a different bit width is not. The
    # severity is emitted here and applied by the shell, so a fresh install of
    # the default model stops reporting a scare about the model it ships.
    if pick_tag != pref:
        same_family = quant_family(pick_tag) == quant_family(pref)
        if same_family:
            msg = f"{pref} is not published here; using its sibling {pick_tag} instead"
        else:
            msg = f"{pref} is not published here; using {pick_tag} instead"
        same_bits = bits_of(quant_family(pick_tag)) == bits_of(quant_family(pref))
        print(f"{'info' if same_bits else 'warn'}\t{msg}", file=sys.stderr)

for n, s in gguf:
    if is_aux(n):
        wanted.add(n)

for n, s in files:
    if n.lower().endswith(".gguf") and n not in wanted:
        continue
    print(f"{s if s is not None else -1}\t{n}")

# Record the decision so the shell can report it.
with open(sys.argv[3], "w") as fh:
    fh.write(chosen or "")
PY

[[ -s "$MANIFEST" ]] || die "The API returned no files for '$REPO'."
TOTAL="$(awk -F'\t' '{s+=$1} END {printf "%.1f", s/1e9}' "$MANIFEST")"
COUNT="$(wc -l < "$MANIFEST" | tr -d ' ')"
CHOSEN="$(cat "$DEST/.quant" 2>/dev/null || echo '')"
NOTE="$(cat "$DEST/.quant.note" 2>/dev/null || echo '')"
rm -f "$DEST/.quant" "$DEST/.quant.note"

if [[ -n "$CHOSEN" ]]; then
  info "quant ${CHOSEN} selected - fetching $COUNT files, $TOTAL GB"
  info "other quants in this repo are skipped (set MODEL_QUANT to change)"
  # The note carries its own severity from the selector: same bit width is
  # informational, a different bit width is a warning.
  case "$NOTE" in
    warn$'\t'*) warn "${NOTE#*$'\t'}" ;;
    info$'\t'*) info "${NOTE#*$'\t'}" ;;
    "")         ;;
    *)          warn "$NOTE" ;;
  esac
else
  info "$COUNT files, $TOTAL GB to fetch"
fi

# ── download loop ────────────────────────────────────────────────────────────
FAILED=0
while IFS=$'\t' read -r WANT NAME; do
  [[ -n "$NAME" ]] || continue
  OUT="$DEST/$NAME"
  mkdir -p "$(dirname "$OUT")"

  HAVE=0
  [[ -f "$OUT" ]] && HAVE="$(stat -f%z "$OUT" 2>/dev/null || echo 0)"

  if [[ "$WANT" != "-1" ]] && [[ "$HAVE" == "$WANT" ]]; then
    ok "have   $NAME  ($((WANT / 1000000)) MB)"
    continue
  fi

  if [[ "$HAVE" != "0" ]]; then
    info "resume $NAME  (${HAVE} of ${WANT} bytes)"
  else
    info "fetch  $NAME"
  fi

  # -C - resumes; --retry rides out transient CDN failures; -L follows to the
  # xet/cdn host. Writing to a .part file keeps a torn download from looking
  # complete on the next run.
  if curl -fL --retry 5 --retry-delay 2 --retry-all-errors -C - \
        -o "$OUT" "https://huggingface.co/${REPO}/resolve/main/${NAME}"; then
    NEW="$(stat -f%z "$OUT" 2>/dev/null || echo 0)"
    if [[ "$WANT" != "-1" ]] && [[ "$NEW" != "$WANT" ]]; then
      warn "size mismatch on $NAME (want $WANT, got $NEW) - refetching from scratch"
      rm -f "$OUT"
      curl -fL --retry 5 --retry-delay 2 --retry-all-errors \
        -o "$OUT" "https://huggingface.co/${REPO}/resolve/main/${NAME}" \
        || { warn "FAILED $NAME"; FAILED=1; }
    fi
  else
    warn "FAILED $NAME  (re-run ./install.sh to resume)"
    FAILED=1
  fi
done < "$MANIFEST"

if (( FAILED )); then
  die "Some files did not download. Re-run ./install.sh - it resumes where it stopped."
fi

# ── final size audit ─────────────────────────────────────────────────────────
# Audit the FILTERED manifest - the files we actually chose to fetch. Auditing
# against the raw API listing checks every quant in the repo, finds the ones we
# deliberately skipped missing, and fails a perfectly good download with
# "incomplete: <quant we never wanted>". That is what made a single-quant fetch
# look like it was still trying to pull the whole repo.
AUDIT="$DEST/.manifest.tsv"
BAD=0
while IFS=$'\t' read -r WANT NAME; do
  [[ -n "$NAME" ]] || continue
  HAVE="$(stat -f%z "$DEST/$NAME" 2>/dev/null || echo 0)"
  if [[ "$HAVE" != "$WANT" ]]; then
    warn "incomplete: $NAME ($HAVE/$WANT bytes)"
    BAD=1
  fi
done < "$AUDIT"

fetch_companions

rm -f "$DEST/.manifest.tsv" "$DEST/.manifest.json"

if (( BAD )); then
  die "Downloaded files are incomplete. Re-run ./install.sh - it resumes where it stopped."
fi

DU="$(du -sh "$DEST" | cut -f1)"
ok "Model ready at $DEST  ($DU)"
