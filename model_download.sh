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
# Download uncensored models, switch between them, or bring your own.
#
#   ./model_download.sh                    list models and what is on disk
#   ./model_download.sh mlx-q-35ba3b       download one by alias
#   ./model_download.sh owner/name         download YOUR OWN model by repo id
#   ./model_download.sh --engine gguf owner/name
#                                          ...when the engine is not obvious
#   ./model_download.sh --all              download every known model
#   ./model_download.sh --switch <model>   download if needed, set it as the
#                                          default in env.conf, and restart
#
# EVERY known model is an uncensored fine-tune. UpinelAIOS does not ship or
# suggest aligned models.
#
# CUSTOM MODELS. Any owner/name Hugging Face repo works. The engine is worked
# out from the repo name - MTPLX packs say MTPLX, GGUF files say GGUF - and if
# the name says neither, --engine settles it. A custom repo is not written to
# the alias list; it is fetched into models/ and is then visible to
# ./start.sh's picker like any other.
#
# Downloads resume, so re-running after an interruption is safe and cheap.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

# --engine applies to a custom repo id whose name does not say which runtime
# serves it. It is ignored for a known alias, which already declares one.
ENGINE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) show_usage "$0"; exit 0 ;;
    --engine)
      [[ -n "${2:-}" ]] || die "--engine needs gguf or mlx"
      case "$2" in
        gguf|mlx) ENGINE_OVERRIDE="$2" ;;
        *) die "ENGINE must be gguf or mlx, not '$2'" ;;
      esac
      shift ;;
    *) break ;;
  esac
  shift
done

# What gets fetched for each model: the selected quant, plus the vision
# projector and the MTP draft head. Not the whole repo - several of these
# publish every quant, and the others are skipped. See MODEL_QUANT in env.conf.
size_hint() {
  # MLX packs are checked first, because the two engines' repo names overlap -
  # both publish a "Qwen3.8-9B", at 5 GB and 6 GB respectively - and matching on
  # the family alone would report the wrong one.
  case "$1" in
    *MTPLX*|*mtplx*)
      case "$1" in
        *6bit*|*6-bit*)          echo "23 GB" ;;
        *3bit*|*3-bit*)          echo "13 GB" ;;
        *35B-A3B*)               echo "22 GB" ;;
        *9B*)                    echo "5 GB"  ;;
        *)                       echo "15 GB" ;;
      esac
      return 0 ;;
  esac

  case "$1" in
    *q4_0-heretic*) echo "15 GB" ;;
    *Qwen3.8-27B*)  echo "19 GB" ;;
    *Qwen3.8-9B*)   echo "6 GB"  ;;
    *Qwen3.6-35B*)  echo "22 GB" ;;
    *26B-A4B*)      echo "18 GB" ;;
    *12B*)          echo "8 GB"  ;;
    *31B*)          echo "20 GB" ;;
    *E4B*)          echo "6 GB"  ;;
    *E2B*)          echo "4 GB"  ;;
    *)              echo "?"     ;;
  esac
}

# Engine-aware: a GGUF model is one weight file, an MLX pack is an
# index-complete shard tree, so "downloaded?" means different things.
model_on_disk() {
  local dir="$MODELS_DIR/${1//\//--}"
  case "$(model_engine_for "$1")" in
    mlx) model_dir_ok "$dir" ;;
    *)   model_present "$dir" ;;
  esac
}
disk_usage()    { du -shL "$MODELS_DIR/${1//\//--}" 2>/dev/null | awk '{print $1}'; }

list_models() {
  step "Known uncensored models"
  printf '  %-5s %-12s %-8s %-12s %s\n' "ENG" "ALIAS" "SIZE" "ON DISK" "REPO"
  printf '  %-5s %-12s %-8s %-12s %s\n' "-----" "------------" "--------" "------------" "------------------------------------------"
  for alias in $MODEL_ALIASES; do
    repo="$(model_repo_for "$alias")"
    if model_on_disk "$repo"; then
      state="${C_GREEN}yes${C_RESET} $(disk_usage "$repo")"
    else
      state="${C_DIM}no${C_RESET}"
    fi
    marker=""
    [[ "$repo" == "$MODEL_REPO" ]] && marker="  ${C_CYAN}<- current${C_RESET}"
    eng="$(model_engine_for "$repo")"
    case "$eng" in
      gguf) engc="$C_YELLOW" ;;
      mlx)  engc="$C_BLUE"   ;;
      *)    engc="$C_DIM"    ;;
    esac
    engup="$(printf '%s' "$eng" | tr '[:lower:]' '[:upper:]')"
    printf "  %b%-5s%b %-12s %-8s %-12b %s%b\n" \
      "$engc" "$engup" "$C_RESET" "$alias" "$(size_hint "$repo")" "$state" "$repo" "$marker"
  done
  log ""
  log "  ${C_DIM}current selection: $MODEL_REPO${C_RESET}"
  log "  ${C_DIM}quant:             ${MODEL_QUANT:-Q4_K_M} (set MODEL_QUANT in env.conf)${C_RESET}"
  log "  ${C_DIM}models live in:    $MODELS_DIR${C_RESET}"
  log ""
  log "  ${C_DIM}ENG is the engine that will serve the model - GGUF for llama.cpp,${C_RESET}"
  log "  ${C_DIM}MLX for MTPLX. The engine follows the model; there is nothing to set.${C_RESET}"
  log "  ${C_DIM}Downloading from an engine you do not have yet offers to install it.${C_RESET}"
  log ""
  log "  Download one:   ./model_download.sh 12b"
  log "  Switch to one:  ./model_download.sh --switch gguf-g-12b"
  log "  ${C_DIM}Your own model: any owner/name Hugging Face repo works, e.g.${C_RESET}"
  log "  ${C_DIM}  ./model_download.sh someone/some-uncensored-GGUF${C_RESET}"
  log "  ${C_DIM}  ./model_download.sh --engine mlx someone/some-MTPLX-pack${C_RESET}"
}

download_one() {
  local want="$1"
  local repo; repo="$(model_repo_for "$want")" || return 1
  local dir="$MODELS_DIR/${repo//\//--}"

  if model_on_disk "$repo"; then
    ok "$want is already on disk ($(disk_usage "$repo"))"
    # "On disk" is not the same as "complete". A GGUF model can be missing the
    # draft head that turns MTP on, and an install made before the companion
    # fetch existed has exactly that problem - it works, just slower, and says
    # nothing. Repair it here rather than silently leaving it autoregressive.
    if [[ "$(model_engine_for "$want")" == "gguf" ]] && [[ -n "$(model_companion_for "$want")" ]]; then
      COMPANIONS_ONLY=1 FETCH_ENGINE=gguf \
        "$REPO_DIR/lib/fetch-model.sh" "$repo" "$dir" || \
        warn "Companion check did not finish; MTP may stay off for this model."
    fi
    return 0
  fi

  # The engine follows the model. If this is the first model from the other
  # engine, install that engine now rather than failing later at ./start.sh.
  local eng
  if [[ -n "$ENGINE_OVERRIDE" ]]; then
    eng="$ENGINE_OVERRIDE"
  else
    eng="$(model_engine_for "$want")"
    [[ -n "$eng" ]] || eng="$(model_engine_for "$repo")"
  fi
  if [[ -z "$eng" ]]; then
    # A custom repo whose name says neither. Guessing gguf is right most of the
    # time, but say so rather than let it fail confusingly later.
    warn "Cannot tell whether '$repo' is a GGUF or MTPLX repo from its name."
    warn "Assuming GGUF. Use --engine mlx if that is wrong."
    eng="gguf"
  fi
  load_engine "$eng"

  step "Downloading $want  ($(engine_name))"
  log "  repo:  $repo"
  log "  size:  about $(size_hint "$repo")"
  if [[ "$eng" == "gguf" ]]; then
    log "  quant: ${MODEL_QUANT:-Q4_K_M}  (other quants in the repo are skipped)"
  fi
  log ""

  if ! engine_present; then
    log "  ${C_DIM}$(engine_name) is not installed, and this model needs it.${C_RESET}"
    if ask_yes_no "Install $(engine_name) now?" y; then
      engine_install || return 1
    else
      warn "Cannot download $want without $(engine_name)."
      return 1
    fi
  fi

  FETCH_ENGINE="$eng" "$REPO_DIR/lib/fetch-model.sh" "$repo" "$dir" || return 1

  if engine_model_ok "$dir"; then
    ok "Model ready: $(engine_model_summary "$dir")"
  else
    warn "Downloaded, but the model looks incomplete for $(engine_name) in $dir"
  fi
  # What counts as an extra depends on the engine, so the engine reports it.
  # These checks used to be inline and GGUF-only, which meant every MLX pack
  # was told it had no draft file and would run autoregressive - a warning
  # about a file MLX does not use, on models whose MTP worked.
  engine_post_fetch_notes "$dir"
}

switch_to() {
  local want="$1"
  local repo; repo="$(model_repo_for "$want")" || return 1

  if ! model_on_disk "$repo"; then
    download_one "$want" || die "Download failed; not switching."
  fi

  info "Set MODEL in env.conf to:"
  log "    $repo"
  python3 - "$ENV_FILE" "$repo" <<'PY'
import re, sys
path, repo = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'^MODEL=.*$', f'MODEL="{repo}"', s, count=1, flags=re.M)
if n != 1:
    raise SystemExit(f"could not set MODEL in {path}")
open(path, 'w').write(s)
PY
  ok "env.conf updated."

  log ""
  if pid_alive || [[ -n "$(port_pids)" ]]; then
    info "Restarting to pick it up..."
    "$REPO_DIR/restart.sh"
  else
    info "Nothing running. Start it with ./start.sh"
  fi
}

case "${1:-}" in
  "")
    list_models
    ;;
  --all)
    step "Downloading every known model"
    log "  ${C_DIM}One quant each (${MODEL_QUANT:-Q4_K_M}), not every quant the repos publish.${C_RESET}"
    log "  ${C_DIM}Expect roughly 50 GB rather than several hundred.${C_RESET}"
    log ""
    failed=0
    for alias in $MODEL_ALIASES; do
      download_one "$alias" || { warn "failed: $alias"; failed=1; }
    done
    log ""
    (( failed )) && die "Some downloads failed. Re-run to resume."
    ok "All known models are on disk."
    ;;
  --switch)
    [[ -n "${2:-}" ]] || die "--switch needs a model, e.g. ./model_download.sh --switch gguf-g-12b"
    switch_to "$2"
    ;;
  -*)  die "Unknown argument: $1  (try --help)" ;;
  *)   download_one "$1" ;;
esac
