#!/usr/bin/env python3
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
"""Work out a model's KV cost per token from its own weights.

The KV table in lib/common.sh decides whether the installer says a model fits.
Getting a row wrong is not cosmetic: too low and a model that will not load
looks comfortable, too high and the installer refuses something that would have
run. Both have happened here.

The honest source for the number is the model itself. GGUF metadata carries the
architecture, and for the models in this bundle that is decisive in a way
guessing is not:

  * Gemma 4 interleaves sliding-window attention. Only the layers with
    ``sliding_window_pattern`` false grow with context - 5 of 30 blocks on the
    26B-A4B. Assuming all 30 gives a number 6x too high.
  * Qwen 3.x is hybrid, with ``full_attention_interval`` 4 and an ``ssm.*``
    block. Only every 4th layer keeps a per-token cache.

Crucially the metadata sits at the *head* of the file, before the tensor data,
so this can read a remote model's architecture with a range request. Deriving
the cost of a 20 GB checkpoint takes about two seconds and downloads 64 MB
instead of 20 GB -- which is the difference between a table that gets checked
and one that gets guessed at.

Metadata is bigger than it looks: the tokenizer vocabulary is in there, so
budget tens of megabytes, not kilobytes.

Usage:
  ./bench/kv-from-gguf.py models/<dir>                    # local model dir
  ./bench/kv-from-gguf.py path/to/model.gguf              # a single file
  ./bench/kv-from-gguf.py owner/repo                      # remote, via range
  ./bench/kv-from-gguf.py owner/repo --quant Q4_K_M       # pick a quant
"""

import argparse
import json
import os
import struct
import subprocess
import sys
import urllib.request

# Enough for the tokenizer vocab plus the architecture block. A range request
# for less than this fails with EOFError partway through the metadata.
HEAD_BYTES = 64 * 1024 * 1024

_SCALARS = {
    0: ("<B", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2), 4: ("<I", 4),
    5: ("<i", 4), 6: ("<f", 4), 7: ("<?", 1), 10: ("<Q", 8), 11: ("<q", 8),
    12: ("<d", 8),
}


class _Buf:
    """Sequential reader over a bytes blob, for the GGUF header."""

    def __init__(self, data):
        self.data = data
        self.pos = 0

    def read(self, n):
        if self.pos + n > len(self.data):
            raise EOFError(
                f"metadata runs past the {len(self.data)} bytes read; "
                f"raise HEAD_BYTES")
        out = self.data[self.pos:self.pos + n]
        self.pos += n
        return out

    def u32(self):
        return struct.unpack("<I", self.read(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.read(8))[0]

    def string(self):
        return self.read(self.u64()).decode("utf-8", "replace")


def _value(f, t):
    if t == 8:
        return f.string()
    if t == 9:
        et, n = f.u32(), f.u64()
        if et == 8:
            return [f.string() for _ in range(n)]
        fmt, sz = _SCALARS[et]
        return list(struct.unpack("<" + fmt[1] * n, f.read(sz * n)))
    fmt, sz = _SCALARS[t]
    return struct.unpack(fmt, f.read(sz))[0]


def parse_metadata(blob):
    f = _Buf(blob)
    if f.read(4) != b"GGUF":
        raise ValueError("not a GGUF file")
    f.u32()                      # version
    f.u64()                      # tensor count
    meta = {}
    for _ in range(f.u64()):
        k = f.string()
        meta[k] = _value(f, f.u32())
    return meta


def derive(meta):
    """(KB per token at f16, explanation) from parsed metadata."""
    arch = meta.get("general.architecture", "")
    g = lambda s: meta.get(f"{arch}.{s}")  # noqa: E731

    blocks = g("block_count")
    if blocks is None:
        return None, "no block_count in metadata"

    # bytes/token = 4 x (K and V, 2 bytes each) x caching layers x heads x head_dim
    interval = g("full_attention_interval")
    if interval:
        n_full = blocks // interval
        kb = 4 * n_full * g("attention.head_count_kv") * g("attention.key_length") // 1024
        return kb, (f"hybrid, {n_full} of {blocks} layers cache "
                    f"(interval {interval}), "
                    f"{g('attention.head_count_kv')} kv heads x {g('attention.key_length')}")

    pattern = g("attention.sliding_window_pattern")
    if pattern is not None:
        kvh = g("attention.head_count_kv")
        n_full = sum(1 for p in pattern if not p)
        # Read the head count from a layer that actually caches. The per-layer
        # array is not uniform - [8,8,8,8,8,2,...] - so indexing positionally
        # picks a sliding layer and reports the wrong figure.
        idx = next(i for i, p in enumerate(pattern) if not p)
        heads = kvh[idx] if isinstance(kvh, list) else kvh
        kb = 4 * n_full * heads * g("attention.key_length") // 1024
        return kb, (f"sliding window, {n_full} of {blocks} layers cache, "
                    f"{heads} kv heads x {g('attention.key_length')}")

    return None, f"architecture '{arch}' has neither pattern; add a rule"


def _remote_head(repo, filename):
    url = f"https://huggingface.co/{repo}/resolve/main/{filename}"
    req = urllib.request.Request(url, headers={"Range": f"bytes=0-{HEAD_BYTES - 1}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()


def _pick_remote_file(repo, quant):
    api = f"https://huggingface.co/api/models/{repo}"
    with urllib.request.urlopen(api, timeout=60) as r:
        info = json.load(r)
    names = [f["rfilename"] for f in info.get("siblings", [])
             if f["rfilename"].endswith(".gguf")
             and not os.path.basename(f["rfilename"]).startswith("mmproj")]
    if not names:
        raise SystemExit(f"no GGUF weights in {repo}")
    if quant:
        for n in names:
            if quant.lower() in n.lower():
                return n
        raise SystemExit(f"no quant matching {quant!r}; have: {', '.join(names)}")
    # Prefer a mid-size quant: the architecture is identical across quants, but
    # a small one downloads less of the header region.
    for pref in ("Q4_K_M", "Q4_0", "Q4_K_S", "Q5_K_M"):
        for n in names:
            if pref in n:
                return n
    return names[0]


def _local_file(path):
    if os.path.isfile(path):
        return path
    if os.path.isdir(path):
        for f in sorted(os.listdir(path)):
            if f.endswith(".gguf") and not f.startswith("mmproj"):
                return os.path.join(path, f)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("target", help="model directory, .gguf path, or owner/repo")
    ap.add_argument("--quant", help="quant to read from a remote repo")
    ap.add_argument("--explain", action="store_true",
                    help="print how the number was derived")
    args = ap.parse_args()

    target = args.target
    local = _local_file(target)

    if local:
        with open(local, "rb") as fh:
            blob = fh.read(HEAD_BYTES)
        src = os.path.basename(local)
    elif "/" in target and not os.path.exists(target):
        name = _pick_remote_file(target, args.quant)
        blob = _remote_head(target, name)
        src = f"{target}/{name} (metadata only)"
    else:
        raise SystemExit(f"cannot read {target!r}: not a file, a directory or owner/repo")

    kb, why = derive(parse_metadata(blob))
    if kb is None:
        raise SystemExit(why)

    arch = parse_metadata(blob).get("general.architecture", "?")
    print(f"{kb} KB/token at f16   [{arch}]   {src}")
    if args.explain:
        print(f"  {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
