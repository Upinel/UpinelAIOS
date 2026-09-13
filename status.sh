#!/usr/bin/env bash
# Live dashboard for the UpinelAIOS-GGUF endpoint: CPU, GPU, memory, and the
# server's concurrent activity, refreshed in real time.
#
#   ./status.sh                live dashboard (Ctrl-C to exit)
#   ./status.sh --once         one-shot summary, for scripts and logs
#   ./status.sh --json         machine-readable snapshot
#   ./status.sh --key          print only the API key, for scripting
#   ./status.sh --thinking off|minimal|low|high   change thinking LIVE
#   ./status.sh --interval 2   slower refresh
#   ./status.sh --no-keys      display only; disable the t/m key toggles
#   ./status.sh --power        add real ANE/GPU power (needs passwordless sudo)
#
# While it runs, these keys work:
#   t   cycle the thinking level        m   cycle the downloaded models
#   Enter apply now   Esc cancel        q   quit
#
# A toggle arms a 2-second countdown and applies when it expires, so pressing
# the key again moves to the next option without committing to the last one.
#
# ANE note: Apple exposes the Neural Engine only through powermetrics, which
# needs root. llama.cpp/Metal is GPU-only, so the ANE is genuinely idle here and
# is shown as "n/a" rather than faked.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

case "${1:-}" in
  -h|--help) show_usage "$0"; exit 0 ;;
  --key)
    ensure_api_key
    printf '%s\n' "$API_KEY"
    exit 0 ;;
  --thinking)
    require_bin curl "curl is required."
    if ! server_healthy; then
      die "No server answering on port $PORT. Start it with ./start.sh"
    fi
    if [[ -z "${2:-}" ]]; then
      log "  live thinking: ${C_BOLD}${THINKING}${C_RESET}  ${C_DIM}(from env.conf)${C_RESET}"
      log "  levels: off | minimal | low | high"
      exit 0
    fi
    LEVEL="$2"
    thinking_level_ok "$LEVEL" || die "THINKING level must be off | minimal | low | high"
    # llama.cpp reads the chat template kwargs per request, so this is a
    # restart-to-persist change rather than a live one.
    python3 - "$ENV_FILE" "$LEVEL" <<'PY'
import re, sys
path, level = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'^THINKING=.*$', f'THINKING="{level}"', s, count=1, flags=re.M)
if n != 1:
    raise SystemExit("THINKING= not found in env.conf")
open(path, 'w').write(s)
PY
    ok "THINKING set to ${C_BOLD}${LEVEL}${C_RESET} in env.conf."
    log "  ${C_DIM}llama.cpp reads chat-template kwargs at launch, so apply it:${C_RESET}"
    log "  ${C_DIM}./restart.sh${C_RESET}"
    exit 0 ;;
esac

require_bin python3 "python3 is required for the dashboard."

MAIN_GGUF_STATUS="$(model_main_gguf "$MODEL_DIR" 2>/dev/null || true)"
WEIGHTS_GB_STATUS=0
[[ -n "$MAIN_GGUF_STATUS" ]] && WEIGHTS_GB_STATUS=$(( $(stat -f%z "$MAIN_GGUF_STATUS") / 1000000000 ))
# Only count the vision tower when it is actually being loaded.
VISION_GB_STATUS=0
if [[ "${ENABLE_VISION}" == "1" ]]; then
  MMPROJ_STATUS="$(model_mmproj_gguf "$MODEL_DIR" 2>/dev/null || true)"
  [[ -n "$MMPROJ_STATUS" ]] && VISION_GB_STATUS=$(( $(stat -f%z "$MMPROJ_STATUS") / 1000000000 ))
fi
KV_KB_STATUS="$(kv_kb_per_token_f16 "$MODEL_REPO")"
case "$KV_QUANT" in q8_0) KV_KB_STATUS=$(( KV_KB_STATUS / 2 ));; q4_0) KV_KB_STATUS=$(( KV_KB_STATUS / 4 ));; esac
KV_GB_STATUS=$(( CONTEXT_WINDOW * KV_KB_STATUS / 1024 / 1024 ))

CONFIG_JSON="$(python3 - <<PY
import json, os
key_path = "${API_KEY_FILE}"
key = open(key_path).read().strip() if os.path.exists(key_path) else ""
main = "${MAIN_GGUF_STATUS}"
weights = ${WEIGHTS_GB_STATUS}
print(json.dumps({
    "base": "http://127.0.0.1:${PORT}/v1",
    "lan_url": "http://$(lan_ip):${PORT}/v1",
    "api_key": key,
    "pid_file": "${PID_FILE}",
    "log_file": "${LOG_FILE}",
    "error_log": "${RUN_DIR}/dashboard.err",
    "model_dir": "${MODEL_DIR}",
    "models_dir": "${MODELS_DIR}",
    "repo_dir": "${REPO_DIR}",
    "env_file": "${ENV_FILE}",
    "model_repo": "${MODEL_REPO}",
    "served_name": "${SERVED_MODEL_NAME}",
    "main_gguf": main,
    "weights_gb": weights,
    "ctx": "${CONTEXT_WINDOW}",
    "kv": "${KV_QUANT}",
    "depth": "$(effective_depth)",
    "thinking": "${THINKING}",
    "memory_limit": "${MEMORY_LIMIT_GB}",
    "slots": "${PARALLEL_SLOTS}",
    "vision_gb": ${VISION_GB_STATUS},
    "kv_gb": ${KV_GB_STATUS},
    "port": "${PORT}",
    "chip": "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')",
    "macos": "$(macos_version)",
}))
PY
)"
export MTPLX_DASH_CFG="$CONFIG_JSON"

exec python3 "$REPO_DIR/lib/dashboard.py" "$@"
