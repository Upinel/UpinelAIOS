#!/usr/bin/env bash
# Start the UpinelAIOS-G endpoint.
#
#   ./start.sh                 start in the background (default)
#   ./start.sh --foreground    run attached to this terminal (Ctrl-C to stop)
#   ./start.sh --print         print the command it would run, then exit
#   ./start.sh --model 12b     serve a different model for this run only
#
# All settings come from env.conf. Apply edits with ./restart.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

FOREGROUND=0; PRINT_ONLY=0; MODEL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--foreground) FOREGROUND=1 ;;
    --print)         PRINT_ONLY=1 ;;
    --model)         MODEL_OVERRIDE="$2"; shift ;;
    -h|--help)       show_usage "$0"; exit 0 ;;
    *)               die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

step "UpinelAIOS-G"

# ── preflight ────────────────────────────────────────────────────────────────
is_apple_silicon || die "UpinelAIOS-G needs an Apple Silicon Mac."
require_bin llama-server "Run ./install.sh first, or: brew install llama.cpp"
require_bin python3 "python3 is required."

if [[ -n "$MODEL_OVERRIDE" ]]; then
  MODEL_REPO="$(model_repo_for "$MODEL_OVERRIDE")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
  export MODEL_REPO MODEL_DIR
  info "Model override for this run: $MODEL_REPO"
fi

# Validate the enums up front, so a typo fails before loading 17 GB of weights.
case "$KV_QUANT" in q8_0|q4_0|f16|bf16) ;; *) die "KV_QUANT=\"$KV_QUANT\" is not one of q8_0 | q4_0 | f16 | bf16" ;; esac
thinking_level_ok "$THINKING" || die "THINKING=\"$THINKING\" is not one of off | minimal | low | high"
case "$FAN_MODE" in default|smart|max) ;; *) die "FAN_MODE=\"$FAN_MODE\" is not one of default | smart | max" ;; esac

MAIN_GGUF="$(model_main_gguf "$MODEL_DIR" || true)"
[[ -n "$MAIN_GGUF" ]] || die "No model weights found in $MODEL_DIR
    Run ./install.sh, or ./model_download.sh $MODEL"

MMPROJ=""
if (( ENABLE_VISION )); then
  MMPROJ="$(model_mmproj_gguf "$MODEL_DIR" || true)"
  [[ -n "$MMPROJ" ]] || warn "ENABLE_VISION=1 but no mmproj file found; serving text only."
fi

DRAFT="$(model_draft_gguf "$MODEL_DIR" || true)"
DEPTH="$(effective_depth)"
if (( DEPTH > 0 )) && [[ -z "$DRAFT" ]]; then
  warn "MTP_DEPTH=$DEPTH but this model has no draft file; running autoregressive."
  DEPTH=0
fi

# ── memory sanity ────────────────────────────────────────────────────────────
RAM_GB="$(total_ram_gb)"
WEIGHTS_GB=$(( $(stat -f%z "$MAIN_GGUF") / 1000000000 ))
KV_KB="$(kv_kb_per_token_f16 "$MODEL_REPO")"
case "$KV_QUANT" in
  q8_0) KV_KB=$(( KV_KB / 2 )) ;;
  q4_0) KV_KB=$(( KV_KB / 4 )) ;;
esac
KV_GB=$(( CONTEXT_WINDOW * KV_KB / 1024 / 1024 ))
VISION_GB=0; [[ -n "$MMPROJ" ]] && VISION_GB=$(( $(stat -f%z "$MMPROJ") / 1000000000 ))
NEED_GB=$(( WEIGHTS_GB + KV_GB + VISION_GB + 3 ))

info "Memory plan: ${WEIGHTS_GB} GB weights + ${KV_GB} GB KV (${KV_QUANT}) + ${VISION_GB} GB vision + 3 GB scratch = ${NEED_GB} GB"
if (( NEED_GB > MEMORY_LIMIT_GB )); then
  warn "Plan needs ~${NEED_GB} GB but MEMORY_LIMIT_GB=${MEMORY_LIMIT_GB}."
  warn "Lower CONTEXT_WINDOW, use KV_QUANT=q4_0, or raise MEMORY_LIMIT_GB."
fi
if (( NEED_GB > RAM_GB )); then
  die "Plan needs ~${NEED_GB} GB but this Mac has ${RAM_GB} GB. It will not load."
fi

# ── API key (llama.cpp refuses a non-loopback bind without one) ──────────────
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
ARGS=(
  -m "$MAIN_GGUF"
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

# Keep the weights resident. Without this macOS can page them out and the
# decode rate becomes erratic rather than merely slow.
(( USE_MLOCK )) && ARGS+=( -lm mlock )

[[ -n "$MMPROJ" ]] && ARGS+=( --mmproj "$MMPROJ" )
(( NEED_KEY )) && ARGS+=( --api-key "$API_KEY" )

if (( DEPTH > 0 )) && [[ -n "$DRAFT" ]]; then
  ARGS+=( -md "$DRAFT" --spec-type draft-mtp --spec-draft-n-max "$DEPTH" --spec-draft-ngl all )
fi

# Thinking. Gemma 4's template reads enable_thinking; llama.cpp passes
# --chat-template-kwargs straight through.
ARGS+=( --chat-template-kwargs "$(thinking_kwargs)" )

mkdir -p "$RUN_DIR"

# Tool-call reliability. Gemma follows a schema's semantics but not its
# `required` list, so agent harnesses see "missing required property" on fields
# the model judged optional. Generating a template that names each tool's
# required fields fixes it server-side. See lib/tools-template.py.
if (( TOOL_TEMPLATE )); then
  if python3 "$REPO_DIR/lib/tools-template.py" --gguf "$MAIN_GGUF" \
       --out "$RUN_DIR/tools-template.jinja" 2>>"$RUN_DIR/template.err"; then
    ARGS+=( --chat-template-file "$RUN_DIR/tools-template.jinja" )
  else
    log "  note: tool template unavailable, using the model's stock template"
    log "        (see $RUN_DIR/template.err)"
  fi
fi

if (( PRINT_ONLY )); then
  log "llama-server \\"
  printf '  %s \\\n' "${ARGS[@]}"
  exit 0
fi

# ── banner ───────────────────────────────────────────────────────────────────
LAN="$(lan_ip)"
log ""
log "  model        $MODEL_REPO"
log "  weights      $(basename "$MAIN_GGUF")  (${WEIGHTS_GB} GB)"
log "  context      $CONTEXT_WINDOW tokens   (KV: $KV_QUANT, ~${KV_GB} GB)"
if (( DEPTH > 0 )); then
  log "  speculative  depth $DEPTH   ($(basename "$DRAFT"))"
else
  log "  speculative  off (plain autoregressive)"
fi
log "  thinking     $THINKING"
log "  vision       $([[ -n "$MMPROJ" ]] && echo "on" || echo "off")"
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
  exec llama-server "${ARGS[@]}"
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
nohup llama-server "${ARGS[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
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
