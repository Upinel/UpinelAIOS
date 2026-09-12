#!/usr/bin/env bash
# Hardware scan, configuration recommendation, and env.conf rewriting.
#
# Sourced by install.sh. Bash 3.2 compatible (no associative arrays, no
# ${var,,}) because that is what ships on macOS.

# ── hardware scan ────────────────────────────────────────────────────────────

# All of these are cheap; the whole scan takes well under a second except the
# system_profiler call, which we keep to a single invocation.
scan_hardware() {
  HW_CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo 'Apple Silicon')"
  HW_RAM_GB="$(total_ram_gb)"
  HW_GPU_CORES="$(gpu_cores)"
  HW_CPU_CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo '?')"
  HW_MACOS="$(macos_version)"
  HW_MACOS_MAJOR="${HW_MACOS%%.*}"
  HW_MODEL_ID="$(sysctl -n hw.model 2>/dev/null || echo unknown)"

  # Free space on the volume that will hold the weights.
  local probe="$MODELS_DIR"
  [[ -d "$probe" ]] || probe="$(dirname "$probe")"
  [[ -d "$probe" ]] || probe="$REPO_DIR"
  HW_FREE_GB="$(df -g "$probe" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "${HW_FREE_GB:-}" ]] || HW_FREE_GB=0

  # Is the model already on disk?
  HW_MODEL_PRESENT="no"
  if [[ -n "$(model_main_gguf "$MODEL_DIR" 2>/dev/null || true)" ]]; then
    HW_MODEL_PRESENT="yes"
  fi
  HW_WEIGHTS_GB="$(model_weights_gb)"

  # Is the runtime installed?
  HW_MTPLX="not installed"
  if command -v llama-server >/dev/null 2>&1; then
    HW_MTPLX="$(llama-server --version 2>/dev/null | head -1 | sed 's/^version: //')"
    [[ -n "$HW_MTPLX" ]] || HW_MTPLX="installed"
  fi
  HW_BREW="no"; command -v brew >/dev/null 2>&1 && HW_BREW="yes"
}

print_hardware() {
  local chip_family
  # "Apple M5 Pro" -> "M5"
  chip_family="$(printf '%s' "$HW_CHIP" | awk '{print $2}')"

  log ""
  printf '  %-16s %s\n' "chip"        "$HW_CHIP  (${HW_GPU_CORES} GPU cores, ${HW_CPU_CORES} CPU cores)"
  printf '  %-16s %s\n' "unified memory" "${HW_RAM_GB} GB"
  printf '  %-16s %s\n' "macOS"       "$HW_MACOS  ($HW_MODEL_ID)"
  printf '  %-16s %s\n' "free disk"   "${HW_FREE_GB} GB"
  printf '  %-16s %s\n' "llama.cpp"   "$HW_MTPLX"
  printf '  %-16s %s\n' "model on disk" "$HW_MODEL_PRESENT$([[ "$HW_MODEL_PRESENT" == yes ]] && echo " (${HW_WEIGHTS_GB} GB measured)")"

  # The single most useful hardware signal for this workload is memory
  # bandwidth class, which tracks the chip generation more than core count.
  case "$chip_family" in
    M1|M2) log "  $C_DIM note: $chip_family-generation memory bandwidth is roughly half an M5's,$C_RESET"
           log "  $C_DIM expect decode around half the numbers in the README.$C_RESET" ;;
    M3|M4) log "  $C_DIM note: $chip_family is close to the reference M5 Pro for decode rate.$C_RESET" ;;
    *)     ;;
  esac
}

# ── recommendation ───────────────────────────────────────────────────────────
# Sets REC_* variables. The rules encode what was actually measured:
#   * decode needs the weights resident, so MEMORY_LIMIT_GB must clear
#     weights + KV + ~6 GB of activations
#   * KV costs 64/34/18 KB per token for f16/q8/q4 (only 16 of 64 layers cache)
#   * the session bank is the biggest allocator after the weights, and MTPLX
#     auto-sizes it far too generously on a shared desktop
recommend_config() {
  local ram="$HW_RAM_GB"

  # Gemma 4 26B-A4B is a mixture-of-experts model: 26B total but only ~4B
  # active per token, so it is both the fastest big model and the one that
  # comfortably fits a 32 GB Mac.
  if (( ram >= 48 )); then
    REC_MODEL="HauhauCS/Gemma4-26B-A4B-QAT-Uncensored-HauhauCS-Balanced-MTP"
    REC_WEIGHTS_GB=17
    REC_REASON_MODEL="26B-A4B is the quality pick: MoE, ~4B active per token, uncensored"
  elif (( ram >= 16 )); then
    REC_MODEL="HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced"
    REC_WEIGHTS_GB=8
    REC_REASON_MODEL="12B fits ${ram} GB comfortably; the 26B-A4B wants ~20 GB resident"
  else
    REC_MODEL="HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive"
    REC_WEIGHTS_GB=4
    REC_REASON_MODEL="${ram} GB is tight, but E2B needs only 4.2 GB resident and is the fastest model here (~107 t/s on the reference Mac)"
  fi

  # Context and KV quant together have to fit the memory budget.
  if (( ram >= 128 )); then
    REC_CONTEXT=262144; REC_KV="q8_0"
    REC_REASON_CTX="maximum context with an unquantized KV cache"
  elif (( ram >= 96 )); then
    REC_CONTEXT=262144; REC_KV="q8_0"
    REC_REASON_CTX="maximum context; q8 KV keeps it inside the budget"
  elif (( ram >= 56 )); then
    REC_CONTEXT=131072; REC_KV="q8_0"
    REC_REASON_CTX="128K, with headroom left for your desktop apps"
  elif (( ram >= 40 )); then
    REC_CONTEXT=65536; REC_KV="q8_0"
    REC_REASON_CTX="64K; llama.cpp reserves the whole window up front, so this is a real cost"
  elif (( ram >= 30 )) ; then
    REC_CONTEXT=32768; REC_KV="q8_0"
    REC_REASON_CTX="32K is the reliable ceiling at ${ram} GB"
  elif (( ram >= 16 )) ; then
    REC_CONTEXT=16384; REC_KV="q8_0"
    REC_REASON_CTX="16K on ${ram} GB; llama.cpp reserves the window up front"
  else
    REC_CONTEXT=8192; REC_KV="q8_0"
    REC_REASON_CTX="${ram} GB leaves little room; 8K is the honest ceiling"
  fi

  # Leave roughly a quarter of RAM to macOS and everything else. On a 64 GB
  # Mac that is the 48 GB ceiling the reference machine was tuned at.
  REC_MEMORY_LIMIT_GB=$(( ram * 3 / 4 ))
  # Floor at 4 GB, not 8: an 8 GB Mac should be told 6, and a floor of 8 would
  # silently recommend more memory than the machine has.
  (( REC_MEMORY_LIMIT_GB >= 4 )) || REC_MEMORY_LIMIT_GB=4

  # Session bank: a fraction of RAM, capped. MTPLX's own auto-sizing picked
  # 16.6 GB on a 64 GB Mac, which pushed wired memory to ~50 GB.
  # Speculative depth. 1 is the measured optimum at agent context lengths;
  # deeper drafting peaks on short prompts and collapses past ~8k.
  REC_PREFILL_CHUNK=512

  # Profile: sustained is memory-safe at long context; turbo is faster but only
  # if you stay short.
  REC_PROFILE="llama.cpp"
  REC_REASON_PROFILE="llama.cpp is the only runtime that can serve uncensored Gemma 4 at speed"

  # Model + KV + activation headroom, for the fit check.
  local kv_kb; kv_kb="$(kv_kb_per_token_f16 "$REC_MODEL")"
  case "$REC_KV" in
    q4_0) kv_kb=$(( kv_kb / 4 )) ;;
    q8_0) kv_kb=$(( kv_kb / 2 )) ;;
  esac
  REC_KV_GB=$(( REC_CONTEXT * kv_kb / 1024 / 1024 ))
  REC_NEED_GB=$(( REC_WEIGHTS_GB + REC_KV_GB + 6 ))
}

# Does the *current* env.conf fit this machine?
current_config_fits() {
  local cur_kb cur_kv_gb cur_weights cur_need
  cur_kb="$(kv_kb_per_token_f16 "$MODEL_REPO")"
  case "$KV_QUANT" in
    q4_0) cur_kb=$(( cur_kb / 4 )) ;;
    q8_0) cur_kb=$(( cur_kb / 2 )) ;;
  esac
  cur_kv_gb=$(( CONTEXT_WINDOW * cur_kb / 1024 / 1024 ))
  cur_weights="$(model_weights_gb)"
  cur_need=$(( cur_weights + cur_kv_gb + 6 ))

  CUR_KV_GB="$cur_kv_gb"
  CUR_NEED_GB="$cur_need"

  # It fits if the plan is inside the configured cap AND inside physical RAM.
  (( cur_need <= MEMORY_LIMIT_GB )) && (( cur_need <= HW_RAM_GB ))
}

# ── display ──────────────────────────────────────────────────────────────────
print_recommendation() {
  log ""
  printf '  %-24s %-34s %s\n' "SETTING" "CURRENT (env.conf)" "SUGGESTED"
  printf '  %-24s %-34s %s\n' "------------------------" "----------------------------------" "----------------------------------"

  # Repo ids are far longer than the column; shorten the head and keep the
  # meaningful tail (the quant tag) so the table stays readable.
  short() {
    local v="$1"
    if (( ${#v} <= 32 )); then printf '%s' "$v"; return; fi
    local owner="${v%%/*}" tail="${v##*/}"
    if (( ${#tail} > 24 )); then tail="...${tail: -21}"; fi
    printf '%s/%s' "$owner" "$tail"
  }

  row() {   # name, current, suggested
    local name="$1" cur="$2" sug="$3"
    local mark=""
    [[ "$cur" == "$sug" ]] && mark="  ${C_DIM}(unchanged)${C_RESET}"
    printf '  %-24s %-34s %s%s\n' "$name" "$(short "$cur")" "$(short "$sug")" "$mark"
  }

  row "MODEL"              "$MODEL"              "$REC_MODEL"
  row "CONTEXT_WINDOW"     "$CONTEXT_WINDOW"     "$REC_CONTEXT"
  row "KV_QUANT"           "$KV_QUANT"           "$REC_KV"
  row "MEMORY_LIMIT_GB"    "$MEMORY_LIMIT_GB"    "$REC_MEMORY_LIMIT_GB"

  row "PREFILL_CHUNK_TOKENS" "$PREFILL_CHUNK_TOKENS" "$REC_PREFILL_CHUNK"
  row "RUNTIME"            "llama.cpp"            "$REC_PROFILE"

  if [[ "$MODEL" != "$REC_MODEL" ]]; then
    log ""
    log "  Full model ids:"
    log "    now       $MODEL"
    log "    suggested $REC_MODEL"
  fi

  log ""
  log "  ${C_BOLD}Why these values:${C_RESET}"
  log "    model    $REC_REASON_MODEL"
  log "    context  $REC_REASON_CTX"
  log "    profile  $REC_REASON_PROFILE"
  log ""
  log "  Projected footprint: ${REC_WEIGHTS_GB} GB weights + ${REC_KV_GB} GB KV ($REC_KV)"
  log "                       = ${REC_NEED_GB} GB of a ${REC_MEMORY_LIMIT_GB} GB cap on ${HW_RAM_GB} GB of RAM"
}

# ── apply ────────────────────────────────────────────────────────────────────
# Rewrite only the keys we recommend, leaving every comment intact.
apply_config() {
  python3 - "$ENV_FILE" \
    "MODEL=$REC_MODEL" \
    "CONTEXT_WINDOW=$REC_CONTEXT" \
    "KV_QUANT=$REC_KV" \
    "MEMORY_LIMIT_GB=$REC_MEMORY_LIMIT_GB" \
    "PREFILL_CHUNK_TOKENS=$REC_PREFILL_CHUNK" <<'PY'
import re, sys

path = sys.argv[1]
changes = [a.split("=", 1) for a in sys.argv[2:]]
src = open(path).read()

# Keys whose value is a plain string needing quotes in env.conf.
QUOTED = {"MODEL", "KV_QUANT"}
applied, missing = [], []

for key, raw in changes:
    value = f'"{raw}"' if key in QUOTED else raw
    new_src, n = re.subn(rf'^{re.escape(key)}=.*$', f'{key}={value}',
                         src, count=1, flags=re.M)
    if n == 1:
        src = new_src
        applied.append(f"{key}={raw}")
    else:
        missing.append(key)

open(path, 'w').write(src)
print("  applied: " + ", ".join(applied))
if missing:
    print("  NOT FOUND in env.conf (add manually): " + ", ".join(missing))
PY
  # Re-read so the rest of install.sh sees the new values.
  load_config
}

# ── the interactive step ─────────────────────────────────────────────────────
# Returns 0 if config is ready to use, 1 if the user aborted.
run_preflight() {
  local assume_yes="$1"

  step "Hardware scan"
  scan_hardware
  print_hardware

  recommend_config
  print_recommendation

  # Disk space for the download, only if it is not already there.
  if [[ "$HW_MODEL_PRESENT" == "no" ]]; then
    local need=$(( REC_WEIGHTS_GB + 3 ))
    if (( HW_FREE_GB < need )); then
      warn "Only ${HW_FREE_GB} GB free where the weights go; the download needs about ${need} GB."
      warn "Free up space and re-run, or set MODELS_DIR in env.conf to a bigger volume."
      return 1
    fi
    ok "Disk space is fine for a ~${need} GB download."
  fi

  # Hard blockers.
  if (( HW_RAM_GB < 24 )); then
    warn "${HW_RAM_GB} GB of unified memory is below what a 27B model needs."
    warn "It may load with a tiny context and q4 KV, but expect it to be slow and tight."
  fi
  if (( HW_MACOS_MAJOR < 14 )); then
    die "macOS ${HW_MACOS} is too old; MLX inference needs macOS 14 or newer."
  fi

  if current_config_fits; then
    ok "Your current env.conf fits this machine (${CUR_NEED_GB} GB plan, ${MEMORY_LIMIT_GB} GB cap)."
    if (( REC_NEED_GB < CUR_NEED_GB )) || [[ "$REC_MODEL" != "$MODEL" ]]; then
      log ""
      log "  The suggestions above would still be an improvement on this hardware."
    fi
  else
    warn "Your current env.conf needs about ${CUR_NEED_GB} GB but the cap is ${MEMORY_LIMIT_GB} GB."
    warn "The suggested values above fix that."
  fi

  log ""
  if (( assume_yes )); then
    info "--yes given: applying the suggested values."
    apply_config
    return 0
  fi

  # Only prompt when a real terminal is attached. Under a pipe or in CI the
  # open of /dev/tty fails loudly on macOS, so test for it first.
  if [[ ! -c /dev/tty ]] || [[ ! -t 0 && ! -t 1 ]]; then
    warn "No terminal attached; keeping your current env.conf."
    log "    Re-run ./install.sh in a terminal, or use --yes to accept these values."
    return 0
  fi

  printf '  Apply the suggested settings to env.conf? [Y/n] '
  local reply=""
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    n|N|no|NO) info "Keeping your current env.conf." ;;
    *)         apply_config ;;
  esac
  return 0
}
