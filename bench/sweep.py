#!/usr/bin/env python3
"""Sweep llama.cpp launch flags and measure agent-realistic performance.

Restarts llama-server once per configuration and records, for each:

  prefill2k / prefill8k / prefill16k   cold prompt speed (TTFT driver)
  decode2k / decode8k / decode16k      generation speed at that context

Decode at *long* context is the number that matters for an agent session:
it falls off as the KV cache grows, and that falloff is what makes turn 20
feel different from turn 1.

Usage
-----
    python3 bench/sweep.py                       # built-in config list
    python3 bench/sweep.py --configs a,b         # only these
    python3 bench/sweep.py --list                # show them

Expects nothing else to be listening on the port, and enough free memory for
one model. Stop the main server first.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import importlib.util
_spec = importlib.util.spec_from_file_location(
    "agent_bench", os.path.join(HERE, "agent-bench.py"))
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)


def env_conf():
    """Read env.conf as plain key=value, without sourcing it."""
    cfg = {}
    path = os.path.join(REPO, "env.conf")
    for line in open(path):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = v.strip().strip('"')
    return cfg


def ggufs(cfg):
    d = os.path.join(cfg.get("MODELS_DIR", os.path.join(REPO, "models")),
                     cfg["MODEL"].replace("/", "--"))
    if not os.path.isdir(d):
        # Aliases map to repos; fall back to whatever is on disk.
        base = os.path.join(REPO, "models")
        for name in sorted(os.listdir(base)):
            if os.path.isdir(os.path.join(base, name)) or os.path.islink(os.path.join(base, name)):
                d = os.path.join(base, name)
                break
    main = draft = mmproj = None
    for root, _dirs, files in os.walk(d, followlinks=True):
        for f in sorted(files):
            if not f.endswith(".gguf"):
                continue
            low = f.lower()
            p = os.path.join(root, f)
            if "mmproj" in low:
                mmproj = p
            elif "mtp" in low or "draft" in low:
                draft = p
            elif main is None:
                main = p
    return main, draft, mmproj


# ── the configurations under test ────────────────────────────────────────────
# Each is a name, a human note, and flag overrides layered on the env.conf
# baseline. Keep the baseline first: every number is read against it.
CONFIGS = [
    ("baseline", "shipped: -b 2048 -ub 512, q8_0 KV, MTP depth 1", {}),
    ("ub1024", "double the physical batch - prefill is the agent cost", {"-ub": "1024"}),
    ("ub2048", "physical batch 2048", {"-ub": "2048"}),
    ("b4096ub2048", "bigger logical and physical batch", {"-b": "4096", "-ub": "2048"}),
    ("kvq4", "q4_0 KV instead of q8_0 - halves attention traffic", {"-ctk": "q4_0", "-ctv": "q4_0"}),
    ("kvq4ub2048", "both of the above", {"-b": "4096", "-ub": "2048", "-ctk": "q4_0", "-ctv": "q4_0"}),
    ("mtp0", "no speculative decoding, for reference", {"__depth": "0"}),
    ("mtp2", "MTP depth 2", {"__depth": "2"}),
    ("mtp3", "MTP depth 3", {"__depth": "3"}),
    ("mtp4", "MTP depth 4", {"__depth": "4"}),
    # Interleaved A/B. Running one config after another confounds the result
    # with thermal drift: whichever runs second is hotter. Alternating them
    # makes drift hit both equally, so the difference is the real one.
    # Prefill-focused batch comparison. Cold prefill of a long agent context
    # is the dominant cost (63s TTFT at 29k tokens), so these alternate to
    # survive thermal drift.
    ("pf_a", "b2048/ub512 (shipped)", {"__depth": "3"}),
    ("pf_b", "b4096/ub1024", {"__depth": "3", "-b": "4096", "-ub": "1024"}),
    ("pf_c", "b8192/ub2048", {"__depth": "3", "-b": "8192", "-ub": "2048"}),
    ("pf_d", "b8192/ub512", {"__depth": "3", "-b": "8192", "-ub": "512"}),
    ("d1a", "depth 1 (A)", {"__depth": "1"}),
    ("d3a", "depth 3 (A)", {"__depth": "3"}),
    ("d1b", "depth 1 (B)", {"__depth": "1"}),
    ("d3b", "depth 3 (B)", {"__depth": "3"}),
    ("threads", "explicit thread count", {"-t": "8"}),
]


def build_args(main, draft, mmproj, cfg, overrides, port):
    depth = overrides.pop("__depth", "1")
    ctx = cfg.get("CONTEXT_WINDOW", "131072")
    args = [
        "llama-server", "-m", main, "-ngl", "all", "-fa", "on",
        "-c", ctx,
        "-b", cfg.get("BATCH_SIZE", "2048"),
        "-ub", cfg.get("UBATCH_SIZE", "512"),
        "--parallel", cfg.get("PARALLEL_SLOTS", "1"),
        "-ctk", cfg.get("KV_QUANT", "q8_0"),
        "-ctv", cfg.get("KV_QUANT", "q8_0"),
        "--host", "127.0.0.1", "--port", str(port),
        "--alias", "sweep", "--no-webui", "--metrics", "--timeout", "3600",
        "-lm", "mlock",
        "--chat-template-kwargs", '{"enable_thinking":false}',
    ]
    if mmproj and os.environ.get("SWEEP_VISION") == "1":
        args += ["--mmproj", mmproj]
    if depth not in ("0", 0) and draft:
        args += ["-md", draft, "--spec-type", "draft-mtp",
                 "--spec-draft-n-max", str(depth), "--spec-draft-ngl", "all"]
    for k, v in overrides.items():
        args += [k, str(v)]
    return args


def wait_ready(port, proc, timeout=300):
    url = f"http://127.0.0.1:{port}/health"
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            return False
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                if b'"ok"' in r.read():
                    return True
        except Exception:                                       # noqa: BLE001
            pass
        time.sleep(1)
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--configs", default="", help="comma-separated subset")
    ap.add_argument("--depths", default="2048,8192,16384")
    ap.add_argument("--repeat", type=int, default=3,
                    help="samples per point; best-of-N is kept")
    ap.add_argument("--max-tokens", type=int, default=128,
                    help="generation length per sample (short samples are noisy)")
    ap.add_argument("--cooldown", type=float, default=5.0,
                    help="seconds between configs, to shed heat")
    ap.add_argument("--ask", choices=["count", "code"], default="count",
                    help="count: predictable, flatters deep MTP. "
                         "code: realistic agent output.")
    ap.add_argument("--temp", type=float, default=None,
                    help="sample at this temperature instead of greedy. "
                         "Use for MTP comparisons: greedy pins acceptance at "
                         "100%% and hides the real falloff with depth.")
    ap.add_argument("--port", type=int, default=8010)
    ap.add_argument("--json", default="/tmp/sweep.json")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list:
        for name, note, _ in CONFIGS:
            print(f"  {name:14s} {note}")
        return 0

    want = [c.strip() for c in args.configs.split(",") if c.strip()]
    configs = [c for c in CONFIGS if not want or c[0] in want]
    # Re-measure the baseline last. A laptop under a sustained sweep throttles,
    # and without this you cannot tell a real regression from a hot chassis.
    # If start and end agree, the run is trustworthy; if not, discard it.
    if not want:
        configs.append(("baseline-end", "drift check - baseline re-measured", {}))
    depths = [int(x) for x in args.depths.split(",") if x.strip()]

    cfg = env_conf()
    main_gguf, draft, mmproj = ggufs(cfg)
    if not main_gguf:
        sys.exit("no model found under models/")
    key = open(os.path.join(REPO, "run", "api-key")).read().strip()
    base = f"http://127.0.0.1:{args.port}/v1"

    print(f"\n  model: {os.path.basename(main_gguf)}")
    print(f"  draft: {os.path.basename(draft) if draft else '(none)'}\n")

    all_results = {}
    for name, note, raw_over in configs:
        over = dict(raw_over)
        cmd = build_args(main_gguf, draft, mmproj, cfg, over, args.port)
        log = open("/tmp/sweep-server.log", "w")
        proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            if not wait_ready(args.port, proc):
                print(f"  {name:14s} FAILED TO START")
                continue
            # Warm the slot, then measure each depth cold.
            rows = {}
            for depth in depths:
                samples = []
                for rep in range(args.repeat):
                    # A unique nonce in the system prompt per sample. Without
                    # it the repeats are cache hits and the "prefill rate" is
                    # one token divided by its own overhead.
                    nonce = f"{name}-{depth}-{rep}-{int(time.time() * 1000) % 1000000}"
                    ask = ab.CODE_ASK if args.ask == "code" else None
                    msgs, _ = ab.build_long_messages(depth, nonce, ask)
                    try:
                        r = ab.measure(base, key, "sweep", msgs,
                                       args.max_tokens, 900,
                                       greedy=(args.temp is None),
                                       temp=args.temp)
                    except Exception as e:                      # noqa: BLE001
                        print(f"  {name:14s} depth {depth}: {type(e).__name__}")
                        break
                    # Every sample must be a genuine cold prefill, or the run
                    # is measuring the cache and not the configuration.
                    if r["cache_n"] == 0 or r["prompt_n"] > 256:
                        samples.append(r)
                if not samples:
                    print(f"  {name:14s} depth {depth}: no cold-prefill sample")
                    continue
                # Best of N, per metric. A laptop throttles during a long
                # sweep, so the slowest samples measure heat, not the config.
                best = dict(max(samples, key=lambda s: s["decode_s"]))
                best["prefill_best"] = max(s["prompt_s"] for s in samples)
                best["samples"] = len(samples)
                rows[depth] = best
            all_results[name] = rows
            line = f"  {name:14s}"
            for d in depths:
                r = rows.get(d)
                line += (f"  {r['prefill_best']:6.0f}p/{r['decode_s']:4.0f}d"
                         if r else "      -/-    ")
            print(line + f"   {note}")
            # MTP acceptance, if it is on.
            r = rows.get(depths[-1])
            if r and r["draft_n"]:
                print(f"                 MTP accepted {r['draft_ok']}/{r['draft_n']}"
                      f" ({100.0 * r['draft_ok'] / r['draft_n']:.0f}%) at {depths[-1]} ctx")
        finally:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
                proc.wait(timeout=20)
            except Exception:                                   # noqa: BLE001
                try:
                    proc.kill()
                except Exception:                               # noqa: BLE001
                    pass
            log.close()
            time.sleep(args.cooldown)

    with open(args.json, "w") as fh:
        json.dump(all_results, fh, indent=2)
    print(f"\n  raw -> {args.json}")

    # Drift verdict: is the whole run trustworthy?
    a, b = all_results.get("baseline"), all_results.get("baseline-end")
    if a and b:
        worst = 0.0
        for d in depths:
            if d in a and d in b and a[d]["decode_s"]:
                drift = 100.0 * (a[d]["decode_s"] - b[d]["decode_s"]) / a[d]["decode_s"]
                worst = max(worst, abs(drift))
        verdict = "TRUSTWORTHY" if worst < 8 else "SUSPECT - thermal drift, re-run"
        print(f"  drift check: baseline moved {worst:.0f}% across the run -> {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
