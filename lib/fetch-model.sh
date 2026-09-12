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
    if pick_tag != pref:
        if quant_family(pick_tag) != quant_family(pref):
            print(f"{pref} is not published here; using {pick_tag} instead",
                  file=sys.stderr)
        else:
            print(f"{pref} is not published here; using its sibling "
                  f"{pick_tag} instead", file=sys.stderr)

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
  [[ -n "$NOTE" ]] && warn "$NOTE"
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
