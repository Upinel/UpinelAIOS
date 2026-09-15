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
# MLX engine - MTPLX.
#
# Sourced by start.sh and install.sh when the selected model is an MTPLX pack.
# Mirrors the contract in lib/engines/gguf.sh exactly, so the shared front end
# does not care which one it is talking to.

# ── presence ─────────────────────────────────────────────────────────────────
engine_present() {
  command -v mtplx >/dev/null 2>&1
}

engine_name() { echo "MLX / MTPLX"; }

engine_version() {
  # mtplx prints its version to stdout, unlike llama-server which uses stderr.
  mtplx --version 2>/dev/null | head -1
}

engine_install_hint() {
  echo "Run ./install.sh first, or: brew install youssofal/mtplx/mtplx"
}

# MTPLX bootstraps a Python runtime on first use.
engine_setup() { :; }

# ── model on disk ────────────────────────────────────────────────────────────
# An MLX pack is a tree of safetensors shards, not one file. Completeness is
# judged against model.safetensors.index.json where the pack ships one, because
# a half-finished download otherwise looks exactly like a finished one.
engine_model_ok() {
  model_dir_ok "$1"
}

engine_main_file() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find -L "$dir" -maxdepth 1 -name '*.safetensors' -type f 2>/dev/null | head -1
}

engine_model_summary() {
  local dir="$1" gb
  gb="$(model_dir_gb "$dir" 2>/dev/null || echo 0)"
  if [[ "${gb:-0}" == "0" ]]; then echo "incomplete"; else echo "${gb} GB"; fi
}

# ── command line ─────────────────────────────────────────────────────────────
engine_build_args() {
  local dir="$1"

  [[ -d "$dir" ]] || die "No MTPLX model found at $dir"

  EFFECTIVE_DEPTH="$(effective_depth)"
  THINKING_ARGS="$(thinking_flags)"

  ARGS=(
    --model "$dir"
    --profile "$PROFILE"
    --host "$HOST"
    --port "$PORT"
    --context-window "$CONTEXT_WINDOW"
    --max-tokens "$MAX_RESPONSE_TOKENS"
    --paged-kv-quantization "$(kv_quant_for mlx)"
    --batching-preset "$BATCHING_PRESET"
    --max-active-requests "$MAX_CONCURRENT"
    --stream-interval "$STREAM_INTERVAL"
    --ssd-session-cache "$SSD_SESSION_CACHE"
    --warmup-tokens "$WARMUP_TOKENS"
    --model-id "$SERVED_MODEL_NAME"
    --no-stats-footer
  )

  if [[ "$EFFECTIVE_DEPTH" == "0" ]]; then
    ARGS+=( --no-mtp )
  else
    ARGS+=( --depth "$EFFECTIVE_DEPTH" )
  fi

  [[ -f "${API_KEY_FILE:-}" ]] && ARGS+=( --api-key-file "$API_KEY_FILE" )
  (( ${RATE_LIMIT:-0} > 0 )) && ARGS+=( --rate-limit "$RATE_LIMIT" )
  ARGS+=( --preserve-thinking "$PRESERVE_THINKING" )
  [[ "$FAN_MODE" != "default" ]] && ARGS+=( --fan-mode "$FAN_MODE" )
  local chunk; chunk="$(prefill_chunk_for mlx)"
  (( chunk > 0 )) && ARGS+=( --prefill-chunk-tokens "$chunk" )

  # shellcheck disable=SC2206
  ARGS+=( $THINKING_ARGS )

  ENGINE_DEPTH="$EFFECTIVE_DEPTH"
}

# MTPLX takes its memory ceilings from the environment rather than the command
# line, and it reads them at startup.
engine_export_env() {
  local mem_bytes per

  # MTPLX otherwise defaults to 75% of physical RAM for the allocator and 60%
  # for wired pages. These pin it instead of guessing.
  mem_bytes=$(( MEMORY_LIMIT_GB * 1024 * 1024 * 1024 ))
  export MTPLX_MEMORY_LIMIT_BYTES="$mem_bytes"
  export MTPLX_MEMORY_BUDGET="$mem_bytes"
  if (( ${WIRED_LIMIT_GB:-0} > 0 )); then
    export MTPLX_WIRED_LIMIT_BYTES=$(( WIRED_LIMIT_GB * 1024 * 1024 * 1024 ))
  fi

  # The session/prefix bank is the biggest allocator after the weights. MTPLX
  # auto-sizes it to half the post-model surplus - ~16 GB on a 64 GB Mac - which
  # is enough to push macOS into swap once a long KV cache is live.
  if (( ${SESSION_BANK_GB:-0} > 0 )); then
    export MTPLX_SESSION_BANK_MAX_BYTES=$(( SESSION_BANK_GB * 1024 * 1024 * 1024 ))
    per=$(( SESSION_BANK_GB / 2 )); (( per < 2 )) && per=2
    export MTPLX_SESSION_BANK_PER_SESSION_BYTES=$(( per * 1024 * 1024 * 1024 ))
  fi
  if (( ${MLX_CACHE_LIMIT_GB:-0} > 0 )); then
    export MTPLX_MLX_CACHE_LIMIT=$(( MLX_CACHE_LIMIT_GB * 1024 * 1024 * 1024 ))
  fi

  apply_thinking_budget_env
}

engine_banner() {
  log "  MTP depth    ${ENGINE_DEPTH:-auto}              (profile: $PROFILE)"
  log "  thinking     $THINKING  (history: $PRESERVE_THINKING)"
  if (( ${SESSION_BANK_GB:-0} > 0 )); then
    log "  session bank ${SESSION_BANK_GB} GB   (prefix cache for repeat turns)"
  fi
  log "  neural accel on (M5; MLX selects NAX kernels automatically)"
}

engine_apply_settings() {
  case "$PROFILE" in
    turbo|sustained|stable|exact|performance-cold|max-diagnostic) ;;
    *) die "PROFILE=\"$PROFILE\" is not a valid MTPLX profile." ;;
  esac
  case "$BATCHING_PRESET" in
    solo|latency|agent|throughput) ;;
    *) die "BATCHING_PRESET=\"$BATCHING_PRESET\" is not one of solo | latency | agent | throughput" ;;
  esac
  case "$SSD_SESSION_CACHE" in
    on|off|write-only) ;;
    *) die "SSD_SESSION_CACHE=\"$SSD_SESSION_CACHE\" is not one of on | off | write-only" ;;
  esac
  case "$PRESERVE_THINKING" in
    auto|on|off|scoped) ;;
    *) die "PRESERVE_THINKING=\"$PRESERVE_THINKING\" is not one of auto | on | off | scoped" ;;
  esac
  # Validate the TRANSLATED value, so the error names the engine's vocabulary.
  case "$(kv_quant_for mlx)" in
    off|q8|q4) ;;
    *) die "KV_QUANT=\"$KV_QUANT\" is not a known cache type (MLX engine accepts q8 | q4 | f16)" ;;
  esac
}

engine_binary() { echo "mtplx"; }
engine_serve_word() { echo "serve"; }
