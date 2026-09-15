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
# Start the UpinelAIOS endpoint - GGUF or MLX, whichever the model needs.
#
#   ./start.sh                 start in the background (default)
#   ./start.sh --foreground    run attached to this terminal (Ctrl-C to stop)
#   ./start.sh --print         print the command it would run, then exit
#   ./start.sh --model mlx-q-9b   serve a different model for this run only
#   ./start.sh --profile agent    master a workload: speed | agent | writer
#
# The engine is not a setting. A model belongs to exactly one runtime - a GGUF
# checkpoint can only run on llama.cpp, an MTPLX pack can only run on MTPLX - so
# choosing the model chooses the engine, and this script loads the matching
# module from lib/engines/ and hands over.
#
# All settings come from env.conf. Apply edits with ./restart.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

FOREGROUND=0; PRINT_ONLY=0; MODEL_OVERRIDE=""; PROFILE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--foreground) FOREGROUND=1 ;;
    --print)         PRINT_ONLY=1 ;;
    --model)         MODEL_OVERRIDE="$2"; shift ;;
    --profile)       PROFILE_OVERRIDE="$2"; shift ;;
    -h|--help)       show_usage "$0"; exit 0 ;;
    *)               die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

step "UpinelAIOS"

# ── preflight ────────────────────────────────────────────────────────────────
is_apple_silicon || die "UpinelAIOS needs an Apple Silicon Mac."
require_bin python3 "python3 is required."

if [[ -n "$MODEL_OVERRIDE" ]]; then
  MODEL_REPO="$(model_repo_for "$MODEL_OVERRIDE")"
  MODEL_ALIAS="$MODEL_OVERRIDE"
  info "Model override for this run: $MODEL_REPO"
else
  MODEL_ALIAS="$(alias_for_repo "$MODEL_REPO")"
fi

# ── which downloaded model to serve ──────────────────────────────────────────
# Offered only when there is a real choice: more than one model on disk, a
# terminal to answer on, and no --model. Anything else keeps env.conf's MODEL,
# so a start in a pipe, in CI or under launchd is never held up by a prompt.
if [[ -z "$MODEL_OVERRIDE" ]] && (( ! PRINT_ONLY )); then
  if choose_model_on_disk; then
    info "Serving $MODEL_REPO for this run. Set MODEL in env.conf to make it permanent."
  fi
fi

# ── which workload to master ─────────────────────────────────────────────────
# Asked here rather than left in env.conf because it changes the launch command
# materially, and which one you want depends on what you are doing today. The
# answer is saved, so the next start defaults to it.
if [[ -n "$PROFILE_OVERRIDE" ]]; then
  case "$PROFILE_OVERRIDE" in
    speed|agent|writer|custom)
      EXPERT_PROFILE="$PROFILE_OVERRIDE"
      # Persisted like the interactive choice, but NOT under --print: a dry run
      # that rewrites your config is a trap, and it is how a test that checks
      # each profile in turn leaves the last one behind.
      (( PRINT_ONLY )) || set_config_value EXPERT_PROFILE "$EXPERT_PROFILE"
      info "Profile: $(expert_profile_label "$EXPERT_PROFILE") - $(expert_profile_note "$EXPERT_PROFILE")"
      ;;
    *) die "--profile must be one of speed | agent | writer | custom" ;;
  esac
elif (( ! PRINT_ONLY )); then
  choose_expert_profile || true
fi

# Apply it before the engine reads any of these, or the launch command would be
# built from the values the profile is about to replace.
apply_expert_profile

# Re-derive the alias from the repo that is actually being served. The picker
# sets MODEL_REPO and MODEL_DIR but not MODEL_ALIAS, so without this the engine
# below would be resolved from the alias left in MODEL - and picking an MLX
# model while env.conf names a GGUF one would launch llama.cpp against an MTPLX
# pack. Same class of bug as the installer installing the wrong runtime.
MODEL_ALIAS="$(alias_for_repo "$MODEL_REPO")"

MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
export MODEL_REPO MODEL_DIR

# ── which engine serves it ───────────────────────────────────────────────────
ENGINE="$(model_engine_for "${MODEL_ALIAS:-$MODEL_REPO}")"
if [[ -z "$ENGINE" ]]; then
  # Not a known alias: decide from what is actually on disk.
  ENGINE="$(engine_for_dir "$MODEL_DIR")"
fi
[[ -n "$ENGINE" ]] || die "Cannot tell which engine serves '$MODEL_REPO'.
    Known aliases: $MODEL_ALIASES
    Or point MODEL at a directory under $MODELS_DIR that holds a complete model."

ENGINE_MODULE="$REPO_DIR/lib/engines/$ENGINE.sh"
[[ -f "$ENGINE_MODULE" ]] || die "No engine module for '$ENGINE' at $ENGINE_MODULE"
# shellcheck source=/dev/null
source "$ENGINE_MODULE"

info "Engine: $(engine_name)"
engine_present || die "$(engine_name) is not installed. $(engine_install_hint)"

# Validate the enum settings this engine cares about, before loading weights.
engine_apply_settings

engine_model_ok "$MODEL_DIR" || die "No complete $(engine_name) model at $MODEL_DIR
    Run ./install.sh, or ./model_download.sh ${MODEL_ALIAS:-$MODEL_REPO}"

# ── memory sanity ────────────────────────────────────────────────────────────
RAM_GB="$(total_ram_gb)"
WEIGHTS_GB="$(model_dir_size_gb "$MODEL_DIR")"
KV_KB="$(kv_kb_for_engine "$ENGINE")"
KV_GB=$(( CONTEXT_WINDOW * KV_KB / 1024 / 1024 ))
NEED_GB=$(( WEIGHTS_GB + KV_GB + 3 ))

if (( NEED_GB > MEMORY_LIMIT_GB )); then
  warn "Plan needs ~${NEED_GB} GB but MEMORY_LIMIT_GB=${MEMORY_LIMIT_GB}."
  warn "Lower CONTEXT_WINDOW, use KV_QUANT=q4, or raise MEMORY_LIMIT_GB."
fi
if (( NEED_GB > RAM_GB )); then
  die "Plan needs ~${NEED_GB} GB but this Mac has ${RAM_GB} GB. It will not load."
fi

# ── API key (both runtimes refuse a non-loopback bind without one) ───────────
NEED_KEY=0
[[ "$HOST" != "127.0.0.1" && "$HOST" != "localhost" ]] && NEED_KEY=1
(( NEED_KEY )) && ensure_api_key

# ── already running? ─────────────────────────────────────────────────────────
if pid_alive; then
  if server_healthy; then
    ok "Already running (pid $(cat "$PID_FILE")). Use ./restart.sh to apply changes."
    exit 0
  fi
  warn "Stale pid file - cleaning up."
  rm -f "$PID_FILE"
fi

EXISTING="$(port_pids | head -1)"
[[ -n "$EXISTING" ]] && die "Port $PORT is already in use by pid $EXISTING.
    Stop it, or change PORT in env.conf."

# ── build the command ────────────────────────────────────────────────────────
# Everything below this line is engine-specific, and the engine module owns it.
mkdir -p "$RUN_DIR"
ARGS=()
engine_build_args "$MODEL_DIR"
engine_export_env

ENGINE_BIN="$(engine_binary)"
SERVE_WORD="$(engine_serve_word 2>/dev/null || echo '')"

if (( PRINT_ONLY )); then
  log "$ENGINE_BIN ${SERVE_WORD:+$SERVE_WORD }\\"
  printf '  %s \\\n' "${ARGS[@]}"
  exit 0
fi

# ── banner ───────────────────────────────────────────────────────────────────
LAN="$(lan_ip)"
log ""
log "  engine       $(engine_name)"
log "  model        $MODEL_REPO"
log "  weights      ${WEIGHTS_GB} GB"
log "  context      $CONTEXT_WINDOW tokens   (KV: $(kv_quant_for "$ENGINE"), ~${KV_GB} GB)"
engine_banner
log "  thinking     $THINKING"
log ""
log "  local URL    http://127.0.0.1:${PORT}/v1"
if (( NEED_KEY )); then
  log "  LAN URL      http://${LAN}:${PORT}/v1"
  log "  model id     $SERVED_MODEL_NAME"
  log "  API key      $API_KEY"
else
  log "  bound to     $HOST (not reachable from other devices)"
fi
log ""

# ── launch ───────────────────────────────────────────────────────────────────
if (( FOREGROUND )); then
  info "Starting in the foreground. Ctrl-C to stop."
  # shellcheck disable=SC2086
  exec "$ENGINE_BIN" $SERVE_WORD "${ARGS[@]}"
fi

# Record the effective config so ./restart.sh can report what changed.
save_config_snapshot

info "Loading the model - first token takes ~20-60s. Logs: $LOG_FILE"
if [[ -f "$LOG_FILE" ]]; then
  SZ="$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)"
  (( SZ > 33554432 )) && mv -f "$LOG_FILE" "${LOG_FILE}.1"
fi

# Detach fully: stdin from /dev/null so the child cannot hold the terminal
# open, and all three fds redirected so a wrapper script returns immediately.
# shellcheck disable=SC2086
nohup "$ENGINE_BIN" $SERVE_WORD "${ARGS[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
echo "$SERVER_PID" > "$PID_FILE"

info "Waiting for the server to answer /health ..."
wait_healthy 900 && RC=0 || RC=$?
case "$RC" in
  0)
    ok "Server is up."
    log ""
    log "  Chat completions:  POST http://${LAN}:${PORT}/v1/chat/completions"
    log "  Health:            GET  http://${LAN}:${PORT}/health"
    log "  Models:            GET  http://${LAN}:${PORT}/v1/models"
    log ""
    log "  Watch it live:  ./status.sh"
    log "  Stop:           ./stop.sh"
    # Rewrite the dashboard payload now that something is actually serving.
    # A dashboard left open - ./status.sh in another window while trying
    # models - re-reads it and follows the switch rather than going stale.
    write_dashboard_payload >/dev/null 2>&1 || true
    ;;
  2)
    rm -f "$PID_FILE"
    die "The server exited during startup. Last lines of $LOG_FILE:
$(tail -n 25 "$LOG_FILE" 2>/dev/null)"
    ;;
  1)
    die "Timed out after 900s waiting for /health. Check $LOG_FILE"
    ;;
esac
