#!/usr/bin/env bash
# Shared helpers for UpinelAIOS-G.
# Sourced by install.sh / start.sh / stop.sh / restart.sh / status.sh / bench.
#
# Bash 3.2 compatible on purpose: that is what ships on macOS, and this bundle
# must run on a stock Mac without Homebrew's bash.

set -euo pipefail

# ── paths ────────────────────────────────────────────────────────────────────
COMMON_SH_SOURCE="${BASH_SOURCE[0]}"
LIB_DIR="$(cd "$(dirname "$COMMON_SH_SOURCE")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
export REPO_DIR

RUN_DIR="$REPO_DIR/run"
mkdir -p "$RUN_DIR"
PID_FILE="$RUN_DIR/server.pid"
ENV_FILE="$REPO_DIR/env.conf"
TUNE_FILE="$RUN_DIR/tuning.json"
CONFIG_SNAPSHOT_FILE="$RUN_DIR/config.snapshot"

# ── pretty output ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
  C_CYAN=''; C_MAGENTA=''
fi

log()   { printf '%s\n' "$*"; }
info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()    { printf '%s\n' "${C_GREEN} ok${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
die()   { printf '%s\n' "${C_RED}fail${C_RESET} $*" >&2; exit 1; }
step()  { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }

show_usage() {
  awk 'NR == 1 { next }
       /^#/ { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { if (seen) exit; else next }
       { exit }' "$1"
}

# ── model registry ───────────────────────────────────────────────────────────
# GEMMA 4, UNCENSORED ONLY.
#
# Every entry is an uncensored Gemma 4 fine-tune served as GGUF by llama.cpp.
# That is not a preference, it is the only combination that works: MTPLX drives
# Gemma 4 through a target/assistant pair and the only pair in existence is
# built from Google's aligned models, so an uncensored Gemma 4 cannot run there
# at all.
#
#   26b-a4b      MoE, ~4B active per token. The speed pick.
#   12b          dense 12B
#   31b-heretic  dense 31B, abliterated. Highest quality.
#   e4b          small and very fast
MODEL_ALIASES="26b-a4b 12b 31b-heretic e4b"

model_repo_for() {
  case "$1" in
    26b-a4b)     echo "HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP" ;;
    12b)         echo "HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced" ;;
    31b-heretic) echo "llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF" ;;
    e4b)         echo "HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive" ;;
    */*)         echo "$1" ;;
    *)           die "MODEL=\"$1\" is neither a known alias nor an owner/name repo id.
    Known aliases: $MODEL_ALIASES" ;;
  esac
}

model_is_known_alias() {
  case "$1" in
    26b-a4b|12b|31b-heretic|e4b) return 0 ;;
    *) return 1 ;;
  esac
}

# Preferred quant, best size/quality first. The downloader picks the first one
# the repo actually publishes rather than just taking the largest file - the
# 31B publishes a 61 GB BF16 and the E4B an 8 GB Q8, neither of which is what
# you want by default.
QUANT_PREFERENCE="Q4_K_M Q4_K_S Q4_K_P IQ4_XS Q5_K_M Q5_K_S Q6_K Q8_0 Q8_K_P Q3_K_M"

# ── config ───────────────────────────────────────────────────────────────────
load_config() {
  [[ -f "$ENV_FILE" ]] || die "env.conf not found at $ENV_FILE"

  MODEL="26b-a4b"
  MODELS_DIR="$REPO_DIR/models"
  CONTEXT_WINDOW=131072
  MAX_RESPONSE_TOKENS=32768
  KV_QUANT="q8_0"
  THINKING="minimal"
  THINKING_BUDGET_TOKENS=0
  MTP_DEPTH="auto"
  PREFILL_CHUNK_TOKENS=512
  BATCH_SIZE=2048
  UBATCH_SIZE=512
  MAX_CONCURRENT=1
  MEMORY_LIMIT_GB=48
  USE_MLOCK=1
  HOST="0.0.0.0"
  PORT=8000
  API_KEY_FILE="$REPO_DIR/run/api-key"
  SERVED_MODEL_NAME="Upinel-AIOS-G"
  ENABLE_VISION=1
  PARALLEL_SLOTS=1
  FAN_MODE="default"
  WIRED_LIMIT_GB=0
  WARMUP_TOKENS=8
  LOG_FILE="$REPO_DIR/run/server.log"

  # shellcheck disable=SC1090
  source "$ENV_FILE"

  MODEL_REPO="$(model_repo_for "$MODEL")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
  export MODEL MODEL_REPO MODEL_DIR MODELS_DIR CONTEXT_WINDOW MAX_RESPONSE_TOKENS
  export KV_QUANT THINKING THINKING_BUDGET_TOKENS MTP_DEPTH HOST PORT API_KEY_FILE
  export SERVED_MODEL_NAME FAN_MODE LOG_FILE ENABLE_VISION PARALLEL_SLOTS
  export MEMORY_LIMIT_GB WIRED_LIMIT_GB USE_MLOCK MAX_CONCURRENT
  export PREFILL_CHUNK_TOKENS BATCH_SIZE UBATCH_SIZE
}

# ── machine facts ────────────────────────────────────────────────────────────
is_apple_silicon() { [[ "$(uname -m)" == "arm64" ]] && [[ "$(uname -s)" == "Darwin" ]]; }
total_ram_gb()     { awk -v b="$(sysctl -n hw.memsize)" 'BEGIN { printf "%d", b/1024/1024/1024 }'; }
macos_version()    { sw_vers -productVersion; }
gpu_cores() {
  system_profiler SPDisplaysDataType 2>/dev/null \
    | awk -F': ' '/Total Number of Cores/ { print $2; exit }' | tr -d ' '
}

require_macos() {
  local v; v="$(macos_version)"; local major="${v%%.*}"
  (( major >= 14 )) || die "macOS $v detected. Apple Silicon inference needs macOS 14 or newer."
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. $2"
}

# ── model files ──────────────────────────────────────────────────────────────
# The main weights: the largest .gguf that is neither a vision projector nor a
# speculative draft.
model_main_gguf() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  find -L "$dir" -maxdepth 1 -name '*.gguf' 2>/dev/null \
    | grep -v '/mmproj' | grep -v '/mtp-' \
    | while read -r f; do printf '%s\t%s\n' "$(stat -f%z "$f")" "$f"; done \
    | sort -rn | head -1 | cut -f2
}

model_mmproj_gguf() {
  local dir="$1"
  find -L "$dir" -maxdepth 1 -name 'mmproj*.gguf' 2>/dev/null | head -1
}

model_draft_gguf() {
  local dir="$1"
  find -L "$dir" -maxdepth 1 -name 'mtp-*.gguf' 2>/dev/null | head -1
}

model_present() {
  local dir="$1"
  [[ -n "$(model_main_gguf "$dir" 2>/dev/null || true)" ]]
}

model_weights_gb() {
  local dir="${1:-$MODEL_DIR}" main
  main="$(model_main_gguf "$dir" 2>/dev/null || true)"
  if [[ -n "$main" ]]; then
    echo $(( $(stat -f%z "$main") / 1000000000 ))
  else
    echo 17   # the default MoE, before anything is downloaded
  fi
}

# ── API key ──────────────────────────────────────────────────────────────────
ensure_api_key() {
  mkdir -p "$(dirname "$API_KEY_FILE")"
  if [[ ! -s "$API_KEY_FILE" ]]; then
    ( umask 077; openssl rand -hex 24 > "$API_KEY_FILE" )
    chmod 600 "$API_KEY_FILE"
    info "Generated a new API key at $API_KEY_FILE"
  fi
  API_KEY="$(tr -d '\n' < "$API_KEY_FILE")"
  [[ -n "$API_KEY" ]] || die "API key file $API_KEY_FILE is empty."
  export API_KEY
}

auth_header() {
  if [[ -s "${API_KEY_FILE:-}" ]]; then
    printf 'Authorization: Bearer %s' "$(tr -d '\n' < "$API_KEY_FILE")"
  fi
}

# ── LAN address ──────────────────────────────────────────────────────────────
lan_ip() {
  local ip=""
  ip="$(ipconfig getifaddr en0 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
  [[ -z "$ip" ]] && ip="$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '^127\.' | head -1)"
  echo "${ip:-<your-lan-ip>}"
}

# ── process / port helpers ───────────────────────────────────────────────────
pid_alive() {
  [[ -f "$PID_FILE" ]] || return 1
  local p; p="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null
}

port_pids() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true; }

server_healthy() {
  local hdr; hdr="$(auth_header)"
  if [[ -n "$hdr" ]]; then
    curl -fsS --max-time 4 -H "$hdr" "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
  else
    curl -fsS --max-time 4 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
  fi
}

health_json() {
  local hdr; hdr="$(auth_header)"
  if [[ -n "$hdr" ]]; then
    curl -fsS --max-time 6 -H "$hdr" "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo '{}'
  else
    curl -fsS --max-time 6 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo '{}'
  fi
}

wait_healthy() {
  local timeout="${1:-900}" waited=0
  while (( waited < timeout )); do
    server_healthy && return 0
    if [[ -f "$PID_FILE" ]] && ! pid_alive; then return 2; fi
    sleep 2; waited=$(( waited + 2 ))
  done
  return 1
}

# ── thinking ─────────────────────────────────────────────────────────────────
thinking_level_ok() {
  case "$1" in off|minimal|low|high) return 0 ;; *) return 1 ;; esac
}

thinking_budget_for() {
  case "$1" in
    off)     echo 0 ;;
    minimal) echo 256 ;;
    low)     echo 1024 ;;
    high)    echo 0 ;;
    *)       echo 256 ;;
  esac
}

# Gemma 4's chat template takes `enable_thinking`. llama.cpp forwards
# --chat-template-kwargs straight into it.
thinking_kwargs() {
  thinking_level_ok "$THINKING" || die "THINKING=\"$THINKING\" is not one of off | minimal | low | high"
  if [[ "$THINKING" == "off" ]]; then
    printf '{"enable_thinking":false}'
  else
    printf '{"enable_thinking":true}'
  fi
}

# ── speculative decoding depth ───────────────────────────────────────────────
# Read the tuned depth written by ./bench/bench.sh --tune. Per model, because
# the optimal depth differs between them.
tune_file_for_current_model() {
  printf '%s/tuning-%s.json' "$RUN_DIR" "${MODEL_REPO//\//--}"
}

tuned_depth() {
  local path=""
  if [[ -n "${MODEL_REPO:-}" ]]; then
    path="$RUN_DIR/tuning-${MODEL_REPO//\//--}.json"
    [[ -f "$path" ]] || path=""
  fi
  [[ -n "$path" ]] || path="$TUNE_FILE"
  [[ -f "$path" ]] || { echo ""; return; }
  python3 - "$path" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit
best = d.get("best_depth")
print("" if best is None else int(best))
PY
}

# Depth actually used: MTP_DEPTH="auto" means "the tuned value, else 1".
# 1 is the measured optimum for the 26b-a4b at agent context lengths; deeper
# drafting peaks on short prompts and collapses past ~8k.
effective_depth() {
  if [[ "${MTP_DEPTH}" == "auto" ]]; then
    local d; d="$(tuned_depth)"
    echo "${d:-1}"
  else
    echo "$MTP_DEPTH"
  fi
}

# ── config snapshot (for restart.sh) ─────────────────────────────────────────
config_fingerprint() {
  printf '%s\n' \
    "MODEL=$MODEL_REPO" \
    "CONTEXT_WINDOW=$CONTEXT_WINDOW" \
    "MAX_RESPONSE_TOKENS=$MAX_RESPONSE_TOKENS" \
    "KV_QUANT=$KV_QUANT" \
    "THINKING=$THINKING" \
    "MTP_DEPTH=$(effective_depth)" \
    "PREFILL_CHUNK_TOKENS=$PREFILL_CHUNK_TOKENS" \
    "BATCH_SIZE=$BATCH_SIZE" \
    "UBATCH_SIZE=$UBATCH_SIZE" \
    "MAX_CONCURRENT=$MAX_CONCURRENT" \
    "MEMORY_LIMIT_GB=$MEMORY_LIMIT_GB" \
    "USE_MLOCK=$USE_MLOCK" \
    "HOST=$HOST" \
    "PORT=$PORT" \
    "SERVED_MODEL_NAME=$SERVED_MODEL_NAME" \
    "ENABLE_VISION=$ENABLE_VISION" \
    "PARALLEL_SLOTS=$PARALLEL_SLOTS" \
    "FAN_MODE=$FAN_MODE" \
    "WARMUP_TOKENS=$WARMUP_TOKENS"
}

save_config_snapshot() {
  mkdir -p "$RUN_DIR"
  config_fingerprint > "$CONFIG_SNAPSHOT_FILE"
}

diff_config_snapshot() {
  [[ -f "$CONFIG_SNAPSHOT_FILE" ]] || return 1
  local changed
  changed="$(diff <(config_fingerprint) "$CONFIG_SNAPSHOT_FILE" 2>/dev/null | grep -E '^[<>]' || true)"
  [[ -n "$changed" ]] || return 1
  printf '%s\n' "$changed"
  return 0
}

# ── memory arithmetic ────────────────────────────────────────────────────────
# Gemma 4 is a dense-attention model (the MoE varies the FFN, not the
# attention), so KV scales with layers x kv_heads x head_dim like any
# transformer. Rough per-token cost at f16; q8_0 is about half.
kv_gb_for_context() {
  local ctx="$1" per_tok_kb="$2"
  echo $(( ctx * per_tok_kb / 1024 / 1024 ))
}

# Rough KV cost per token for the current model, in KB at f16.
kv_kb_per_token_f16() {
  case "$1" in
    *26B-A4B*)  echo 64  ;;
    *12B*)      echo 32  ;;
    *31B*)      echo 80  ;;
    *E4B*)      echo 16  ;;
    *)          echo 64  ;;
  esac
}
