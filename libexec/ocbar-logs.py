#!/usr/bin/env python3
"""Общий журнал: хвосты всех журналов одной лентой по времени.

Аргументы: <строк> <следить 0|1> тег=путь…
"""
import os, re, sys, time
n, follow = int(sys.argv[1]), sys.argv[2] == "1"
srcs = [a.split("=", 1) for a in sys.argv[3:]]
TS = re.compile(r"^\[?(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d:\d\d)\]?\s?")
TAG = {"supervisor": "супервизор", "openconnect": "openconnect", "proxy": "прокси", "auth": "вход", "app": "приложение"}
COL = {"supervisor": "36", "openconnect": "35", "proxy": "35", "auth": "33", "app": "34"}
tty = sys.stdout.isatty()
width = max(len(TAG[t]) for t, _ in srcs) if srcs else 0
def read_tail(path, limit=512 * 1024):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - limit)); data = f.read()
    except OSError:
        return [], 0
    text = data.decode("utf-8", "replace")
    if size > limit and "\n" in text: text = text.split("\n", 1)[1]
    return text.split("\n"), size
def parse(tag, lines, last):
    out = []
    for l in lines:
        m = TS.match(l)
        if m: last, l = m.group(1) + " " + m.group(2), l[m.end():]
        if l.strip(): out.append((last, tag, l.rstrip()))
    return out, last
day = [None]
def show(ts, tag, text):
    d, t = (ts.split(" ") + [""])[:2] if ts else ("", "--:--:--")
    if d and d != day[0]:
        day[0] = d; print(("\033[2m" if tty else "") + "── " + d + " ──" + ("\033[0m" if tty else ""))
    for pre in ("ocbar-auth: ", "ocbar-helper: ", "ocbar: "):
        if text.startswith(pre): text = text[len(pre):]; break
    label = TAG[tag].ljust(width)
    if tty: label = "\033[" + COL[tag] + "m" + label + "\033[0m"
    print(t, label, text)
rows, state = [], {}
for tag, path in srcs:
    lines, size = read_tail(path)
    got, last = parse(tag, lines[-(n * 4):], "")
    rows += got; state[tag] = [path, size, last, ""]
rows.sort(key=lambda r: r[0])
for r in rows[-n:]: show(*r)
sys.stdout.flush()
while follow:
    time.sleep(1)
    for tag, st in state.items():
        path, off, last, rest = st
        try: size = os.path.getsize(path)
        except OSError: continue
        if size < off: off, rest = 0, ""
        if size == off: continue
        with open(path, "rb") as f:
            f.seek(off); chunk = rest + f.read(size - off).decode("utf-8", "replace")
        parts = chunk.split("\n"); rest = parts.pop()
        got, last = parse(tag, parts, last)
        for r in got: show(*r)
        st[1:] = [size, last, rest]
    sys.stdout.flush()
