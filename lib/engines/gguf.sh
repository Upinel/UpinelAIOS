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
# GGUF engine - llama.cpp.
#
# Sourced by start.sh and install.sh when the selected model is a GGUF
# checkpoint. Everything engine-specific lives here: which binary to run, how to
# recognise a complete model on disk, how to turn env.conf into command-line
# flags, and how to launch.
#
# The shared front end (config, registry, picker, chat, dashboard) knows none of
# this and only calls the engine_* functions below.

# ── presence ─────────────────────────────────────────────────────────────────
engine_present() {
  command -v llama-server >/dev/null 2>&1
}

engine_name() { echo "llama.cpp"; }

engine_version() {
  llama_version
}

engine_install_hint() {
  echo "Run ./install.sh first, or: brew install llama.cpp"
}

# Nothing to install beyond the binary itself. LLAMA_SERVER in env.conf may
# point at a patched build for models whose draft head needs it.
engine_setup() { :; }

# ── model on disk ────────────────────────────────────────────────────────────
# A GGUF model directory is usable when it holds a main weights file. Draft
# heads and projectors are optional extras, not requirements.
engine_model_ok() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ -n "$(model_main_gguf "$dir" 2>/dev/null || true)" ]]
}

engine_main_file() {
  model_main_gguf "$1" 2>/dev/null || true
}

# Human-facing one-liner for the picker.
engine_model_summary() {
  local dir="$1" main
  main="$(engine_main_file "$dir")"
  [[ -n "$main" ]] || { echo "incomplete"; return 0; }
  echo "$(basename "$main")"
}

# ── command line ─────────────────────────────────────────────────────────────
# Builds ARGS[] from the unified config. Declares ARGS global on purpose: the
# caller echoes it for --print and passes it to the binary.
engine_build_args() {
  local dir="$1"
  local main mmproj draft depth budget

  main="$(model_main_gguf "$dir" || true)"
  [[ -n "$main" ]] || die "No GGUF weights found in $dir"

  mmproj=""
  if (( ENABLE_VISION )); then
    mmproj="$(model_mmproj_gguf "$dir" || true)"
    [[ -n "$mmproj" ]] || warn "ENABLE_VISION=1 but no mmproj found; serving text only."
  fi

  draft="$(model_draft_gguf "$dir" || true)"
  depth="$(effective_depth)"

  # A trimmed-vocabulary draft head accepts fewer tokens the deeper you draft,
  # so depth 1 beats depth 3 for those. Only when the user left MTP_DEPTH=auto
  # and no tuned value exists.
  if [[ "$MTP_DEPTH" == "auto" ]] && [[ -n "$draft" ]] \
     && [[ -z "$(tuned_depth)" ]] && draft_needs_patched_runtime "$draft"; then
    depth=1
  fi
  if (( depth > 0 )) && [[ -z "$draft" ]]; then depth=0; fi

  # A draft built against a patched llama.cpp will not load on a stock one, and
  # llama-server treats that as fatal. Detect it rather than letting "a bit more
  # speed" become "will not start".
  LLAMA_BIN="llama-server"
  if (( depth > 0 )) && [[ -n "$draft" ]] && draft_needs_patched_runtime "$draft"; then
    if [[ -n "${LLAMA_SERVER:-}" && -x "${LLAMA_SERVER:-}" ]]; then
      LLAMA_BIN="$LLAMA_SERVER"
    elif (( ${DRAFT_PATCHED_RUNTIME:-0} )); then
      LLAMA_BIN="llama-server"
    else
      warn "$(basename "$draft") needs a patched llama.cpp (trimmed draft vocab)."
      warn "Running autoregressive. See docs/GGUF-RUNTIME.md."
      depth=0; draft=""
    fi
  fi

  ARGS=(
    -m "$main"
    -ngl all
    -fa on
    -c "$CONTEXT_WINDOW"
    -b "$BATCH_SIZE"
    -ub "$UBATCH_SIZE"
    --parallel "$PARALLEL_SLOTS"
    -ctk "$KV_QUANT"
    -ctv "$KV_QUANT"
    --host "$HOST"
    --port "$PORT"
    --alias "$SERVED_MODEL_NAME"
    --no-webui
    --metrics
    --timeout 3600
  )

  # Keep the weights resident. Without this macOS can page them out and decode
  # becomes erratic rather than merely slow.
  (( USE_MLOCK )) && ARGS+=( -lm mlock )
  [[ -n "$mmproj" ]] && ARGS+=( --mmproj "$mmproj" )
  [[ -n "${API_KEY:-}" ]] && ARGS+=( --api-key "$API_KEY" )

  if (( depth > 0 )) && [[ -n "$draft" ]]; then
    ARGS+=( -md "$draft" --spec-type draft-mtp --spec-draft-n-max "$depth" --spec-draft-ngl all )
  fi

  # Thinking. Gemma 4's template reads enable_thinking; llama.cpp passes
  # --chat-template-kwargs straight through.
  ARGS+=( --chat-template-kwargs "$(thinking_kwargs)" )

  # Cap the thought channel. Without this "thinking on" is unbounded and the
  # model will spend 300 tokens reasoning about where to find a file.
  budget="$(effective_thinking_budget)"
  if [[ -n "$budget" ]]; then
    ARGS+=( --reasoning-budget "$budget" )
    [[ -n "${THINKING_BUDGET_MESSAGE:-}" ]] && \
      ARGS+=( --reasoning-budget-message "$THINKING_BUDGET_MESSAGE" )
  fi

  # Tool-call reliability. Gemma follows a schema's semantics but not its
  # `required` list, so harnesses see "missing required property" on fields the
  # model judged optional. Naming them in the template fixes it server-side.
  if (( TOOL_TEMPLATE )) && [[ -n "$main" ]]; then
    if python3 "$REPO_DIR/lib/tools-template.py" --gguf "$main" \
         --out "$RUN_DIR/tools-template.jinja" 2>>"$RUN_DIR/template.err"; then
      ARGS+=( --chat-template-file "$RUN_DIR/tools-template.jinja" )
    else
      log "  note: tool template unavailable, using the model's stock template"
    fi
  fi

  ENGINE_DEPTH="$depth"
  ENGINE_DRAFT="${draft:-}"
  ENGINE_MMPROJ="$mmproj"
}

# Extra environment the runtime needs, beyond the command line.
engine_export_env() { :; }

# Lines for the startup banner. Engine-specific facts the shared front end
# cannot know.
engine_banner() {
  if (( ${ENGINE_DEPTH:-0} > 0 )); then
    log "  speculative  depth $ENGINE_DEPTH   ($(basename "$ENGINE_DRAFT"))"
  else
    log "  speculative  off (plain autoregressive)"
  fi
  log "  vision       $([[ -n "${ENGINE_MMPROJ:-}" ]] && echo "on" || echo "off")"
  log "  tensor API   $(gguf_tensor_state)"
}

# Report the RESOLVED state, not the setting: "auto" means something different
# on an M5 than on an M3.
gguf_tensor_state() {
  if chip_has_neural_accelerator; then
    case "${METAL_TENSOR_API:-auto}" in
      off) echo "off (forced)" ;;
      *)   echo "on (M5 Neural Accelerators, ~1.9x prefill)" ;;
    esac
  elif [[ "${METAL_TENSOR_API:-auto}" == "on" ]]; then
    echo "on (forced on a chip without them)"
  else
    echo "off (no Neural Accelerators on this chip)"
  fi
}

# Apply METAL_TENSOR_API to llama.cpp's env vars. It reads these at device init,
# so they must be set before the server starts.
engine_apply_settings() {
  case "${METAL_TENSOR_API:-auto}" in
    auto) ;;
    on)
      if ! chip_has_neural_accelerator; then
        warn "METAL_TENSOR_API=on, but this chip has no Neural Accelerators (M5+)."
        warn "llama.cpp measures the tensor API as ~5% SLOWER on M2 Ultra, neutral on M4."
      fi
      export GGML_METAL_TENSOR_ENABLE=1
      ;;
    off) export GGML_METAL_TENSOR_DISABLE=1 ;;
    *)   die "METAL_TENSOR_API=\"$METAL_TENSOR_API\" is not one of auto | on | off" ;;
  esac
}

engine_binary() { echo "${LLAMA_BIN:-llama-server}"; }
