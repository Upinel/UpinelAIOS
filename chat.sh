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
# Interactive chat against the running UpinelAIOS endpoint.
#
#   ./chat.sh                      start chatting
#   ./chat.sh --system "..."       set the system prompt
#   ./chat.sh --thinking on        start with thinking on
#   ./chat.sh --temp 0.2           sampling temperature
#   ./chat.sh --no-stream          wait for whole replies instead of streaming
#   ./chat.sh --max-tokens 4096    reply ceiling
#
# The chat client is lib/chat.py. This wrapper exists to resolve the running
# server's address, model id and API key from env.conf, so the client does not
# have to know how the project is laid out - same split as ./status.sh.
#
# Requires the server to be up: ./start.sh, and check ./status.sh.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
load_config

SYSTEM=""
THINKING_START="$THINKING"
TEMP=""
STREAM=1
MAXTOK="$MAX_RESPONSE_TOKENS"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system)     SYSTEM="${2:-}"; shift 2 ;;
    --thinking)   THINKING_START="${2:-}"; shift 2 ;;
    --temp)       TEMP="${2:-}"; shift 2 ;;
    --max-tokens) MAXTOK="${2:-}"; shift 2 ;;
    --no-stream)  STREAM=0; shift ;;
    # show_usage() reads the leading comment block rather than a line range: a
    # line range silently truncates the help the moment a comment is added.
    -h|--help)    show_usage "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            die "Unknown argument: $1  (try --help)" ;;
  esac
done

case "$THINKING_START" in
  off)     THINKING_BOOL=0 ;;
  on)      THINKING_BOOL=1 ;;
  "")      THINKING_BOOL=0 ;;
  *)       THINKING_BOOL=1 ;;   # minimal/low/medium/high all mean "think"
esac

# Point at the loopback address; HOST is often 0.0.0.0, which is a bind
# address rather than something to connect to.
if [[ "$HOST" == "0.0.0.0" || -z "$HOST" ]]; then
  CONNECT_HOST="127.0.0.1"
else
  CONNECT_HOST="$HOST"
fi

KEY=""
[[ -f "$API_KEY_FILE" ]] && KEY="$(cat "$API_KEY_FILE")"

# Capabilities, so one client serves both projects without guessing.
#   stream    this server streams responses
#   thinking  thinking can be flipped per request via chat_template_kwargs
# llama.cpp supports both. The MLX project's wrapper declares its own set.
if (( STREAM )); then CAPS="stream,thinking"; else CAPS="thinking"; fi

export CHAT_BASE="http://${CONNECT_HOST}:${PORT}/v1"
export CHAT_KEY="$KEY"
export CHAT_MODEL="$SERVED_MODEL_NAME"
export CHAT_MAX_TOKENS="$MAXTOK"
export CHAT_THINKING="$([[ $THINKING_BOOL -eq 1 ]] && echo on || echo off)"
export CHAT_CAPS="$CAPS"
export CHAT_SYSTEM="$SYSTEM"
export CHAT_TEMP="${TEMP:-}"

# Arguments are consumed here; chat.py reads the environment.
exec python3 "$REPO_DIR/lib/chat.py"
