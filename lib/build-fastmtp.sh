#!/usr/bin/env bash
# Build the patched llama.cpp that the Qwen 27B FastMTP draft head needs.
#
#   ./lib/build-fastmtp.sh                 build and wire it up
#   ./lib/build-fastmtp.sh --dir ~/src     build somewhere else
#   ./lib/build-fastmtp.sh --check         report what is already built
#
# Why this is a separate build rather than an upgrade
# --------------------------------------------------
# HauhauCS's FastMTP head trims the drafter's output vocabulary and adds a `d2t`
# remap tensor. Upstream llama.cpp already knows the tensor - eagle3 uses it -
# but the Qwen35 architecture never wires it up, so a stock build refuses the
# head with "tensor 'output.weight' has wrong shape" and llama-server exits
# rather than falling back. The 53-line patch applies the same handling to
# qwen35. See docs/GGUF-RUNTIME.md.
#
# The patched build is pinned to the patch's base commit, which is OLDER than
# current llama.cpp. Measured on the reference machine it is therefore about
# 2-3% SLOWER for Gemma. So it does not replace the Homebrew build: this script
# records its path in env.conf as LLAMA_SERVER, and you set DRAFT_PATCHED_RUNTIME=1
# when serving a model that needs it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_DIR/lib/common.sh"
load_config

BASE_COMMIT="4df29be4f4c3673f428170fda944a5b19f743bb8"
PATCH_NAME="HauhauCS-FastMTP-llama.cpp.patch"
SRC_DIR="${HOME}/src"
BUILD_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)   SRC_DIR="${2:-}"; shift 2 ;;
    --check) BUILD_DIR="__check__"; shift ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1  (try --help)" ;;
  esac
done

# ── where the patch lives ────────────────────────────────────────────────────
find_patch() {
  local p
  p="$(find -L "$MODELS_DIR" -maxdepth 2 -name "$PATCH_NAME" 2>/dev/null | head -1)"
  [[ -n "$p" ]] && { echo "$p"; return; }
  return 1
}

check_existing() {
  local target="$SRC_DIR/llama.cpp-fastmtp/build/bin/llama-server"
  if [[ -x "$target" ]]; then
    ok "patched llama-server already built: $target"
    if [[ "$LLAMA_SERVER" == "$target" ]]; then
      info "env.conf already points at it (LLAMA_SERVER)."
    else
      info "to use it, set in env.conf:"
      log "    LLAMA_SERVER=\"$target\""
      log "    DRAFT_PATCHED_RUNTIME=1"
    fi
    return 0
  fi
  info "no patched build at $target"
  return 1
}

if [[ "$BUILD_DIR" == "__check__" ]]; then
  check_existing || true
  exit 0
fi

step "Building a patched llama.cpp for the Qwen 27B FastMTP draft"

PATCH="$(find_patch || true)"
if [[ -z "$PATCH" ]]; then
  warn "Could not find $PATCH_NAME under $MODELS_DIR"
  warn "It ships inside the Qwen 27B model repo. Download it first:"
  log "    ./model_download.sh qwen-27b"
  die  "patch file not found."
fi
info "patch: $(basename "$(dirname "$PATCH")")/$PATCH_NAME"

# Verify the patch against the checksum its repo publishes. A corrupted or
# substituted patch is not something to compile and trust blindly.
PROV="$(dirname "$PATCH")/FastMTP-PROVENANCE.json"
if [[ -f "$PROV" ]]; then
  WANT="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['runtime_patch_sha256'])" "$PROV")"
  GOT="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
  if [[ "$WANT" == "$GOT" ]]; then
    ok "patch checksum matches the published provenance"
  else
    warn "patch checksum MISMATCH"
    log "    published: $WANT"
    log "    actual:    $GOT"
    die  "refusing to build with an unverified patch."
  fi
fi

# ── toolchain ────────────────────────────────────────────────────────────────
require_bin git "git is required."
require_bin python3 "python3 is required."
if ! command -v cmake >/dev/null 2>&1; then
  warn "cmake is required to build llama.cpp."
  if command -v brew >/dev/null 2>&1; then
    info "installing it with Homebrew..."
    brew install cmake || die "brew install cmake failed."
  else
    die "Install cmake and re-run: https://cmake.org/download/"
  fi
fi

# ── clone, patch, build ──────────────────────────────────────────────────────
DEST="$SRC_DIR/llama.cpp-fastmtp"
mkdir -p "$SRC_DIR"

if [[ -d "$DEST/.git" ]]; then
  info "reusing $DEST"
  git -C "$DEST" checkout -- . 2>/dev/null || true
  git -C "$DEST" checkout "$BASE_COMMIT" >/dev/null 2>&1 || true
else
  info "cloning llama.cpp (this pulls ~200 MB)..."
  git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$DEST" \
    > /tmp/fastmtp-clone.log 2>&1 || die "clone failed; see /tmp/fastmtp-clone.log"
  git -C "$DEST" checkout "$BASE_COMMIT" >> /tmp/fastmtp-clone.log 2>&1 \
    || die "could not check out the patch's base commit $BASE_COMMIT"
fi
ok "source at $BASE_COMMIT"

info "applying the patch..."
if git -C "$DEST" apply --check "$PATCH" 2>/dev/null; then
  git -C "$DEST" apply "$PATCH"
  ok "patch applied"
elif git -C "$DEST" apply --reverse --check "$PATCH" 2>/dev/null; then
  ok "patch already applied"
else
  die "patch does not apply to $BASE_COMMIT - upstream may have changed the file.
    Inspect manually: $PATCH"
fi

# Shaders are compiled at runtime when the Metal compiler is absent, which is
# the case on a CommandLineTools-only machine. That is slower to start but
# produces an identical model.
EMBED=OFF
if xcrun -sdk macosx --find metal >/dev/null 2>&1; then
  EMBED=ON
  info "Metal compiler found - embedding the shader library"
else
  info "no Metal compiler (CommandLineTools only) - shaders compile at runtime"
fi

info "configuring..."
cmake -B "$DEST/build" -S "$DEST" \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=$EMBED \
      -DLLAMA_CURL=OFF \
      > /tmp/fastmtp-cmake.log 2>&1 || die "configure failed; see /tmp/fastmtp-cmake.log"

JOBS="$(sysctl -n hw.ncpu)"
info "compiling with -j$JOBS (this takes several minutes)..."
cmake --build "$DEST/build" --config Release -j "$JOBS" \
      --target llama-server llama-bench > /tmp/fastmtp-build.log 2>&1 \
  || die "build failed; see /tmp/fastmtp-build.log"

SERVER="$DEST/build/bin/llama-server"
[[ -x "$SERVER" ]] || die "build reported success but $SERVER is missing"
ok "built: $SERVER"

# ── wire it into env.conf ────────────────────────────────────────────────────
info "recording the path in env.conf..."
python3 - "$ENV_FILE" "$SERVER" <<'PY'
import re, sys
path, server = sys.argv[1], sys.argv[2]
s = open(path).read()
s, n = re.subn(r'^LLAMA_SERVER=.*$', f'LLAMA_SERVER="{server}"', s,
               count=1, flags=re.M)
if n != 1:
    raise SystemExit(f"could not set LLAMA_SERVER in {path}")
open(path, 'w').write(s)
PY
ok "env.conf: LLAMA_SERVER set"

log ""
info "One more step when serving a model that needs it - set in env.conf:"
log "    DRAFT_PATCHED_RUNTIME=1"
log ""
info "Measured on the reference machine (docs/GGUF-RUNTIME.md):"
log "    qwen-27b   7.6 t/s  ->  ~14-15 t/s with the FastMTP draft"
log "    gemma 26b  ~2-3% SLOWER on this build, so leave LLAMA_SERVER clear"
log "               when you are not serving Qwen."
log ""
info "Verify it worked:"
log "    ./start.sh --model qwen-27b && ./bench/verify-tools.sh"
