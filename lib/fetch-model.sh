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
# Engine-aware model fetcher.
#
#   ./lib/fetch-model.sh <owner/name> <destination-dir>
#
# The two engines download different things and cannot share an implementation:
#
#   gguf  one weight file, chosen from the repo's quant ladder, plus a vision
#         projector and an MTP draft head when the repo publishes them
#   mlx   every shard the pack's model.safetensors.index.json names, so the
#         result is a complete tree rather than a single file
#
# So this is a dispatcher, and each engine keeps its own proven fetcher. Both
# take the same two arguments and both resume partial downloads.

REPO="${1:-}"
DEST="${2:-}"

# The per-engine fetchers source lib/common.sh themselves, but this dispatcher
# runs before them and needs the registry to resolve the engine.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$LIB_DIR/common.sh"

[[ -n "$REPO" ]] || die "usage: fetch-model.sh <owner/name> <dest-dir>"

# Which engine fetches this. FETCH_ENGINE lets a caller that already knows
# settle it - model_download.sh --engine passes it through for a custom repo
# whose name says neither GGUF nor MTPLX.
ENGINE="${FETCH_ENGINE:-}"
if [[ -z "$ENGINE" ]]; then
  ENGINE="$(model_engine_for "$REPO")"
fi
[[ -n "$ENGINE" ]] || ENGINE="gguf"

FETCHER="$LIB_DIR/fetch-model-$ENGINE.sh"
[[ -f "$FETCHER" ]] || die "No fetcher for engine '$ENGINE' at $FETCHER"

# shellcheck source=/dev/null
exec "$FETCHER" "$REPO" "$DEST"
