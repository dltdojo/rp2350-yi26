#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
#
# Drive an interactive tool through a pty, answer only what it recognises, and
# write down every word either way.
#
#   python3 control_drive.py OUT.transcript 2 -- ./bin/age-plugin-fido2-hmac -g
#
# The answers are positional and consumed in order, so the transcript pairs each
# question with the key that was sent to it. Everything the pty saw — prompts,
# answers, and the tool's own output, which a pty merges into one stream — goes
# to OUT.transcript.
#
# **It does not guess.** The first version answered anything that looked like a
# prompt with a bare return, on the theory that an empty line is the tool's own
# default. `age-plugin-fido2-hmac` does not have defaults: it printed
# `invalid selection '\n'`, asked again, and would have done so forever, with a
# credential already made and a person's press already spent. So an unrecognised
# prompt, an exhausted answer list, and a rejected answer are all the same
# thing here — stop, and let the transcript be the finding.
import os, pty, re, select, sys, time

if "--" not in sys.argv:
    print("usage: control_drive.py OUT.transcript [ANSWER...] -- CMD...", file=sys.stderr)
    raise SystemExit(64)
cut = sys.argv.index("--")
transcript_path = sys.argv[1]
answers = list(sys.argv[2:cut])
cmd = sys.argv[cut + 1:]
timeout_s = float(os.environ.get("CONTROL_TIMEOUT", "180"))

# The one prompt shape this tool uses, in its own words:
#     (press [1] for "yes" or [2] for "no")
CHOICE = re.compile(rb'press \[(\d)\] for "([^"]*)"')

pid, fd = pty.fork()
if pid == 0:
    # One prompt fewer, and named in the tool's own --help rather than guessed.
    os.execvpe(cmd[0], cmd, dict(os.environ, FIDO2_HMAC_PQ="0"))

seen, buf = [], b""
last_answer, verdict = 0.0, "ran to completion"
deadline = time.time() + timeout_s

def record(msg):
    seen.append(b"\n<<< " + msg.encode() + b"\n")
    print("<<< " + msg, file=sys.stderr)

while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 1.0)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:            # the child closed the pty: it is done
            break
        if not chunk:
            break
        buf += chunk
        seen.append(chunk)
        sys.stdout.buffer.write(chunk); sys.stdout.flush()

    if b"invalid selection" in buf:
        verdict = "the tool rejected an answer this script sent"
        record(verdict)
        break

    # A prompt is a line that has stopped without a newline. The two-second
    # floor is there because a pty echoes what is written to it, and an echo
    # that looks like a prompt would answer itself forever.
    tail = buf.split(b"\n")[-1].rstrip()
    if not tail or time.time() - last_answer <= 2.0:
        continue
    # Over the whole buffer, not the last line: the question and its
    # `(press [1] ...)` line arrive separately, and matching only the tail
    # labelled the answer "?" in the transcript.
    options = CHOICE.findall(buf)
    if not options:
        if tail.endswith((b"?", b":", b">")):
            verdict = "an unrecognised prompt: " + tail.decode(errors="replace")
            record(verdict)
            break
        continue
    if not answers:
        verdict = "the answers ran out at: " + tail.decode(errors="replace")
        record(verdict)
        break
    a = answers.pop(0)
    label = dict((k.decode(), v.decode()) for k, v in options).get(a, "?")
    record(f'answering {a} ("{label}")')
    os.write(fd, a.encode())
    last_answer = time.time()
    buf = b""

else:
    verdict = f"nothing happened for {timeout_s:.0f}s"
    record(verdict)

try:
    os.close(fd)
except OSError:
    pass
try:
    _, status = os.waitpid(pid, 0)
    code = os.waitstatus_to_exitcode(status)
except ChildProcessError:
    code = -1
with open(transcript_path, "wb") as f:
    f.write(b"".join(seen))
    f.write(f"\n<<< {verdict}; exit {code}\n".encode())
raise SystemExit(0 if code == 0 else 1)
