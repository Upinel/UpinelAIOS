#!/usr/bin/env bash
# Benchmark the running endpoint, or re-measure the best speculative depth.
#
#   ./bench/bench.sh --quick     one short-context sanity run (~15s)
#   ./bench/bench.sh             decode + prefill sweep at 512 / 8k / 32k / your context
#   ./bench/bench.sh --tune      sweep speculative depth 0..4 and save the winner
#
# The sweep uses the context from env.conf as its upper bound.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
load_config

MODE="sweep"; MAX_TOKENS=256; REPEATS=1; CONTEXTS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick)      MODE="quick" ;;
    --tune)       MODE="tune" ;;
    --max-tokens) MAX_TOKENS="$2"; shift ;;
    --repeats)    REPEATS="$2"; shift ;;
    --contexts)   CONTEXTS="$2"; shift ;;
    -h|--help)    show_usage "$0"; exit 0 ;;
    *)            die "Unknown argument: $1" ;;
  esac
  shift
done

require_bin python3 "python3 is required."

# ── depth sweep ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "tune" ]]; then
  step "Sweeping speculative depth on this Mac"
  [[ -n "$(model_draft_gguf "$MODEL_DIR" 2>/dev/null || true)" ]] \
    || die "This model has no draft file, so there is nothing to tune."
  log "Depth 0 = autoregressive. This loads the model 5 times."
  log ""
  ORIG_DEPTH="$MTP_DEPTH"
  BEST_DEPTH=""; BEST_TPS=0
  OUT="$RUN_DIR/tuning-${MODEL_REPO//\//--}.json"
  echo '{"results":[' > "$OUT"
  FIRST=1
  for d in 0 1 2 3 4; do
    python3 - "$ENV_FILE" "$d" <<'PY'
import re, sys
path, depth = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'^MTP_DEPTH=.*$', f'MTP_DEPTH="{depth}"', s, count=1, flags=re.M)
if n != 1: raise SystemExit("MTP_DEPTH= not found")
open(path, "w").write(s)
PY
    "$REPO_DIR/stop.sh" >/dev/null 2>&1 || true
    "$REPO_DIR/start.sh" >/dev/null 2>&1 || true
    if ! server_healthy; then warn "depth $d: server did not start"; continue; fi
    LINE="$(python3 "$REPO_DIR/bench/bench.py" --url "http://127.0.0.1:${PORT}" \
      --model "$SERVED_MODEL_NAME" --api-key-file "$API_KEY_FILE" \
      --contexts 8192 --max-tokens "$MAX_TOKENS" 2>/dev/null | grep 'context~' | head -1)"
    TPS="$(printf '%s' "$LINE" | sed -n 's/.*decode= *\([0-9.]*\) t\/s.*/\1/p')"
    printf '  depth %-2s  %s t/s\n' "$d" "${TPS:-?}"
    [[ -n "$TPS" ]] && awk -v a="$TPS" -v b="$BEST_TPS" 'BEGIN{exit !(a>b)}' \
      && { BEST_TPS="$TPS"; BEST_DEPTH="$d"; }
    (( FIRST )) || printf ',' >> "$OUT"; FIRST=0
    printf '{"depth":%s,"tok_s":%s}' "$d" "${TPS:-0}" >> "$OUT"
  done
  printf '],"best_depth":%s,"best_tok_s":%s,"model_repo":"%s"}\n' \
    "${BEST_DEPTH:-1}" "${BEST_TPS:-0}" "$MODEL_REPO" >> "$OUT"
  # Restore the original setting and restart on the winner.
  python3 - "$ENV_FILE" "$BEST_DEPTH" <<'PY'
import re, sys
path, depth = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'^MTP_DEPTH=.*$', f'MTP_DEPTH="{depth}"', s, count=1, flags=re.M)
open(path, "w").write(s)
PY
  log ""
  ok "Winner: depth ${BEST_DEPTH} at ${BEST_TPS} t/s  (saved to $OUT)"
  info "Restarting on the winner..."
  "$REPO_DIR/restart.sh" >/dev/null 2>&1 || true
  exit 0
fi

# ── normal benchmarks need a live server ─────────────────────────────────────
server_healthy || die "No server answering on port $PORT. Start it with ./start.sh"
KEY_ARG=()
[[ -s "$API_KEY_FILE" ]] && KEY_ARG=( --api-key-file "$API_KEY_FILE" )

run_sweep() {
  step "$1"
  python3 "$REPO_DIR/bench/bench.py" \
    --url "http://127.0.0.1:${PORT}" \
    --model "$SERVED_MODEL_NAME" \
    --contexts "$2" --max-tokens "$MAX_TOKENS" --repeats "$REPEATS" \
    "${KEY_ARG[@]}"
}

if [[ "$MODE" == "quick" ]]; then run_sweep "Quick sanity check" "512"; exit 0; fi

if [[ -z "$CONTEXTS" ]]; then
  CONTEXTS="512,8192,32768"
  (( CONTEXT_WINDOW >= 131072 )) && CONTEXTS="$CONTEXTS,131072"
fi

log ""
log "  model        $MODEL_REPO"
log "  context      $CONTEXT_WINDOW   KV $KV_QUANT"
log "  speculative  depth $(effective_depth)"
log "  thinking     $THINKING"
log "  vision       $([[ "$ENABLE_VISION" == "1" ]] && echo on || echo off)"

run_sweep "Decode / prefill sweep" "$CONTEXTS"
log ""
log "  decode  = steady-state generation speed (the agent-relevant number)"
log "  prefill = how fast a long prompt is ingested, dominated by first turn"
