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
# Restart the UpinelAIOS server, reloading env.conf.
#
#   ./restart.sh              graceful stop, then start with the current env.conf
#   ./restart.sh --model X    switch to a model (and therefore an engine)
#   ./restart.sh --force      SIGKILL on stop if the graceful path hangs
#   ./restart.sh --wait 5     extra seconds to let the port and GPU settle
#   ./restart.sh --print      show what would start, and whether config changed
#
# --model is how you change engines: a GGUF model runs on llama.cpp, an MTPLX
# pack on MTPLX, so naming one is the whole switch. It lasts for this run only,
# exactly like ./start.sh --model; set MODEL in env.conf to make it permanent.
# With no --model and a terminal attached, you get the picker instead.
#
# Editing env.conf has no effect until the server is restarted, because the
# settings are passed to llama-server as command-line arguments at launch. This
# script is the supported way to apply them, and it tells you which settings
# actually changed rather than leaving you to diff the file by hand.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

FORCE=0
SETTLE=3
PRINT_ONLY=0
MODEL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)  FORCE=1 ;;
    --wait)   SETTLE="$2"; shift ;;
    --print)  PRINT_ONLY=1 ;;
    --model)  MODEL_OVERRIDE="$2"; shift ;;
    -h|--help) show_usage "$0"; exit 0 ;;
    *) die "Unknown argument: $1  (try --help)" ;;
  esac
  shift
done

step "UpinelAIOS restart"

# ── what is about to change ──────────────────────────────────────────────────
if [[ -f "$CONFIG_SNAPSHOT_FILE" ]] && ! diff -q <(config_fingerprint) \
        "$CONFIG_SNAPSHOT_FILE" >/dev/null 2>&1; then
  log ""
  log "  ${C_BOLD}env.conf changed since the server last started:${C_RESET}"
  # Pair the two sides by key so each setting reads as old -> new rather than
  # as two separated lists the reader has to reconcile. Both sides go in as
  # files: a heredoc and a process substitution cannot share stdin.
  config_fingerprint > "$RUN_DIR/config.pending"
  python3 "$REPO_DIR/lib/diff_config.py" "$CONFIG_SNAPSHOT_FILE" "$RUN_DIR/config.pending"
  rm -f "$RUN_DIR/config.pending"
  log ""
  log "  ${C_DIM}left of the arrow is what is running now; right is what will start.${C_RESET}"
else
  info "env.conf is unchanged since the last start."
fi

EFFECTIVE_DEPTH="$(effective_depth)"

# Ask before printing the banner, not after: otherwise the banner would name
# one model and the restart would load another. start.sh runs the same picker,
# so the choice is handed over as --model to stop it asking twice.
PICKED=0
if [[ -n "$MODEL_OVERRIDE" ]]; then
  # A named model is the switch, so no picker. Validate it here rather than
  # letting start.sh fail after the old server has already been stopped.
  MODEL_REPO="$(model_repo_for "$MODEL_OVERRIDE")"
  MODEL_ALIAS="$(alias_for_repo "$MODEL_REPO")"
  MODEL_DIR="$MODELS_DIR/${MODEL_REPO//\//--}"
  ENGINE_OV="$(model_engine_for "${MODEL_ALIAS:-$MODEL_REPO}")"
  [[ -n "$ENGINE_OV" ]] || ENGINE_OV="$(engine_for_dir "$MODEL_DIR" 2>/dev/null || true)"
  [[ -n "$ENGINE_OV" ]] || ENGINE_OV="gguf"
  load_engine "$ENGINE_OV" >/dev/null 2>&1 || true
  if ! engine_model_ok "$MODEL_DIR" 2>/dev/null; then
    warn "$MODEL_OVERRIDE is not on disk yet - it would be the only thing to start."
    warn "Fetch it first:  ./model_download.sh $MODEL_OVERRIDE"
    die "Nothing to restart onto."
  fi
  PICKED=1
  info "Switching to $MODEL_REPO ($ENGINE_OV). This run only - set MODEL in env.conf to keep it."
elif (( ! PRINT_ONLY )); then
  if choose_model_on_disk; then
    PICKED=1
    info "Serving $MODEL_REPO for this run. Set MODEL in env.conf to make it permanent."
  fi
fi

# Resolve the engine before the banner, so it reports the shape the server
# will actually start with rather than one engine's fields on the other's run.
#
# When a model was picked or named, that is what is about to start - reading
# $MODEL here instead would print the env.conf model in the banner and then
# load the other one, which is the exact confusion this banner exists to stop.
if (( PICKED )); then
  MODEL_REPO_R="$MODEL_REPO"
else
  MODEL_REPO_R="$(model_repo_for "$MODEL")"
fi
# Derived from the repo in both cases. choose_model_on_disk() sets MODEL_REPO
# and MODEL_DIR but knows nothing about aliases, so reading $MODEL_ALIAS here
# after an interactive pick died with "unbound variable" - and under set -u,
# which lib/common.sh turns on for every script, that is fatal.
MODEL_ALIAS_R="$(alias_for_repo "$MODEL_REPO_R")"
ENGINE_R="$(model_engine_for "${MODEL_ALIAS_R:-$MODEL_REPO_R}")"
[[ -n "$ENGINE_R" ]] || ENGINE_R="$(engine_for_dir "$MODELS_DIR/${MODEL_REPO_R//\//--}")"
[[ -n "$ENGINE_R" ]] || ENGINE_R="gguf"
# Load the engine for real, not inside a command substitution. A subshell load
# defines its functions only for that subshell, so engine_name() and
# engine_resolved_profile() were undefined by the time the banner called them -
# which is how the profile line came to print an empty string and a
# "command not found" to stderr.
load_engine "$ENGINE_R" >/dev/null 2>&1 || true
EFFECTIVE_DEPTH="$(effective_depth 2>/dev/null || echo 3)"

log ""
log "  ${C_BOLD}Starting with:${C_RESET}"
log "    engine     $(engine_name 2>/dev/null || echo "$ENGINE_R")"
log "    model      $MODEL_REPO_R${MODEL_ALIAS_R:+   ($MODEL_ALIAS_R)}"
log "    served as  $SERVED_MODEL_NAME"
log "    context    $CONTEXT_WINDOW   KV $(kv_quant_for "$ENGINE_R")"
if [[ "$ENGINE_R" == "mlx" ]]; then
  log "    profile    $(engine_resolved_profile "$MODELS_DIR/${MODEL_REPO_R//\//--}")   thinking $THINKING   history $PRESERVE_THINKING"
  log "    memory     ${MEMORY_LIMIT_GB} GB cap   session bank ${SESSION_BANK_GB} GB"
else
  log "    depth      $EFFECTIVE_DEPTH   thinking $THINKING"
  log "    memory     ${MEMORY_LIMIT_GB} GB cap"
fi
log "    network    $HOST:$PORT"
log ""

if (( PRINT_ONLY )); then
  info "--print given; not restarting."
  exit 0
fi

# ── stop ─────────────────────────────────────────────────────────────────────
WAS_RUNNING=0
pid_alive && WAS_RUNNING=1
[[ -n "$(port_pids)" ]] && WAS_RUNNING=1

if (( WAS_RUNNING )); then
  if (( FORCE )); then
    "$REPO_DIR/stop.sh" --force
  else
    "$REPO_DIR/stop.sh"
  fi
else
  info "Server was not running; starting it."
fi

# ── settle ───────────────────────────────────────────────────────────────────
# Wait for the port to actually be free, then a few more seconds. macOS needs a
# moment to release the wired GPU allocation, and starting into a port that is
# still closing is the usual cause of a failed restart.
info "Waiting for the port and GPU memory to settle..."
for _ in $(seq 1 30); do
  [[ -z "$(port_pids)" ]] && break
  sleep 1
done
if [[ -n "$(port_pids)" ]]; then
  die "Port $PORT is still held after 30s. Try ./stop.sh --force, then ./start.sh"
fi
sleep "$SETTLE"

# ── start ────────────────────────────────────────────────────────────────────
# start.sh records the new config snapshot itself, so a failed start still
# leaves an accurate "last attempted" record for the next diff.
# Two branches rather than an array: expanding an empty array is an unbound
# variable error in bash 3.2 under `set -u`.
if (( PICKED )); then
  "$REPO_DIR/start.sh" --model "$MODEL_REPO"
else
  "$REPO_DIR/start.sh"
fi
RC=$?

if (( RC != 0 )); then
  warn "Restart failed. The previous state is in $LOG_FILE"
  exit $RC
fi

ok "Restart complete."
