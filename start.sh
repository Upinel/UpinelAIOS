#!/usr/bin/env bash
# Start the UpinelAIOS-GGUF endpoint.
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

step "UpinelAIOS-GGUF"

# ── preflight ────────────────────────────────────────────────────────────────
is_apple_silicon || die "UpinelAIOS-GGUF needs an Apple Silicon Mac."
require_bin llama-server "Run ./install.sh first, or: brew install llama.cpp"
# LLAMA_SERVER may point at a patched build. It is only used for models whose
# draft head actually requires the patch - see the selection below - so setting
# it does not slow down anything else.
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

# ── which downloaded model to serve ──────────────────────────────────────────
# Offered only when there is a real choice: more than one model on disk, a
# terminal to answer on, and no --model. Anything else keeps env.conf's MODEL,
# so a start in a pipe, in CI or under launchd is never held up by a prompt.
if [[ -z "$MODEL_OVERRIDE" ]] && (( ! PRINT_ONLY )); then
  if choose_model_on_disk; then
    export MODEL_REPO MODEL_DIR
    info "Serving $MODEL_REPO for this run. Set MODEL in env.conf to make it permanent."
  fi
fi

MAIN_GGUF="$(model_main_gguf "$MODEL_DIR" || true)"
[[ -n "$MAIN_GGUF" ]] || die "No model weights found in $MODEL_DIR
    Run ./install.sh, or ./model_download.sh $MODEL"

MMPROJ=""
if (( ENABLE_VISION )); then
  MMPROJ="$(model_mmproj_gguf "$MODEL_DIR" || true)"
  [[ -n "$MMPROJ" ]] || warn "ENABLE_VISION=1 but no mmproj file found; serving text only."
fi

# Default to the stock build on PATH. This is swapped for a patched one only
# when the selected model's draft head requires it.
LLAMA_BIN="llama-server"

DRAFT="$(model_draft_gguf "$MODEL_DIR" || true)"
DEPTH="$(effective_depth)"

# A trimmed-vocabulary draft head accepts far fewer tokens the deeper you
# draft: measured 77% at depth 1 against 53% at depth 3, so depth 3 does less
# work per round and comes out slower (10.6 t/s against 15.4). When the user
# has left MTP_DEPTH on "auto" and no tuned value exists, use 1 for these
# heads instead of the default 3. An explicit MTP_DEPTH always wins.
if [[ "$MTP_DEPTH" == "auto" ]] && [[ -n "$DRAFT" ]] \
   && [[ -z "$(tuned_depth)" ]] && draft_needs_patched_runtime "$DRAFT"; then
  DEPTH=1
  info "trimmed-vocab draft head: using depth 1 (it accepts 77% here against 53% at depth 3)."
fi
if (( DEPTH > 0 )) && [[ -z "$DRAFT" ]]; then
  warn "MTP_DEPTH=$DEPTH but this model has no draft file; running autoregressive."
  DEPTH=0
fi

# A draft built against a patched llama.cpp will not load on a stock one, and
# llama-server treats that as fatal - the whole server exits rather than
# falling back. Left alone, "a bit more speed" becomes "will not start".
# Detect it and run autoregressive unless the user says they built the patch.
if (( DEPTH > 0 )) && [[ -n "$DRAFT" ]] && draft_needs_patched_runtime "$DRAFT"; then
  # This head needs the patched runtime. Use it if we have one: either
  # LLAMA_SERVER points somewhere, or the user says their PATH already has it.
  # Choosing here rather than up front is the whole point - the patched build
  # is a couple of percent slower, and Gemma must not pay that.
  if [[ -n "${LLAMA_SERVER:-}" && -x "${LLAMA_SERVER:-}" ]]; then
    LLAMA_BIN="$LLAMA_SERVER"
    info "using the patched runtime for this draft: $LLAMA_SERVER"
  elif (( ${DRAFT_PATCHED_RUNTIME:-0} )); then
    LLAMA_BIN="llama-server"
    info "draft needs a patched llama.cpp; DRAFT_PATCHED_RUNTIME=1 so using it as-is."
  else
    warn "$(basename "$DRAFT") needs a patched llama.cpp (trimmed draft vocab)."
    warn "Running autoregressive to keep the server up."
    warn "Build llama.cpp with the HauhauCS FastMTP patch and set"
    warn "DRAFT_PATCHED_RUNTIME=1 in env.conf to use it. See docs/GGUF-RUNTIME.md."
    DEPTH=0
    DRAFT=""
  fi
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

# Cap the thought channel. Without this, "thinking on" is unbounded and the
# model will happily spend 300 tokens reasoning about where to find a file.
# The message matters as much as the budget: measured on eight agent tasks,
# every budgeted setting without it scored 7/8 against thinking-off's 8/8,
# because a thought cut off mid-sentence never got round to emitting a tool
# call. With it, every budget scored 8/8. See lib/common.sh for the numbers.
BUDGET="$(effective_thinking_budget)"
if [[ -n "$BUDGET" ]]; then
  ARGS+=( --reasoning-budget "$BUDGET" )
  if [[ -n "${THINKING_BUDGET_MESSAGE:-}" ]]; then
    ARGS+=( --reasoning-budget-message "$THINKING_BUDGET_MESSAGE" )
  fi
fi

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
  log "$LLAMA_BIN \\"
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
  exec "$LLAMA_BIN" "${ARGS[@]}"
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
nohup "$LLAMA_BIN" "${ARGS[@]}" </dev/null >>"$LOG_FILE" 2>&1 &
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
