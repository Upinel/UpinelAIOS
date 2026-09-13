#!/usr/bin/env bash
# One-time setup for UpinelAIOS-GGUF.
#
#   ./install.sh                 scan hardware, suggest settings, install
#   ./install.sh --yes           accept the suggested settings without asking
#   ./install.sh --no-tune       skip the (slow) speculative depth sweep
#   ./install.sh --deps-only     only install llama.cpp
#   ./install.sh --model-only    only download and verify the model
#   ./install.sh --scan-only     print the hardware scan and suggestions, stop
#   ./install.sh --model REPO    use this model instead of env.conf's
#
# Re-running is safe: downloads resume and finished steps are skipped.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config
# shellcheck source=lib/preflight.sh
source "$REPO_DIR/lib/preflight.sh"

DO_DEPS=1; DO_MODEL=1; DO_TUNE=1; DO_SCAN=1
ASSUME_YES=0
MODEL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1 ;;
    --no-scan)    DO_SCAN=0 ;;
    --scan-only)  DO_SCAN=1; DO_DEPS=0; DO_MODEL=0; DO_TUNE=0 ;;
    --deps-only)  DO_MODEL=0; DO_TUNE=0 ;;
    --model-only) DO_DEPS=0; DO_TUNE=0; DO_SCAN=0 ;;
    --no-tune)    DO_TUNE=0 ;;
    --model)      MODEL_OVERRIDE="$2"; shift ;;
    -h|--help)    show_usage "$0"; exit 0 ;;
    *)            die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

step "UpinelAIOS-GGUF - One-Click AI Agent Server OS for Mac, Gemma 4 edition"

is_apple_silicon || die "This bundle targets Apple Silicon Macs. Detected: $(uname -s)/$(uname -m)."
require_macos

# ── 1. hardware scan and configuration ───────────────────────────────────────
if (( DO_SCAN )); then
  run_preflight "$ASSUME_YES" || die "Setup stopped. Fix the issue above and re-run ./install.sh"
  # load_config already re-ran inside apply_config; refresh derived values.
  MODEL_REPO="$(model_repo_for "$MODEL")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
else
  step "Skipping the hardware scan (--model-only)"
fi

# A --model flag beats both env.conf and the scan, but is not written back:
# it is a one-off choice for this run.
if [[ -n "$MODEL_OVERRIDE" ]]; then
  MODEL_REPO="$(model_repo_for "$MODEL_OVERRIDE")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
  info "Overriding the model for this run: $MODEL_REPO"
  info "To make it permanent, set MODEL in env.conf."
fi

if (( DO_MODEL || DO_TUNE )); then
  log ""
  log "  Serving:  $MODEL_REPO"
  log "  Context:  $CONTEXT_WINDOW tokens   KV: $KV_QUANT   profile: $PROFILE"
fi

# ── 2. dependencies ──────────────────────────────────────────────────────────
if (( DO_DEPS )); then
  step "Installing the MTPLX runtime"

  if command -v llama-server >/dev/null 2>&1; then
    ok "llama.cpp already installed: $(llama-server --version 2>/dev/null | head -1)"
  else
    require_bin brew "Install Homebrew from https://brew.sh, then re-run ./install.sh"
    info "brew install llama.cpp"
    brew install llama.cpp
  fi
  ok "llama.cpp ready: $(llama-server --version 2>/dev/null | head -1)"

  command -v python3 >/dev/null 2>&1 || warn "python3 not found - ./bench/bench.sh needs it."
else
  step "Skipping dependency install"
fi

# ── 3. model ─────────────────────────────────────────────────────────────────
if (( DO_MODEL )); then
  step "Fetching the model"
  "$REPO_DIR/lib/fetch-model.sh" "$MODEL_REPO" "$MODEL_DIR"

  info "Checking the model files..."
  MAIN="$(model_main_gguf "$MODEL_DIR" || true)"
  [[ -n "$MAIN" ]] && ok "Weights: $(basename "$MAIN")" || warn "No main .gguf found."
  [[ -n "$(model_mmproj_gguf "$MODEL_DIR" || true)" ]] && ok "Vision projector present."
  if [[ -n "$(model_draft_gguf "$MODEL_DIR" || true)" ]]; then
    ok "Speculative draft present - expect a real speedup."
  else
    warn "No draft file: this model runs autoregressive only."
  fi
else
  step "Skipping model download"
fi

# ── 4. speculative depth ─────────────────────────────────────────────────────
if (( DO_TUNE )); then
  step "Measuring the fastest speculative depth on THIS machine"
  log "     Loads the model several times; 10-20 minutes."
  log "     Depth 1 is the shipped default; this measures your Mac."
  log ""
  if [[ ! -d "$MODEL_DIR" ]]; then
    warn "Model directory missing, skipping."
  elif "$REPO_DIR/bench/bench.sh" --tune; then
    ok "Tune complete."
  else
    warn "Auto-tune did not complete; MTP_DEPTH=auto will use depth 1,"
    warn "which is the measured optimum on the reference M5 Pro."
  fi
else
  step "Skipping the depth sweep (MTP_DEPTH=auto will use depth 1)"
fi

# ── 5. optional wired-memory ceiling ─────────────────────────────────────────
if (( WIRED_LIMIT_GB > 0 )); then
  step "Raising the macOS GPU wired-memory ceiling"
  CURRENT_MB="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
  TARGET_MB=$(( WIRED_LIMIT_GB * 1024 ))
  if (( CURRENT_MB >= TARGET_MB )); then
    ok "Already at ${CURRENT_MB} MB (target ${TARGET_MB} MB)."
  elif (( TARGET_MB > HW_RAM_GB * 1024 * 90 / 100 )); then
    warn "WIRED_LIMIT_GB=${WIRED_LIMIT_GB} is over 90% of RAM. Refusing to apply."
    warn "That setting causes jetsam kills and can leak wired pages on a hard kill."
  else
    warn "Needs sudo once, and does NOT survive a reboot."
    sudo sysctl "iogpu.wired_limit_mb=${TARGET_MB}" \
      && ok "Wired limit set to ${TARGET_MB} MB for this boot." \
      || warn "Could not set it; the macOS default stands."
  fi
fi

# ── done ─────────────────────────────────────────────────────────────────────
if (( DO_DEPS == 0 && DO_MODEL == 0 && DO_TUNE == 0 )); then
  step "Scan complete"
  log "  Review env.conf, then run:  ./install.sh"
  exit 0
fi

step "Install complete"
cat <<EOF

  Start the server:      ./start.sh
  Watch it live:         ./status.sh
  Verify tool calling:   ./bench/verify-tools.sh
  Measure tok/s:         ./bench/bench.sh
  Re-tune MTP depth:     ./bench/bench.sh --tune
  Apply env.conf changes: ./restart.sh
  Stop it:               ./stop.sh

  Config lives in:       env.conf

EOF
