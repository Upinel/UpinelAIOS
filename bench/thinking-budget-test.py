#!/usr/bin/env python3
"""Measure what a thinking budget actually does.

llama.cpp exposes `--reasoning-budget N`: a hard token cap on the thinking
channel, after which it injects a message and closes the thought block. That is
the lever for "I need thinking, but not 800 tokens of it". This measures the
real trade rather than assuming it:

  tokens/turn   how much the model actually emits, thinking included
  thinking      of which is reasoning
  answer        of which is the actual reply or tool call
  correct       did it still pick the right tool

Each budget needs its own server because the flag is fixed at launch, so this
restarts llama-server per value and reports a table.

Usage
-----
    python3 bench/thinking-budget-test.py
    python3 bench/thinking-budget-test.py --budgets -1,256,128,64,0
    python3 bench/thinking-budget-test.py --port 8011 --json /tmp/think.json

Stop the main server first: this needs the memory and the port.
"""

import argparse
import json
import os
import signal
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def env_conf():
    cfg = {}
    for line in open(os.path.join(REPO, "env.conf")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip().strip('"')
    return cfg


def model_paths():
    base = os.path.join(REPO, "models")
    d = None
    for name in sorted(os.listdir(base)):
        p = os.path.join(base, name)
        if os.path.isdir(p) or os.path.islink(p):
            d = p
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


# A mix of tasks: some genuinely need a step of reasoning, some do not. A
# budget that helps the hard ones without breaking the easy ones is the target.
TASKS = [
    ("Read the file src/main.py.", "read_file", True),
    ("Run the test suite.", "bash", True),
    ("I changed three files and forgot which. Show me what is modified.", "git_diff", False),
    ("The build is broken and there is no error message. Work out why.", "bash", False),
    ("src/db.py has a missing null check on the connection. Look at it.", "read_file", False),
    ("Where is MAX_RETRIES defined anywhere in the repo?", "grep", False),
    ("How much free disk space is there?", "bash", False),
    ("Show me the contents of config/settings.yaml.", "read_file", False),
]


def tools():
    def t(name, desc, props, req):
        return {"type": "function", "function": {
            "name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": req}}}
    S = {"type": "string"}
    return [
        t("read_file", "Read a file", {"file_path": S}, ["file_path"]),
        t("bash", "Run a shell command", {"command": S}, ["command"]),
        t("git_diff", "Show working tree changes", {"path": S}, []),
        t("grep", "Search file contents", {"pattern": S}, ["pattern"]),
    ]


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


def run_budget(budget, port, key, cfg, main, draft, tmpl, timeout=300,
               budget_msg=None):
    args = ["llama-server", "-m", main, "-ngl", "all", "-fa", "on",
            "-c", cfg.get("CONTEXT_WINDOW", "131072"),
            "-b", cfg.get("BATCH_SIZE", "2048"),
            "-ub", cfg.get("UBATCH_SIZE", "512"),
            "--parallel", "1",
            "-ctk", cfg.get("KV_QUANT", "q8_0"), "-ctv", cfg.get("KV_QUANT", "q8_0"),
            "--host", "127.0.0.1", "--port", str(port),
            "--alias", "think", "--no-webui", "--metrics", "--timeout", "3600",
            "-lm", "mlock", "--api-key", key]
    # budget -2 is the template-off case (THINKING="off"), for comparison:
    # it is a different mechanism from a token budget, not just budget=0.
    if budget == -2:
        args += ["--chat-template-kwargs", '{"enable_thinking":false}']
    else:
        args += ["--chat-template-kwargs", '{"enable_thinking":true}',
                 "--reasoning-budget", str(budget)]
        if budget_msg:
            args += ["--reasoning-budget-message", budget_msg]
    if tmpl and os.path.exists(tmpl):
        args += ["--chat-template-file", tmpl]
    if draft:
        args += ["-md", draft, "--spec-type", "draft-mtp",
                 "--spec-draft-n-max", "3", "--spec-draft-ngl", "all"]

    log = open("/tmp/think-server.log", "w")
    proc = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                            start_new_session=True)
    try:
        if not wait_ready(port, proc):
            return None
        url = f"http://127.0.0.1:{port}/v1/chat/completions"
        rows = []
        for task, want, _hard in TASKS:
            body = {"model": "think", "max_tokens": 3000, "tools": tools(),
                    "temperature": 0, "seed": 1,
                    "messages": [{"role": "system", "content": "You are a coding agent."},
                                 {"role": "user", "content": task}]}
            req = urllib.request.Request(
                url, data=json.dumps(body).encode(),
                headers={"Content-Type": "application/json",
                         "Authorization": "Bearer " + key})
            try:
                with urllib.request.urlopen(req, timeout=timeout) as r:
                    d = json.loads(r.read())
            except Exception as e:                              # noqa: BLE001
                rows.append({"total": 0, "thinking": 0, "correct": False,
                             "err": type(e).__name__})
                continue
            ch = (d.get("choices") or [{}])[0]
            msg = ch.get("message") or {}
            usage = d.get("usage") or {}
            det = usage.get("prompt_tokens_details") or {}
            rc = msg.get("reasoning_content") or ""
            # llama.cpp may report reasoning tokens; fall back to estimating
            # from the reasoning text when it does not.
            think_tok = (usage.get("completion_tokens_details") or {}).get(
                "reasoning_tokens")
            if think_tok is None:
                think_tok = max(1, len(rc) // 4) if rc else 0
            tcs = msg.get("tool_calls") or []
            got = tcs[0]["function"]["name"] if tcs else "none"
            rows.append({
                "total": usage.get("completion_tokens", 0),
                "thinking": think_tok,
                "answer": max(0, usage.get("completion_tokens", 0) - think_tok),
                "correct": got == want,
                "got": got,
                "reasoning_chars": len(rc),
            })
        return rows
    finally:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            proc.wait(timeout=20)
        except Exception:                                       # noqa: BLE001
            try:
                proc.kill()
            except Exception:                                   # noqa: BLE001
                pass
        log.close()
        time.sleep(3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budgets", default="-2,-1,256,128,96,64",
                    help="comma-separated budgets; N:message sets "
                         "--reasoning-budget-message")
    ap.add_argument("--port", type=int, default=8011)
    ap.add_argument("--json", default="/tmp/thinkbudget.json")
    args = ap.parse_args()

    cfg = env_conf()
    main_gguf, draft, _mm = model_paths()
    if not main_gguf:
        sys.exit("no model found under models/")
    key = open(os.path.join(REPO, "run", "api-key")).read().strip()
    tmpl = os.path.join(REPO, "run", "tools-template.jinja")

    specs = []
    for part in args.budgets.split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            b, _, m = part.partition(":")
            specs.append((int(b), m))
        else:
            specs.append((int(part), None))
    print(f"\n  Thinking budget sweep   ({len(TASKS)} tasks each, greedy)")
    print("  budget   tokens/turn   thinking   answer    correct   (median)")
    print("  ------   -----------   --------   -------   -------")

    out = {}
    for b, bmsg in specs:
        rows = run_budget(b, args.port, key, cfg, main_gguf, draft, tmpl,
                          budget_msg=bmsg)
        if not rows:
            print(f"  {b:6d}   FAILED TO START")
            continue
        out[(str(b) + ("+msg" if bmsg else ""))] = rows
        tot = statistics.median(r["total"] for r in rows)
        th = statistics.median(r["thinking"] for r in rows)
        ans = statistics.median(r["answer"] for r in rows)
        ok = sum(1 for r in rows if r["correct"])
        label = {-2: "off", -1: "unlimited"}.get(b, str(b))
        if bmsg:
            label += "+msg"
        print(f"  {label:6s}   {tot:11.0f}   {th:8.0f}   {ans:7.0f}   "
              f"{ok}/{len(rows)}")

    with open(args.json, "w") as fh:
        json.dump(out, fh, indent=2)
    print(f"\n  raw -> {args.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
