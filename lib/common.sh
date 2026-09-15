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
# TWO ENGINES, ONE REGISTRY. UNCENSORED ONLY.
#
# UpinelAIOS serves through either of two runtimes, and the alias tells you
# which. The engine is a property of the model, not a global setting: a GGUF
# checkpoint can only run on llama.cpp, an MTPLX pack can only run on MTPLX, so
# picking the model picks the engine and there is nothing else to decide.
#
#   engine   runtime          what it is best at
#   ------   ---------------  ------------------------------------------------
#   gguf     llama.cpp        Gemma 4 at peak speed; vision; 100+ t/s
#   mlx      MLX / MTPLX      anything Qwen - up to 2.6x faster than llama.cpp
#
# ── GGUF (llama.cpp) ─────────────────────────────────────────────────────────
#   26b-q4       MoE, Q4_0 QAT. FASTEST 26B - default. See below.
#   26b-a4b      the same MoE in Q4_K_M. ~47% slower, kept for comparison.
#   12b          dense 12B, the largest that fits a 16 GB Mac
#   31b-heretic  dense 31B, abliterated. Highest quality dense model.
#   e4b          middle size - measured slower than both the 26B MoE and E2B
#   e2b          smallest and FITS an 8 GB Mac
#   qwen-27b / qwen-9b / qwen-35b   Qwen through llama.cpp - see the MLX note
#
# Why 26b-q4 is the default: llama.cpp's Metal kernels run Q4_0 markedly
# faster than K-quants, and Google's QAT release makes Q4_0 quality-safe
# (quantization-aware training, so it holds near-bf16 quality where a naive
# Q4_0 would not). Measured on this machine, MTP depth 3, identical prompts:
#
#     quant     size      decode
#     -------   -------   ------
#     Q4_K_M    16.80 GB    72.5 t/s
#     Q4_0 QAT  14.25 GB   106.4 t/s
#
# ~47% faster decode and 15% smaller. The existing MTP drafter works with it
# unchanged, at slightly HIGHER acceptance than on Q4_K_M.
#
# ── MLX (MTPLX) ──────────────────────────────────────────────────────────────
#   4bit        27B dense, 4-bit. The quality pick.
#   6bit        27B dense, 6-bit. Closer to the original weights.
#   27b-3bit    the smallest 27B pack
#   27b-4bit    a different 27B 4-bit conversion
#   9b          dense 9B, for tight memory
#   9b is the MLX default only on a small Mac.
#   moe         35B-A3B MoE. DEFAULT - fastest thing here, and the best agent
#               balance. Note this is Qwen 3.6, not 3.8: Qwen never released a
#               3.8 35B-A3B, and the one repo labelled that way is a 3.6 distill.
#
# The two families are NOT interchangeable on speed. A dense 27B reads ~15 GB of
# weights per token through llama.cpp and manages ~13.5 t/s; the same model
# through MLX reaches ~34.7 t/s, because MTPLX's MTP implementation works on
# Metal and llama.cpp's does not. The MLX aliases exist to collect that.
#
# NOTE: a case statement, not an associative array. macOS ships bash 3.2,
# which has no `declare -A`, and this bundle must run on a stock Mac.
MODEL_ALIASES="\
gguf-g-26ba4b gguf-g-26ba4b-q4km gguf-g-12b gguf-g-31b gguf-g-e4b gguf-g-e2b \
gguf-q-27b gguf-q-9b gguf-q-35ba3b \
mlx-q-35ba3b mlx-q-27b-4bit mlx-q-27b-6bit mlx-q-27b-3bit mlx-q-27b-4bit-bz mlx-q-9b"

# Aliases from before the rename. Still accepted - an existing env.conf or a
# bookmarked command keeps working - but warned about, and mapped to the new
# name so there is exactly one entry per model.
legacy_alias_for() {
  case "$1" in
    26b-q4)      echo gguf-g-26ba4b      ;;
    26b-a4b)     echo gguf-g-26ba4b-q4km ;;
    12b)         echo gguf-g-12b         ;;
    31b-heretic) echo gguf-g-31b         ;;
    e4b)         echo gguf-g-e4b         ;;
    e2b)         echo gguf-g-e2b         ;;
    qwen-27b)    echo gguf-q-27b         ;;
    qwen-9b)     echo gguf-q-9b          ;;
    qwen-35b)    echo gguf-q-35ba3b      ;;
    4bit)        echo mlx-q-27b-4bit     ;;
    6bit)        echo mlx-q-27b-6bit     ;;
    27b-3bit)    echo mlx-q-27b-3bit     ;;
    27b-4bit)    echo mlx-q-27b-4bit-bz  ;;
    9b)          echo mlx-q-9b           ;;
    moe)         echo mlx-q-35ba3b       ;;
    *)           echo ""                 ;;
  esac
}

# Which engine serves this alias: gguf | mlx. Empty when unknown.
#
# A raw owner/name repo id is inferred from its name, because that is all we
# have - MTPLX packs say MTPLX, GGUF files say GGUF. An unrecognisable repo id
# returns empty and the caller decides what to do about it.
model_engine_for() {
  local a
  # The rename put the engine in the alias, so a known alias needs no table at
  # all - the name says which runtime serves it. This is the main practical win
  # of the format: a new model cannot forget to declare its engine.
  case "$1" in
    gguf-*) echo gguf; return 0 ;;
    mlx-*)  echo mlx;  return 0 ;;
  esac

  a="$(legacy_alias_for "$1")"
  [[ -n "$a" ]] && { model_engine_for "$a"; return 0; }

  # A registered repo id: resolve through the alias table, because several of
  # them do not say GGUF in the name.
  a="$(alias_for_repo "$1")"
  if [[ -n "$a" ]]; then model_engine_for "$a"; return 0; fi

  # An unregistered repo id: infer from the name, best effort. Callers holding
  # a directory should use engine_for_dir(), which looks at the contents.
  case "$1" in
    *MTPLX*|*mtplx*) echo mlx  ;;
    *GGUF*|*gguf*)   echo gguf ;;
    *)               echo ""   ;;
  esac
}

model_repo_for() {
  local _a
  _a="$(legacy_alias_for "$1")"
  if [[ -n "$_a" ]]; then
    warn "MODEL alias \"$1\" was renamed to \"$_a\" - update env.conf."
    set -- "$_a"
  fi

  case "$1" in
    gguf-g-26ba4b)      echo "OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF" ;;
    gguf-g-26ba4b-q4km)     echo "HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP" ;;
    gguf-g-12b)         echo "HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced" ;;
    gguf-g-31b) echo "llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF" ;;
    gguf-g-e4b)         echo "HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive" ;;
    gguf-g-e2b)         echo "HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive" ;;
    # ── MLX / MTPLX ──────────────────────────────────────────────────────────
    mlx-q-27b-4bit)        echo "itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-4bit" ;;
    mlx-q-27b-6bit)        echo "itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-6bit" ;;
    mlx-q-27b-3bit)    echo "barozp/Qwen3.8-27B-Uncensored-MTPLX-3bit" ;;
    mlx-q-27b-4bit-bz)    echo "barozp/Qwen3.8-27B-Uncensored-MTPLX-4bit" ;;
    mlx-q-9b)          echo "Foresee/Qwen3.8-9B-heretic-uncensored-4bit-MTPLX" ;;
    mlx-q-35ba3b)         echo "hawhyhb/Qwen3.6-35B-A3B-Uncensored-Heretic-MTPLX-4bit-FP16" ;;
    # ── Qwen ─────────────────────────────────────────────────────────────────
    # Same rule as the Gemma side: uncensored only. Qwen3.8 is served through
    # llama.cpp like everything else here, so the family is just another set of
    # registry entries rather than a second code path.
    gguf-q-27b)    echo "HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF" ;;
    gguf-q-9b)     echo "mradermacher/Qwen3.8-9B-heretic-uncensored-i1-GGUF" ;;
    # Qwen never released a 3.8 35B-A3B. This is the HauhauCS uncensored 3.6
    # 35B-A3B build - same MoE shape, nearest thing that exists. Named for what
    # it is rather than mislabelled as 3.8.
    gguf-q-35ba3b)    echo "HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive" ;;
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
# set_config_value <KEY> <value>
#
# Rewrites one key in env.conf, preserving every comment and every other line.
# Used by install.sh to persist a model choice that the hardware scan would
# otherwise overwrite.
set_config_value() {
  local key="$1" value="$2"
  python3 - "$ENV_FILE" "$key" "$value" <<'PYSET'
import re, sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
# Keys that env.conf quotes; keep the file's own convention.
QUOTED = {"MODEL", "KV_QUANT", "PROFILE", "THINKING", "MODEL_QUANT",
          "FAN_MODE", "BATCHING_PRESET", "PRESERVE_THINKING",
          "SSD_SESSION_CACHE", "METAL_TENSOR_API", "SERVED_MODEL_NAME",
          "HOST", "API_KEY_FILE", "LLAMA_SERVER", "TOOL_TEMPLATE",
          "MODELS_DIR", "LOG_FILE", "DRAFT_PATCHED_RUNTIME",
          "MTP_DEPTH", "PREFILL_CHUNK_TOKENS"}
src = open(path, encoding="utf-8").read()
val = f'"{value}"' if key in QUOTED and not value.startswith('"') else value
new, n = re.subn(rf'^{re.escape(key)}=.*$', f'{key}={val}', src, count=1, flags=re.M)
if n == 1:
    open(path, "w", encoding="utf-8").write(new)
    sys.exit(0)
sys.exit(1)
PYSET
}

load_config() {
  [[ -f "$ENV_FILE" ]] || die "env.conf not found at $ENV_FILE"

  MODEL="gguf-g-26ba4b"
  MODELS_DIR="$REPO_DIR/models"
  CONTEXT_WINDOW=131072
  MAX_RESPONSE_TOKENS=32768
  KV_QUANT="q8_0"
  THINKING="off"
  THINKING_BUDGET_TOKENS=0
  MTP_DEPTH="auto"
  METAL_TENSOR_API="auto"
  # MLX-only keys. Defaulted here so a trimmed env.conf still works on either
  # engine; the GGUF engine simply never reads them.
  PROFILE="sustained"
  BATCHING_PRESET="agent"
  SESSION_BANK_GB=8
  MLX_CACHE_LIMIT_GB=0
  PRESERVE_THINKING="scoped"
  THINKING_NOVELTY_CLOSE=1
  SSD_SESSION_CACHE="off"
  STREAM_INTERVAL=1
  RATE_LIMIT=0
  NGRAM_PREWARM=0
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

# Does this chip have Neural Accelerators in its GPU cores?
#
# M5 and later do; M1-M4 do not. It matters because llama.cpp exposes the
# Metal 4 tensor API only where the hardware supports it, and gates it by chip
# name for a reason: its own notes record the tensor API as ~5% SLOWER on
# M2 Ultra and neutral on M4/M4 Max. Forcing it on older silicon is a
# pessimisation, not an optimisation.
chip_has_neural_accelerator() {
  case "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)" in
    *" M5"*|*" M6"*|*" M7"*|*" M8"*|*" M9"*) return 0 ;;
  esac
  return 1
}

# Version of the llama.cpp runtime, or empty when it is not installed.
#
# Two traps, both of which produced a silently blank version everywhere this
# was done inline:
#
#   * llama-server prints --version to STDERR, so `2>/dev/null` throws away the
#     only thing the call exists to read;
#   * `| head -1` closes the pipe early, and under `set -o pipefail` that fails
#     the whole pipeline. sed reads to EOF instead, so nothing is left holding
#     a SIGPIPE.
llama_version() {
  command -v llama-server >/dev/null 2>&1 || return 0
  llama-server --version 2>&1 | sed -n '1s/^version: //p'
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

# ── which models are actually downloaded ─────────────────────────────────────
# One line per model directory that holds a loadable weight file. A directory
# left behind by an interrupted download is skipped rather than offered, so the
# picker cannot hand the server something that fails to load a second later.
#
# `|| true` is load-bearing: model_main_gguf ends in a pipeline, and under
# `set -o pipefail` a directory with no .gguf at all makes that pipeline fail,
# which would abort the caller.
model_dirs_on_disk() {
  local dir eng
  for dir in "$MODELS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    eng="$(engine_for_dir "$dir")"
    [[ -n "$eng" ]] || continue
    printf '%s\n' "$dir"
  done
  return 0
}

# Which engine owns this model directory, by looking at what is in it.
# Empty when it holds no complete model of either kind.
#
# A directory belongs to exactly one engine, so the picker never has to guess
# and the launcher never has to ask: the contents decide.
engine_for_dir() {
  local dir="$1" repo
  repo="$(model_repo_from_dir "$dir")"
  case "$(model_engine_for "$repo")" in
    gguf) model_main_gguf "$dir" >/dev/null 2>&1 || true
          [[ -n "$(model_main_gguf "$dir" 2>/dev/null || true)" ]] && echo gguf && return 0 ;;
    mlx)  model_dir_ok "$dir" && echo mlx && return 0 ;;
  esac
  # Unknown repo id: fall back to sniffing the contents.
  if [[ -n "$(model_main_gguf "$dir" 2>/dev/null || true)" ]]; then
    echo gguf; return 0
  fi
  if model_dir_ok "$dir"; then echo mlx; return 0; fi
  echo ""
}

# Size of a model directory in GB, whichever engine owns it.
model_dir_size_gb() {
  local dir="$1" eng mf
  eng="$(engine_for_dir "$dir")"
  if [[ "$eng" == "gguf" ]]; then
    mf="$(model_main_gguf "$dir" 2>/dev/null || true)"
    [[ -n "$mf" ]] && echo $(( $(stat -f%z "$mf" 2>/dev/null || echo 0) / 1000000000 )) || echo 0
  elif [[ "$eng" == "mlx" ]]; then
    model_dir_gb "$dir" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# "owner--name" back to "owner/name". Only the FIRST separator is restored,
# which is correct: exactly one was inserted when the directory was named.
model_repo_from_dir() {
  local base; base="$(basename "$1")"
  printf '%s\n' "${base/--//}"
}

# Reverse-map a repo id back to its alias. Empty when it is not a known alias.
alias_for_repo() {
  local a
  for a in $MODEL_ALIASES; do
    [[ "$(model_repo_for "$a" 2>/dev/null)" == "$1" ]] && { printf '%s\n' "$a"; return 0; }
  done
  printf '\n'
}

# How long the on-disk picker waits before taking the default. Whole seconds
# only: bash 3.2 - which is what ships on macOS - rejects `read -t 0.5` with
# "invalid timeout specification".
MODEL_PICK_SECONDS=5

# Offer the models already downloaded, when there is a real choice to make.
#
# Sets MODEL_REPO and MODEL_DIR when something is chosen and returns 0; returns
# 1 to mean "keep what env.conf says", which covers every case where asking
# would be wrong: one model on disk, no terminal to ask on, an unreadable
# answer, or no answer within MODEL_PICK_SECONDS.
#
# Never prompts without a terminal. A server start must not hang behind a
# question in a pipe, in CI, or under launchd.
choose_model_on_disk() {
  local dirs=() d
  while IFS= read -r d; do
    [[ -n "$d" ]] && dirs+=("$d")
  done < <(model_dirs_on_disk)

  (( ${#dirs[@]} > 1 )) || return 1
  [[ -t 0 ]] || return 1

  local default_dir="$MODELS_DIR/${MODEL_REPO//\//--}"
  local default_idx=1 i=1 repo alias name eng engc engup size mark
  for d in "${dirs[@]}"; do
    [[ "$d" == "$default_dir" ]] && default_idx=$i
    i=$(( i + 1 ))
  done

  log ""
  log "  ${C_BOLD}Models on disk${C_RESET}   ${C_DIM}${#dirs[@]} downloaded - pick one to serve now${C_RESET}"
  log ""
  printf '  %2s  %-5s %-20s %6s  %s\n' "#" "ENGINE" "ALIAS" "SIZE" ""
  i=1
  for d in "${dirs[@]}"; do
    repo="$(model_repo_from_dir "$d")"
    alias="$(alias_for_repo "$repo")"
    name="${alias:-${repo##*/}}"
    eng="$(engine_for_dir "$d")"
    size="$(model_dir_size_gb "$d")"
    # Colour the engine so the two are separable at a glance: amber for GGUF,
    # violet for MLX, matching the badges used elsewhere in the project.
    case "$eng" in
      gguf) engc="$C_YELLOW" ;;
      mlx)  engc="$C_BLUE"   ;;
      *)    engc="$C_DIM"    ;;
    esac
    mark=""
    (( i == default_idx )) && mark="${C_DIM}<- default${C_RESET}"
    # tr, not ${eng^^}: bash 3.2 ships on macOS and has no case conversion.
    engup="$(printf '%s' "$eng" | tr '[:lower:]' '[:upper:]')"
    printf '  %2d  %s%-5s%s %-20s %4s GB  %s\n' \
      "$i" "$engc" "$engup" "$C_RESET" "$name" "$size" "$mark"
    i=$(( i + 1 ))
  done
  log ""
  printf '  Number [1-%d], or Enter for the default. Auto-selects in %ds: ' \
         "${#dirs[@]}" "$MODEL_PICK_SECONDS"

  local ans=""
  if ! read -r -t "$MODEL_PICK_SECONDS" ans; then
    log ""
    info "No answer in ${MODEL_PICK_SECONDS}s - using $(basename "$default_dir")."
    return 1
  fi

  ans="${ans//[!0-9]/}"
  if [[ -z "$ans" ]]; then
    return 1                      # Enter: keep the default
  fi
  if (( ans < 1 || ans > ${#dirs[@]} )); then
    warn "No model number $ans - using the default."
    return 1
  fi

  MODEL_DIR="${dirs[$(( ans - 1 ))]}"
  MODEL_REPO="$(model_repo_from_dir "$MODEL_DIR")"
  return 0
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
# Which model a filename is for: "26B-A4B", "E2B", "31B". Empty when the name
# carries no such token.
#
# Bash 3.2 has no ${var^^}, and macOS ships 3.2, hence the tr.
model_designation() {
  local name tok=""
  name="$(basename "$1")"
  if [[ "$name" =~ ([0-9]+[Bb]-[Aa][0-9]+[Bb]) ]]; then
    tok="${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ([Ee][0-9]+[Bb]) ]]; then
    tok="${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ([0-9]+[Bb]) ]]; then
    tok="${BASH_REMATCH[1]}"
  fi
  printf '%s\n' "$(printf '%s' "$tok" | tr '[:lower:]' '[:upper:]')"
}

# Speculative draft head for a model directory, or nothing.
#
# A draft head is only valid for the exact model it was trained against - it is
# a second network predicting that target's next tokens. Getting this wrong does
# not degrade, it aborts: pairing the 26B head with the 2B target died in
# llama.cpp with
#
#   GGML_ASSERT(ggml_can_mul_mat(a, b)) failed
#   llama_model_gemma4_assistant::graph
#
# and took the whole server with it, for a model that runs fine without MTP.
#
# So a head is accepted only if its designation matches the target's, and a head
# found OUTSIDE this model's own directory must additionally match its family -
# a Gemma head on a Qwen target loads with no complaint and is silently wrong.
#
# The cross-directory search is not optional: the default `26b-q4` repo ships
# weights and a projector but no draft, and borrows the 26B head from the
# sibling `26b-a4b` directory, which is the same architecture and is correct.
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

  # What the target is, taken from its weights file where possible: that is the
  # file the draft has to line up with. `|| true` because model_main_gguf ends
  # in a pipeline and pipefail turns "no weights here" into a failure.
  local target want
  target="$(model_main_gguf "$dir" 2>/dev/null || true)"
  want="$(model_designation "${target:-$(basename "$dir")}")"

  local f d
  # Same directory first. An unparseable name on either side is accepted here:
  # a draft shipped alongside the model is taken at its word, and plenty are
  # named "draft.gguf" with no size token at all.
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    d="$(model_designation "$f")"
    if [[ -z "$want" || -z "$d" || "$want" == "$d" ]]; then
      hit="$f"; break
    fi
  done < <(find -L "$dir" -maxdepth 1 \
             \( -iname '*mtp*.gguf' -o -iname '*draft*.gguf' \) 2>/dev/null)

  # Then across model directories, where both sides must agree explicitly.
  if [[ -z "$hit" && -n "$want" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      d="$(model_designation "$f")"
      [[ -n "$d" && "$d" == "$want" ]] || continue
      if [[ -n "$fam" ]] && ! printf '%s' "$f" | grep -qi "$fam"; then
        continue
      fi
      hit="$f"; break
    done < <(find -L "$MODELS_DIR" -maxdepth 2 \
               \( -iname '*mtp*.gguf' -o -iname '*draft*.gguf' \) 2>/dev/null)
  fi

  [[ -n "$hit" ]] && echo "$hit"
  # Always succeed. Callers run under `set -e`, and "this model has no draft
  # head" is a normal answer, not a failure - returning 1 here aborted
  # start.sh outright for every model without one.
  return 0
}

# ── MLX engine helpers ───────────────────────────────────────────────────────
# Used by lib/engines/mlx.sh. They live here rather than in the engine module
# because the shared front end also needs them: the model picker, model_fit()
# and the installer all have to judge an MLX pack.
#
# An MLX pack is a tree of safetensors shards, not a single file, so "is this
# downloaded?" cannot be answered by looking for one filename.

# Size of one model directory in GB, from the safetensors it holds. Returns
# non-zero when the weights come to less than a gigabyte, which in practice
# means the download did not finish.
# KV cost per token in KB at f16, for the MLX engine's packs.
#
# NOTE: for Qwen this disagrees with the GGUF table above by about 4x, and the
# disagreement is unresolved. The two projects modelled the same base models
# differently - the GGUF table assumes full attention on every layer
# (Qwen3.8-27B: 260 KB/token), the MLX table assumes a hybrid that caches KV on
# a subset (64 KB/token). At least one of them is wrong, and a 4x error in this
# number either wastes memory or invites an OOM.
#
# Both are kept verbatim so that neither engine's memory arithmetic changes
# under the merge. Resolving it needs a measurement, not a guess: run a long
# prompt on each engine and read the KV allocation out of the server log.
kv_kb_per_token_f16_mlx() {
  case "$1" in
    # ~12 of 48 attention layers.
    *Qwen3.6-35B*) echo 48  ;;
    # 32 of 32 layers - dense, full attention on every layer.
    *Qwen3.8-9B*)  echo 128 ;;
    # 16 of 64 layers - every 27B build here (4bit/6bit/3bit, both owners).
    *)             echo 64  ;;
  esac
}

# KV KB/token at f16 for whichever engine serves this repo. The engine is
# derived from the repo id, so existing callers keep working unchanged.
kv_kb_per_token_f16() {
  case "$(model_engine_for "$1")" in
    mlx) kv_kb_per_token_f16_mlx "$1" ;;
    *)   kv_kb_per_token_f16_gguf "$1" ;;
  esac
}

# KV KB/token for one engine at one quant, ready for the memory arithmetic.
kv_kb_for_engine() {
  local eng="$1" kb
  kb="$(kv_kb_per_token_f16 "$MODEL_REPO")"
  case "$(kv_quant_for "$eng")" in
    q8|q8_0)   kb=$(( kb / 2 )) ;;
    q4|q4_0)   kb=$(( kb / 4 )) ;;
  esac
  echo "$kb"
}

# ── cross-engine value translation ───────────────────────────────────────────
# env.conf holds one vocabulary; each engine has its own spelling for the same
# idea. These are the translators, so a shared key never has to hold two values
# and the user never has to remember which engine they are on.
#
# Legacy spellings (q8_0, q4_0) are accepted so an env.conf written before the
# merge keeps working.

# KV cache quant, in the engine's own spelling. $1 = engine.
kv_quant_for() {
  case "$1:${KV_QUANT:-q8}" in
    gguf:q8|gguf:q8_0)   echo q8_0 ;;
    gguf:q4|gguf:q4_0)   echo q4_0 ;;
    gguf:f16|gguf:bf16)  echo f16  ;;
    mlx:q8|mlx:q8_0)     echo q8   ;;
    mlx:q4|mlx:q4_0)     echo q4   ;;
    # MLX calls an unquantized cache "off" rather than "f16".
    mlx:f16|mlx:off)     echo off  ;;
    # Unknown value: pass it through and let the engine validate it, so the
    # error message names the engine's vocabulary rather than ours.
    *)                   echo "${KV_QUANT}" ;;
  esac
}

# Prefill chunk size for the engine. "auto" resolves to each runtime's own
# preferred value; a number is passed through untouched.
prefill_chunk_for() {
  case "${PREFILL_CHUNK_TOKENS:-auto}" in
    auto|"") case "$1" in gguf) echo 512 ;; mlx) echo 2048 ;; *) echo 512 ;; esac ;;
    *)       echo "$PREFILL_CHUNK_TOKENS" ;;
  esac
}

# ── live server settings (MLX engine only) ───────────────────────────────────
# MTPLX exposes a settings endpoint, so thinking can be changed on a running
# server without reloading the model. llama.cpp has no equivalent - its
# thinking is a per-request chat-template kwarg - so status.sh writes
# env.conf there instead and asks for a restart.
# ── live settings (no restart needed) ───────────────────────────────────────
# MTPLX exposes POST /v1/mtplx/settings accepting reasoning, reasoning_effort,
# enable_thinking, depth and more. This is what makes an on-the-fly toggle
# possible: the model stays loaded and only the decode policy changes.
live_settings_get() {
  local hdr; hdr="$(auth_header)"
  curl -fsS --max-time 8 ${hdr:+-H "$hdr"} "http://127.0.0.1:${PORT}/v1/mtplx/settings" 2>/dev/null
}

live_settings_set() {
  local json="$1"
  local hdr; hdr="$(auth_header)"
  curl -fsS --max-time 10 -X POST     -H "Content-Type: application/json" ${hdr:+-H "$hdr"}     -d "$json" "http://127.0.0.1:${PORT}/v1/mtplx/settings" 2>/dev/null
}

# Map a THINKING level onto the live-settings payload.
live_thinking_payload() {
  local level="$1"
  thinking_level_ok "$level" || die "Unknown thinking level: $level"
  local effort; effort="$(thinking_effort_for "$level")"
  if [[ "$level" == "off" ]]; then
    printf '{"reasoning":"off","enable_thinking":false}'
  else
    printf '{"reasoning":"on","enable_thinking":true,"reasoning_effort":"%s"}' "$effort"
  fi
}

# ── interactive prompts ──────────────────────────────────────────────────────
# ask_yes_no <question> <default: y|n>
#
# Reads from /dev/tty when stdin is not a terminal, so a scripted install
# (curl | bash) can still ask. Returns 1 without asking when there is no
# terminal at all, which is what makes an unattended install work.
ask_yes_no() {
  local q="$1" default="${2:-n}" reply="" hint="[y/N]"
  [[ "$default" == "y" ]] && hint="[Y/n]"

  if [[ ! -c /dev/tty ]]; then
    [[ "$default" == "y" ]] && return 0 || return 1
  fi

  printf '  %s %s ' "$q" "$hint"
  if [[ -t 0 ]]; then
    read -r reply || reply=""
  else
    read -r reply < /dev/tty || reply=""
  fi

  case "$reply" in
    "") [[ "$default" == "y" ]] && return 0 || return 1 ;;
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) [[ "$default" == "y" ]] && return 0 || return 1 ;;
  esac
}

# The engine the user did NOT pick, for the "install both?" offer.
other_engine() {
  case "$1" in
    gguf) echo mlx  ;;
    mlx)  echo gguf ;;
    *)    echo ""   ;;
  esac
}

# Load an engine module by name.
load_engine() {
  local mod="$REPO_DIR/lib/engines/$1.sh"
  [[ -f "$mod" ]] || die "No engine module at $mod"
  # shellcheck source=/dev/null
  source "$mod"
}

model_dir_gb() {
  local bytes
  bytes="$(find -L "$1" -name '*.safetensors' -type f \
            -exec stat -f%z {} + 2>/dev/null | awk '{n+=$1} END {print n+0}')"
  (( bytes > 1000000000 )) || return 1
  echo $(( bytes / 1000000000 ))
}

# Is this directory a model that will actually load?
#
# Not "does it contain a safetensors file": a download in progress leaves a
# directory with the first shards in it, and offering that in the picker
# produces exactly the failure the picker exists to prevent. Packs ship
# model.safetensors.index.json naming every shard, so when that index is there,
# all of it has to be there.
model_dir_ok() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  # -L matters: without it a models/ entry that is a symlink to another volume
  # is invisible, and the picker silently omits a model the user can see.
  find -L "$dir" -maxdepth 1 -name '*.safetensors' -type f 2>/dev/null \
    | grep -q . || return 1
  [[ -f "$dir/model.safetensors.index.json" ]] || return 0
  python3 - "$dir" <<'PYEOF'
import json, os, sys
d = sys.argv[1]
try:
    weight_map = json.load(open(os.path.join(d, "model.safetensors.index.json")))
except Exception:
    sys.exit(0)          # an unreadable index is not grounds to hide a model
want = set((weight_map.get("weight_map") or {}).values())
if not want:
    sys.exit(0)
sys.exit(0 if all(os.path.exists(os.path.join(d, f)) for f in want) else 1)
PYEOF
}

# MLX takes thinking as flags rather than a template kwarg, so it needs its own
# mapping from the project's five levels onto MTPLX's three efforts.
thinking_effort_for() {
  case "$1" in
    high)   echo xhigh  ;;
    medium) echo medium ;;
    *)      echo low    ;;
  esac
}

thinking_flags() {
  thinking_level_ok "$THINKING" || die "THINKING=\"$THINKING\" is not one of off | minimal | low | medium | high"
  if [[ "$THINKING" == "off" ]]; then
    echo "--reasoning off"
  else
    echo "--reasoning on --reasoning-effort $(thinking_effort_for "$THINKING")"
  fi
}

# MTPLX's thinking guard applies to requests carrying tools - exactly the agent
# case - and it is off by default. This is what turns "think briefly" into a
# limit rather than a suggestion.
apply_thinking_budget_env() {
  local budget="$THINKING_BUDGET_TOKENS"
  [[ "$budget" == "0" ]] && budget="$(thinking_budget_for "$THINKING")"
  if [[ "$THINKING" == "off" ]]; then
    unset MTPLX_THINKING_BUDGET MTPLX_THINKING_NOVELTY_CLOSE
    return 0
  fi
  if (( budget > 0 )); then
    export MTPLX_THINKING_BUDGET="$budget"
    # End thinking early once it stops producing new content, so a capped run
    # does not merely truncate mid-thought.
    export MTPLX_THINKING_NOVELTY_CLOSE="${THINKING_NOVELTY_CLOSE:-1}"
  else
    unset MTPLX_THINKING_BUDGET
    export MTPLX_THINKING_NOVELTY_CLOSE="${THINKING_NOVELTY_CLOSE:-1}"
  fi
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

# Is the server on $PORT actually OURS?
#
# /health alone is not enough. Any OpenAI-compatible server answers it, so a
# server belonging to a *different* project satisfies the check and start.sh
# reports success while serving the wrong thing. That happened for real: the
# MLX project's start.sh printed "Server is up" while a GGUF llama-server from
# this project held port 8000, and the only visible symptom was every client
# getting 401 against a key the running server had never heard of.
#
# The served model id is the cheapest reliable fingerprint - each project
# publishes its own, and it is present as soon as the server can answer.
server_is_ours() {
  local hdr body
  hdr="$(auth_header)"
  if [[ -n "$hdr" ]]; then
    body="$(curl -fsS --max-time 4 -H "$hdr" \
              "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null)"
  else
    body="$(curl -fsS --max-time 4 \
              "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null)"
  fi
  [[ -n "$body" ]] && grep -qF "$SERVED_MODEL_NAME" <<<"$body"
}

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
    # Both: answering /health is not the same as being our server.
    server_healthy && server_is_ours && return 0
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
# KV cache growth per token, in KB, at f16. Divide by 2 for q8, by 4 for q4.
#
# These are computed from each model's own GGUF architecture, not guessed, and
# the two families differ by more than an order of magnitude:
#
#   * Gemma 4 interleaves sliding-window attention (a 1024-token window on 25
#     of 30 layers) with a few full-attention layers, so only those few grow
#     with context. 26B-A4B costs ~20 KB/token, i.e. 1.3 GB at q8 over 131k.
#   * Qwen 3.x is full attention on every layer. The 27B has 65 layers of
#     4 KV heads at 256 wide, so ~260 KB/token - 17 GB at q8 over 131k, which
#     is most of a 32 GB Mac before any weights are loaded.
#
# Getting this wrong in the low direction is what matters: an earlier version
# of this table had no Qwen entries at all and fell through to a 64 KB default,
# under-reporting the 27B by 4x and making a model that will not fit look
# comfortable.
kv_kb_per_token_f16_gguf() {
  case "$1" in
    # Gemma 4 - sliding-window attention, so growth is only the full layers.
    *q4_0-heretic*|*26B-A4B*) echo 20 ;;   # 5 of 30 layers full, 2 KV heads x 512
    *Gemma4-12B*)             echo 32 ;;   # 48 layers; estimate, not measured
    *gemma-4-31B*)            echo 40 ;;   # 60 layers; estimate, not measured
    *Gemma-4-E4B*)            echo 16 ;;
    *Gemma-4-E2B*)            echo 16 ;;
    # Qwen 3.x - full attention everywhere.
    *Qwen3.8-27B*)            echo 260 ;;  # 65 layers, 4 KV x 256
    *Qwen3.8-9B*)             echo 128 ;;  # 32 layers, 4 KV x 256
    *Qwen3.6-35B*)            echo 192 ;;  # MoE, 48 layers; estimate, not measured
    *)                        echo 64 ;;
  esac
}
