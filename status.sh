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
# Live dashboard for the agent endpoint: CPU, GPU, ANE, memory, and the
# server's concurrent activity, refreshed in real time.
#
#   ./status.sh                live dashboard (Ctrl-C to exit)
#   ./status.sh --once         one-shot summary, for scripts and logs
#   ./status.sh --json         machine-readable snapshot
#   ./status.sh --key          print only the API key, for scripting
#   ./status.sh --thinking off|minimal|low|medium|high
#                              MLX: applied LIVE, model stays loaded.
#                              GGUF: written to env.conf, takes a ./restart.sh.
#   ./status.sh --no-keys      display only; disable the t/m key toggles
#
# While it runs, these keys work:
#   t   cycle the thinking level        m   cycle the downloaded models
#   Enter apply now   Esc cancel        q   quit
#
# A toggle arms a 2-second countdown and applies when it expires, so pressing
# the key again moves to the next option without committing to the last one.
#   ./status.sh --thinking     show the current thinking setting
#   ./status.sh --interval 2   slower refresh
#   ./status.sh --power        add real ANE/GPU power (needs passwordless sudo)
#
# ANE note: Apple exposes the Neural Engine only through powermetrics, which
# needs root. MLX is GPU-only anyway, so the ANE is genuinely idle here and is
# shown as "n/a" rather than faked. --power reads the real figure when sudo is
# already passwordless.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

# Which model is being served, and therefore which engine.
#
# env.conf is the configured model, but ./start.sh --model serves a different
# one for a single run without touching env.conf. Reporting the configured
# model while another is running would put the wrong weights, the wrong KV
# figure and the wrong engine on the dashboard - so when a server has written
# a launch snapshot, that is what is actually running and it wins.
STATUS_REPO="$(model_repo_for "$MODEL")"
if [[ -f "$CONFIG_SNAPSHOT_FILE" ]]; then
  _launched="$(sed -n 's/^MODEL=//p' "$CONFIG_SNAPSHOT_FILE" 2>/dev/null | head -1)"
  [[ -n "$_launched" ]] && STATUS_REPO="$_launched"
fi
STATUS_ALIAS="$(alias_for_repo "$STATUS_REPO")"
STATUS_ENGINE="$(model_engine_for "${STATUS_ALIAS:-$STATUS_REPO}")"
[[ -n "$STATUS_ENGINE" ]] || STATUS_ENGINE="$(engine_for_dir "$MODELS_DIR/${STATUS_REPO//\//--}")"
[[ -n "$STATUS_ENGINE" ]] || STATUS_ENGINE="gguf"

case "${1:-}" in
  -h|--help)
    show_usage "$0"
    exit 0 ;;
  --key)
    # Just the key, so it can be captured: export KEY=$(./status.sh --key)
    ensure_api_key
    printf '%s\n' "$API_KEY"
    exit 0 ;;
  --thinking)
    # llama.cpp takes thinking as a per-request chat-template kwarg, so there is
    # nothing live to change - write env.conf and say what applies it. MTPLX has
    # a settings endpoint, so there the change is immediate and the model stays
    # loaded. Same command, two honest behaviours.
    if [[ "$STATUS_ENGINE" == "gguf" ]]; then
      if [[ -z "${2:-}" ]]; then
        log "  thinking: ${C_BOLD}${THINKING}${C_RESET}  ${C_DIM}(from env.conf)${C_RESET}"
        log "  levels: off | minimal | low | high"
        log "  ${C_DIM}llama.cpp reads chat-template kwargs at launch, so a change needs ./restart.sh${C_RESET}"
        exit 0
      fi
      LEVEL="$2"
      thinking_level_ok "$LEVEL" || die "THINKING level must be off | minimal | low | high"
      set_config_value THINKING "$LEVEL" || die "THINKING= not found in env.conf"
      ok "THINKING set to ${C_BOLD}${LEVEL}${C_RESET} in env.conf."
      log "  ${C_DIM}Apply it:  ./restart.sh${C_RESET}"
      exit 0
    fi

    # ── MLX: change it on the running server ──
    require_bin curl "curl is required."
    if ! server_healthy; then
      die "No server answering on port $PORT. Start it with ./start.sh"
    fi
    if [[ -z "${2:-}" ]]; then
      CUR="$(live_settings_get | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('unknown'); raise SystemExit
mode = d.get('reasoning','?')
effort = d.get('reasoning_effort') or ''
# effort only means anything while reasoning is on
print(mode if mode == 'off' else (mode + ' ' + effort).strip())
" 2>/dev/null)"
      log "  live thinking: ${C_BOLD}${CUR}${C_RESET}"
      log "  levels: off | minimal | low | medium | high"
      log "  ${C_DIM}restart-persistent default is THINKING=\"$THINKING\" in env.conf${C_RESET}"
      exit 0
    fi
    LEVEL="$2"
    thinking_level_ok "$LEVEL" || die "THINKING level must be off | minimal | low | medium | high"
    RESP="$(live_settings_set "$(live_thinking_payload "$LEVEL")")"
    if [[ -z "$RESP" ]]; then
      die "The server rejected the change. Check run/server.log"
    fi
    NOW="$(printf '%s' "$RESP" | python3 -c "
import json,sys
try: d=json.load(sys.stdin)
except Exception: print('?'); raise SystemExit
mode = d.get('reasoning','?'); effort = d.get('reasoning_effort') or ''
print(mode if mode == 'off' else (mode + ' ' + effort).strip())
" 2>/dev/null)"
    ok "Thinking is now: ${C_BOLD}$NOW${C_RESET}"
    log ""
    case "$LEVEL" in
      off)     log "  ${C_DIM}No thinking at all. Fastest, and the right default for tool loops.${C_RESET}" ;;
      minimal) log "  ${C_DIM}Thinking is bounded to $(thinking_budget_for minimal) tokens with an early stop.${C_RESET}" ;;
      low)     log "  ${C_DIM}Thinking is bounded to $(thinking_budget_for low) tokens.${C_RESET}" ;;
      medium)  log "  ${C_DIM}Thinking is bounded to $(thinking_budget_for medium) tokens.${C_RESET}" ;;
      high)    log "  ${C_YELLOW:-}Thinking is unbounded. Expect the slowest, most deliberative output.${C_RESET}" ;;
    esac
    log ""
    log "  ${C_DIM}This is live only. To make it survive a restart, set THINKING in env.conf.${C_RESET}"
    exit 0 ;;
  *)
    ;;
esac

require_bin python3 "python3 is required for the dashboard."

# Hand the configuration to the dashboard as JSON so we keep one source of
# truth (env.conf) instead of duplicating parsing in Python.
# Facts about the model on disk, for the dashboard. The engine fills the parts
# that apply to it - a GGUF model has one weight file and maybe a projector, an
# MLX pack has neither - so this script does not branch on the engine and
# cannot fall out of step with it.
STATUS_MAIN=""; STATUS_WEIGHTS_GB=0; STATUS_KV_GB=0; STATUS_VISION_GB=0
STATUS_DIR="$MODELS_DIR/${STATUS_REPO//\//--}"
if load_engine "$STATUS_ENGINE" >/dev/null 2>&1; then
  engine_status_extras "$STATUS_DIR"
fi
# KV is derived from the model's own cost per token, which is engine-aware even
# when the model files are not present yet.
STATUS_KV_GB=$(( CONTEXT_WINDOW * $(kv_kb_for_engine "$STATUS_ENGINE") / 1024 / 1024 ))

CONFIG_JSON="$(python3 - <<PY
import json, os
print(json.dumps({
    "base": "http://127.0.0.1:${PORT}/v1",
    "lan_url": "http://$(lan_ip):${PORT}/v1",
    "api_key": open("${API_KEY_FILE}").read().strip() if os.path.exists("${API_KEY_FILE}") else "",
    "api_key_file": "${API_KEY_FILE}",
    "pid_file": "${PID_FILE}",
    "log_file": "${LOG_FILE}",
    "error_log": "$RUN_DIR/dashboard.err",
    "models_dir": "${MODELS_DIR}",
    "repo_dir": "${REPO_DIR}",
    "env_file": "${ENV_FILE}",
    "model_dir": "${MODEL_DIR}",
    "model": "${MODEL}",
    "served_name": "${SERVED_MODEL_NAME}",
    "model_repo": "${MODEL_REPO}",
    # Which engine is serving. The dashboard shows it, and uses it to decide
    # which panels make sense - a GGUF draft head means nothing on MLX.
    "engine": "${STATUS_ENGINE}",
    # GGUF-only facts, computed from what is actually on disk. Empty on MLX,
    # where a pack is a shard tree rather than one file plus extras.
    "main_gguf": "${STATUS_MAIN:-}",
    "weights_gb": "${STATUS_WEIGHTS_GB:-0}",
    "kv_gb": "${STATUS_KV_GB:-0}",
    "vision_gb": "${STATUS_VISION_GB:-0}",
    "slots": "${PARALLEL_SLOTS:-1}",
    "context": "${CONTEXT_WINDOW}",
    "ctx": "${CONTEXT_WINDOW}",
    "kv": "$(kv_quant_for "$STATUS_ENGINE")",
    "profile": "${PROFILE}",
    "thinking": "${THINKING}",
    "preserve_thinking": "${PRESERVE_THINKING}",
    "depth": "$(effective_depth)",
    "memory_limit": "${MEMORY_LIMIT_GB}",
    "batching": "${BATCHING_PRESET}",
    "host": "${HOST}",
    "port": "${PORT}",
    "chip": "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')",
    "macos": "$(macos_version)",
}))
PY
)"
export AIOS_DASH_CFG="$CONFIG_JSON"

exec python3 "$REPO_DIR/lib/dashboard.py" "$@"
