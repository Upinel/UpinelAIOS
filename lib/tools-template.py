#!/usr/bin/env python3
"""Generate a tool-aware chat template for UpinelAIOS-GGUF.

Why this exists
---------------
Gemma 4 in llama.cpp honours the *semantics* of a tool schema but not its
``required`` list.  When a tool declares a field the model judges unnecessary
(a boolean that has an obvious default, an optional-looking timeout), the model
silently drops it from the emitted call regardless of where that field sits in
the schema.  An agent harness then rejects the call with::

    Error: invalid arguments: missing required property "file_path"

Measured on Gemma-4-26B-A4B (M5 Pro), 9 trials each, schema with 5-6 required
fields::

    plain system prompt                     6/9 complete
    "MUST include every required field"     3/9 complete   <- actively worse
    explicit field names in the prompt      9/9 complete

The generic reminder hurts: it makes the model deliberate about required-ness
without telling it *which* fields are required.  Naming the fields works.

Naming them client-side means editing every harness.  Naming them in the chat
template means fixing it once, server-side, for every client -- which is the
whole point of a one-click AIOS.

What it does
------------
Reads the model's own ``tokenizer.chat_template`` straight out of the GGUF,
injects a short per-tool reminder listing that tool's required fields, and
writes an augmented template.  ``start.sh`` then passes it to llama-server as
``--chat-template-file``.

Usage
-----
    python3 lib/tools-template.py --gguf <model.gguf> --out run/tools-template.jinja
    python3 lib/tools-template.py --in base.jinja --out run/tools-template.jinja
    python3 lib/tools-template.py --capture http://127.0.0.1:8000 run/base.jinja

Note on Jinja support: llama.cpp uses minja, a small Jinja subset. Some
filters that work in Python Jinja do not exist there - `default` on an object,
for instance, raises "Unknown (built-in) filter 'default' for type Object" at
render time, which makes every tool-using request fail with a 500. Keep the
injected markup simple, and after changing it, make a real tool call before
believing it works: the anchor check cannot catch a semantic error.

Exits non-zero (without writing) if the anchor is missing, so start.sh can fall
back to the model's stock template rather than shipping a broken one.
"""

import argparse
import json
import os
import struct
import sys
import urllib.request

# The exact line that closes the tools block in the Gemma 4 template.  It is
# unique in the template; we inject immediately before it so the reminder lands
# right after the last <tool|> declaration and before <turn|>.
ANCHOR = "        {%- set ns.prev_message_type = 'tool' -%}"

# The pairing rule goes at the very TOP of the system turn, not beside the tool
# declarations. Measured: with it after the tools, thinking=off still emitted
# `justification` alone in 40% of calls, because a rule sitting behind a long
# tool list is a long way from where the model starts writing. The same
# sentence in the system prompt fore-fixed it completely. Position, not wording,
# was the problem.
EARLY_ANCHOR = "    {{- '<|turn>system\\n' -}}"

PAIRING_NOTE = """
    {%- if tools -%}
        {{- '\\nField rule: some fields are only legal alongside another. Never supply `justification` unless you also supply `sandbox_permissions`, and never supply `sandbox_permissions` without `justification` - both or neither, every time. A call with only one of them is rejected. `justification` is not a general explanation field; use `description` for that.\\n' -}}
    {%- endif -%}
"""

REMINDER = """
        {%- for tool in tools -%}
            {%- set _req = tool['function']['parameters']['required'] | default([]) -%}
            {%- if _req -%}
                {{- '\\nAll of the following fields are MANDATORY in every ' + tool['function']['name'] + ' call and must never be omitted, even when a value seems obvious or optional: ' + (_req | join(', ')) + '.' -}}
            {%- endif -%}
        {%- endfor -%}"""


# ---------------------------------------------------------------------------
# Minimal GGUF metadata reader -- enough to pull tokenizer.chat_template out.
# ---------------------------------------------------------------------------

_SIZES = {0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8}


def _read_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", "replace")


def _read_value(f, vtype):
    if vtype == 8:
        return _read_string(f)
    if vtype == 9:  # array
        (etype,) = struct.unpack("<I", f.read(4))
        (count,) = struct.unpack("<Q", f.read(8))
        return [_read_value(f, etype) for _ in range(count)]
    size = _SIZES.get(vtype)
    if size is None:
        raise ValueError(f"unknown GGUF value type {vtype}")
    raw = f.read(size)
    fmt = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I",
           5: "<i", 6: "<f", 7: "<B", 10: "<Q", 11: "<q", 12: "<d"}[vtype]
    return struct.unpack(fmt, raw)[0]


def gguf_template(path):
    """Return tokenizer.chat_template from a GGUF file, or None."""
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise ValueError(f"{path}: not a GGUF file")
        struct.unpack("<I", f.read(4))          # version
        struct.unpack("<Q", f.read(8))          # tensor count
        (kv_count,) = struct.unpack("<Q", f.read(8))
        for _ in range(kv_count):
            key = _read_string(f)
            (vtype,) = struct.unpack("<I", f.read(4))
            value = _read_value(f, vtype)
            if key == "tokenizer.chat_template":
                return value
    return None


def capture(url, out_path, api_key=None):
    """Save the chat template of a running llama-server to out_path."""
    req = urllib.request.Request(url.rstrip("/") + "/props")
    if api_key:
        req.add_header("Authorization", "Bearer " + api_key)
    with urllib.request.urlopen(req, timeout=60) as r:
        props = json.loads(r.read())
    tmpl = props.get("chat_template")
    if not tmpl:
        sys.exit("capture: server reported no chat_template")
    with open(out_path, "w") as f:
        f.write(tmpl)
    print(f"captured {len(tmpl)} chars -> {out_path}")


def patch(template):
    """Inject both reminders. Returns (new_template, n_anchors_found)."""
    if ANCHOR not in template or EARLY_ANCHOR not in template:
        return None, 0
    if template.count(ANCHOR) != 1 or template.count(EARLY_ANCHOR) != 1:
        return None, -1
    out = template.replace(ANCHOR, REMINDER + ANCHOR, 1)
    out = out.replace(EARLY_ANCHOR, EARLY_ANCHOR + PAIRING_NOTE, 1)
    return out, 2


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--gguf", help="read the template from this GGUF")
    src.add_argument("--in", dest="inp", help="read the template from this file")
    src.add_argument("--capture", metavar="URL",
                     help="capture the template from a running llama-server")
    ap.add_argument("--out", help="write the patched template here")
    ap.add_argument("--api-key-file", help="file holding the bearer token")
    args = ap.parse_args()

    if args.capture:
        if not args.out:
            ap.error("--capture requires --out")
        key = None
        if args.api_key_file and os.path.exists(args.api_key_file):
            key = open(args.api_key_file).read().strip()
        capture(args.capture, args.out, key)
        return

    if args.gguf:
        template = gguf_template(args.gguf)
        if template is None:
            sys.exit(f"{args.gguf}: no tokenizer.chat_template in metadata")
    else:
        template = open(args.inp).read()

    patched, found = patch(template)
    if patched is None:
        sys.exit(f"anchor {'ambiguous' if found == -1 else 'not found'} "
                 f"in template; refusing to write a broken template")

    if not args.out:
        sys.stdout.write(patched)
        return

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(patched)

    # Verify the reminder actually landed.
    if REMINDER not in open(args.out).read():
        sys.exit(f"verification failed: reminder missing from {args.out}")
    print(f"patched template ({len(template)} -> {len(patched)} chars) -> {args.out}")


if __name__ == "__main__":
    main()
