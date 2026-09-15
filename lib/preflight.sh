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
  HW_LLAMA="not installed"
  if command -v llama-server >/dev/null 2>&1; then
    HW_LLAMA="$(llama_version)"
    [[ -n "$HW_LLAMA" ]] || HW_LLAMA="installed"
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
  printf '  %-16s %s\n' "llama.cpp"   "$HW_LLAMA"
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
#   * the KV cache is the second allocator after the weights, and on the Qwen
#     models - which cache KV on every layer - it can outgrow the weights
# ── per-engine recommendation ────────────────────────────────────────────────
# UpinelAIOS serves two engines, and the honest thing is to suggest a model for
# EACH rather than pick one on the user's behalf: they are not the same offer.
#
#   gguf  llama.cpp   Gemma 4 at peak decode - 106 t/s measured - and vision
#   mlx   MTPLX       anything Qwen; up to 2.6x llama.cpp on the same model
#
# Both are judged with model_fit(), so the same memory arithmetic decides both
# and neither can recommend something this Mac cannot load.
#
# Sets: REC_GGUF_ALIAS/_REPO/_WEIGHTS/_NOTE and the MLX equivalents.
recommend_engines() {
  local ram="$HW_RAM_GB" cand fit verdict

  # Preference order per engine, best first. The list is walked until one fits;
  # the last entry is taken regardless, so there is always an answer.
  local gguf_ladder="gguf-g-26ba4b gguf-g-12b gguf-g-e2b"
  local mlx_ladder="mlx-q-35ba3b mlx-q-27b-4bit mlx-q-9b"

  REC_GGUF_ALIAS=""; REC_MLX_ALIAS=""

  for cand in $gguf_ladder; do
    fit="$(model_fit "$cand")"; verdict="${fit#* }"
    if [[ "$verdict" != "will not fit" ]] || [[ "$cand" == "${gguf_ladder##* }" ]]; then
      REC_GGUF_ALIAS="$cand"; REC_GGUF_NEED="${fit%% *}"; REC_GGUF_VERDICT="$verdict"
      break
    fi
  done

  for cand in $mlx_ladder; do
    fit="$(model_fit "$cand")"; verdict="${fit#* }"
    if [[ "$verdict" != "will not fit" ]] || [[ "$cand" == "${mlx_ladder##* }" ]]; then
      REC_MLX_ALIAS="$cand"; REC_MLX_NEED="${fit%% *}"; REC_MLX_VERDICT="$verdict"
      break
    fi
  done

  REC_GGUF_REPO="$(model_repo_for "$REC_GGUF_ALIAS")"
  REC_MLX_REPO="$(model_repo_for "$REC_MLX_ALIAS")"
  REC_GGUF_WEIGHTS="$(model_size_gb "$REC_GGUF_REPO")"
  REC_MLX_WEIGHTS="$(model_size_gb "$REC_MLX_REPO")"
  REC_GGUF_NOTE="$(model_note "$REC_GGUF_ALIAS")"
  REC_MLX_NOTE="$(model_note "$REC_MLX_ALIAS")"
}

recommend_config() {
  local ram="$HW_RAM_GB"

  # Gemma 4 26B-A4B is a mixture-of-experts model: 26B total but only ~4B
  # active per token, so it is both the fastest big model and the one that
  # comfortably fits a 32 GB Mac.
  #
  # This recommends the alias 26b-q4, not the Q4_K_M build of the same model.
  # Same weights, but Q4_0 QAT decodes ~47% faster on Metal (106.4 vs 72.5
  # t/s measured) and is 15% smaller. Recommending the K-quant here would hand
  # a fresh install a slower model than the one start.sh defaults to.
  if (( ram >= 48 )); then
    REC_MODEL="$(model_repo_for gguf-g-26ba4b)"
    REC_WEIGHTS_GB=15
    REC_REASON_MODEL="26B-A4B Q4_0 QAT is the quality pick: MoE, ~4B active per token, uncensored, and the fastest thing that runs here"
  elif (( ram >= 16 )); then
    REC_MODEL="$(model_repo_for gguf-g-12b)"
    REC_WEIGHTS_GB=8
    REC_REASON_MODEL="12B fits ${ram} GB comfortably; the 26B MoE wants ~16 GB resident before context"
  else
    REC_MODEL="$(model_repo_for gguf-g-e2b)"
    REC_WEIGHTS_GB=4
    REC_REASON_MODEL="${ram} GB is tight; E2B is the only model here that fits, at ~4.2 GB resident, and it still decodes at ~100 t/s"
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

  # Prefill chunk. Keep each Metal allocation small at long context; this is
  # what prevents the command-buffer OOM that the tuning sweep also guards on.
  REC_PREFILL_CHUNK=512

  # Runtime. There is only one candidate here - llama.cpp - so this is not a
  # choice, it is the row that says why the other sister project's runtime
  # cannot serve these models at all.
  REC_RUNTIME="llama.cpp"
  REC_REASON_RUNTIME="llama.cpp is the only runtime that can serve uncensored Gemma 4 at speed"

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
# alias_for_repo() lives in lib/common.sh: the start/restart picker needs it
# too, and it does not source this file.

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
  row "RUNTIME"            "llama.cpp"            "$REC_RUNTIME"

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
  log "    runtime  $REC_REASON_RUNTIME"
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


# ── per-model fit, for the picker ────────────────────────────────────────────
# Download size in GB for each known repo. These are what lands on disk
# (weights + projector + draft), not the weight file alone.
model_size_gb() {
  case "$1" in
    *q4_0-heretic*)                         echo 15 ;;
    *Gemma4-26B-A4B*)                       echo 18 ;;
    *Gemma4-12B*)                           echo 8  ;;
    *gemma-4-31B*)                          echo 20 ;;
    *Gemma-4-E4B*)                          echo 6  ;;
    *Gemma-4-E2B*)                          echo 4  ;;
    *Qwen3.8-27B*)                          echo 19 ;;
    *Qwen3.8-9B*)                           echo 6  ;;
    *Qwen3.6-35B*)                          echo 22 ;;
    *)                                      echo 0  ;;
  esac
}

# One-line note about a model, shown beside its verdict.
model_note() {
  case "$1" in
    gguf-g-26ba4b)   echo "uncensored MoE, 3B active - the fastest 26B here" ;;
    gguf-g-26ba4b-q4km) echo "same MoE in Q4_K_M: about 20% slower, 3 GB bigger" ;;
    gguf-g-12b)      echo "dense 12B - smaller and less capable, still quick" ;;
    gguf-g-31b)      echo "dense 31B abliterated - the highest quality, and the slowest" ;;
    gguf-g-e4b)      echo "loses to both e2b and the 26B on every axis" ;;
    gguf-g-e2b)      echo "smallest, and the fastest small model: fits an 8 GB Mac" ;;
    gguf-q-27b)      echo "dense 27B, ~13.5 t/s; its MTP head needs a build step - or use the MLX build (~2.6x faster)" ;;
    gguf-q-9b)       echo "dense 9B, ~44 t/s - the MLX build is ~47% faster on this model" ;;
    gguf-q-35ba3b)   echo "MoE like the default, different family (Qwen 3.6, not 3.8)" ;;
    # ── MLX ──
    mlx-q-35ba3b)    echo "35B MoE, ~3B active - fastest Qwen here (~79 t/s), best agent balance" ;;
    mlx-q-27b-4bit)  echo "dense 27B 4-bit - the quality pick (~35 t/s)" ;;
    mlx-q-27b-6bit)  echo "dense 27B 6-bit - closer to the original weights, slower" ;;
    mlx-q-27b-3bit)  echo "dense 27B at 3-bit - smallest 27B, some quality loss" ;;
    mlx-q-27b-4bit-bz) echo "another 27B 4-bit conversion, 1 GB bigger than mlx-q-27b-4bit" ;;
    mlx-q-9b)        echo "dense 9B (~65 t/s) - only when memory is tight" ;;
    *)           echo "" ;;
  esac
}

# What this model would actually cost on THIS machine, and whether it fits.
# Prints "<need> <verdict>".
model_fit() {
  # Named _mf rather than "alias": alias is a bash builtin, and shadowing it
  # in a function that other code may call is asking for trouble.
  local _mf="$1" size_kb kv_gb need_gb
  size_kb="$(model_size_gb "$(model_repo_for "$_mf" 2>/dev/null)")"
  (( size_kb > 0 )) || { echo "? unknown"; return; }
  # KV for this model at the recommended context, scaled by the quant.
  local per_tok; per_tok="$(kv_kb_per_token_f16 "$(model_repo_for "$_mf" 2>/dev/null)")"
  local kb=$(( REC_CONTEXT * per_tok ))
  case "$REC_KV" in
    q8*) kb=$(( kb / 2 )) ;;
    q4*) kb=$(( kb / 4 )) ;;
  esac
  kv_gb=$(( kb / 1024 / 1024 ))
  need_gb=$(( size_kb + kv_gb + 3 ))

  local verdict
  if [[ -n "${REC_ALIAS:-}" && "$_mf" == "$REC_ALIAS" ]]; then
    verdict="RECOMMENDED"
  elif (( need_gb + 4 <= HW_RAM_GB )); then
    verdict="fits comfortably"
  elif (( need_gb <= HW_RAM_GB )); then
    verdict="tight - expect paging"
  else
    verdict="will not fit"
  fi
  echo "${need_gb} ${verdict}"
}

# Numbered picker. Echoes the chosen alias, or nothing to keep the current one.
print_model_menu() {
  log ""
  log "  ${C_BOLD}Pick a model${C_RESET}   ${C_DIM}this Mac has ${HW_RAM_GB} GB of unified memory${C_RESET}"
  log ""
  printf '  %3s  %-12s %-6s %-20s %s\n' "#" "ALIAS" "SIZE" "VERDICT" "NOTE"
  printf '  %3s  %-12s %-6s %-20s %s\n' "---" "------------" "------" "--------------------" "----------------------------------------"

  local i=1 alias fit need verdict note colour
  MODEL_MENU_ALIASES=""
  for alias in $MODEL_ALIASES; do
    fit="$(model_fit "$alias")"
    need="${fit%% *}"; verdict="${fit#* }"
    note="$(model_note "$alias")"
    case "$verdict" in
      RECOMMENDED)        colour="$C_GREEN"  ;;
      fits\ comfortably) colour=""           ;;
      tight*)             colour="$C_YELLOW" ;;
      will\ not\ fit)    colour="$C_RED"    ;;
      *)                  colour="$C_DIM"    ;;
    esac
    printf '  %3d  %-12s %-6s %s%-20s%s %s%s%s\n' \
      "$i" "$alias" "$(model_size_gb "$(model_repo_for "$alias" 2>/dev/null)") GB" \
      "$colour" "$verdict" "$C_RESET" "$C_DIM" "$note" "$C_RESET"
    MODEL_MENU_ALIASES="$MODEL_MENU_ALIASES $alias"
    i=$(( i + 1 ))
  done

  log ""
  log "  ${C_DIM}Enter a number, or press Enter to keep your current model.${C_RESET}"
  log "  ${C_DIM}A model that will not fit can still be chosen - it will just be slow,${C_RESET}"
  log "  ${C_DIM}or fail to load. ./model_download.sh fetches it afterwards.${C_RESET}"
  log ""
  printf '  Model number: '
}

# ── the interactive step ─────────────────────────────────────────────────────
# Returns 0 if config is ready to use, 1 if the user aborted.
run_preflight() {
  local assume_yes="$1"

  step "Hardware scan"
  scan_hardware
  print_hardware

  recommend_config
  REC_ALIAS="$(alias_for_repo "$REC_MODEL")"
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
    n|N|no|NO)
      # Declining the whole suggestion usually means "not that model". Offer
      # the list with a per-machine verdict rather than just giving up.
      print_model_menu
      local pick=""
      read -r pick < /dev/tty || pick=""
      pick="${pick//[!0-9]/}"
      if [[ -z "$pick" ]]; then
        info "Keeping your current env.conf."
        return 0
      fi
      local idx=1 chosen="" a
      for a in $MODEL_MENU_ALIASES; do
        if (( idx == pick )); then chosen="$a"; break; fi
        idx=$(( idx + 1 ))
      done
      if [[ -z "$chosen" ]]; then
        warn "No model number $pick; keeping your current env.conf."
        return 0
      fi
      local fit verdict wgb
      fit="$(model_fit "$chosen")"; verdict="${fit#* }"
      REC_MODEL="$(model_repo_for "$chosen")"
      REC_ALIAS="$chosen"
      wgb="$(model_size_gb "$REC_MODEL")"
      log ""
      if [[ "$verdict" == "will not fit" ]]; then
        warn "$chosen needs about ${fit%% *} GB and this Mac has ${HW_RAM_GB} GB."
        warn "It will be slow at best and may fail to load. Choosing it anyway."
      elif [[ "$verdict" == tight* ]]; then
        warn "$chosen needs about ${fit%% *} GB on a ${HW_RAM_GB} GB Mac - expect paging."
      fi
      # The disk check above ran against the SUGGESTED model's size, so a larger
      # pick has to be re-checked or the download dies half way through.
      if (( wgb > 0 )) && (( HW_FREE_GB < wgb + 3 )); then
        warn "$chosen downloads about ${wgb} GB and only ${HW_FREE_GB} GB is free."
        warn "Free up space, or set MODELS_DIR in env.conf to a bigger volume."
        info "Keeping your current env.conf."
        return 0
      fi
      info "Using $chosen. The other suggested settings still apply."
      (( wgb > 0 )) && REC_WEIGHTS_GB="$wgb"
      apply_config
      ;;
    *)         apply_config ;;
  esac
  return 0
}
