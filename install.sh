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
# One-time setup for UpinelAIOS.
#
#   ./install.sh                 scan hardware, suggest settings, install
#   ./install.sh --yes           accept the suggested settings without asking
#   ./install.sh --no-tune       skip the (slow) speculative depth sweep
#   ./install.sh --deps-only     only install llama.cpp
#   ./install.sh --model-only    only download and verify the model
#   ./install.sh --scan-only     print the hardware scan and suggestions, stop
#   ./install.sh --model REPO    use this model instead of env.conf's
#
# Re-running is safe: downloads resume and finished steps are skipped.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config
# shellcheck source=lib/preflight.sh
source "$REPO_DIR/lib/preflight.sh"

DO_DEPS=1; DO_MODEL=1; DO_TUNE=1; DO_SCAN=1
ASSUME_YES=0
MODEL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)     ASSUME_YES=1 ;;
    --no-scan)    DO_SCAN=0 ;;
    --scan-only)  DO_SCAN=1; DO_DEPS=0; DO_MODEL=0; DO_TUNE=0 ;;
    --deps-only)  DO_MODEL=0; DO_TUNE=0 ;;
    --model-only) DO_DEPS=0; DO_TUNE=0; DO_SCAN=0 ;;
    --no-tune)    DO_TUNE=0 ;;
    --model)      MODEL_OVERRIDE="$2"; shift ;;
    -h|--help)    show_usage "$0"; exit 0 ;;
    *)            die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

step "UpinelAIOS - One-Click AI Agent Server OS for Mac"

is_apple_silicon || die "This bundle targets Apple Silicon Macs. Detected: $(uname -s)/$(uname -m)."
require_macos

# ── 1. hardware scan and configuration ───────────────────────────────────────
if (( DO_SCAN )); then
  run_preflight "$ASSUME_YES" || die "Setup stopped. Fix the issue above and re-run ./install.sh"
  # load_config already re-ran inside apply_config; refresh derived values.
  MODEL_REPO="$(model_repo_for "$MODEL")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
else
  step "Skipping the hardware scan (--model-only)"
fi

# A --model flag beats both env.conf and the scan, but is not written back:
# it is a one-off choice for this run.
if [[ -n "$MODEL_OVERRIDE" ]]; then
  MODEL_REPO="$(model_repo_for "$MODEL_OVERRIDE")"
  MODEL_ALIAS="$MODEL_OVERRIDE"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
  info "Model for this install: $MODEL_REPO"
  # Persist it. --model means "install this one", and the hardware scan above
  # has just written its own suggestion into env.conf - so without this the
  # installer would download one model and ./start.sh would serve another.
  # (./start.sh --model stays a one-off; this is the install path, where the
  # choice is the point.)
  set_config_value MODEL "$MODEL_REPO"
  ok "MODEL set in env.conf"
else
  MODEL_ALIAS="$(alias_for_repo "$MODEL_REPO")"
fi

# ── which engine, and therefore which model ──────────────────────────────────
# The hardware scan above recommends settings. The engine is a separate
# question, and not one to answer on the user's behalf: GGUF and MLX are
# different offers - Gemma at peak decode versus Qwen up to 2.2x faster - so
# both are shown with the measured reason to want each.
#
# Five ways to settle the model:
#   1  take the GGUF suggestion      - one model, already checked against RAM
#   2  take the MLX suggestion       - ditto, the other runtime
#   3  take both                     - both runtimes, both models
#   4  pick from the list we ship    - any alias, with a verdict for this Mac
#   5  type an owner/name repo       - anything uncensored on Hugging Face
# An engine with nothing that fits drops out, so 2 is absent on a Mac where no
# MLX model loads; the remaining options renumber rather than leaving a gap.
#
# Skipped when the model was named explicitly, when --yes was given, or when
# there is no terminal to ask on.
# One row of the engine menu. A function so the menus below - both engines,
# one engine - cannot drift apart in alignment.
#
# The format string is double-quoted on purpose: single quotes would make
# printf print the literal text ${C_BOLD} instead of switching the colour.
menu_row() {
  if [[ -n "$4" ]]; then
    printf "  %s%s%s  %-5s %-20s %4s GB   %s\n" \
      "$C_BOLD" "$1" "$C_RESET" "$2" "$3" "$4" "$5"
  else
    printf "  %s%s%s  %-5s %-20s %8s   %s\n" \
      "$C_BOLD" "$1" "$C_RESET" "$2" "$3" "" "$5"
  fi
}

read_pick() {
  PICK=""
  if [[ -t 0 ]]; then read -r PICK || PICK=""; else read -r PICK < /dev/tty || PICK=""; fi
}

# Any owner/name repo. Sets MODEL and ENGINE_FORCED; returns non-zero when the
# id is unusable, so the caller can fall back to what it already suggested.
ask_custom_model() {
  local custom custom_engine
  log ""
  printf "  Hugging Face repo id (owner/name): "
  if [[ -t 0 ]]; then read -r custom || custom=""; else read -r custom < /dev/tty || custom=""; fi
  custom="${custom#https://huggingface.co/}"; custom="${custom%/}"
  if [[ "$custom" != */* ]]; then
    warn "That is not an owner/name repo id."
    return 1
  fi
  # The engine is read off the name, and asked for only when the name does not
  # say - so a custom model works on either engine without the user needing to
  # know the rule.
  custom_engine="$(model_engine_for "$custom")"
  if [[ -z "$custom_engine" ]]; then
    printf "  Is it a GGUF repo or an MTPLX pack? [gguf/mlx] "
    if [[ -t 0 ]]; then read -r custom_engine || custom_engine=""; else read -r custom_engine < /dev/tty || custom_engine=""; fi
    case "$custom_engine" in
      mlx|MLX) custom_engine=mlx ;;
      *)       custom_engine=gguf ;;
    esac
  fi
  MODEL="$custom"
  ENGINE_FORCED="$custom_engine"
  info "Custom $(printf '%s' "$custom_engine" | tr '[:lower:]' '[:upper:]'): $custom"
  return 0
}

# Pick one of the models we ship, from the same list ./start.sh uses. Sets
# MODEL and ENGINE_FORCED, and returns non-zero when the user declined or
# picked something there is no room for - so the caller can fall back to its
# own suggestion rather than leaving MODEL unset.
pick_from_list() {
  if ! choose_model_from_list; then
    return 1
  fi
  if ! adopt_model_alias "$MENU_CHOSEN_ALIAS"; then
    return 1
  fi
  MODEL="$REC_MODEL"
  ENGINE_FORCED="$(model_engine_for "$MENU_CHOSEN_ALIAS")"
  info "$(printf '%s' "$ENGINE_FORCED" | tr '[:lower:]' '[:upper:]'): $MENU_CHOSEN_ALIAS"
  return 0
}

DO_BOTH=0
ENGINE_FORCED=""
if [[ -z "$MODEL_OVERRIDE" ]] && (( DO_SCAN )) && (( ! ASSUME_YES )); then
  recommend_engines

  if (( ${REC_ALL_TOO_BIG:-0} )); then
    warn "No model in this bundle fits ${HW_RAM_GB} GB of unified memory."
    warn "The smallest of each engine is shown; expect paging and expect it to be slow."
    log ""
  fi

  case "$REC_SUGGEST" in
    both)
      step "Which engine?"
      log ""
      menu_row 1 GGUF "$REC_GGUF_ALIAS" "$REC_GGUF_WEIGHTS" "$REC_GGUF_NOTE"
      menu_row 2 MLX  "$REC_MLX_ALIAS"  "$REC_MLX_WEIGHTS"  "$REC_MLX_NOTE"
      menu_row 3 both "install both engines and both models" "" ""
      menu_row 4 list "pick any model we ship" "" "with a verdict for this Mac"
      menu_row 5 yours "type a Hugging Face repo id" "" "any uncensored owner/name"
      # "fits" and "only just fits" are different promises, and this menu is
      # where the choice is made - so the verdict belongs here too, not only in
      # the scan table above.
      if [[ "$REC_GGUF_VERDICT" == tight* ]]; then
        warn "$REC_GGUF_ALIAS only just fits ${HW_RAM_GB} GB - it will page under load."
      fi
      if [[ "$REC_MLX_VERDICT" == tight* ]]; then
        warn "$REC_MLX_ALIAS only just fits ${HW_RAM_GB} GB - it will page under load."
      fi
      log ""
      log "  ${C_DIM}1 is the fastest decode measured here (106 t/s). 2 is the best"
      log "  agent balance for Qwen, and up to 2.2x llama.cpp on the same model."
      log "  3 costs about $((${REC_GGUF_WEIGHTS} + ${REC_MLX_WEIGHTS})) GB of disk.${C_RESET}"
      log ""

      printf "  Choose [1/2/3/4/5]: "
      read_pick
      case "${PICK:-1}" in
        2) MODEL="$(model_repo_for "$REC_MLX_ALIAS")"
           info "MLX: $REC_MLX_ALIAS" ;;
        3) DO_BOTH=1
           MODEL="$(model_repo_for "$REC_GGUF_ALIAS")"
           info "Both engines, starting with GGUF: $REC_GGUF_ALIAS" ;;
        4) if ! pick_from_list; then
             MODEL="$(model_repo_for "$REC_GGUF_ALIAS")"
             info "Keeping the GGUF suggestion: $REC_GGUF_ALIAS"
           fi ;;
        5) if ! ask_custom_model; then
             MODEL="$(model_repo_for "$REC_GGUF_ALIAS")"
             info "Keeping the GGUF suggestion: $REC_GGUF_ALIAS"
           fi ;;
        *) MODEL="$(model_repo_for "$REC_GGUF_ALIAS")"
           info "GGUF: $REC_GGUF_ALIAS" ;;
      esac
      ;;

    gguf|mlx)
      # Only one engine has a model this Mac can load, so there is only one
      # suggestion to make. The other engine is explained rather than listed:
      # a suggestion that will not fit is not a choice, it is a trap.
      if [[ "$REC_SUGGEST" == "gguf" ]]; then
        S_ENGINE=GGUF; S_ALIAS="$REC_GGUF_ALIAS"; S_GB="$REC_GGUF_WEIGHTS"
        S_NOTE="$REC_GGUF_NOTE"; S_VERDICT="$REC_GGUF_VERDICT"
        M_NAME="$REC_MLX_MINNAME"; M_NEED="$REC_MLX_MINNEED"; M_ENGINE="MLX"
      else
        S_ENGINE=MLX; S_ALIAS="$REC_MLX_ALIAS"; S_GB="$REC_MLX_WEIGHTS"
        S_NOTE="$REC_MLX_NOTE"; S_VERDICT="$REC_MLX_VERDICT"
        M_NAME="$REC_GGUF_MINNAME"; M_NEED="$REC_GGUF_MINNEED"; M_ENGINE="GGUF"
      fi

      step "Suggested model"
      log ""
      menu_row 1 "$S_ENGINE" "$S_ALIAS" "$S_GB" "$S_NOTE"
      menu_row 2 list "pick any model we ship" "" "with a verdict for this Mac"
      menu_row 3 yours "type a Hugging Face repo id" "" "any uncensored owner/name"
      log ""
      log "  ${C_DIM}No ${M_ENGINE} model is offered: the smallest one, ${M_NAME},"
      log "  needs about ${M_NEED} GB and this Mac has ${HW_RAM_GB} GB.${C_RESET}"
      if [[ "$S_VERDICT" == tight* ]]; then
        warn "This one only just fits - it will page under load."
      fi
      log ""

      printf "  Choose [1/2/3]: "
      read_pick
      case "${PICK:-1}" in
        2) if ! pick_from_list; then
             MODEL="$(model_repo_for "$S_ALIAS")"
             info "Keeping the suggestion: $S_ALIAS"
           fi ;;
        3) if ! ask_custom_model; then
             MODEL="$(model_repo_for "$S_ALIAS")"
             info "Keeping the suggestion: $S_ALIAS"
           fi ;;
        *) MODEL="$(model_repo_for "$S_ALIAS")"
           info "$S_ENGINE: $S_ALIAS" ;;
      esac
      ;;
  esac
  set_config_value MODEL "$MODEL"
  log ""
fi

# The engine choice above may have changed MODEL, so re-derive the repo and
# alias from it before anything reads them. Missing this is how the installer
# came to install llama.cpp after the user picked MLX.
MODEL_REPO="$(model_repo_for "$MODEL")"
MODEL_ALIAS="$(alias_for_repo "$MODEL_REPO")"
MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"

# ── which engine serves the chosen model ─────────────────────────────────────
# The engine follows the model, and everything below - which runtime to
# install, how to verify the download, whether a depth sweep applies - depends
# on it.
ENGINE="${ENGINE_FORCED:-}"
if [[ -z "$ENGINE" ]]; then
  ENGINE="$(model_engine_for "${MODEL_ALIAS:-$MODEL_REPO}")"
fi
if [[ -z "$ENGINE" ]]; then
  ENGINE="$(engine_for_dir "$MODEL_DIR")"
fi
if [[ -z "$ENGINE" ]]; then
  die "Cannot tell which engine serves '$MODEL_REPO'.
    Known aliases: $MODEL_ALIASES"
fi
load_engine "$ENGINE"
export MODEL_REPO MODEL_DIR

if (( DO_MODEL || DO_TUNE )); then
  log ""
  log "  Serving:  $MODEL_REPO"
  log "  Engine:   $(engine_name)"
  log "  Context:  $CONTEXT_WINDOW tokens   KV: $(kv_quant_for "$ENGINE")   MTP depth: $MTP_DEPTH"
fi

# ── 2. dependencies ──────────────────────────────────────────────────────────
if (( DO_DEPS )); then
  # The engine follows the model, so install the one this model needs - and
  # only then offer the other. Installing both up front would mean a Homebrew
  # formula plus, for MTPLX, a Python runtime most people never use.
  step "Installing the $(engine_name) runtime"
  engine_install

  OTHER="$(other_engine "$ENGINE")"
  if [[ -n "$OTHER" ]]; then
    load_engine "$OTHER"
    if engine_present; then
      ok "$(engine_name) is also installed - you can run both engines."
    else
      log ""
      log "  ${C_DIM}$(engine_name) is not installed. It would add roughly 1-2 GB and"
      log "  lets you run the other half of the model list:${C_RESET}"
      log "  ${C_DIM}  gguf: Gemma 4 at peak speed, vision${C_RESET}"
      log "  ${C_DIM}  mlx:  anything Qwen, up to 2.2x faster than llama.cpp${C_RESET}"
      log ""
      if ask_yes_no "Install $(engine_name) as well?" n; then
        engine_install
      else
        info "Skipping $(engine_name). Run ./install.sh again any time, or"
        info "./model_download.sh will offer it if you pick one of its models."
      fi
    fi
    # Restore the engine this install is actually about.
    load_engine "$ENGINE"
  fi

  command -v python3 >/dev/null 2>&1 || warn "python3 not found - ./bench/bench.sh needs it."

  # Every Python file must actually parse with the python3 we are about to use.
  #
  # This runs at install time because a syntax error can be version-dependent:
  # an f-string with a backslash in its replacement field (f"{'\u2591' * n}")
  # parses on Python 3.12+ and is a hard SyntaxError on anything older. A file
  # can therefore work perfectly on the machine it was written on and fail on a
  # user's the moment they run ./status.sh. Checking all of them here turns
  # that into a clear message at install time instead of a stack trace later.
  if command -v python3 >/dev/null 2>&1; then
    BADPY="$(python3 - "$REPO_DIR" <<'PYCHECK'
import os, sys
root = sys.argv[1]
bad = []
for base, dirs, files in os.walk(root):
    dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "models", "run")]
    for f in files:
        if not f.endswith(".py"):
            continue
        p = os.path.join(base, f)
        try:
            compile(open(p, encoding="utf-8").read(), p, "exec")
        except SyntaxError as e:
            bad.append(f"{os.path.relpath(p, root)}:{e.lineno}: {e.msg}")
print("\n".join(bad))
PYCHECK
)"
    if [[ -n "$BADPY" ]]; then
      warn "These Python files do not parse with $(python3 -V 2>&1):"
      printf '%s\n' "$BADPY" | while IFS= read -r l; do log "    $l"; done
      die "Fix the syntax or use a newer python3; the dashboard and bench tools will not run."
    fi
    ok "Python files parse with $(python3 -V 2>&1 | cut -d' ' -f2)"
  fi

else
  step "Skipping dependency install"
fi

# ── 3. model ─────────────────────────────────────────────────────────────────
if (( DO_MODEL )); then
  step "Fetching the model"
  # FETCH_ENGINE matters for a custom repo whose name does not reveal its
  # engine: the choice made above has to survive into the downloader.
  FETCH_ENGINE="$ENGINE" "$REPO_DIR/lib/fetch-model.sh" "$MODEL_REPO" "$MODEL_DIR"

  # "Both" means both models, not just both runtimes: an engine with no model
  # to serve is not much use on its own.
  if (( DO_BOTH )); then
    OTHER_ALIAS="$REC_MLX_ALIAS"; OTHER_REPO="$REC_MLX_REPO"
    OTHER_DIR="$MODELS_DIR/${OTHER_REPO//\//--}"
    if [[ -n "$OTHER_REPO" ]] && ! model_dir_ok "$OTHER_DIR"; then
      step "Also fetching the MLX suggestion ($OTHER_ALIAS)"
      "$REPO_DIR/lib/fetch-model.sh" "$OTHER_REPO" "$OTHER_DIR" || \
        warn "Second model did not download; the GGUF one is ready."
    else
      info "Second model already on disk."
    fi
  fi

  info "Checking the model files..."
  # Each engine knows what a complete model looks like: one weight file for
  # GGUF, an index-complete shard set for MLX.
  if engine_model_ok "$MODEL_DIR"; then
    ok "Model ready: $(engine_model_summary "$MODEL_DIR")"
  else
    warn "The download looks incomplete for $(engine_name)."
    warn "Re-run ./model_download.sh ${MODEL_ALIAS:-$MODEL_REPO} to finish it."
  fi
  # Extras that decide whether the model is fast or merely working - a
  # projector, a draft head, an MTP head. Which of those exist is engine
  # knowledge, so the engine reports it rather than this script guessing.
  engine_post_fetch_notes "$MODEL_DIR"
else
  step "Skipping model download"
fi

# ── 4. speculative depth ─────────────────────────────────────────────────────
if (( DO_TUNE )) && ! engine_tunable; then
  step "Skipping the depth sweep"
  log "    The $(engine_name) engine records depth per model rather than sweeping it."
  DO_TUNE=0
fi

if (( DO_TUNE )); then
  step "Measuring the fastest speculative depth on THIS machine"
  log "     Loads the model several times; 10-20 minutes."
  log "     Depth 1 is the shipped default; this measures your Mac."
  log ""
  if [[ ! -d "$MODEL_DIR" ]]; then
    warn "Model directory missing, skipping."
  elif "$REPO_DIR/bench/bench.sh" --tune; then
    ok "Tune complete."
  else
    warn "Auto-tune did not complete; MTP_DEPTH=auto will use depth 1,"
    warn "which is the measured optimum on the reference M5 Pro."
  fi
else
  step "Skipping the depth sweep (MTP_DEPTH=auto will use depth 1)"
fi

# ── 5. optional wired-memory ceiling ─────────────────────────────────────────
if (( WIRED_LIMIT_GB > 0 )); then
  step "Raising the macOS GPU wired-memory ceiling"
  CURRENT_MB="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
  TARGET_MB=$(( WIRED_LIMIT_GB * 1024 ))
  if (( CURRENT_MB >= TARGET_MB )); then
    ok "Already at ${CURRENT_MB} MB (target ${TARGET_MB} MB)."
  elif (( TARGET_MB > HW_RAM_GB * 1024 * 90 / 100 )); then
    warn "WIRED_LIMIT_GB=${WIRED_LIMIT_GB} is over 90% of RAM. Refusing to apply."
    warn "That setting causes jetsam kills and can leak wired pages on a hard kill."
  else
    warn "Needs sudo once, and does NOT survive a reboot."
    sudo sysctl "iogpu.wired_limit_mb=${TARGET_MB}" \
      && ok "Wired limit set to ${TARGET_MB} MB for this boot." \
      || warn "Could not set it; the macOS default stands."
  fi
fi

# ── done ─────────────────────────────────────────────────────────────────────
if (( DO_DEPS == 0 && DO_MODEL == 0 && DO_TUNE == 0 )); then
  step "Scan complete"
  log "  Review env.conf, then run:  ./install.sh"
  exit 0
fi

step "Install complete"
cat <<EOF

  Start the server:      ./start.sh
  Watch it live:         ./status.sh
  Verify tool calling:   ./bench/verify-tools.sh
  Measure tok/s:         ./bench/bench.sh
  Re-tune MTP depth:     ./bench/bench.sh --tune
  Apply env.conf changes: ./restart.sh
  Stop it:               ./stop.sh

  Config lives in:       env.conf

EOF
