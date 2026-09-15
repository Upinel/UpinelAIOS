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
"""
Verify that the endpoint's tool calling works, and diagnose the failure that
actually happens in practice.

Run this first if an agent reports something like:

    invalid arguments: missing required property "file_path"

That message is almost never a broken schema. It is a truncated tool call: the
model writes a file's whole contents *inside* the arguments, and if the client's
max_tokens is small the JSON is cut off mid-string. The agent then sees an
incomplete object and reports the first required property it cannot find.

This script measures how many tokens a realistic file-write actually needs, so
the number stops being a guess.

Usage:
  bench/verify-tools.py --url http://127.0.0.1:8000 --model Upinel-AIOS
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

TOOLS = [
    {"type": "function",
     "function": {"name": "write_file",
                  "description": "Write text to a file, creating it if needed",
                  "parameters": {"type": "object",
                                 "properties": {"file_path": {"type": "string"},
                                                "content": {"type": "string"}},
                                 "required": ["file_path", "content"]}}},
    {"type": "function",
     "function": {"name": "read_file",
                  "description": "Read a file and return its contents",
                  "parameters": {"type": "object",
                                 "properties": {"file_path": {"type": "string"}},
                                 "required": ["file_path"]}}},
    {"type": "function",
     "function": {"name": "run_bash",
                  "description": "Run a shell command and return its output",
                  "parameters": {"type": "object",
                                 "properties": {"command": {"type": "string"}},
                                 "required": ["command"]}}},
    {"type": "function",
     "function": {"name": "list_dir",
                  "description": "List the entries in a directory",
                  "parameters": {"type": "object",
                                 "properties": {"path": {"type": "string"}},
                                 "required": ["path"]}}},
]

# A tool whose required fields include a human-readable label. Models frequently
# treat a label as optional metadata and omit it even when the schema says
# required, which the agent then reports as a missing property.
ADVISORY_TOOLS = [
    {"type": "function",
     "function": {"name": "bash",
                  "description": "Run a shell command",
                  "parameters": {"type": "object",
                                 "properties": {
                                     "command": {"type": "string",
                                                 "description": "The command to run"},
                                     "description": {"type": "string",
                                                     "description": "Short description of what this command does"}},
                                 "required": ["command", "description"]}}},
]

# A request that forces a substantial file body, so the tool call is the size
# real agent work produces rather than a one-line toy.
BIG_TASK = ("Create a Python file at /tmp/upinel_stats.py that reads a CSV, "
            "computes the per-column mean and standard deviation, and prints a "
            "formatted table. Use the write_file tool, then run it with run_bash.")
BIG_SYSTEM = "You are a coding agent. Think carefully before acting."

GREEN, RED, YELLOW, DIM, RESET = "\033[32m", "\033[31m", "\033[33m", "\033[2m", "\033[0m"
if not sys.stdout.isatty():
    GREEN = RED = YELLOW = DIM = RESET = ""


def post(url, payload, headers, timeout):
    # Greedy by default. Without this the suite samples randomly, so a check
    # that passes on one run can fail on the next with no change to the model
    # or the server - which is indistinguishable from a real regression and
    # wastes a lot of time chasing. Deterministic runs make a failure mean
    # something. Pass --sampled to measure the real sampling behaviour instead.
    if not globals().get("SAMPLED"):
        payload = {**payload, "temperature": 0, "seed": 1,
                   "top_k": 1, "top_p": 1}
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


class Report:
    def __init__(self):
        self.passed = 0
        self.failed = 0
        self.transport = 0

    def check(self, label, ok, detail="", transport=False):
        mark = f"{GREEN}PASS{RESET}" if ok else f"{RED}FAIL{RESET}"
        print(f"  [{mark}] {label}")
        if detail:
            print(f"         {DIM}{detail}{RESET}")
        if ok:
            self.passed += 1
        else:
            self.failed += 1
            if transport:
                self.transport += 1
        return ok


def first_call(body):
    choice = (body.get("choices") or [{}])[0]
    msg = choice.get("message") or {}
    calls = msg.get("tool_calls") or []
    return choice, msg, (calls[0] if calls else None)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8000")
    ap.add_argument("--model", default="Upinel-AIOS")
    ap.add_argument("--api-key")
    ap.add_argument("--api-key-file")
    ap.add_argument("--timeout", type=int, default=900)
    ap.add_argument("--sampled", action="store_true",
                    help="sample randomly instead of greedily. Reproduces\n"
                         "the flakiness a real client sees, at the cost of\n"
                         "non-deterministic results")
    args = ap.parse_args()
    globals()["SAMPLED"] = args.sampled

    key = args.api_key
    if not key and args.api_key_file:
        try:
            key = open(args.api_key_file).read().strip()
        except OSError:
            pass

    base = args.url.rstrip("/")
    if not base.endswith("/v1"):
        base += "/v1"
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    report = Report()

    print(f"\nTool-calling diagnostic against {base}\n")
    print("  1. Server reachability")
    try:
        req = urllib.request.Request(base + "/models", headers=headers)
        with urllib.request.urlopen(req, timeout=15) as r:
            models = json.loads(r.read())
        ids = [m.get("model") or m.get("id") for m in models.get("models", models.get("data", []))]
        report.check("GET /v1/models", bool(ids), f"serving: {', '.join(str(i) for i in ids)}")
    except Exception as e:                                     # noqa: BLE001
        report.check("GET /v1/models", False, f"{type(e).__name__}: {e}")
        print("\nThe server is not answering. Start it with ./start.sh\n")
        return 1

    # ── 2. a small tool call ─────────────────────────────────────────────────
    print("\n  2. Small tool call")
    small_ok = False
    try:
        body = post(base + "/chat/completions",
                    {"model": args.model, "max_tokens": 512, "tools": TOOLS,
                     "messages": [{"role": "user",
                                   "content": "Create /tmp/demo.txt containing the word hi. "
                                              "Use the write_file tool."}]},
                    headers, args.timeout)
        choice, msg, call = first_call(body)
        small_ok = report.check("response contains tool_calls", call is not None,
                                f"finish_reason={choice.get('finish_reason')!r}"
                                if call is None else "")
        if call:
            fn = call.get("function") or {}
            try:
                parsed = json.loads(fn.get("arguments") or "{}")
                ok = parsed.get("file_path") and parsed.get("content")
                report.check("arguments complete", bool(ok), json.dumps(parsed)[:120])
            except json.JSONDecodeError:
                report.check("arguments complete", False, "arguments are not valid JSON")
            report.check("finish_reason is tool_calls",
                         choice.get("finish_reason") == "tool_calls",
                         f"got {choice.get('finish_reason')!r}")
    except Exception as e:                                     # noqa: BLE001
        report.check("small tool call", False, f"{type(e).__name__}: {e}",
                     transport=isinstance(e, (urllib.error.URLError, OSError, TimeoutError)))

    # ── 3. the failure that actually happens ─────────────────────────────────
    print("\n  3. Large tool call  (this is the one agents hit)")
    print(f"     {DIM}a file write carries the whole file inside the arguments,{RESET}")
    print(f"     {DIM}so its token cost scales with what is being written.{RESET}")
    needed = None
    arg_chars = 0
    try:
        body = post(base + "/chat/completions",
                    {"model": args.model, "max_tokens": 4000, "tools": TOOLS,
                     "messages": [{"role": "system", "content": BIG_SYSTEM},
                                  {"role": "user", "content": BIG_TASK}]},
                    headers, args.timeout)
        choice, msg, call = first_call(body)
        finish = choice.get("finish_reason")
        used = (body.get("usage") or {}).get("completion_tokens")
        if call:
            fn = call.get("function") or {}
            parsed = None
            try:
                parsed = json.loads(fn.get("arguments") or "{}")
            except json.JSONDecodeError:
                pass
            # A required property can go missing two different ways, and they
            # need different fixes, so they are reported separately:
            #   finish=length + unusable JSON -> truncated, raise max_tokens
            #   finish=tool_calls + valid JSON missing a field -> the model
            #     treated that field as optional
            if parsed is None:
                report.check("complete file write returned", False,
                             f"truncated after {used} tokens - raise the client's max_tokens")
            else:
                missing = [k for k in ("file_path", "content") if k not in parsed]
                report.check("complete file write returned",
                             finish == "tool_calls" and not missing,
                             f"{used} tokens used, {len(parsed.get('content') or '')} chars"
                             + (f", MISSING {missing}" if missing else ""))
                needed = used
                # Size of the tool call itself, excluding any thinking the
                # model did first. The starvation run below must undercut the
                # *call*, not the total, or a model that thinks less on the
                # second try slips under the budget and the check passes by
                # accident.
                arg_chars = len(fn.get("arguments") or "")
    except Exception as e:                                     # noqa: BLE001
        report.check("large tool call", False, f"{type(e).__name__}: {e}",
                     transport=isinstance(e, (urllib.error.URLError, OSError, TimeoutError)))

    # ── 4. deliberately starve it, to show the failure mode ──────────────────
    if needed:
        print("\n  4. Reproducing the failure with a small budget")
        # Roughly half the call's own token cost (~4 chars per token), so the
        # arguments cannot fit even if the model skips thinking this time.
        starve = max(64, arg_chars // 8) if arg_chars else max(64, needed // 4)
        try:
            body = post(base + "/chat/completions",
                        {"model": args.model, "max_tokens": starve, "tools": TOOLS,
                         "messages": [{"role": "system", "content": BIG_SYSTEM},
                                      {"role": "user", "content": BIG_TASK}]},
                        headers, args.timeout)
            choice, msg, call = first_call(body)
            finish = choice.get("finish_reason")
            truncated = False
            if call:
                fn = call.get("function") or {}
                try:
                    json.loads(fn.get("arguments") or "{}")
                except json.JSONDecodeError:
                    truncated = True
            # Burning the whole budget before emitting a call at all is also
            # truncation, and is the more common shape in a real harness. The
            # earlier version scored "no call returned" as a pass.
            if not truncated and (finish == "length" or not call):
                truncated = True
            report.check(f"max_tokens={starve} truncates the call (expected)", truncated,
                         "this is what produces 'missing required property' in an agent"
                         if truncated else "did not truncate on this run")
        except Exception as e:                                 # noqa: BLE001
            report.check("starvation run", False, f"{type(e).__name__}: {e}")

    # ── 4b. required fields the model treats as optional ─────────────────────
    print("\n  4b. Advisory required fields  (the 'description' failure)")
    print(f"     {DIM}a label field is easy for a model to skip even when the{RESET}")
    print(f"     {DIM}schema says required, and the agent reports it as missing.{RESET}")
    trials = 10
    kept = 0
    trunc = 0
    for _ in range(trials):
        try:
            # Generous budget on purpose: this check is about which fields the
            # model chooses to emit, not about truncation. A starved budget
            # would report a truncation bug as a schema-honouring bug, and the
            # two have different fixes.
            body = post(base + "/chat/completions",
                        {"model": args.model, "max_tokens": 1500,
                         "tools": ADVISORY_TOOLS,
                         "messages": [{"role": "system", "content": "You are a coding agent."},
                                      {"role": "user",
                                       "content": "Find every Python file that imports "
                                                  "requests and report the count."}]},
                        headers, args.timeout)
            choice, msg, call = first_call(body)
            if not call:
                continue
            fn = call.get("function") or {}
            raw = fn.get("arguments") or "{}"
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                trunc += 1
                continue
            if "description" in parsed and "command" in parsed:
                kept += 1
        except Exception:                                      # noqa: BLE001
            continue
    rate = kept / trials
    # Truncation is a different bug with a different fix (see check 4), so a
    # starved run is not counted against field adherence.
    judged = trials - trunc
    report.check(f"advisory field present in all {judged} completed trials",
                 judged > 0 and kept == judged,
                 f"included in {kept}/{judged} runs"
                 + (f", {trunc} truncated - raise max_tokens" if trunc else ""))
    if kept < judged:
        print(f"         {YELLOW}-> the model treated a required field as optional.{RESET}")
        print(f"         {DIM}   env.conf ships TOOL_TEMPLATE=1, which names every tool's{RESET}")
        print(f"         {DIM}   required fields in the prompt, server-side, for any client.{RESET}")
        print(f"         {YELLOW}   With TOOL_TEMPLATE=0 this is expected: measured 6/9 plain{RESET}")
        print(f"         {YELLOW}   and 3/9 with a generic 'include every field' reminder.{RESET}")
        print(f"         {YELLOW}   Name the fields in the agent's prompt, or turn it back on.{RESET}")

    # ── 5. streaming, the path agents use ────────────────────────────────────
    print("\n  5. Streaming tool call")
    try:
        req = urllib.request.Request(
            base + "/chat/completions",
            data=json.dumps({"model": args.model, "max_tokens": 512, "stream": True,
                             "tools": TOOLS,
                             "messages": [{"role": "user",
                                           "content": "Create /tmp/demo.txt containing hi. "
                                                      "Use the write_file tool."}]}).encode(),
            headers={"Content-Type": "application/json",
                     "Accept": "text/event-stream", **headers})
        name = None
        accum = ""
        finish = None
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    obj = json.loads(data)
                except json.JSONDecodeError:
                    continue
                for c in obj.get("choices") or []:
                    for tc in (c.get("delta") or {}).get("tool_calls") or []:
                        fn = tc.get("function") or {}
                        if fn.get("name"):
                            name = fn["name"]
                        if fn.get("arguments"):
                            accum += fn["arguments"]
                    if c.get("finish_reason"):
                        finish = c["finish_reason"]
        report.check("stream emitted a tool call", name is not None, f"tool={name!r}")
        try:
            json.loads(accum or "{}")
            report.check("assembled arguments are valid JSON", bool(accum), accum[:120])
        except json.JSONDecodeError:
            report.check("assembled arguments are valid JSON", False, accum[-80:])
        report.check("finish_reason is tool_calls", finish == "tool_calls", f"got {finish!r}")
    except Exception as e:                                     # noqa: BLE001
        report.check("streaming tool call", False, f"{type(e).__name__}: {e}",
                     transport=isinstance(e, (urllib.error.URLError, OSError, TimeoutError)))

    # ── 6. multi-turn: feed the result back ──────────────────────────────────
    print("\n  6. Multi-turn tool result round-trip")
    try:
        body = post(base + "/chat/completions",
                    {"model": args.model, "max_tokens": 512, "tools": TOOLS,
                     "messages": [
                         {"role": "user", "content": "Create /tmp/demo.txt containing hi."},
                         {"role": "assistant", "content": None,
                          "tool_calls": [{"id": "call_1", "type": "function",
                                          "function": {"name": "write_file",
                                                       "arguments": json.dumps(
                                                           {"file_path": "/tmp/demo.txt",
                                                            "content": "hi"})}}]},
                         {"role": "tool", "tool_call_id": "call_1",
                          "content": "File written successfully."}]},
                    headers, args.timeout)
        _, msg, _ = first_call(body)
        text = (msg.get("content") or "").strip()
        report.check("model accepts a tool result and answers", bool(text), text[:140])
    except Exception as e:                                     # noqa: BLE001
        report.check("tool result round-trip", False, f"{type(e).__name__}: {e}")

    # ── verdict ──────────────────────────────────────────────────────────────
    print()
    if report.failed == 0:
        print(f"  {GREEN}All {report.passed} checks passed.{RESET}")
        if needed:
            print(f"\n  The endpoint calls tools correctly. A file write of this size")
            print(f"  needs about {needed} tokens, so an agent that writes real files")
            print(f"  should set max_tokens to {needed * 2} or more - the call must fit")
            print(f"  inside the budget alongside anything the model thinks first.")
        print()
        return 0

    print(f"  {RED}{report.failed} check(s) failed{RESET} ({report.passed} passed).")
    if report.transport >= report.failed and report.transport > 0:
        print(f"\n  {YELLOW}These look like connection failures, not model failures.{RESET}")
        print("  The endpoint answered /v1/models but then stopped responding, which")
        print("  usually means it is still loading. Check ./status.sh --once.\n")
        return 1
    print(f"\n  {YELLOW}If a tool call came back truncated or unparseable:{RESET}")
    print("    the client's max_tokens is too small. A file write carries the whole")
    print("    file inside the arguments, so it costs hundreds of tokens. This is the")
    print("    usual cause of 'missing required property' in an agent harness.")
    print("    Raise the agent's max_tokens; the server cap is MAX_RESPONSE_TOKENS.")
    print(f"\n  {YELLOW}If the model chose the wrong tool or invented an argument name:{RESET}")
    print("    that is a model behaviour issue, not a configuration one. Fewer tools")
    print("    and THINKING=off both help.\n")
    return 1


if __name__ == "__main__":
    sys.exit(main())
