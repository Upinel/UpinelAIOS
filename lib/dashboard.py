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
Real-time dashboard for the UpinelAIOS server.

  ./status.sh                 live dashboard, 1s refresh, Ctrl-C to exit
  ./status.sh --once          one-shot summary (scripts, logs)
  ./status.sh --json          machine-readable snapshot
  ./status.sh --interval 2    slower refresh
  ./status.sh --power         add ANE/GPU power via sudo powermetrics

Where each number comes from, and what it honestly means:

  CPU     host_statistics(HOST_CPU_LOAD_INFO) tick deltas. Exact, no sudo.
  GPU     IOKit IOAccelerator "Device Utilization %" via ioreg. This is the
          GPU's own hardware busy counter, readable without sudo.
  ANE     Apple does not expose the Neural Engine without powermetrics, which
          needs root. MLX is GPU-only in any case, so the ANE is genuinely
          idle for this workload -- it is shown as "--" rather than faked.
          With --power (or passwordless sudo) the real figure is read.
  RAM     vm_stat pages, sysctl for swap. Wired memory is what matters here:
          it is the MLX allocation and macOS cannot reclaim it.
  SERVER  MTPLX /health, /admin/sessions and /metrics.
"""

import argparse
import ctypes
import ctypes.util
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.request
from collections import deque

# ── terminal ─────────────────────────────────────────────────────────────────
USE_COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
# True when we can draw in place with cursor control. We deliberately do
# NOT switch to the alternate screen buffer: the frame is sized to fit the
# window exactly, so leaving the previous shell output in scrollback is a
# feature, not pollution.
TTY_MODE = sys.stdout.isatty()


def c(code):
    return code if USE_COLOR else ""


RESET, BOLD, DIM = c("\033[0m"), c("\033[1m"), c("\033[2m")
RED, GREEN, YELLOW, BLUE, CYAN, MAGENTA = (
    c("\033[31m"), c("\033[32m"), c("\033[33m"),
    c("\033[34m"), c("\033[36m"), c("\033[35m"))
HOME, CLR_EOL, CLR_EOS = "\033[H", "\033[K", "\033[J"
HIDE_CURSOR, SHOW_CURSOR = "\033[?25l", "\033[?25h"

# Window/tab title. OSC 0 sets icon + title, OSC 2 the window title; Terminal
# and iTerm2 both honour them. Re-asserted every frame so nothing else can
# claim the heading.
WINDOW_TITLE = "UpinelAIOS Status"
SET_TITLE = f"\033]0;{WINDOW_TITLE}\007\033]2;{WINDOW_TITLE}\007"
CLEAR_TITLE = "\033]0;\007\033]2;\007"


def term_size():
    sz = shutil.get_terminal_size((100, 30))
    return sz.columns, sz.lines


# ── keyboard input ───────────────────────────────────────────────────────────
class Keys:
    """
    Single-keypress input in cbreak mode.

    cbreak rather than raw: it turns off line buffering so a key arrives
    immediately, while leaving ISIG alone so Ctrl-C still raises SIGINT and the
    dashboard can shut down cleanly. Terminal attributes are always restored,
    including on an exception, because leaving a shell in cbreak mode is a
    genuinely unpleasant state to hand back to someone.
    """

    def __init__(self, enabled):
        self.enabled = bool(enabled) and sys.stdin.isatty()
        self._fd = None
        self._saved = None

    def __enter__(self):
        if not self.enabled:
            return self
        try:
            import termios
            import tty
            self._fd = sys.stdin.fileno()
            self._saved = termios.tcgetattr(self._fd)
            tty.setcbreak(self._fd)
        except Exception:
            self.enabled = False
        return self

    def __exit__(self, *exc):
        self.restore()
        return False

    def restore(self):
        if self._fd is None or self._saved is None:
            return
        try:
            import termios
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._saved)
        except Exception:
            pass
        self._fd = None
        self._saved = None

    def poll(self, timeout):
        """Wait up to `timeout` seconds for one key. Returns str or None."""
        if not self.enabled:
            time.sleep(max(0.0, timeout))
            return None
        try:
            import select
            ready, _, _ = select.select([sys.stdin], [], [], max(0.0, timeout))
        except (OSError, ValueError):
            return None
        if not ready:
            return None
        try:
            ch = sys.stdin.read(1)
        except (OSError, ValueError):
            return None
        if ch == "\x1b":
            # Report Escape immediately rather than trying to classify the
            # sequence. Waiting to see whether more bytes follow an ESC is a
            # coin flip against terminal buffering, and getting it wrong means
            # the cancel key silently does nothing - which is how an accidental
            # model switch got committed during testing. Drain anything already
            # queued (an arrow key's trailing bytes) and treat it as Escape:
            # cancel is only meaningful while a toggle is pending, so a stray
            # arrow key cancelling a pending action is harmless.
            try:
                import select
                while select.select([sys.stdin], [], [], 0.005)[0]:
                    if not sys.stdin.read(1):
                        break
            except (OSError, ValueError):
                pass
            return "ESC"
        return ch


# ── pending-action state ─────────────────────────────────────────────────────
# A toggle does not apply on the keystroke that chose it. It arms a countdown
# and applies when the countdown expires, so pressing the key again cycles on
# without committing, and Enter commits early. That is what makes "press t until
# you see the level you want" work.
SETTLE_SECONDS = 2.0


class Pending:
    def __init__(self):
        self.kind = None          # "thinking" | "model"
        self.value = None         # level, or repo id
        self.deadline = 0.0
        self.from_value = None    # what it will change away from

    def arm(self, kind, value, from_value=None, seconds=SETTLE_SECONDS):
        self.kind = kind
        self.value = value
        self.from_value = from_value
        self.deadline = time.time() + seconds

    def clear(self):
        self.kind = self.value = self.from_value = None
        self.deadline = 0.0

    @property
    def active(self):
        return self.kind is not None

    def remaining(self):
        return max(0.0, self.deadline - time.time())

    def expired(self):
        return self.active and self.remaining() <= 0


# ── sampling helpers ─────────────────────────────────────────────────────────
def run(cmd, timeout=5):
    """
    Run a probe command, return stdout or '' on any failure.

    start_new_session=True is load-bearing, not hygiene. Without it each probe
    shares our session and controlling terminal, and Terminal.app titles the
    window from whatever process group is in front of the tty - so spawning
    lsof, ioreg and pmset once a second made the window heading flicker between
    "lsof", "ioreg", "python3" and back. setsid() detaches them completely, so
    the terminal never sees them at all.
    """
    try:
        p = subprocess.run(cmd, capture_output=True, text=True,
                           timeout=timeout, start_new_session=True)
        return p.stdout
    except (subprocess.SubprocessError, OSError):
        return ""


PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")


def vm_stat():
    """Parse vm_stat into a dict of page counts."""
    out = run(["vm_stat"])
    stats = {}
    for line in out.splitlines():
        m = re.match(r'"?([^":]+)"?:\s+(\d+)', line.strip())
        if m:
            stats[m.group(1).strip()] = int(m.group(2))
    return stats


class CPUSampler:
    """CPU utilisation from Mach host_statistics tick counters."""

    HOST_CPU_LOAD_INFO = 3
    CPU_STATE_MAX = 4

    def __init__(self):
        self.ok = False
        try:
            libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
            self.libc = libc
            libc.mach_host_self.restype = ctypes.c_uint
            libc.host_statistics.argtypes = [
                ctypes.c_uint, ctypes.c_int, ctypes.c_void_p,
                ctypes.POINTER(ctypes.c_uint)]
            self.host = libc.mach_host_self()
            self.ok = True
        except Exception:
            return
        # Mach reports cumulative ticks, so the first delta is always zero and
        # a single-sample reading shows "--". Take a short baseline now so even
        # the first rendered frame carries a real percentage.
        self.prev = self._read()
        if self.prev is not None:
            time.sleep(0.15)
            second = self._read()
            if second is not None:
                self.prev = second

    def _read(self):
        buf = (ctypes.c_uint32 * (self.CPU_STATE_MAX))()
        count = ctypes.c_uint(self.CPU_STATE_MAX)
        rc = self.libc.host_statistics(
            self.host, self.HOST_CPU_LOAD_INFO,
            ctypes.byref(buf), ctypes.byref(count))
        if rc != 0:
            return None
        return list(buf)

    def sample(self):
        """Return (total_pct, user_pct, sys_pct) since the previous call."""
        if not self.ok:
            return None
        cur = self._read()
        if cur is None or self.prev is None:
            self.prev = cur
            return None
        deltas = [cur[i] - self.prev[i] for i in range(self.CPU_STATE_MAX)]
        self.prev = cur
        total = sum(deltas)
        if total <= 0:
            return None
        user = deltas[0] + deltas[3]      # USER + NICE
        sysc = deltas[1]                  # SYSTEM
        busy = user + sysc
        return (100.0 * busy / total, 100.0 * user / total, 100.0 * sysc / total)


class GPUSampler:
    """
    GPU utilisation from IOKit. The accelerator publishes its own busy counter
    as "Device Utilization %"; ioreg can read it without privileges.
    """

    PATTERNS = {
        "device": re.compile(r'"Device Utilization %"=(\d+)'),
        "renderer": re.compile(r'"Renderer Utilization %"=(\d+)'),
        "tiler": re.compile(r'"Tiler Utilization %"=(\d+)'),
        "vram_alloc": re.compile(r'"Allocated PB Size"=(\d+)'),
    }

    def __init__(self):
        self.available = self._probe()

    def _probe(self):
        return bool(run(["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"],
                        timeout=4).strip())

    def sample(self):
        out = run(["ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"],
                  timeout=4)
        if not out:
            return None
        result = {}
        for key, pat in self.PATTERNS.items():
            m = pat.search(out)
            if m:
                result[key] = int(m.group(1))
        return result or None


class PowerSampler:
    """
    Optional ANE/GPU power via powermetrics. Needs root; we only use it when
    sudo is already passwordless, so the dashboard never prompts mid-run.
    """

    def __init__(self):
        self.available = False
        try:
            probe = subprocess.run(["sudo", "-n", "true"], capture_output=True,
                                   timeout=3, start_new_session=True)
            self.available = (probe.returncode == 0)
        except (subprocess.SubprocessError, OSError):
            self.available = False

    def sample(self):
        if not self.available:
            return None
        out = run(["sudo", "-n", "powermetrics", "--samplers", "gpu_power,ane_power",
                   "-n", "1", "-i", "200"], timeout=8)
        if not out:
            return None
        res = {}
        for key, pat in (
            ("gpu_busy", r"GPU HW active frequency.*?(\d+) MHz"),
            ("gpu_residency", r"GPU Active Residency\s+([\d.]+)%"),
            ("ane_power", r"ANE Power:\s+([\d.]+) mW"),
            ("gpu_power", r"GPU Power:\s+([\d.]+) mW"),
        ):
            m = re.search(pat, out)
            if m:
                res[key] = float(m.group(1))
        return res or None


def swap_usage():
    out = run(["sysctl", "-n", "vm.swapusage"])
    m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M\s+free = ([\d.]+)M", out)
    if not m:
        return None
    return {"total_gb": float(m.group(1)) / 1024,
            "used_gb": float(m.group(2)) / 1024,
            "free_gb": float(m.group(3)) / 1024}


def proc_stats(pid):
    out = run(["ps", "-o", "rss=,%cpu=,etime=", "-p", str(pid)], timeout=4)
    parts = out.split()
    if len(parts) < 3:
        return None
    return {"rss_gb": int(parts[0]) / 1024 / 1024,
            "cpu_pct": float(parts[1]),
            "elapsed": parts[2]}


def thermal_state():
    out = run(["pmset", "-g", "therm"], timeout=4)
    if "No thermal warning level has been recorded" in out:
        return "nominal"
    m = re.search(r"CPU_Scheduler_Limit\s*=\s*(\d+)", out)
    if m and int(m.group(1)) < 100:
        return f"throttled ({m.group(1)}%)"
    return "elevated"


# ── server sampling ──────────────────────────────────────────────────────────
class ServerSampler:
    """
    llama.cpp server telemetry.

    /health   liveness
    /props    model identity and slot count
    /slots    live per-slot state: prefill progress, ctx, speculative on/off
    /metrics  Prometheus counters (requires --metrics, which start.sh passes)

    Cumulative token totals are parsed from the server log, because llama.cpp
    exposes per-request timings there rather than as lifetime counters.
    """

    def __init__(self, base, api_key, model_dir=None, pid_file=None,
                 port=None, log_file=None):
        self.base = base.rstrip("/")
        self.root = self.base[:-3] if self.base.endswith("/v1") else self.base
        self.key = api_key
        self.model_dir = model_dir
        self.pid_file = pid_file
        self.port = port
        self.log_file = log_file

    def _headers(self):
        return {"Authorization": f"Bearer {self.key}"} if self.key else {}

    def _get(self, path, timeout=4):
        try:
            req = urllib.request.Request(self.root + path, headers=self._headers())
            with urllib.request.urlopen(req, timeout=timeout) as r:
                raw = r.read().decode("utf-8", "replace")
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            return None
        if path == "/metrics":
            return raw
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return None

    def health(self):
        h = self._get("/health")
        # llama.cpp answers {"status":"ok"}; older builds used {"ok":true}.
        if isinstance(h, dict) and (h.get("status") == "ok" or h.get("ok")):
            return h
        return None

    def props(self):
        return self._get("/props")

    def slots(self):
        d = self._get("/slots")
        return d if isinstance(d, list) else None

    def metrics(self):
        raw = self._get("/metrics")
        if not isinstance(raw, str):
            return {}
        out = {}
        for line in raw.splitlines():
            if line.startswith("#") or " " not in line:
                continue
            key, _, value = line.rpartition(" ")
            try:
                out[key.strip()] = float(value)
            except ValueError:
                continue
        return out

    def clients(self):
        """
        TCP peers currently connected to the server port.

        llama.cpp does not record the client address on a request, so this is
        read from the socket table: it answers "who is connected", not "which
        request came from where".

        lsof prints one row per socket endpoint, so a single connection appears
        twice - once owned by the server and once by the client. Only the client
        side is kept, so the panel reports who is talking to us rather than
        naming our own server process back at the user.
        """
        if not self.port:
            return []
        port = int(self.port)
        out = run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:ESTABLISHED"],
                  timeout=5)
        if not out:
            return []
        server_pid = self.server_pid()
        peers = {}
        for line in out.splitlines()[1:]:
            parts = line.split()
            if len(parts) < 9:
                continue
            try:
                pid = int(parts[1])
            except (ValueError, IndexError):
                continue
            if pid == server_pid:
                continue
            name = parts[8]
            if "->" not in name:
                continue
            _, remote = name.split("->", 1)
            peer_ip = remote.rsplit(":", 1)[0]
            if not peer_ip:
                continue
            entry = peers.setdefault(peer_ip, {"conns": 0, "procs": set()})
            entry["conns"] += 1
            entry["procs"].add(re.sub(r"\\x([0-9a-fA-F]{2})",
                                      lambda m: chr(int(m.group(1), 16)),
                                      parts[0]))
        result = []
        for ip, entry in sorted(peers.items()):
            loopback = ip.startswith("127.") or ip == "::1"
            result.append({"ip": ip, "conns": entry["conns"],
                           "procs": sorted(entry["procs"]), "local": loopback})
        return result

    def server_pid(self):
        if self.pid_file and os.path.exists(self.pid_file):
            try:
                return int(open(self.pid_file).read().strip())
            except (OSError, ValueError):
                return None
        return None

    # ── log parsing ──────────────────────────────────────────────────────────
    # llama.cpp writes one timing block per completed request:
    #   n_gen = 167, tg = 54.92 t/s, tg_3s = 55.25 t/s
    #   eval time = 4704.36 ms / 256 tokens (..., 54.21 tokens per second)
    #   draft acceptance = 0.80851 (114 accepted / 141 generated), mean len = 1.81
    LOG_RATE = re.compile(r"n_gen =\s*(\d+), tg =\s*([\d.]+) t/s")
    LOG_EVAL = re.compile(r"eval time =\s*[\d.]+ ms /\s*(\d+) tokens")
    LOG_PROMPT = re.compile(r"prompt eval time =\s*[\d.]+ ms /\s*(\d+) tokens")
    LOG_ACCEPT = re.compile(r"draft acceptance = ([\d.]+)")

    def log_stats(self, cache):
        """
        Incrementally parse the server log.

        Returns lifetime decode/prompt token counts plus the most recent live
        rate and draft acceptance. Reads only new bytes each call, and resets
        when the log is rotated.
        """
        if not self.log_file or not os.path.exists(self.log_file):
            return None
        try:
            size = os.path.getsize(self.log_file)
        except OSError:
            return None
        offset = cache.get("offset", 0)
        if size < offset:
            cache.clear()
            offset = 0
        stats = {
            "decode_tokens": cache.get("decode_tokens", 0),
            "prompt_tokens": cache.get("prompt_tokens", 0),
            "requests": cache.get("requests", 0),
            "last_rate": cache.get("last_rate"),
            "last_accept": cache.get("last_accept"),
        }
        try:
            with open(self.log_file, "r", errors="replace") as fh:
                fh.seek(offset)
                for line in fh:
                    if "print_timing" not in line:
                        continue
                    m = self.LOG_EVAL.search(line)
                    if m:
                        stats["decode_tokens"] += int(m.group(1))
                        stats["requests"] += 1
                    m = self.LOG_PROMPT.search(line)
                    if m:
                        stats["prompt_tokens"] += int(m.group(1))
                    m = self.LOG_RATE.search(line)
                    if m:
                        stats["last_rate"] = float(m.group(2))
                    m = self.LOG_ACCEPT.search(line)
                    if m:
                        stats["last_accept"] = float(m.group(1))
                cache["offset"] = fh.tell()
        except OSError:
            return None
        cache.update(stats)
        return stats


# ── rendering ────────────────────────────────────────────────────────────────
def bar(pct, width=16, warn=75, crit=90):
    """A horizontal meter. Returns text; caller adds colour."""
    pct = max(0.0, min(100.0, float(pct)))
    filled = int(round(pct * width / 100.0))
    return "\u2588" * filled + "\u2591" * (width - filled)


def color_for(pct, warn=75, crit=90):
    if pct >= crit:
        return RED
    if pct >= warn:
        return YELLOW
    return GREEN


SPARK = " \u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"


def sparkline(values, width=40):
    vals = list(values)[-width:]
    if not vals:
        return DIM + "\u00b7" * width + RESET
    hi = max(vals)
    lo = min(vals)
    if hi == lo:
        # Flat series: draw a steady line rather than dividing by zero.
        return DIM + "\u2585" * len(vals) + "\u00b7" * (width - len(vals)) + RESET
    span = (hi - lo) or 1.0
    out = []
    for v in vals:
        idx = int(round((v - lo) / span * 8))
        out.append(SPARK[max(1, min(8, idx))])
    pad = "\u00b7" * (width - len(out))
    return pad + "".join(out)


CHART_BLOCKS = "\u2581\u2582\u2583\u2584\u2585\u2586\u2587\u2588"

# Box-drawing glyphs as named constants rather than inline escapes.
#
# These used to sit inside f-string replacement fields - f"{SHADE * barw}" -
# which is only legal from Python 3.12 (PEP 701). On anything older the file
# does not even parse: "SyntaxError: f-string expression part cannot include a
# backslash", pointing at a line that looks perfectly fine. The failure lands
# on whatever machine happens to have an older python3, so it shows up on some
# testing devices and not others. Keeping the literals out of the fields makes
# the file parse on every supported version.
SHADE = "\u2591"   # ░  light shade, for empty gauge cells
RULE = "\u2500"    # ─  horizontal rule


def line_chart(values, width, height=4):
    """
    Draw a filled area chart `height` rows tall, and return
    (rows, axis_lo, axis_hi).

    The y-axis is zoomed to the data's own range rather than anchored at zero.
    A throughput chart anchored at zero is a flat wall of blocks: 14-23 t/s
    against a 0-23 axis is all in the top eighth, so the shape disappears. The
    returned bounds are printed next to the chart so the zoom is explicit
    rather than implied.

    Each column is a bar of eighths, so four rows still resolve 32 levels.
    """
    vals = [float(v) for v in values][-width:]
    if not vals:
        return [" " * width for _ in range(height)], 0.0, 0.0
    lo_raw, hi_raw = min(vals), max(vals)
    if hi_raw <= lo_raw:
        # Flat series: centre it in the band rather than dividing by zero.
        lo, hi = lo_raw * 0.9, hi_raw * 1.1 + 1e-6
    else:
        span = hi_raw - lo_raw
        lo = max(0.0, lo_raw - span * 0.35)
        hi = hi_raw + span * 0.15

    vals = [0.0] * (width - len(vals)) + vals
    span = (hi - lo) or 1.0

    rows = [[" "] * width for _ in range(height)]
    for x, v in enumerate(vals):
        eighths = int(round(max(0.0, (v - lo)) / span * height * 8))
        full, part = divmod(eighths, 8)
        for r in range(full):
            y = height - 1 - r
            if 0 <= y < height:
                rows[y][x] = "\u2588"
        if part and full < height:
            y = height - 1 - full
            if 0 <= y < height:
                rows[y][x] = CHART_BLOCKS[part - 1]
    return ["".join(r) for r in rows], lo, hi


def num(value, default=0.0):
    """
    Coerce a telemetry value to float.

    MTPLX publishes `null` for a field it has not measured yet - most often
    decode_tok_s while a long prompt is still prefilling - and JSON `null`
    becomes Python None. `d.get(key, 0)` does NOT protect against that: the key
    is present, so the default is never used and the None flows into a format
    specifier and raises. Everything numeric that comes from telemetry goes
    through here.
    """
    if value is None:
        return default
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def lp_num(value, default=0):
    """Integer coercion for a telemetry count."""
    try:
        return int(num(value, default))
    except (TypeError, ValueError):
        return default


def fmt_num(value, spec=".1f", suffix="", default="--"):
    """Format a possibly-None telemetry number, falling back to `default`."""
    if value is None:
        return default
    try:
        return format(float(value), spec) + suffix
    except (TypeError, ValueError, ValueError):
        return default


def human_gb(gb):
    gb = num(gb)
    if gb >= 100:
        return f"{gb:.0f}G"
    if gb >= 10:
        return f"{gb:.1f}G"
    return f"{gb:.2f}G"


def col_widths(left_lines, right_lines, total_width):
    """Left/right column widths for a two-column block."""
    gutter = 3
    lw = max((len(strip_ansi(s)) for s in left_lines), default=0) + gutter
    lw = max(24, min(lw, (total_width * 62) // 100))
    return lw, total_width - lw


def two_col(left_lines, right_lines, total_width):
    """Lay two lists of strings side by side."""
    lw, rw = col_widths(left_lines, right_lines, total_width)
    rows = max(len(left_lines), len(right_lines))
    out = []
    for i in range(rows):
        l = left_lines[i] if i < len(left_lines) else ""
        r = right_lines[i] if i < len(right_lines) else ""
        pad = " " * max(0, lw - len(strip_ansi(l)))
        # Truncate the right column so we never wrap and corrupt the frame.
        r = truncate(r, rw)
        out.append(l + pad + r)
    return out


ANSI_RE = re.compile(r"\033\[[0-9;?]*[a-zA-Z]")


def strip_ansi(s):
    return ANSI_RE.sub("", s)


def truncate(s, width):
    if len(strip_ansi(s)) <= width:
        return s
    # Colour-safe truncation: drop from the plain-text end.
    out, visible = [], 0
    i = 0
    while i < len(s):
        m = ANSI_RE.match(s, i)
        if m:
            out.append(m.group(0))
            i = m.end()
            continue
        if visible >= width - 1:
            out.append("\u2026")
            break
        out.append(s[i])
        visible += 1
        i += 1
    return "".join(out) + RESET


class Dashboard:
    def __init__(self, cfg, args, cfg_path=None):
        self.cfg = cfg
        self.args = args
        # Where the payload came from, so a model or engine switch can be
        # noticed without restarting this process. See _reload_cfg().
        self._cfg_path = cfg_path
        self._cfg_mtime = self._stat_cfg(cfg_path)
        self.cpu = CPUSampler()
        self.gpu = GPUSampler()
        self.power = PowerSampler() if args.power else None
        self.server = ServerSampler(cfg["base"], cfg["api_key"],
                                    cfg.get("model_dir"), cfg.get("pid_file"),
                                    port=cfg.get("port"),
                                    log_file=cfg.get("log_file"))
        self.hist_cpu = deque(maxlen=80)
        self.hist_gpu = deque(maxlen=80)
        self.hist_tps = deque(maxlen=80)
        self.t0 = time.time()
        self.last_good = 0.0
        self._log_cache = {}
        self.log_totals = None
        # Cached probes. lsof and pmset are not free, and neither the client
        # list nor the thermal state changes meaningfully at 1 Hz - spawning
        # them every second just churns the process table for no new data.
        self._clients_cache = (0, [])
        self._thermal_cache = (0, "unknown")
        self._frame = 0
        self._error_count = 0
        self._last_error = ""
        self.pending = Pending()
        self.status_note = ""        # one-line feedback under the panels
        self.status_note_until = 0.0
        self.levels = ["off", "minimal", "low", "high"]
        self._cached_thinking = None
        self._thinking_checked = 0.0
        self._pending_thinking = None
        self._health_cache = None
        self._props_cache = None
        self._switching_to = None

    # ── live config reload ───────────────────────────────────────────────────
    @staticmethod
    def _stat_cfg(path):
        try:
            return os.path.getmtime(path)
        except (OSError, TypeError):
            return None

    def _reload_cfg(self):
        """Adopt a new model/engine without being restarted.

        ./start.sh and ./restart.sh rewrite the payload when they launch, so a
        dashboard left open across a switch - which is the normal way to use it
        while trying models - shows what is serving now instead of what was
        serving when it started. Everything the config feeds has to be rebuilt
        or reset, or the panels would mix the old model's numbers with the new
        model's name.
        """
        path = self._cfg_path
        mtime = self._stat_cfg(path)
        if mtime is None or mtime == self._cfg_mtime:
            return False
        try:
            with open(path, encoding="utf-8") as fh:
                new = json.load(fh)
        except (OSError, ValueError):
            # A half-written file is not worth crashing over; try again next tick.
            return False
        self._cfg_mtime = mtime
        if new == self.cfg:
            return False

        self.cfg = new
        self.server = ServerSampler(
            new["base"], new.get("api_key", ""), new.get("model_dir"),
            new.get("pid_file"), port=new.get("port"),
            log_file=new.get("log_file"))
        # Anything derived from the previous model is now wrong.
        self._log_cache = {}
        self.log_totals = None
        self._health_cache = None
        self._props_cache = None
        self._clients_cache = (0, [])
        self._cached_thinking = None
        self._thinking_checked = 0.0
        self._pending_thinking = None
        self.hist_tps.clear()
        self.status_note = (
            f"switched to {new.get('model_repo', '?')} ({new.get('engine', '?')})")
        self.status_note_until = time.time() + 6
        return True

    # ── model discovery ──────────────────────────────────────────────────────
    def downloaded_models(self):
        """
        Models present on disk, newest-relevant first.

        Directory names are owner--name, which is how fetch-model.sh lays them
        out, so the repo id is recoverable without reading any manifest.
        """
        root = self.cfg.get("models_dir")
        if not root or not os.path.isdir(root):
            return []
        found = []
        try:
            for name in sorted(os.listdir(root)):
                path = os.path.join(root, name)
                if not os.path.isdir(path) or "--" not in name:
                    continue
                if not any(f.endswith(".gguf") for f in os.listdir(path)):
                    continue
                found.append({"repo": name.replace("--", "/", 1), "dir": path})
        except OSError:
            return []
        return found

    def loaded_model(self):
        """
        The repo the server actually has loaded, from /health model_path.

        The dashboard's config is a snapshot taken at launch. After an in-app
        model switch that snapshot is stale, so anything showing "which model is
        this" has to come from the server, not from cfg.
        """
        prop = self._props_cache or {}
        path = prop.get("model_path") or ""
        # The launcher lays models out as models/owner--name/weights.gguf, so
        # walk up until a directory carries the owner--name encoding.
        for part in reversed(path.split(os.sep)):
            if "--" in part:
                return part.replace("--", "/", 1)
        return self.cfg.get("model_repo", "")

    def shown_model(self):
        """
        What to print as the current model: the loaded one when the server is
        up, what we are switching to while it restarts, and the configured value
        when nothing is running.
        """
        if self._switching_to:
            return self._switching_to
        if self._health_cache and self._props_cache:
            return self.loaded_model()
        return self.cfg.get("model_repo", "")

    def short_model(self, repo):
        """A label that fits in a footer: the tail of the repo id."""
        tail = repo.split("/")[-1]
        for marker in ("Uncensored-HauhauCS-Aggressive-MTPLX-",
                       "Uncensored-MTPLX-", "-MTPLX-Optimized-Speed", "-MTPLX"):
            if marker in tail:
                head = tail.split(marker)[0].rstrip("-_.")
                if head:
                    return head if len(head) <= 22 else head[:21] + "…"
        return tail if len(tail) <= 26 else tail[:25] + "…"

    # ── live actions ─────────────────────────────────────────────────────────
    def note(self, text, seconds=4.0):
        self.status_note = text
        self.status_note_until = time.time() + seconds

    def current_thinking(self):
        """
        The configured thinking level.

        Unlike MTPLX, llama.cpp has no live settings endpoint: thinking is a
        chat-template kwarg handed to the server at launch, so env.conf is the
        source of truth and changing it needs a restart.
        """
        level = self._pending_thinking or self.cfg.get("thinking", "minimal")
        return level if level in self.levels else "minimal"

    def apply_thinking(self, level):
        """
        Write the level to env.conf and restart.

        llama.cpp reads chat-template kwargs at launch, so there is no live
        path here - the honest behaviour is to persist the choice and reload,
        which is what ./status.sh --thinking does from the command line too.
        """
        env_file = self.cfg.get("env_file")
        repo_dir = self.cfg.get("repo_dir")
        if not env_file or not repo_dir:
            self.note(f"{RED}Cannot change thinking: env.conf path unknown{RESET}", 6)
            return
        try:
            src = open(env_file).read()
            src, n = re.subn(r'^THINKING=.*$', f'THINKING="{level}"', src,
                             count=1, flags=re.M)
            if n != 1:
                raise OSError("THINKING= not found in env.conf")
            open(env_file, "w").write(src)
        except OSError as exc:
            self.note(f"{RED}Could not write env.conf: {exc}{RESET}", 8)
            return
        self._pending_thinking = level
        self.cfg["thinking"] = level
        try:
            subprocess.Popen([os.path.join(repo_dir, "restart.sh")],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as exc:
            self.note(f"{RED}Could not restart: {exc}{RESET}", 8)
            return
        self.note(f"{GREEN}thinking -> {level}{RESET}  "
                  f"{DIM}reloading to apply{RESET}", 12)

    def apply_model(self, repo):
        """
        Persist the choice and restart. The restart is detached, so the
        dashboard survives it and simply shows "not running" until the new
        model finishes loading.
        """
        env_file = self.cfg.get("env_file")
        repo_dir = self.cfg.get("repo_dir")
        if not env_file or not repo_dir:
            self.note(f"{RED}Cannot switch models: env.conf path unknown{RESET}", 6)
            return
        try:
            import re as _re
            src = open(env_file).read()
            src, n = _re.subn(r'^MODEL=.*$', f'MODEL="{repo}"', src,
                              count=1, flags=_re.M)
            if n != 1:
                raise OSError("MODEL= not found in env.conf")
            open(env_file, "w").write(src)
        except OSError as exc:
            self.note(f"{RED}Could not write env.conf: {exc}{RESET}", 8)
            return
        self._switching_to = repo
        self._health_cache = None
        self.note_target = repo
        try:
            subprocess.Popen([os.path.join(repo_dir, "restart.sh")],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL,
                             stdin=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as exc:
            self.note(f"{RED}Could not restart: {exc}{RESET}", 8)
            return
        self.note(f"{GREEN}switching to {self.short_model(repo)}{RESET}  "
                  f"{DIM}loading, this takes 30-90s{RESET}", 12)

    # ── key handling ─────────────────────────────────────────────────────────
    def handle_key(self, key):
        if key is None:
            return
        # Everything is compared in lower case. Keys.poll() returns the literal
        # "ESC" for an escape byte, so Escape must be matched as "esc" here -
        # comparing against "ESC" after lowering is a silent no-op, and that
        # bug let an accidental model switch commit twice during testing.
        key = key.lower()

        if key == "t":
            cur = self.pending.value if self.pending.kind == "thinking" \
                else (self.current_thinking() or "minimal")
            if cur not in self.levels:
                cur = "minimal"
            nxt = self.levels[(self.levels.index(cur) + 1) % len(self.levels)]
            self.pending.arm("thinking", nxt, from_value=cur)
        elif key == "m":
            models = self.downloaded_models()
            if len(models) < 2:
                self.note(f"{YELLOW}Only one model downloaded. "
                          f"Try ./model_download.sh{RESET}", 5)
                return
            repos = [m["repo"] for m in models]
            cur = self.pending.value if self.pending.kind == "model" \
                else self.shown_model()
            idx = repos.index(cur) if cur in repos else -1
            self.pending.arm("model", repos[(idx + 1) % len(repos)], from_value=cur)
        elif key in ("\r", "\n"):
            if self.pending.active:
                self._commit()
        elif key == "esc":
            if self.pending.active:
                self.pending.clear()
                self.note(f"{DIM}cancelled{RESET}", 3)
        elif key == "q":
            raise KeyboardInterrupt

    def _commit(self):
        kind, value = self.pending.kind, self.pending.value
        self.pending.clear()
        if kind == "thinking":
            self.apply_thinking(value)
        elif kind == "model":
            self.apply_model(value)

    def tick(self):
        """Apply a pending action whose settle time has elapsed."""
        if self.pending.expired():
            self._commit()

    # ── one sample ───────────────────────────────────────────────────────────
    def collect(self):
        s = {"t": time.time()}

        cpu = self.cpu.sample()
        s["cpu"] = cpu[0] if cpu else None
        s["cpu_user"] = cpu[1] if cpu else None
        s["cpu_sys"] = cpu[2] if cpu else None

        g = self.gpu.sample()
        s["gpu"] = g.get("device") if g else None
        s["gpu_renderer"] = g.get("renderer") if g else None
        s["gpu_tiler"] = g.get("tiler") if g else None

        if self.power:
            p = self.power.sample()
            s["ane"] = p.get("ane_power") if p else None
            s["gpu_power"] = p.get("gpu_power") if p else None
            s["gpu_residency"] = p.get("gpu_residency") if p else None
        else:
            s["ane"] = None

        vs = vm_stat()
        total_bytes = os.sysconf("SC_PHYS_PAGES") * PAGE_SIZE
        s["ram_total_gb"] = total_bytes / 1024 ** 3

        def pages(key):
            return vs.get(key, 0) * PAGE_SIZE / 1024 ** 3

        # vm_stat pages overlap in ways that are easy to double count. Use the
        # conventional macOS breakdown:
        #   free  = truly available (free + speculative)
        #   cached= inactive + file-backed; reclaimable on demand
        #   used  = wired + active + compressed; not available without swapping
        s["ram_wired_gb"] = pages("Pages wired down")
        s["ram_compressed_gb"] = pages("Pages occupied by compressor")
        s["ram_free_gb"] = pages("Pages free") + pages("Pages speculative")
        s["ram_cached_gb"] = pages("Pages inactive") + pages("File-backed pages")
        s["ram_active_gb"] = pages("Pages active")
        s["ram_used_gb"] = (s["ram_wired_gb"] + pages("Pages active")
                            + s["ram_compressed_gb"])
        # Never let rounding push the columns past the total.
        over = (s["ram_used_gb"] + s["ram_cached_gb"] + s["ram_free_gb"]
                - s["ram_total_gb"])
        if over > 0:
            s["ram_cached_gb"] = max(0.0, s["ram_cached_gb"] - over)
        s["ram_pressure_pct"] = (100.0 * s["ram_wired_gb"] / s["ram_total_gb"]
                                 if s["ram_total_gb"] else 0)

        s["swap"] = swap_usage()
        # Thermal state moves on the scale of tens of seconds.
        if self._frame % 10 == 0:
            self._thermal_cache = (self._frame, thermal_state())
        s["thermal"] = self._thermal_cache[1]

        pid = self.server.server_pid()
        s["proc"] = proc_stats(pid) if pid else None

        # ── server ──
        health = self.server.health()
        self._health_cache = health
        s["server_up"] = health is not None
        s["props"] = self.server.props() if s["server_up"] else None
        # The loaded model identity comes from /props, not from the launch-time
        # config: after an in-app model switch the config snapshot is stale,
        # which is exactly why the header once kept showing the old model.
        self._props_cache = s["props"]
        s["slots"] = self.server.slots() if s["server_up"] else None
        s["prom"] = self.server.metrics() if s["server_up"] else {}
        s["log"] = self.server.log_stats(self._log_cache)
        s["in_flight"] = []
        s["sessions_n"] = len(s["slots"] or [])
        # The connection list is worth refreshing often enough to notice a new
        # client, but not every frame.
        if s["server_up"] and self._frame % 3 == 0:
            self._clients_cache = (self._frame, self.server.clients())
        s["clients"] = self._clients_cache[1] if s["server_up"] else []
        s["proc"] = proc_stats(self.server.server_pid()) if self.server.server_pid() else None
        s["weights_gb"] = self.cfg.get("weights_gb") or None

        # Live activity from the slot table. llama.cpp reports prefill progress
        # as processed/total, which is the most useful thing on screen during a
        # long prompt: it is the difference between "working" and "hung".
        if s["slots"]:
            for slot in s["slots"]:
                if slot.get("is_processing"):
                    s["in_flight"].append({
                        "id": slot.get("id"),
                        "prompt_tokens": slot.get("n_prompt_tokens") or 0,
                        "processed": slot.get("n_prompt_tokens_processed") or 0,
                        "cached": slot.get("n_prompt_tokens_cache") or 0,
                        "speculative": slot.get("speculative"),
                    })

        if s.get("log") and s["log"].get("last_rate"):
            s["live_tps"] = s["log"]["last_rate"]
            self.hist_tps.append(float(s["live_tps"]))
        else:
            s["live_tps"] = None

        if s["cpu"] is not None:
            self.hist_cpu.append(s["cpu"])
        if s["gpu"] is not None:
            self.hist_gpu.append(float(s["gpu"]))
        return s

    # ── render ───────────────────────────────────────────────────────────────
    # The layout is built as ordered blocks and emitted only while they fit the
    # terminal. A dashboard that renders more rows than the window has scrolls
    # its own header off the top, which is worse than showing fewer panels.
    def _block_header(self, s, width):
        cfg = self.cfg
        up = time.time() - self.t0
        hh, rem = divmod(int(up), 3600)
        mm, ss = divmod(rem, 60)

        L = []
        title = f"{BOLD}UpinelAIOS{RESET}"
        status = (f"{GREEN}\u25cf serving{RESET}" if s["server_up"]
                  else f"{RED}\u25cf not running{RESET}")
        clock = f"up {hh:02d}:{mm:02d}:{ss:02d}"
        pad = max(1, width - len(strip_ansi(title)) - len(strip_ansi(status))
                  - len(clock) - 4)
        L.append(f"{title}{' ' * pad}{status}  {DIM}{clock}{RESET}")
        L.append(f"{DIM}  Upinel's One-Click AI Agent Server OS for Mac (GGUF){RESET}")
        L.append(DIM + "\u2500" * width + RESET)

        key = cfg.get("api_key") or "(none - loopback only)"
        shown = self.shown_model()
        suffix = ""
        if self._switching_to:
            suffix = f" {YELLOW}(loading...){RESET}"
        elif not self._props_cache:
            suffix = f" {DIM}(configured; server not running){RESET}"
        L.append(f"  {DIM}model {RESET}{BOLD}{shown}{RESET}{suffix}")
        L.append(f"  {DIM}served as {RESET}{CYAN}{cfg.get('served_name','')}{RESET}"
                 f"{DIM}   ctx {cfg.get('ctx','?')}   KV {cfg.get('kv','?')}"
                 f"   spec d{cfg.get('depth','?')}   "
                 f"{cfg.get('slots','?')} slot(s){RESET}")
        L.append(f"  {DIM}api key {RESET}{YELLOW}{key}{RESET}"
                 f"{DIM}   {cfg.get('lan_url', cfg['base'])}{RESET}")
        L.append("")
        return L

    def _live_thinking_label(self):
        """What thinking is actually set to right now, not what env.conf says."""
        if self.pending.kind == "thinking":
            return self.pending.value
        return self.current_thinking()

    def _header_lines(self):
        """Header line count, used to size everything else."""
        return 7

    def _block_host(self, s, width):
        def gauge(label, pct, text, barw=16):
            if pct is None:
                return (f"  {BOLD}{label:<5}{RESET} "
                        f"{DIM}{SHADE * barw}   {'--':>7}{RESET}")
            return (f"  {BOLD}{label:<5}{RESET} "
                    f"{color_for(pct)}{bar(pct, barw)}{RESET} {text:>7}")

        ram_pct = 100.0 * s["ram_used_gb"] / (s["ram_total_gb"] or 1)
        swap_pct = None
        if s.get("swap") and s["swap"]["total_gb"] > 0:
            swap_pct = 100.0 * s["swap"]["used_gb"] / s["swap"]["total_gb"]

        left = [f"  {BOLD}HOST{RESET}"]
        left.append(gauge("CPU", s["cpu"],
                          f"{s['cpu']:.1f}%" if s["cpu"] is not None else "--"))
        left.append(gauge("GPU", s["gpu"],
                          f"{s['gpu']:.0f}%" if s["gpu"] is not None else "--"))
        if s.get("ane") is not None:
            left.append(f"  {BOLD}ANE  {RESET} {GREEN}{bar(min(100, s['ane'] / 20), 16)}"
                        f"{RESET} {s['ane']:>5.0f}mW")
        else:
            left.append(f"  {BOLD}ANE  {RESET} {DIM}{SHADE * 16}   n/a{RESET}")
        left.append(gauge("RAM", ram_pct, human_gb(s["ram_used_gb"])))
        left.append(gauge("SWAP", swap_pct,
                          human_gb(s["swap"]["used_gb"]) if s.get("swap") else "--"))
        detail = []
        if s["cpu_user"] is not None:
            detail.append(f"cpu {s['cpu_user']:.0f}u/{s['cpu_sys']:.0f}s")
        detail.append(s["thermal"])
        detail.append("gpu=system")
        left.append(f"  {DIM}{'  '.join(detail)}{RESET}")

        # Right column: the server process plus the memory plan the launcher
        # computed. llama.cpp publishes no allocator breakdown, so this reports
        # what was actually requested rather than a fabricated split.
        cfg = self.cfg
        right = [f"  {BOLD}SERVER{RESET}"]
        prop = s.get("props") or {}
        proc = s.get("proc")
        if proc:
            right.append(f"  {'process rss':<13}{human_gb(proc['rss_gb']):>7}")
            right.append(f"  {'process cpu':<13}{proc['cpu_pct']:>6.1f}%")
        weights = s.get("weights_gb")
        if weights:
            right.append(f"  {'weights':<13}{weights:>6} GB")
        if cfg.get("kv_gb") is not None:
            right.append(f"  {'kv cache':<13}{cfg['kv_gb']:>6} GB"
                         f"  {DIM}({cfg.get('ctx','')}, {cfg.get('kv','')}){RESET}")
        if cfg.get("vision_gb"):
            right.append(f"  {'vision':<13}{cfg['vision_gb']:>6} GB")
        right.append(f"  {'cap':<13}{cfg.get('memory_limit','?'):>6} GB")
        right.append(f"  {'slots':<13}{prop.get('total_slots', s.get('sessions_n', 0)):>7}")
        return two_col(left, right, width) + [""]

    def _block_activity(self, s, width, compact=False):
        act = [f"  {BOLD}CONCURRENT ACTIVITY{RESET}"]
        live = s["in_flight"]
        if compact:
            act.append(f"  in-flight {YELLOW}{len(live)}{RESET}"
                       f"  slots {s.get('sessions_n', 0)}"
                       + (f"  {GREEN}{s['live_tps']:.1f} t/s{RESET}"
                          if s.get("live_tps") else ""))
        else:
            spec = "speculative" if (s["slots"] and s["slots"][0].get("speculative")) \
                else "autoregressive"
            act.append(f"  in-flight {YELLOW}{len(live)}{RESET}"
                       f"   slots {s.get('sessions_n', 0)}"
                       f"   {spec}")
            for slot in live[:2]:
                total = slot.get("prompt_tokens") or 0
                done = slot.get("processed") or 0
                cached = slot.get("cached") or 0
                line = f"  slot {slot.get('id')}   {total} prompt tok"
                if total and done:
                    line += f"   {100.0 * done / total:.0f}% prefilled"
                if cached:
                    line += f"   {DIM}{cached} cached{RESET}"
                act.append(line)
            if not live and s["server_up"]:
                acc = (s.get("log") or {}).get("last_accept")
                act.append(f"  {DIM}idle" + (f"   last draft acceptance {acc*100:.0f}%"
                                             if acc else "") + f"{RESET}")

        cli = [f"  {BOLD}CLIENTS{RESET}  {DIM}connected peers{RESET}"]
        if s["clients"]:
            for cl in s["clients"][:4]:
                where = "this Mac" if cl.get("local") else cl["ip"]
                who = ",".join(cl["procs"])[:16] or "?"
                cli.append(f"  {where:<16} {cl['conns']} conn  {DIM}{who}{RESET}")
        elif s["server_up"]:
            cli.append(f"  {DIM}none connected{RESET}")
        else:
            cli.append(f"  {DIM}-{RESET}")
        return two_col(act, cli, width) + [""]

    def _block_rate(self, s, width, chart_rows_n, max_rows):
        """
        Live decode-rate chart beside lifetime token counters.

        Both columns are sized to max_rows: the counter column is usually taller
        than the chart, and letting it dictate the block height is what pushed
        the whole panel out of a 24-row terminal.
        """
        hist = list(self.hist_tps)
        lw, _ = col_widths(
            [f"  {BOLD}TOKEN RATE{RESET}  {DIM}live{RESET}"
             f"  {DIM}min 00.0  avg 00.0  max 00.0{RESET}"], [], width)
        chart_w = max(12, lw - 9)
        chart_h = max(1, min(chart_rows_n, max_rows - 3))
        rows, axis_lo, axis_hi = line_chart(hist, chart_w, height=chart_h)

        log = s.get("log") or {}
        counters = [f"  {BOLD}TOKENS{RESET}  {DIM}this server{RESET}"]
        detail = []
        if log:
            detail.append(("generated", f"{log.get('decode_tokens', 0):,}"))
            detail.append(("prompt", f"{log.get('prompt_tokens', 0):,}"))
            detail.append(("requests", f"{log.get('requests', 0):,}"))
        acc = log.get("last_accept")
        if acc:
            detail.append(("draft acc", f"{acc * 100:.0f}%"))
        counter_cap = max(1, max_rows - 1)
        for label, value in detail:
            if len(counters) < counter_cap:
                counters.append(f"  {label:<10}{value:>12}")

        now = s.get("live_tps")
        head = f"  {BOLD}TOKEN RATE{RESET}  {DIM}live{RESET}"
        if hist:
            head += (f"  {DIM}min {min(hist):.1f}  avg {sum(hist)/len(hist):.1f}"
                     f"  max {max(hist):.1f}{RESET}")
        lines = [head]
        for i, row in enumerate(rows):
            label = f"{axis_hi:>6.1f} " if i == 0 else " " * 7
            lines.append(f"  {DIM}{label}{RESET}{GREEN}{row}{RESET}")
        if hist:
            lines.append(f"  {DIM}{axis_lo:>6.1f} {RESET}"
                         + (f"{CYAN}now {now:.1f} t/s{RESET}" if now
                            else f"{DIM}idle{RESET}"))
        else:
            lines.append(f"  {DIM}{' ' * 7}waiting for traffic{RESET}")
        return two_col(lines, counters, width) + [""]

    def _block_rate_summary(self, s):
        """One-line token panel for terminals too short for the chart."""
        logt = s.get("log_totals") or {}
        now = s.get("live_tps")
        bits = [f"  {BOLD}TOKENS{RESET}"]
        if now:
            bits.append(f"{GREEN}{now:.1f} t/s{RESET}")
        if logt:
            bits.append(f"{DIM}out {logt['completion']:,}"
                        f"   in {logt['prompt']:,}"
                        f"   {logt['requests']:,} reqs{RESET}")
        return [" ".join(bits), ""]

    def _block_spark(self, width):
        sw = max(20, width - 16)
        return [f"  {BOLD}cpu {RESET}{sparkline(self.hist_cpu, sw)}",
                f"  {BOLD}gpu {RESET}{sparkline(self.hist_gpu, sw)}",
                ""]

    def render(self, s):
        width, height = term_size()
        width = max(60, min(width, 200))
        L = []

        header = self._block_header(s, width)
        host = self._block_host(s, width)
        footer = None   # built after the blocks are placed

        # Essential blocks first, then optional ones in priority order, each
        # admitted only if the remaining rows can hold it.
        L.extend(header)
        L.extend(host)

        # The token rate is the panel people watch, so it outranks activity and
        # gets whatever rows are left after the essential blocks.
        # Reserve two rows for the footer block (separator + footer line).
        RESERVED = 2
        remaining = height - len(L) - RESERVED
        rate = None
        if remaining >= 4:
            for chart_rows_n in (5, 4, 3, 2, 1):
                candidate = self._block_rate(s, width, chart_rows_n, remaining)
                if len(candidate) <= remaining:
                    rate = candidate
                    break
                # Last resort: a one-line summary so the panel still appears.
            if rate is None:
                summary = self._block_rate_summary(s)
                if len(summary) <= remaining:
                    rate = summary
        if rate:
            L.extend(rate)
            remaining -= len(rate)

        activity_shown = False
        for compact in (False, True):
            if remaining < 3:
                break
            act = self._block_activity(s, width, compact=compact)
            if len(act) <= remaining:
                L.extend(act)
                remaining -= len(act)
                activity_shown = True
                break

        if remaining >= len(self._block_spark(width)):
            L.extend(self._block_spark(width))

        # One blank row between the last panel and the footer, no more.
        while L and not strip_ansi(L[-1]).strip():
            L.pop()
        L.append("")

        # A pending toggle owns the footer: it is the thing needing a decision,
        # and the countdown has to be visible or the delay feels like a hang.
        if self.pending.active:
            left_txt = self.short_model(self.pending.from_value or "?") \
                if self.pending.kind == "model" else (self.pending.from_value or "?")
            right_txt = self.short_model(self.pending.value) \
                if self.pending.kind == "model" else self.pending.value
            label = "model" if self.pending.kind == "model" else "thinking"
            secs = self.pending.remaining()
            hint = (f"{YELLOW}{label}: {left_txt} \u2192 {right_txt}{RESET}"
                    f"   {BOLD}applying in {secs:.1f}s{RESET}"
                    f"   {DIM}[same key] next  [Enter] now  [Esc] cancel{RESET}")
        elif self.status_note and time.time() < self.status_note_until:
            hint = self.status_note
        else:
            if self.keys.enabled:
                # Show each toggle with its current value, so the footer is a
                # readout as well as a keymap - you can see what t and m are
                # sitting on without pressing them.
                hint = (f"{BOLD}t{RESET}{DIM} thinking{RESET}"
                        f"{CYAN}={self._live_thinking_label()}{RESET}"
                        f"   {BOLD}m{RESET}{DIM} model{RESET}"
                        f"{CYAN}={self.short_model(self.shown_model())}{RESET}"
                        f"   {DIM}q quit{RESET}")
            else:
                hint = (f"refresh {self.args.interval}s \u00b7 Ctrl-C to exit"
                        + ("" if self.power and self.power.available
                           else f" \u00b7 --power for ANE")
                        + RESET)
        # If the activity panel did not fit, its essentials ride along in the
        # footer rather than vanishing: who is connected and how much is running.
        if not activity_shown and s["server_up"]:
            bits = [f"{len(s['in_flight'])} in-flight",
                    f"{s.get('sessions_n', 0)} sessions"]
            if s["clients"]:
                who = ", ".join(
                    (c["ip"] if not c.get("local") else "this Mac")
                    + (f" x{c['conns']}" if c["conns"] > 1 else "")
                    for c in s["clients"][:2])
                bits.append(who)
            hint = " \u00b7 ".join(bits) + "   " + f"{DIM}{hint}{RESET}"
        footer = [f"  {DIM}\u2500\u2500{RESET} {hint}"]

        while len(L) < height - len(footer) - 1:
            L.append("")
        L.extend(footer)

        # Final safety pass: clamp every line to the terminal width. The model
        # id and the API key are printed in full, and an unclamped line would
        # wrap and corrupt every row below it.
        L = [truncate(line, width) if len(strip_ansi(line)) > width else line
             for line in L][:height - 1]

        if not TTY_MODE:
            body = "\n".join(strip_ansi(x) if not USE_COLOR else x for x in L)
            return body + "\n" + "\u2500" * min(width, 78) + "\n"

        return SET_TITLE + HOME + "\n".join(x + CLR_EOL for x in L) + CLR_EOS

    def _log_fault(self, detail):
        """Append a render fault to run/dashboard.err, trimmed to one file."""
        path = self.cfg.get("error_log")
        if not path:
            return
        try:
            if os.path.exists(path) and os.path.getsize(path) > 262144:
                os.replace(path, path + ".1")
            with open(path, "a") as fh:
                fh.write(f"\n--- {time.strftime('%Y-%m-%d %H:%M:%S')} "
                         f"frame {self._frame} ---\n{detail}")
        except OSError:
            pass

    def _empty_snapshot(self):
        """Minimal snapshot so a failed collect still yields a renderable frame."""
        return {
            "cpu": None, "cpu_user": None, "cpu_sys": None, "gpu": None,
            "gpu_renderer": None, "gpu_tiler": None, "ane": None,
            "ram_total_gb": 0.0, "ram_free_gb": 0.0, "ram_used_gb": 0.0,
            "ram_wired_gb": 0.0, "ram_cached_gb": 0.0, "ram_compressed_gb": 0.0,
            "ram_active_gb": 0.0, "ram_pressure_pct": 0.0, "thermal": "unknown",
            "swap": None, "proc": None, "server_up": False, "clients": [],
            "in_flight": [], "slots": None, "props": None, "prom": {},
            "log": None, "sessions_n": 0, "live_tps": None,
        }

    def _fault_frame(self, s):
        """
        Minimal but useful frame when rendering failed.

        The system numbers are collected before rendering, so they are still
        good; only the panel layout is suspect. Showing them means the dashboard
        remains worth watching even while a panel is broken.
        """
        width, _ = term_size()
        width = max(60, min(width, 200))
        L = [
            f"{BOLD}{WINDOW_TITLE}{RESET}"
            f"{' ' * max(1, width - len(WINDOW_TITLE) - 26)}"
            f"{RED}\u25cf display error{RESET}",
            DIM + "\u2500" * width + RESET,
            f"  {YELLOW}The dashboard hit a rendering fault and degraded rather "
            f"than exiting.{RESET}",
            f"  {DIM}{self._last_error.strip().splitlines()[-1][:width - 6]}{RESET}",
            "",
        ]
        if s.get("cpu") is not None:
            L.append(f"  {'cpu':<12}{s['cpu']:.1f}%")
        if s.get("gpu") is not None:
            L.append(f"  {'gpu':<12}{s['gpu']:.0f}%")
        if s.get("ram_total_gb"):
            L.append(f"  {'ram used':<12}{human_gb(s.get('ram_used_gb'))}"
                     f" / {s['ram_total_gb']:.0f} GB")
        if s.get("live_tps"):
            L.append(f"  {'decode':<12}{fmt_num(s['live_tps'], '.1f', ' t/s')}")
        L += [
            "",
            f"  {DIM}in-flight {len(s.get('in_flight') or [])}"
            f"   sessions {s.get('sessions_n', 0)}"
            f"   faults this run: {self._error_count}{RESET}",
            f"  {DIM}detail logged to "
            f"{self.cfg.get('error_log', '(none)')}{RESET}",
            "",
            f"  {DIM}Ctrl-C to exit{RESET}",
        ]
        L = [truncate(x, width) if len(strip_ansi(x)) > width else x for x in L]
        if not TTY_MODE:
            return "\n".join(strip_ansi(x) for x in L) + "\n"
        return SET_TITLE + HOME + "\n".join(x + CLR_EOL for x in L) + CLR_EOS

    def run(self):
        if TTY_MODE:
            sys.stdout.write(SET_TITLE + HIDE_CURSOR)
            sys.stdout.flush()
        self.keys = Keys(self.args.enable_keys and TTY_MODE)
        try:
            with self.keys:
                self._loop()
        except KeyboardInterrupt:
            pass
        finally:
            self.keys.restore()
            if TTY_MODE:
                # Hand the heading back rather than leaving ours behind.
                sys.stdout.write(CLEAR_TITLE + SHOW_CURSOR + "\n")
                sys.stdout.flush()

    def _loop(self):
        while True:
            started = time.time()
            self._reload_cfg()
            try:
                s = self.collect()
            except Exception:                                  # noqa: BLE001
                # Sampling is as capable of raising as rendering is - a probe
                # renamed, a telemetry field that vanished. Degrade the frame
                # rather than dying, for the same reason the render guard exists.
                self._error_count += 1
                self._last_error = traceback.format_exc()
                self._log_fault(self._last_error)
                s = self._empty_snapshot()
            self.tick()
            try:
                frame = self.render(s)
            except Exception:                                  # noqa: BLE001
                # This is a long-running display. A fault in one panel must not
                # kill the tool and dump a traceback over the frame - that is
                # exactly how the decode_tok_s bug announced itself. Show a
                # degraded frame, keep running, and leave the detail in a log.
                self._error_count += 1
                self._last_error = traceback.format_exc()
                self._log_fault(self._last_error)
                frame = self._fault_frame(s)
            sys.stdout.write(frame)
            sys.stdout.flush()
            if self.args.iterations and self.args.iterations > 0:
                self.args.iterations -= 1
                if self.args.iterations == 0:
                    break
            # Wait out the refresh interval, but wake immediately on a key or
            # when a pending action's countdown is about to expire.
            wait = max(0.05, self.args.interval - (time.time() - started))
            if self.pending.active:
                wait = min(wait, max(0.02, self.pending.remaining()))
            key = self.keys.poll(wait)
            if key is not None:
                self.handle_key(key)


# ── one-shot report (previously status.sh) ───────────────────────────────────
def print_once(cfg, snap):
    s = snap
    eng = cfg.get("engine", "gguf")
    eng_label = {"gguf": "llama.cpp", "mlx": "MLX / MTPLX"}.get(eng, eng)
    print(f"\n{BOLD}UpinelAIOS{RESET} {DIM}- "
          f"One-Click AI Agent Server OS for Mac  ·  {eng_label}{RESET}\n")

    def line(label, value):
        print(f"  {label:<18} {value}")

    print(f"{BOLD}Model{RESET}")
    line("name", cfg.get("model_repo", "?"))
    line("served as", cfg.get("served_name", "?"))
    line("engine", {"gguf": "llama.cpp", "mlx": "MLX / MTPLX"}.get(cfg.get("engine", "gguf"), cfg.get("engine")))
    line("weights", cfg.get("main_gguf") or cfg.get("model_dir", "?"))
    line("vision", "on" if cfg.get("vision_gb") else "off")

    print(f"\n{BOLD}Configuration{RESET}  (env.conf)")
    line("context window", f"{cfg.get('ctx')} tokens")
    line("KV quant", cfg.get("kv"))
    line("speculative", f"depth {cfg.get('depth')}" if cfg.get("depth")
         else "off (autoregressive)")
    line("thinking", cfg.get("thinking"))
    line("memory cap", f"{cfg.get('memory_limit')} GB")
    line("slots", cfg.get("slots"))

    print(f"\n{BOLD}Host{RESET}")
    line("chip", cfg.get("chip", "Apple Silicon"))
    line("cpu", f"{s['cpu']:.1f}%" if s["cpu"] is not None else "--")
    line("gpu", f"{s['gpu']:.0f}%" if s["gpu"] is not None else "--")
    line("ram used", f"{s['ram_used_gb']:.1f} GB / {s['ram_total_gb']:.0f} GB")
    line("ram wired", f"{s['ram_wired_gb']:.1f} GB")
    line("thermal", s["thermal"])

    print(f"\n{BOLD}Server{RESET}")
    if not s["server_up"]:
        print(f"  {RED}not running{RESET} - start it with ./start.sh")
        return
    prop = s.get("props") or {}
    line("state", f"{GREEN}serving{RESET} on {cfg['base']}")
    line("build", prop.get("build_info", "?"))
    line("slots", prop.get("total_slots", s.get("sessions_n", 0)))
    if s.get("live_tps"):
        line("decode now", f"{s['live_tps']:.1f} t/s")

    log = s.get("log") or {}
    if log:
        print(f"\n{BOLD}Tokens{RESET}  {DIM}this server{RESET}")
        line("generated", f"{log.get('decode_tokens', 0):,}")
        line("prompt", f"{log.get('prompt_tokens', 0):,}")
        line("requests", f"{log.get('requests', 0):,}")
        if log.get("last_accept"):
            line("draft acceptance", f"{log['last_accept'] * 100:.0f}%")

    print(f"\n{BOLD}Clients{RESET}")
    if s["clients"]:
        for cl in s["clients"]:
            line(cl["ip"], f"{cl['conns']} connection(s)  {', '.join(cl['procs'])[:40]}")
    else:
        line("(none)", "no established connections")

    print(f"\n{BOLD}Connect a client{RESET}")
    line("base URL", cfg.get("lan_url", cfg["base"]))
    line("model", cfg.get("served_name", "?"))
    line("api key", cfg.get("api_key") or "(none - loopback only)")
    print(f"\n  {DIM}Live dashboard:  ./status.sh{RESET}")
    print(f"  {DIM}Key only:        ./status.sh --key{RESET}\n")


def print_json(cfg, snap):
    out = dict(snap)
    out.pop("snap", None)          # the whole raw telemetry blob
    out["sessions"] = snap.get("sessions_n", 0)
    out["in_flight"] = [
        {"request_id": r.get("request_id"),
         "age_s": r.get("age_s"),
         "prompt_tokens": r.get("prompt_tokens"),
         "session_id": r.get("session_id"),
         "completion_tokens": (r.get("last_progress") or {}).get("completion_tokens"),
         "decode_tok_s": (r.get("last_progress") or {}).get("decode_tok_s")}
        for r in (snap.get("in_flight") or [])
    ]
    out["live_history"] = len(snap.get("live_history") or [])
    out["config"] = cfg
    print(json.dumps(out, indent=2, default=str))


# ── main ─────────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--once", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--power", action="store_true",
                    help="add ANE/GPU power via passwordless sudo powermetrics")
    ap.add_argument("--iterations", type=int, default=0,
                    help="stop after N refreshes (0 = run until Ctrl-C)")
    ap.add_argument("--no-keys", dest="enable_keys", action="store_false",
                    default=True,
                    help="disable the t/m key toggles (display only)")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args()

    if args.help:
        print(__doc__)
        return 0

    # The shell writes the payload to a file and passes its path, so this
    # process can notice a model switch while it is running. The inline env var
    # is still honoured for anyone calling the dashboard directly.
    cfg_path = os.environ.get("AIOS_DASH_CFG_FILE") or None
    if cfg_path and os.path.exists(cfg_path):
        with open(cfg_path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    else:
        cfg_path = None
        cfg = json.loads(os.environ["AIOS_DASH_CFG"])
    dash = Dashboard(cfg, args, cfg_path=cfg_path)

    if args.once or args.json:
        snap = dash.collect()
        print_json(cfg, snap) if args.json else print_once(cfg, snap)
        return 0 if snap["server_up"] else 1

    dash.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
