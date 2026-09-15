#!/usr/bin/env python3
# Drives a VM started by `elv vm` (any mode but --serial) through what it
# leaves in the workspace:
#
#   console.sock/.log  the virtio console (hvc0): a root bash
#   serial.log         the serial port: firmware, boot menu, kernel log
#   qmp.sock           QEMU itself: keys, screenshots, quit
#
# QEMU logs everything the guest writes to a console, whether or not a client
# is connected, so output is always read from the logs.
#
# Python rather than nushell: this is unix sockets and byte offsets.

import argparse
import base64
import gzip
import json
import os
import re
import secrets
import socket
import struct
import sys
import time

ws = os.environ["ELV_WORKSPACE"]
CONSOLE_LOG, CONSOLE, SERIAL_LOG, QMP, STATE = (
    os.path.join(ws, f)
    for f in ("console.log", "console.sock", "serial.log", "qmp.sock", "vmctl.state")
)

BOOT = re.compile(rb"BdsDxe: loading")  # firmware starting a boot option
LOGIN = re.compile(rb"elv-vmctl-ready")  # hvc0's bash (see elv vm)
NOISE = re.compile(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]|\r")


def read(path) -> bytes:
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return b""


def boots() -> int:
    return len(BOOT.findall(read(SERIAL_LOG)))


def last_login() -> int:
    ends = [m.end() for m in LOGIN.finditer(read(CONSOLE_LOG))]
    return ends[-1] if ends else -1


console = None


def send(text: str):
    # One connection for the life of this process: QEMU drops what it has
    # not yet taken off the socket when the client goes, and every verb waits
    # for the guest before exiting.
    global console
    if console is None:
        console = socket.socket(socket.AF_UNIX)
        console.connect(CONSOLE)
    console.sendall(text.encode())


def drain():
    # QEMU also writes the guest's output to a connected client; unread, it
    # would stall the console. The log has it all, so throw it away.
    if console is None:
        return
    try:
        while console.recv(65536, socket.MSG_DONTWAIT):
            pass
    except BlockingIOError:
        pass


def until(what, test, timeout):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        drain()
        if (r := test()) is not None:
            return r
        time.sleep(0.05)
    sys.exit(f"vmctl: timed out after {timeout}s waiting for {what}")


def qmp(command: str, **arguments):
    with socket.socket(socket.AF_UNIX) as s:
        s.connect(QMP)
        f = s.makefile("rw")
        f.readline()  # greeting
        for msg in ({"execute": "qmp_capabilities"}, {"execute": command, "arguments": arguments}):
            f.write(json.dumps(msg) + "\n")
            f.flush()
            while "return" not in (reply := json.loads(f.readline())) and "error" not in reply:
                pass  # events
            if "error" in reply:
                sys.exit(f"vmctl: {command}: {reply['error']['desc']}")
        return reply["return"]


def glyphs(path: str) -> tuple[int, int, dict]:
    """A PSF console font: its cell size, and each glyph's bitmap -> the
    character it draws. Several characters can share a glyph; the first
    listed (ASCII before its look-alikes) wins."""
    data = gzip.open(path).read() if path.endswith(".gz") else open(path, "rb").read()
    if data[:2] == b"\x36\x04":  # PSF1
        mode, size = data[2], data[3]
        count, width, height, start = (512 if mode & 1 else 256), 8, size, 4
        table, unicode = start + count * size, bool(mode & 2)
        entries = lambda: _psf1_table(data[table:], count)
    elif data[:4] == b"\x72\xb5\x4a\x86":  # PSF2
        start, flags, count, size, height, width = struct.unpack("<6I", data[8:32])
        table, unicode = start + count * size, bool(flags & 1)
        entries = lambda: _psf2_table(data[table:], count)
    else:
        raise ValueError(f"{path}: not a PSF font")
    stride = (width + 7) // 8
    bitmaps = [data[start + i * size : start + (i + 1) * size] for i in range(count)]
    chars = entries() if unicode else [[chr(i)] for i in range(count)]
    out = {}
    for bitmap, cs in zip(bitmaps, chars, strict=False):
        rows = tuple(
            int.from_bytes(bitmap[r * stride : (r + 1) * stride]) >> (stride * 8 - width)
            for r in range(height)
        )
        if cs and rows not in out:
            out[rows] = min(cs, key=lambda c: (not c.isascii(), c))
    return width, height, out


def _psf1_table(t: bytes, count: int):
    words = struct.unpack(f"<{len(t) // 2}H", t[: len(t) // 2 * 2])
    out, cur = [], []
    for w in words:
        if w == 0xFFFF:
            out.append(cur)
            cur = []
        elif w != 0xFFFE:
            cur.append(chr(w))
    return out[:count]


def _psf2_table(t: bytes, count: int):
    out = []
    for entry in t.split(b"\xff")[:count]:
        out.append(list(entry.split(b"\xfe")[0].decode("utf-8", "replace")))
    return out


def cell_bitmaps(fw: int, fh: int):
    """Screenshot the display; each character cell's bitmap, row by row: a
    pixel is set where it differs from the cell's commonest colour."""
    ppm = os.path.join(ws, "screen.ppm")
    qmp("screendump", filename=ppm, format="ppm")
    data = open(ppm, "rb").read()
    os.unlink(ppm)
    _magic, w, h, _maxval, pixels = data.split(maxsplit=4)
    w, h = int(w), int(h)
    stride = w * 3
    for cy in range(h // fh):
        row = []
        for cx in range(w // fw):
            px = [
                [pixels[o + i : o + i + 3] for i in range(0, fw * 3, 3)]
                for o in ((cy * fh + y) * stride + cx * fw * 3 for y in range(fh))
            ]
            flat = [p for r in px for p in r]
            bg = max(set(flat), key=flat.count)
            row.append(tuple(sum(1 << (fw - 1 - x) for x in range(fw) if r[x] != bg) for r in px))
        yield row


# What calibration writes to the console: ASCII, the CP437 repertoire the kernel's
# built-in font covers - its low half spelled out, as Python's codec decodes
# those bytes as control characters - and some of what systemd prints.
CALIBRATION = (
    "".join(map(chr, range(33, 127)))
    + bytes(range(128, 256)).decode("cp437")
    + "☺☻♥♦♣♠•◘○◙♂♀♪♫☼►◄↕‼¶§▬↨↑↓→←∟↔▲▼⌂"
    + "●✓✗‣…"
)
GLYPHS = os.path.join(ws, "console-glyphs.json")
VT = 12


def calibrate(key: str):
    """Learn the console font from the guest itself: write known characters
    to tty1, and read back which bitmap each cell shows. No font file is
    quite the kernel's built-in one, and a font file cannot know which
    characters the kernel draws with its replacement glyph."""
    data = base64.b64encode(CALIBRATION.encode()).decode()
    # On a VT nothing runs on: kmscon draws tty1-6 itself, and the kernel
    # draws only the VT in front - so switch to it, and back after.
    marker(
        f"vt=$(fgconsole); chvt {VT}; {{ printf '\\033[2J\\033[H'; echo {data} | base64 -d; }} > /dev/tty{VT}; sleep 0.3",
        10,
    )
    # What each cell holds, from the kernel (/dev/vcsuN: one UTF-32 code
    # point per cell) - not assumed from the string, whose characters need
    # not take one cell each.
    held = marker(f"iconv -f UTF-32LE -t UTF-8 /dev/vcsu{VT}", 10)[0].decode()
    cells = [c for row in cell_bitmaps(8, 16) for c in row]
    seen = {}
    for bitmap, ch in zip(cells, held, strict=False):
        if ch != " ":
            seen.setdefault(bitmap, []).append(ch)
    seen = {b: list(dict.fromkeys(cs)) for b, cs in seen.items()}
    # One glyph for several characters: the ASCII one if any; else it is
    # the replacement glyph, standing for whatever the kernel cannot draw.
    table = {
        ",".join(map(str, b)): next((c for c in cs if c.isascii()), cs[0] if len(cs) == 1 else "?")
        for b, cs in seen.items()
    }
    marker(f"printf '\\033[2J\\033[H' > /dev/tty{VT}; chvt $vt", 10)
    json.dump({"key": key, "width": 8, "height": 16, "glyphs": table}, open(GLYPHS, "w"))


def font() -> tuple[int, int, dict]:
    if os.path.exists(GLYPHS):
        g = json.load(open(GLYPHS))
        return (
            g["width"],
            g["height"],
            {tuple(map(int, b.split(","))): c for b, c in g["glyphs"].items()},
        )
    # Before any calibration: of the fonts kbd ships, the closest to the
    # kernel's - all of ASCII and most of CP437 draw the same.
    return glyphs(
        next(
            p
            for p in (
                os.path.join(ws, "tree/usr/share/kbd/consolefonts/cp850-8x16.psfu.gz"),
                "/usr/share/kbd/consolefonts/cp850-8x16.psfu.gz",
            )
            if os.path.exists(p)
        )
    )


def screen_text() -> str:
    """The console's text, read off a screenshot.

    The Linux console draws a bitmap font on a fixed grid, so this is exact
    rather than OCR: each cell's bitmap is looked up among the font's glyphs,
    the nearest one when nothing matches exactly (the cursor, say)."""
    fw, fh, table = font()
    known = list(table.items())
    lines = []
    for row in cell_bitmaps(fw, fh):
        line = []
        for bitmap in row:
            if not any(bitmap):
                c = " "
            elif (c := table.get(bitmap)) is not None:
                pass
            elif all(r in (0, (1 << fw) - 1) for r in bitmap) and not any(bitmap[: fh - 3]):
                c = " "  # fbcon's underline cursor, alone in its cell
            else:

                def bits(g, bitmap=bitmap):
                    return sum((a ^ b).bit_count() for a, b in zip(g, bitmap, strict=False))

                g, c = min(known, key=lambda kv: bits(kv[0]))
                if bits(g) > fw * fh // 8:
                    c = "?"
            line.append(c)
        lines.append("".join(line).rstrip())
    while lines and not lines[-1]:
        lines.pop()
    return "\n".join(lines)


def marker(cmd: str, timeout: float) -> tuple[bytes, int]:
    """Run cmd in the guest shell; its output and exit status."""
    tag = secrets.token_hex(4)
    start = len(read(CONSOLE_LOG))
    # printf builds the marker at run time, so the command line itself - if
    # anything echoes it - never matches.
    send(f"{cmd}\nprintf '\\n@@%s:%s@@\\n' {tag} $?\n")
    pattern = re.compile(rb"@@" + tag.encode() + rb":(\d+)@@")
    m = until("the command to finish", lambda: pattern.search(read(CONSOLE_LOG), start), timeout)
    return NOISE.sub(b"", read(CONSOLE_LOG)[start : m.start()]).strip(b"\n"), int(m.group(1))


def ready(timeout: float):
    """Wait for this boot's shell on hvc0, and make it scriptable once."""
    state = json.load(open(STATE)) if os.path.exists(STATE) else {"boots": -1, "login": -1}
    n = boots()
    if n == state["boots"] and last_login() == state["login"]:
        return
    # A login this boot is one after the last we set up.
    at = until(
        "the guest to log in", lambda: (l := last_login()) > state["login"] and l or None, timeout
    )
    # A bare bash (elv vm puts it on hvc0 instead of a login). No line
    # editing, so the tty's echo setting applies and can be turned off; no
    # prompt, and none of the OSC context sequences profile hooks print.
    marker("stty -echo; PS1= PS0= PROMPT_COMMAND=; export TERM=dumb SYSTEMD_COLORS=0 PAGER=", 10)
    json.dump({"boots": boots(), "login": at}, open(STATE, "w"))
    # The console font is the kernel's (or vconsole.conf's): learn it once
    # for each, while there is a shell to do it with.
    key = marker("uname -r; grep -s ^FONT= /etc/vconsole.conf", 10)[0].decode()
    if not os.path.exists(GLYPHS) or json.load(open(GLYPHS)).get("key") != key:
        calibrate(key)


def main():
    p = argparse.ArgumentParser(prog="elv vmctl")
    sub = p.add_subparsers(dest="verb", required=True)
    w = sub.add_parser(
        "wait",
        help="wait for the guest's shell; with a pattern, for it on this boot's serial output",
    )
    w.add_argument("pattern", nargs="?")
    r = sub.add_parser("run", help="run a shell command in the guest; exits with its status")
    r.add_argument("command")
    b = sub.add_parser(
        "reboot", help="reboot the guest and wait for its shell (--no-wait: just the firmware)"
    )
    b.add_argument("--no-wait", action="store_true")
    k = sub.add_parser("key", help="press keys by QEMU name: a, ret, spc, ctrl-alt-f2 ...")
    k.add_argument("keys", nargs="+")
    s = sub.add_parser(
        "screen",
        help="the console's text, read off the display; with a file, a PNG screenshot instead",
    )
    s.add_argument("file", nargs="?")
    l = sub.add_parser("log", help="print a console log so far, cleaned up")
    l.add_argument("which", nargs="?", choices=["console", "serial"], default="serial")
    m = sub.add_parser(
        "menu",
        help="pick boot menu entry N (0 = the first) - the menu shows in window and --pristine VMs",
    )
    m.add_argument("entry", type=int)
    u = sub.add_parser("push", help="copy a local file into the guest")
    u.add_argument("local")
    u.add_argument("remote")
    sub.add_parser("quit", help="stop the VM")
    for x in (w, r, b, m, u):
        x.add_argument("-t", "--timeout", type=float, default=120)
    a = p.parse_args()

    if a.verb == "wait" and a.pattern:
        # Anywhere in this boot: from the firmware's last start, so a line
        # printed before the call still counts.
        starts = [m.start() for m in BOOT.finditer(read(SERIAL_LOG))]
        start = starts[-1] if starts else 0
        pattern = re.compile(a.pattern.encode())
        until(repr(a.pattern), lambda: pattern.search(read(SERIAL_LOG), start), a.timeout)
    elif a.verb == "wait":
        ready(a.timeout)
    elif a.verb == "run":
        ready(a.timeout)
        out, status = marker(a.command, a.timeout)
        sys.stdout.buffer.write(out + b"\n" if out else b"")
        sys.exit(status)
    elif a.verb == "reboot":
        ready(a.timeout)
        n = boots()
        send("systemctl reboot\n")
        until("the firmware", lambda: True if boots() > n else None, a.timeout)
        if not a.no_wait:
            ready(a.timeout)
    elif a.verb == "menu":
        # The menu of the current boot: a fresh Secure Boot VM first enrolls
        # the keys and resets without showing one.
        def shown():
            data = read(SERIAL_LOG)
            starts = [m.start() for m in BOOT.finditer(data)]
            return True if starts and re.search(rb"Boot in \d+s", data[starts[-1] :]) else None

        until("the boot menu", shown, a.timeout)
        for key in ["down"] * a.entry + ["ret"]:
            qmp("human-monitor-command", **{"command-line": f"sendkey {key}"})
            time.sleep(0.1)
    elif a.verb == "push":
        # Through the console, as base64 in a heredoc: short lines, since a
        # tty in canonical mode takes at most 4096 bytes per line.
        ready(a.timeout)
        data = base64.encodebytes(open(a.local, "rb").read()).decode()
        _, status = marker(f"base64 -d > '{a.remote}' <<'ELV-PUSH'\n{data}ELV-PUSH", a.timeout)
        sys.exit(status)
    elif a.verb == "key":
        for key in a.keys:
            qmp("human-monitor-command", **{"command-line": f"sendkey {key}"})
            time.sleep(0.05)
    elif a.verb == "screen" and a.file:
        qmp("screendump", filename=os.path.abspath(a.file), format="png")
    elif a.verb == "screen":
        text = screen_text()
        print(text)
        # A VT kmscon draws (after login prompts appear) is no bitmap font on
        # a grid: the cells come out as noise.
        drawn = [c for c in text if not c.isspace()]
        if drawn and drawn.count("?") > len(drawn) // 3:
            print(
                "vmctl: this is not the kernel console (kmscon?) - use `vmctl screen FILE.png`",
                file=sys.stderr,
            )
    elif a.verb == "log":
        sys.stdout.buffer.write(
            NOISE.sub(b"", read(CONSOLE_LOG if a.which == "console" else SERIAL_LOG))
        )
    elif a.verb == "quit":
        qmp("quit")


main()
