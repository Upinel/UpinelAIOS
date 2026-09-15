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
"""The dashboard must follow a model switch without being restarted.

Trying models is the normal way to use this thing, and the dashboard is the
window onto it. Leaving ./status.sh open in one window and running
./restart.sh --model ... in another is the obvious workflow, so a dashboard
that keeps showing the model it started with is not a cosmetic problem: the
weights, the KV figure, the engine and the speculative-depth panel would all
describe a model that is no longer loaded.

start.sh and restart.sh rewrite the payload on every launch; the dashboard
re-reads it each frame. This checks that re-read actually happens, that it
rebuilds what the config feeds rather than only swapping the name, and that a
half-written file is ignored instead of adopted.

Runs offline - it drives the Dashboard object directly, with no server.

Run:  python3 bench/verify-dashboard-reload.py
"""

import argparse
import importlib.util
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

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


def load_dashboard():
    spec = importlib.util.spec_from_file_location(
        "aios_dash", os.path.join(REPO, "lib", "dashboard.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def payload(repo, engine, base="http://127.0.0.1:8000/v1"):
    return {
        "base": base, "lan_url": base, "api_key": "", "api_key_file": "",
        "pid_file": "/tmp/none.pid", "log_file": "/tmp/none.log",
        "error_log": "/tmp/none.err", "models_dir": "/tmp", "repo_dir": REPO,
        "env_file": "/tmp/none.conf", "model_dir": f"/tmp/{engine}",
        "model": repo, "served_name": "Upinel-AIOS", "model_repo": repo,
        "engine": engine, "main_gguf": "", "weights_gb": "1", "kv_gb": "1",
        "vision_gb": "0", "slots": "1", "context": "131072", "ctx": "131072",
        "kv": "q8_0" if engine == "gguf" else "q8", "profile": "",
        "thinking": "low", "preserve_thinking": "", "depth": "3",
        "memory_limit": "48", "batching": "", "host": "0.0.0.0",
        "port": "8000", "chip": "Apple M5 Pro", "macos": "27.0",
    }


def write(path, obj, mtime=None):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(obj, fh)
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def main():
    print("\n  Dashboard live reload\n")
    mod = load_dashboard()
    args = argparse.Namespace(power=False, enable_keys=False, interval=1.0,
                              once=True, json=False, iterations=0)

    tmp = tempfile.mkdtemp(prefix="dash-reload-")
    cfg_path = os.path.join(tmp, "dashboard-cfg.json")

    A = payload("OS-Software/gemma-4-26B-A4B-it-qat-q4_0-heretic-ja-GGUF", "gguf")
    B = payload("hawhyhb/Qwen3.6-35B-A3B-Uncensored-Heretic-MTPLX-4bit-FP16", "mlx")
    write(cfg_path, A)

    with open(cfg_path, encoding="utf-8") as fh:
        dash = mod.Dashboard(json.load(fh), args, cfg_path=cfg_path)

    check("starts on the payload it was handed", dash.cfg["engine"], "gguf")
    check("no reload when nothing changed", dash._reload_cfg(), False)

    # Pollute the caches the way a real session would, so a reload that only
    # swapped the dict would leave stale data behind and still pass a name check.
    dash._log_cache["x"] = {"n": 1}
    dash.log_totals = 123
    dash._health_cache = {"ok": True}
    dash._props_cache = {"n_slots": 1}
    dash.hist_tps.extend([1.0, 2.0])
    old_server = dash.server

    time.sleep(1.1)                      # ensure a distinct mtime
    write(cfg_path, B)
    check("a changed payload is noticed", dash._reload_cfg(), True)
    check("engine followed the switch", dash.cfg["engine"], "mlx")
    check("model repo followed the switch", dash.cfg["model_repo"], B["model_repo"])
    check("KV vocabulary followed the engine", dash.cfg["kv"], "q8")

    # The part that actually matters: everything derived from the old model.
    check("log cache was dropped", dash._log_cache, {})
    check("token totals were dropped", dash.log_totals, None)
    check("health cache was dropped", dash._health_cache, None)
    check("props cache was dropped", dash._props_cache, None)
    check("throughput history was cleared", list(dash.hist_tps), [])
    check("the sampler was rebuilt for the new endpoint",
          dash.server is not old_server, True)
    check("the rebuilt sampler points at the new model dir",
          dash.server.model_dir, B["model_dir"])
    check("the switch is announced on screen",
          "switched" in dash.status_note, True)

    # Re-reading again must be a no-op, or every frame would reset the history.
    check("no reload when nothing changed again", dash._reload_cfg(), False)

    # A partial write must never be adopted.
    time.sleep(1.1)
    with open(cfg_path, "w", encoding="utf-8") as fh:
        fh.write('{"base": "http://127.0.0.1:8000/v1", "engine"')
    check("a truncated payload is ignored, not crashed on",
          dash._reload_cfg(), False)
    check("still on the last good payload", dash.cfg["engine"], "mlx")

    # And recovery: the next complete write is picked up.
    time.sleep(1.1)
    write(cfg_path, A)
    check("recovers on the next complete payload", dash._reload_cfg(), True)
    check("back on the GGUF payload", dash.cfg["engine"], "gguf")

    print(f"\n  {PASSED} passed, {FAILED} failed\n")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
