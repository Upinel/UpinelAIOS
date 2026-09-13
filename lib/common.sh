#!/usr/bin/env bash
# Shared helpers for UpinelAIOS-GGUF.
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
#   26b-q4       MoE, Q4_0 QAT. FASTEST 26B - default. See below.
#   26b-a4b      the same MoE in Q4_K_M. ~22% slower, kept for comparison.
#   12b          dense 12B
#   31b-heretic  dense 31B, abliterated. Highest quality.
#   e4b          middle size - measured slower than both the 26B MoE and E2B
#   e2b          smallest and FITS an 8 GB Mac.
#
# Why 26b-q4 is the default: llama.cpp's Metal kernels run Q4_0 markedly
# faster than K-quants, and Google's QAT release makes Q4_0 quality-safe
# (quantization-aware training, so it holds near-bf16 quality where a naive
# Q4_0 would not). Measured on this machine, MTP depth 3, identical prompts:
#
#     quant     size      prefill    decode    draft acceptance
#     -------   -------   -------    ------    ----------------
#     Q4_K_M    16.80 GB   112 t/s    97.2 t/s       79%
#     Q4_0 QAT  14.25 GB   129 t/s   119.1 t/s       82%
#
# +22% decode, +15% prefill, 15% smaller. The existing MTP drafter works
# with it unchanged; acceptance is slightly HIGHER than on Q4_K_M.
MODEL_ALIASES="26b-q4 26b-a4b 12b 31b-heretic e4b e2b qwen-27b qwen-9b qwen-35b"

model_repo_for() {
  case "$1" in
    26b-q4)      echo "OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF" ;;
    26b-a4b)     echo "HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP" ;;
    12b)         echo "HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced" ;;
    31b-heretic) echo "llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF" ;;
    e4b)         echo "HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive" ;;
    e2b)         echo "HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive" ;;
    # ── Qwen ─────────────────────────────────────────────────────────────────
    # Same rule as the Gemma side: uncensored only. Qwen3.8 is served through
    # llama.cpp like everything else here, so the family is just another set of
    # registry entries rather than a second code path.
    qwen-27b)    echo "HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF" ;;
    qwen-9b)     echo "mradermacher/Qwen3.8-9B-heretic-uncensored-i1-GGUF" ;;
    # Qwen never released a 3.8 35B-A3B. This is the HauhauCS uncensored 3.6
    # 35B-A3B build - same MoE shape, nearest thing that exists. Named for what
    # it is rather than mislabelled as 3.8.
    qwen-35b)    echo "HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive" ;;
    */*)         echo "$1" ;;
    *)           die "MODEL=\"$1\" is neither a known alias nor an owner/name repo id.
    Known aliases: $MODEL_ALIASES" ;;
  esac
}

model_is_known_alias() {
  case "$1" in
    26b-q4|26b-a4b|12b|31b-heretic|e4b|e2b|qwen-27b|qwen-9b|qwen-35b) return 0 ;;
    *) return 1 ;;
  esac
}

# Which family an alias belongs to. Drives the chat-template handling and the
# default quant, because the two families do not share either.
model_family_for() {
  case "$(model_repo_for "$1" 2>/dev/null)" in
    *[Qq]wen*) echo "qwen" ;;
    *)         echo "gemma" ;;
  esac
}

# ── config ───────────────────────────────────────────────────────────────────
load_config() {
  [[ -f "$ENV_FILE" ]] || die "env.conf not found at $ENV_FILE"

  MODEL="26b-q4"
  MODELS_DIR="$REPO_DIR/models"
  CONTEXT_WINDOW=131072
  MAX_RESPONSE_TOKENS=32768
  KV_QUANT="q8_0"
  THINKING="off"
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
  SERVED_MODEL_NAME="Upinel-AIOS-GGUF"
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
  export MODEL_QUANT
  export KV_QUANT THINKING THINKING_BUDGET_TOKENS THINKING_BUDGET_MESSAGE
  export MTP_DEPTH HOST PORT API_KEY_FILE DRAFT_PATCHED_RUNTIME
  export LLAMA_SERVER
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

# Match "mmproj" anywhere in the name, not only at the start. Plenty of repos
# embed it mid-filename - gemma-4-26B-A4B-...-mmproj-BF16.gguf - and the old
# anchored mmproj*.gguf pattern silently found nothing for them.
model_mmproj_gguf() {
  local dir="$1"
  # `return 0` matters: callers run under `set -e`, and "no projector" is a
  # normal result, not a failure. Without it a model with no mmproj aborts
  # whatever script asked.
  find -L "$dir" -maxdepth 1 -iname '*.gguf' 2>/dev/null \
    | grep -iE 'mmproj' | head -1
  return 0
}

# The MTP draft head. DRAFT_FILE in env.conf overrides everything.
#
# A repo may ship weights without the drafter - the Q4_0 QAT 26B does exactly
# that - and the head is a separate artifact that transfers across quants of
# the same architecture, so a miss is worth chasing elsewhere rather than
# quietly running autoregressive and losing a fifth of decode speed.
#
# But it must stay inside the same model FAMILY. Pairing a Gemma MTP head with
# a Qwen target loads without complaint and is silently wrong; that happened
# while adding the Qwen entries, because the fallback searched all of models/.
# So a draft found outside this model's own directory has to match its family.
#
# Draft files are named inconsistently across repos - mtp-*.gguf,
# FastMTP-32K.gguf, *-draft.gguf - so match on the substring, not a prefix.
model_draft_gguf() {
  local dir="$1" hit="" fam=""
  if [[ -n "${DRAFT_FILE:-}" && -f "${DRAFT_FILE:-}" ]]; then
    echo "$DRAFT_FILE"
    return
  fi

  case "$(basename "$dir")" in
    *[Qq]wen*)  fam="qwen"  ;;
    *[Gg]emma*) fam="gemma" ;;
  esac

  # Match the BASENAME, not the whole path: the HauhauCS Gemma directory is
  # literally named "...-MTP", so grepping the path made its vision projector
  # look like a draft head.
  hit="$(find -L "$dir" -maxdepth 1 \
           \( -iname '*mtp*.gguf' -o -iname '*draft*.gguf' \) 2>/dev/null | head -1)"

  if [[ -z "$hit" && -n "$fam" ]]; then
    # Cross-directory, so gate on family: a Gemma head paired with a Qwen
    # target loads without complaint and is silently wrong.
    hit="$(find -L "$MODELS_DIR" -maxdepth 2 \
             \( -iname '*mtp*.gguf' -o -iname '*draft*.gguf' \) 2>/dev/null \
            | grep -i "$fam" | head -1)"
  fi

  [[ -n "$hit" ]] && echo "$hit"
  # Always succeed. Callers run under `set -e`, and "this model has no draft
  # head" is a normal answer, not a failure - returning 1 here aborted
  # start.sh outright for every model without one.
  return 0
}

model_present() {
  local dir="$1"
  [[ -n "$(model_main_gguf "$dir" 2>/dev/null || true)" ]]
}

# Does this draft head need a patched llama.cpp?
#
# HauhauCS's FastMTP heads trim the drafter's output vocabulary and carry a
# `d2t` remap tensor to compensate. Stock llama.cpp does not know that tensor,
# so it compares the trimmed output against the full vocab and refuses:
#
#   tensor 'output.weight' has wrong shape; expected 5120, 248320, got 5120, 32768
#
# Worse, llama-server treats a failed draft as fatal and exits, so attaching
# one of these turns "a bit more speed" into "the server will not start".
#
# Detect the d2t tensor itself rather than pattern-matching the filename, so
# this keeps working for any future head built the same way. Returns 0 when
# the draft needs a patched runtime.
draft_needs_patched_runtime() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" ]] || return 1
  python3 - "$f" <<'PY' 2>/dev/null
import struct, sys

# Walk the GGUF tensor directory and look for a d2t remap tensor.
with open(sys.argv[1], 'rb') as fh:
    if fh.read(4) != b'GGUF':
        raise SystemExit(1)
    struct.unpack('<I', fh.read(4))            # version
    n_tensors, = struct.unpack('<Q', fh.read(8))
    n_kv, = struct.unpack('<Q', fh.read(8))

    SIZES = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8}

    def rd_str():
        (n,) = struct.unpack('<Q', fh.read(8))
        return fh.read(n).decode('utf-8', 'replace')

    def skip_val(t):
        if t == 8:
            rd_str()
        elif t == 9:
            et, = struct.unpack('<I', fh.read(4))
            (cnt,) = struct.unpack('<Q', fh.read(8))
            for _ in range(cnt):
                skip_val(et)
        else:
            fh.read(SIZES[t])

    for _ in range(n_kv):
        rd_str()
        (vt,) = struct.unpack('<I', fh.read(4))
        skip_val(vt)

    for _ in range(n_tensors):
        name = rd_str()
        if name == 'd2t' or name.endswith('.d2t'):
            raise SystemExit(0)
        (nd,) = struct.unpack('<I', fh.read(4))
        fh.read(8 * nd)                        # dims
        fh.read(4 + 8)                         # type, offset
raise SystemExit(1)
PY
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
# llama.cpp CAN cap thinking after all: `--reasoning-budget N` hard-limits the
# thought channel, and `--reasoning-budget-message` is injected as the cap is
# reached. (An earlier version of this file claimed no such budget existed.
# That was wrong and is worth stating plainly, because the fake level names it
# implied - minimal/low/high all meaning "on" - were built on the mistake.)
#
# The levels are now real token budgets, tuned on this machine. Eight agent
# tasks, greedy, median completion tokens per turn and tool-call accuracy:
#
#     level     budget   tokens/turn   correct
#     -------   ------   -----------   -------
#     off       none         133         8/8
#     minimal     32           72         8/8
#     low        128          170         7/8
#     medium     512          288         8/8
#     high        -1          288         8/8
#
# Two things this measurement establishes:
#
#   * A budget WITHOUT the message loses accuracy. Every budgeted value
#     scored 7/8 against thinking-off's 8/8 - the thought channel was cut
#     mid-sentence and the model never got round to emitting a tool call.
#     Adding the message restored 8/8 at every budget. Never set a budget
#     without also setting a message.
#   * minimal (32) is the cheapest of all, beating even thinking-off, and
#     still gets every task right. The model spends a little on a plan and
#     then answers; without a thought channel it rambles in the content
#     instead, which costs more.
#
# Budget cuts are sensitive to where they land - 96 scored 7/8 while both 32
# and 128 scored 8/8 - so treat these as measured points, not a formula.
thinking_level_ok() {
  case "$1" in off|minimal|low|medium|high) return 0 ;; *) return 1 ;; esac
}

thinking_budget_for() {
  case "$1" in
    off)     echo ""   ;;
    minimal) echo 32   ;;
    low)     echo 128  ;;
    medium)  echo 512  ;;
    high)    echo -1   ;;
    *)       echo 32   ;;
  esac
}

# The budget actually passed to llama-server, or empty when thinking is off.
# THINKING_BUDGET_TOKENS overrides the level's tuned value when above zero.
effective_thinking_budget() {
  [[ "$THINKING" == "off" ]] && { echo ""; return; }
  if [[ -n "${THINKING_BUDGET_TOKENS:-}" ]] && (( THINKING_BUDGET_TOKENS > 0 )); then
    echo "$THINKING_BUDGET_TOKENS"
    return
  fi
  thinking_budget_for "$THINKING"
}

# Gemma 4's chat template takes `enable_thinking`. llama.cpp forwards
# --chat-template-kwargs straight into it.
thinking_kwargs() {
  thinking_level_ok "$THINKING" || die "THINKING=\"$THINKING\" is not one of off | minimal | low | medium | high"
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

# Depth actually used: MTP_DEPTH="auto" means "the tuned value, else 3".
#
# 3, not 1. Measured on an M5 Pro against realistic code generation, depth 3
# beats depth 1 at every context length and never falls behind:
#
#     context    depth 1    depth 3
#     -------    -------    -------
#       2k        65 t/s     82 t/s     +27%
#       8k        46 t/s     48 t/s      +5%
#      16k        40 t/s     39 t/s      ~0%
#
# Draft acceptance does fall with depth (91% at depth 1, 78% at depth 3), which
# is why this was previously set to 1. But acceptance is not the metric that
# matters - tokens per second is, and accepting two extra tokens 78% of the
# time still beats accepting one 91% of the time.
#
# Beware of measuring this with a trivially predictable prompt. Counting to
# 200 pins acceptance at 100% for every depth and makes deep drafting look far
# better than it is. Use bench/sweep.py --ask code.
effective_depth() {
  if [[ "${MTP_DEPTH}" == "auto" ]]; then
    local d; d="$(tuned_depth)"
    echo "${d:-3}"
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
