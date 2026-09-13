#!/usr/bin/env bash
# Download uncensored Gemma 4 and Qwen models and switch between them.
#
#   ./model_download.sh                 list known models and what is on disk
#   ./model_download.sh 12b             download one
#   ./model_download.sh --all           download every known model
#   ./model_download.sh --switch 12b    download if needed, set it as the
#                                       default in env.conf, and restart
#
# EVERY known model is an uncensored Gemma 4 fine-tune. UpinelAIOS-GGUF does not
# ship or suggest aligned models.
#
# Downloads resume, so re-running after an interruption is safe and cheap.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

case "${1:-}" in
  -h|--help) show_usage "$0"; exit 0 ;;
esac

# What gets fetched for each model: the selected quant, plus the vision
# projector and the MTP draft head. Not the whole repo - several of these
# publish every quant, and the others are skipped. See MODEL_QUANT in env.conf.
size_hint() {
  case "$1" in
    *q4_0-heretic*) echo "15 GB" ;;
    *Qwen3.8-27B*)  echo "19 GB" ;;
    *Qwen3.8-9B*)   echo "6 GB"  ;;
    *Qwen3.6-35B*)  echo "22 GB" ;;
    *26B-A4B*) echo "18 GB" ;;
    *12B*)     echo "8 GB"  ;;
    *31B*)     echo "20 GB" ;;
    *E4B*)     echo "6 GB"  ;;
    *E2B*)     echo "4 GB"  ;;
    *)         echo "?"     ;;
  esac
}

model_on_disk() { model_present "$MODELS_DIR/${1//\//--}"; }
disk_usage()    { du -shL "$MODELS_DIR/${1//\//--}" 2>/dev/null | awk '{print $1}'; }

list_models() {
  step "Known uncensored models"
  printf '  %-12s %-8s %-10s %s\n' "ALIAS" "SIZE" "ON DISK" "REPO"
  printf '  %-12s %-8s %-10s %s\n' "------------" "--------" "----------" "------------------------------------------"
  for alias in $MODEL_ALIASES; do
    repo="$(model_repo_for "$alias")"
    if model_on_disk "$repo"; then
      state="${C_GREEN}yes${C_RESET} $(disk_usage "$repo")"
    else
      state="${C_DIM}no${C_RESET}"
    fi
    marker=""
    [[ "$repo" == "$MODEL_REPO" ]] && marker="  ${C_CYAN}<- current${C_RESET}"
    printf "  %-12s %-8s %-10b %s%b\n" "$alias" "$(size_hint "$repo")" "$state" "$repo" "$marker"
  done
  log ""
  log "  ${C_DIM}current selection: $MODEL_REPO${C_RESET}"
  log "  ${C_DIM}quant:             ${MODEL_QUANT:-Q4_K_M} (set MODEL_QUANT in env.conf)${C_RESET}"
  log "  ${C_DIM}models live in:    $MODELS_DIR${C_RESET}"
  log ""
  log "  ${C_DIM}Size is what will actually be fetched: the selected quant plus the${C_RESET}"
  log "  ${C_DIM}vision projector and MTP draft head. Other quants are skipped.${C_RESET}"
  log ""
  log "  Download one:   ./model_download.sh 12b"
  log "  Switch to one:  ./model_download.sh --switch 12b"
  log "  ${C_DIM}Any owner/name Hugging Face repo also works if it is a GGUF Gemma 4.${C_RESET}"
}

download_one() {
  local want="$1"
  local repo; repo="$(model_repo_for "$want")" || return 1
  local dir="$MODELS_DIR/${repo//\//--}"

  if model_on_disk "$repo"; then
    ok "$want is already on disk ($(disk_usage "$repo"))"
    return 0
  fi

  step "Downloading $want"
  log "  repo:  $repo"
  log "  quant: ${MODEL_QUANT:-Q4_K_M}  (other quants in the repo are skipped)"
  log "  size:  about $(size_hint "$repo")"
  log ""
  "$REPO_DIR/lib/fetch-model.sh" "$repo" "$dir" || return 1

  local main; main="$(model_main_gguf "$dir" || true)"
  if [[ -n "$main" ]]; then
    ok "Weights: $(basename "$main")  ($(( $(stat -f%z "$main") / 1000000000 )) GB)"
  else
    warn "Downloaded, but no main .gguf was found in $dir"
  fi
  if [[ -n "$(model_mmproj_gguf "$dir" || true)" ]]; then
    ok "Vision projector present."
  fi
  if [[ -n "$(model_draft_gguf "$dir" || true)" ]]; then
    ok "Speculative draft present - expect a solid speedup."
  else
    warn "No draft file; this model will run autoregressive only."
  fi
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
    [[ -n "${2:-}" ]] || die "--switch needs a model, e.g. ./model_download.sh --switch 12b"
    switch_to "$2"
    ;;
  -*)  die "Unknown argument: $1  (try --help)" ;;
  *)   download_one "$1" ;;
esac
