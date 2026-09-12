#!/usr/bin/env bash
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

python3 - "$DEST/.manifest.json" "$MODEL_QUANT" "$DEST/.quant" > "$MANIFEST" <<'PY'
import json, os, re, sys

pref = (sys.argv[2] or "Q4_K_M").strip().upper()
d = json.load(open(sys.argv[1]))

# Quality order to fall back through when the preferred quant is absent.
# Q4_K_M first: the measured sweet spot on Apple silicon. Then the nearest
# neighbours by quality-per-byte before dropping to something much smaller.
LADDER = ["Q4_K_M", "Q4_K_S", "Q5_K_M", "Q3_K_M", "Q5_K_S",
          "Q6_K", "Q3_K_L", "Q4_0", "Q8_0", "Q2_K", "BF16", "F16", "F32"]

TAG = re.compile(r"(?i)(IQ\d+_[A-Z0-9_]+|Q\d+_K_[A-Z]+|Q\d+_K|Q\d+_\d|BF16|F16|F32)")


def quant_of(name):
    base = name.rsplit("/", 1)[-1]
    base = re.sub(r"(?i)\.gguf$", "", base)
    base = re.sub(r"-\d{5}-of-\d{5}$", "", base)
    hits = TAG.findall(base)
    return hits[-1].upper() if hits else ""


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

# Group the main weights by quant tag; a split model contributes several parts
# that all share one tag, so grouping keeps every part of the chosen quant.
groups = {}
for n, s in main:
    groups.setdefault(quant_of(n), []).append((n, s))

chosen = ""
if pref in groups:
    chosen = pref
elif len(groups) <= 1:
    # Single-quant repo with no recognisable tag: take what is there.
    chosen = next(iter(groups), "")
else:
    for q in LADDER:
        if q in groups:
            chosen = q
            break
    if not chosen:
        # Unknown naming: fall back to the largest below the preferred size,
        # which is the closest a heuristic can get to "the useful one".
        chosen = max(groups, key=lambda q: sum(s or 0 for _, s in groups[q]))

wanted = {n for n, _ in groups.get(chosen, [])}
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
rm -f "$DEST/.quant"

if [[ -n "$CHOSEN" ]]; then
  info "quant ${CHOSEN} selected - fetching $COUNT files, $TOTAL GB"
  info "other quants in this repo are skipped (set MODEL_QUANT to change)"
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

rm -f "$DEST/.manifest.tsv" "$DEST/.manifest.json"

if (( BAD )); then
  die "Downloaded files are incomplete. Re-run ./install.sh - it resumes where it stopped."
fi

DU="$(du -sh "$DEST" | cut -f1)"
ok "Model ready at $DEST  ($DU)"
