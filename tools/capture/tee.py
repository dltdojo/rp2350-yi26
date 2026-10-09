#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
#
# tee, plus when each line arrived.
#
#   { ... } 2>&1 | python3 tools/capture/tee.py capture.txt build/capture-timing.txt
#
# Copies stdin to stdout and to CAPTURE byte for byte, a line at a time, and
# writes nothing else there. When stdin ends, TIMING gets the arithmetic:
#   - the sections, each `>>>` line to the next, longest first;
#   - the slowest lines, each charged with the wait since the line before it,
#     which is how long whatever printed it took;
#   - every line, with its time from the start and that wait.
#
# A line is charged when it arrives, so a program that buffers its output —
# Python writing into a pipe, for one — shows as one long wait on its first
# line and nothing on the rest. The sections are right regardless: a `>>>` line
# is echoed by bash after the previous command has exited and flushed.

import re
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;]*m")


def mmss(s):
    m, s = divmod(int(round(s)), 60)
    return f"{m}m{s:02d}s"


def text(line, width=110):
    t = ANSI.sub(b"", line).decode("utf-8", "replace").rstrip()
    return t if len(t) <= width else t[: width - 1] + "…"


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: tee.py CAPTURE TIMING")
    capture, timing = sys.argv[1], sys.argv[2]
    start = time.monotonic()
    lines = []   # (seconds from start, wait since the line before, bytes)
    last = start
    out = sys.stdout.buffer
    with open(capture, "wb") as cap:
        for line in sys.stdin.buffer:
            now = time.monotonic()
            out.write(line)
            out.flush()
            cap.write(line)
            cap.flush()
            lines.append((now - start, now - last, line))
            last = now
    total = time.monotonic() - start

    sections = []   # [title, start]
    for t, _, line in lines:
        if line.startswith(b">>>"):
            sections.append([text(line[3:].strip()), t])
    if lines and (not sections or sections[0][1] > 0):
        sections.insert(0, ["(before the first >>>)", 0.0])
    durations = [(sections[i + 1][1] if i + 1 < len(sections) else total) - s[1]
                 for i, s in enumerate(sections)]

    title = text(lines[0][2]) if lines else capture
    with open(timing, "w") as f:
        f.write(f"{title}\n")
        f.write(f"total {mmss(total)}, {len(lines)} lines into {capture}\n\n")
        f.write("sections, longest first\n")
        for d, (name, _) in sorted(zip(durations, sections), key=lambda x: -x[0]):
            f.write(f"  {mmss(d):>7}  {100 * d / total if total else 0:4.0f}%  {name}\n")
        f.write("\nslowest lines: the wait before each\n")
        for t, w, line in sorted(lines, key=lambda x: -x[1])[:20]:
            f.write(f"  {mmss(w):>7}  at {mmss(t):>7}  {text(line)}\n")
        f.write("\nevery line: from the start, the wait before it\n")
        for t, w, line in lines:
            f.write(f"  {t:8.1f}  {w:7.1f}  {text(line)}\n")
    print(f"timing: {timing} (total {mmss(total)})", file=sys.stderr)


if __name__ == "__main__":
    main()
