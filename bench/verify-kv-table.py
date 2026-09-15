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
"""KV cost per token must be a property of the model, not of the table.

This number decides whether the installer says a model fits, which model the
picker recommends, and what the dashboard reports as live KV. Two ways it can
be wrong, and both have bitten:

  * **The two engines disagree.** The merge carried two tables, and for Qwen
    they differed by 4x - one assumed full attention on every layer, the other
    a hybrid. Both were partly wrong. KV per token is the same either way,
    because the same model stores the same K and V whatever reads it, so a
    disagreement between engines is a bug by construction.

  * **The table disagrees with the weights.** Qwen 3.x here is hybrid: the GGUF
    metadata carries ``full_attention_interval = 4`` and an ``ssm.*`` block, so
    only every 4th layer keeps a per-token cache. The old numbers assumed all
    of them did, overstating the 35B by nearly 10x - which makes the installer
    refuse a model that would have run.

The second check needs the weights on disk and is skipped when they are absent,
so this still runs on a fresh clone.

Run:  python3 bench/verify-kv-table.py
"""

import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

SHIM = r'''
source "$1/lib/common.sh"
kv_kb_per_token_f16 "$2"
'''

# One base model, every alias repo that serves it, and the KB/token the table
# must hold. The values are derived from the weights by bench/kv-from-gguf.py;
# the metadata check below re-derives them rather than trusting this list.
MODELS = [
    ("Qwen3.8-9B",
     ["mradermacher/Qwen3.8-9B-heretic-uncensored-i1-GGUF",
      "Foresee/Qwen3.8-9B-heretic-uncensored-4bit-MTPLX"], 32),
    ("Qwen3.8-27B",
     ["HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF",
      "itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-4bit",
      "barozp/Qwen3.8-27B-Uncensored-MTPLX-4bit"], 64),
    ("Qwen3.6-35B-A3B",
     ["HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive",
      "hawhyhb/Qwen3.6-35B-A3B-Uncensored-Heretic-MTPLX-4bit-FP16"], 20),
    ("Gemma-4-26B-A4B",
     ["OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF"], 20),
    ("Gemma-4-12B",
     ["HauhauCS/Gemma4-12B-QAT-Uncensored-HauhauCS-Balanced"], 16),
    ("Gemma-4-31B",
     ["llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF"], 80),
    ("Gemma-4-E4B",
     ["HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive"], 28),
    ("Gemma-4-E2B",
     ["HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive"], 14),
]

PASSED = 0
FAILED = 0


def check(label, got, want):
    global PASSED, FAILED
    if got == want:
        print(f"  [PASS] {label}")
        PASSED += 1
    else:
        print(f"  [FAIL] {label}\n         got  {got!r}\n         want {want!r}")
        FAILED += 1


def table_kb(repo):
    r = subprocess.run(["bash", "-c", SHIM, "shim", REPO, repo],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return int(r.stdout.strip())


# ── GGUF metadata, enough of it to derive the cache ─────────────────────────

_SCALARS = {0: ("<B", 1), 1: ("<b", 1), 2: ("<H", 2), 3: ("<h", 2), 4: ("<I", 4),
            5: ("<i", 4), 6: ("<f", 4), 7: ("<?", 1), 10: ("<Q", 8), 11: ("<q", 8),
            12: ("<d", 8)}


def _read_str(fh):
    n, = struct.unpack("<Q", fh.read(8))
    return fh.read(n).decode("utf-8", "replace")


def _read_val(fh, t):
    if t == 8:
        return _read_str(fh)
    if t == 9:
        et, = struct.unpack("<I", fh.read(4))
        n, = struct.unpack("<Q", fh.read(8))
        if et == 8:
            return [_read_str(fh) for _ in range(n)]
        fmt, sz = _SCALARS[et]
        return list(struct.unpack("<" + fmt[1] * n, fh.read(sz * n)))
    fmt, sz = _SCALARS[t]
    return struct.unpack(fmt, fh.read(sz))[0]


def gguf_meta(path):
    with open(path, "rb") as fh:
        if fh.read(4) != b"GGUF":
            raise ValueError("not a GGUF file")
        struct.unpack("<I", fh.read(4))
        struct.unpack("<Q", fh.read(8))
        nkv, = struct.unpack("<Q", fh.read(8))
        meta = {}
        for _ in range(nkv):
            k = _read_str(fh)
            t, = struct.unpack("<I", fh.read(4))
            meta[k] = _read_val(fh, t)
    return meta


def expected_kb(meta):
    """KB/token at f16, from the architecture itself.

    bytes/token = 4 x (K and V, 2 bytes each) x layers-that-cache x kv_heads x head_dim
    """
    arch = meta.get("general.architecture", "")
    def g(suffix):
        return meta.get(f"{arch}.{suffix}")

    blocks = g("block_count")
    if blocks is None:
        return None

    # Qwen 3.x - hybrid: only every Nth layer keeps a per-token cache.
    interval = g("full_attention_interval")
    if interval:
        n_full = blocks // interval
        return 4 * n_full * g("attention.head_count_kv") * g("attention.key_length") // 1024

    # Gemma 4 - sliding window; only the layers with the pattern false grow.
    pattern = g("attention.sliding_window_pattern")
    if pattern is not None:
        kv_heads = g("attention.head_count_kv")
        # Use the head count of an actual full-attention layer rather than a
        # positional guess: the per-layer array is [8,8,8,8,8,2,8,...], so the
        # full layers are exactly the ones with the smaller count, and picking
        # by index instead of by pattern reads a sliding layer by mistake.
        n_full = sum(1 for p in pattern if not p)
        full_idx = next(i for i, p in enumerate(pattern) if not p)
        heads = kv_heads[full_idx] if isinstance(kv_heads, list) else kv_heads
        return 4 * n_full * heads * g("attention.key_length") // 1024
    return None


def gguf_path_for(repo):
    d = os.path.join(REPO, "models", repo.replace("/", "--"))
    if not os.path.isdir(d):
        return None
    for root, _, files in os.walk(d):
        for f in sorted(files):
            if f.endswith(".gguf") and not f.startswith("mmproj"):
                return os.path.join(root, f)
    return None


def main():
    print("\n  KV cost per token\n")

    for name, repos, want in MODELS:
        got = {r: table_kb(r) for r in repos}
        vals = set(got.values())

        check(f"{name}: every engine agrees", len(vals), 1)
        check(f"{name}: table value", sorted(vals)[0], want)

        # Strongest form of the check: derive it from the weights.
        gguf_repo = next((r for r in repos if "GGUF" in r or r.count("-") >= 0), None)
        path = None
        for r in repos:
            path = gguf_path_for(r)
            if path:
                break
        if path:
            derived = expected_kb(gguf_meta(path))
            if derived is None:
                print(f"  [SKIP] {name}: architecture not recognised in metadata")
            else:
                check(f"{name}: table matches the weights ({os.path.basename(path)})",
                      sorted(vals)[0], derived)
        else:
            print(f"  [SKIP] {name}: weights not on disk, metadata not re-derived")

    # The specific regression, stated plainly so a failure is self-explaining.
    gguf_27 = table_kb("HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF")
    mlx_27 = table_kb("itrejomx/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTPLX-4bit")
    check("the 27B no longer differs across engines", gguf_27 == mlx_27, True)
    check("the 27B is no longer the old 260", gguf_27 != 260, True)
    check("the 9B is no longer the old 128",
          table_kb("Foresee/Qwen3.8-9B-heretic-uncensored-4bit-MTPLX") != 128, True)

    # Two Gemma rows were wrong in the direction that matters: too low makes a
    # model the Mac cannot hold look comfortable. The 31B was estimated at 40
    # and is 80 - a 2x under-report.
    #
    # The impact, stated precisely because it is easy to overstate: this does
    # not flip any verdict in the current context ladder. The ladder pairs a
    # large context with a large Mac, so the 2.5 GB difference at 131k is small
    # next to 64 GB. What it fixes is the reported memory being wrong by half,
    # and the margin on any Mac that is genuinely close to its limit.
    check("the 31B is no longer the old 40",
          table_kb("llmfan46/gemma-4-31B-it-uncensored-heretic-GGUF") != 40, True)
    check("the E4B is no longer the old 16",
          table_kb("HauhauCS/Gemma-4-E4B-Uncensored-HauhauCS-Aggressive") != 16, True)

    # And the direction itself, since that is the thing that does the harm:
    # no row may claim a model is cheaper than its architecture allows.
    for name, repos, want in MODELS:
        for r in repos:
            check(f"{name}: {r.split('/')[0]} does not under-report KV",
                  table_kb(r) >= want, True)

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
