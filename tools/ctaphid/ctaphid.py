#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""A CTAPHID client, by hand, over `/dev/hidraw`.

    python3 ctaphid.py <case> [args]        one case, one JSON object
    python3 ctaphid.py --list               the cases and what the spec says
    python3 ctaphid.py --socket P <case>    against a device on a Unix socket

# Why this is here and not in an experiment

[exp168](../../experiments/exp168-a-security-key-that-knows-nothing/) wrote the
first one of these, and six experiments after it each derived their own: seven
copies between 238 and 689 lines, six of them textually different. That is the
same accretion the firmware side has, mirrored on the host, and
`experiments/duplication.sh` cannot see it because it only reads Rust.

[exp194](../../experiments/exp194-the-transport-that-drifted/) is the first
caller that needs one client to speak to *several* firmwares — a suite that
changes between boards is not a comparison — so this is where it lives now. The
seven existing copies are grandfathered; nothing rewrites them.

# What a case is

Every case below is one where **CTAP-HID says what the right answer is**, so a
firmware can be graded rather than described. Each returns a JSON object with a
`verdict` field: `"spec"` when the device answered what the specification
requires, otherwise a short reason.

Nothing here parses CBOR. This is the transport, and the transport's contract is
the same whether or not there is an authenticator above it.

# Two transports, and one of them is not evidence

By default a case runs against a board through `/dev/hidraw`. With `--socket` it
runs against [`tools/vctaphid`](../vctaphid/), which answers out of
`crates/ctap-hid` with no hardware anywhere.

That second one is a **pre-flight check and never a verification**: it says a
change to the crate or to this file did not break the ten answers, on a machine
with nothing plugged in. It touches no USB stack, no enumeration and no silicon,
so it may not fill an experiment's `Expected output` and may not lower a
`Needs` level. Every row says which transport produced it, so the two can never
be mistaken for each other after the fact.
"""

import json
import os
import socket
import struct
import sys
import time

PACKET = 64
INIT_HEADER, CONT_HEADER = 7, 5
INIT_PAYLOAD, CONT_PAYLOAD = PACKET - INIT_HEADER, PACKET - CONT_HEADER
BROADCAST = b"\xff\xff\xff\xff"

CTAPHID_PING, CTAPHID_MSG, CTAPHID_INIT = 0x01, 0x03, 0x06
CTAPHID_CBOR, CTAPHID_CANCEL, CTAPHID_ERROR = 0x10, 0x11, 0x3F

# A command number CTAP-HID does not assign and no experiment here implements.
# `unknown` used to be sent as CTAPHID_CBOR, which was right for exp168 (it had
# no CBOR) and wrong for every firmware after it.
CTAPHID_NOT_A_COMMAND = 0x7E

ERR_INVALID_CMD, ERR_INVALID_PAR, ERR_INVALID_LEN = 0x01, 0x02, 0x03
ERR_INVALID_SEQ, ERR_MSG_TIMEOUT, ERR_CHANNEL_BUSY = 0x04, 0x05, 0x06
ERR_INVALID_CHANNEL, ERR_OTHER = 0x0B, 0x7F

ERRORS = {
    ERR_INVALID_CMD: "ERR_INVALID_CMD",
    ERR_INVALID_PAR: "ERR_INVALID_PAR",
    ERR_INVALID_LEN: "ERR_INVALID_LEN",
    ERR_INVALID_SEQ: "ERR_INVALID_SEQ",
    ERR_MSG_TIMEOUT: "ERR_MSG_TIMEOUT",
    ERR_CHANNEL_BUSY: "ERR_CHANNEL_BUSY",
    ERR_INVALID_CHANNEL: "ERR_INVALID_CHANNEL",
    ERR_OTHER: "ERR_OTHER",
}

# The largest message CTAP-HID can express: a 16-bit BCNT, capped by the
# specification at 7609 bytes, and capped again by every implementation here at
# 1024. What matters is not the number but that one byte past it is refused
# rather than truncated.
MAX_PING = 1024


class NoChannel(Exception):
    """The device would not open a channel.

    Broadcast INIT is the client's only recovery path — CTAP-HID has the device
    answer it whatever else is going on — so a device refusing it is a device
    that cannot be talked to, and that is a verdict rather than an error.
    """

    def __init__(self, reply):
        super().__init__(reply)
        self.reply = reply

    def verdict(self):
        if not self.reply:
            return "device would not open a channel: silence"
        if self.reply.get("cmd") == CTAPHID_ERROR:
            return f"device would not open a channel: {self.reply.get('error_name')}"
        return f"device would not open a channel: cmd 0x{self.reply.get('cmd', 0):02x}"


def find_device():
    """The device, found the way libfido2 finds one: by asking every hidraw
    node what its report descriptor says."""
    for name in sorted(os.listdir("/dev")):
        if not name.startswith("hidraw"):
            continue
        try:
            desc = open(f"/sys/class/hidraw/{name}/device/report_descriptor", "rb").read()
        except OSError:
            continue
        # Usage Page (0xF1D0), Usage (0x01) — the two items that make a device a
        # FIDO authenticator to every host tool there is.
        if desc.startswith(b"\x06\xd0\xf1\x09\x01"):
            try:
                return f"/dev/{name}", os.open(f"/dev/{name}", os.O_RDWR)
            except PermissionError:
                continue
    raise SystemExit("no FIDO hidraw device this user can open — is a board flashed?")


class HidrawTransport:
    """A board, through the kernel's HID driver."""

    kind = "hidraw"

    def __init__(self):
        self.path, self.fd = find_device()

    def write(self, pkt):
        # Linux hidraw wants the report number first. This device uses no
        # numbered reports, so it is zero — and leaving it out is a write that
        # succeeds and delivers 63 bytes of the wrong thing.
        os.write(self.fd, b"\x00" + pkt)

    def read(self, timeout):
        end = time.time() + timeout
        os.set_blocking(self.fd, False)
        while time.time() < end:
            try:
                d = os.read(self.fd, PACKET)
                if d:
                    return d
            except BlockingIOError:
                time.sleep(0.002)
        return None


class SocketTransport:
    """`tools/vctaphid`, or anything else that speaks reports on a socket.

    **No leading report-number byte.** That zero is a hidraw convention, not
    part of CTAP-HID, and sending it here would mean the two transports
    disagree about what a 64-byte report is — which would make a case pass on
    one and fail on the other for a reason that is nobody's bug.

    A stream socket may also split a write, so a report is accumulated rather
    than assumed to arrive whole.
    """

    kind = "socket"

    def __init__(self, path):
        self.path = path
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            self.sock.connect(path)
        except OSError as e:
            raise SystemExit(f"no device on {path}: {e} — is tools/vctaphid running?")
        self.held = b""

    def write(self, pkt):
        self.sock.sendall(pkt)

    def read(self, timeout):
        end = time.time() + timeout
        while len(self.held) < PACKET:
            left = end - time.time()
            if left <= 0:
                return None
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(PACKET)
            except (socket.timeout, TimeoutError):
                return None
            if not chunk:
                return None
            self.held += chunk
        pkt, self.held = self.held[:PACKET], self.held[PACKET:]
        return pkt


class Link:
    def __init__(self, transport=None):
        self.transport = transport or HidrawTransport()
        self.path = self.transport.path
        self.last = b""
        # Start from an empty pipe. See `drain`.
        self.drain()

    def drain(self):
        """Throw away anything the device sent before we started listening.

        **exp174 paid for this and only exp174 had it.** Every experiment before
        it had a device that spoke only when spoken to, so a fresh client could
        assume an empty pipe. A device that sends `KEEPALIVE` while it waits
        does not: a run that ends during a presence wait leaves packets in the
        kernel's buffer, and the next `INIT` reads one of them as its own reply
        and fails with a missing channel id.

        It was in one of the seven copies of this client, which is the whole
        argument for there being one — and this shared version did not have it
        until the seven were compared. It is called on construction rather than
        left to a caller to remember, because remembering is what the six other
        copies did not do.
        """
        n = 0
        while True:
            if self.read_packet(timeout=0.05) is None:
                return n
            n += 1

    def send_packet(self, pkt):
        assert len(pkt) == PACKET
        self.transport.write(pkt)

    def read_packet(self, timeout=1.5):
        return self.transport.read(timeout)

    def send_message(self, cid, cmd, data, hold_back=0):
        """Fragment and send. `hold_back` stops short of the byte count the
        header promised, which is how a truncated transaction is built."""
        pkt = bytearray(PACKET)
        pkt[0:4] = cid
        pkt[4] = 0x80 | cmd
        pkt[5:7] = struct.pack(">H", len(data))
        n = min(len(data), INIT_PAYLOAD)
        pkt[INIT_HEADER:INIT_HEADER + n] = data[:n]
        self.send_packet(bytes(pkt))
        sent, seq, packets = n, 0, 1
        while sent < len(data) - hold_back:
            pkt = bytearray(PACKET)
            pkt[0:4] = cid
            pkt[4] = seq
            n = min(len(data) - hold_back - sent, CONT_PAYLOAD)
            pkt[CONT_HEADER:CONT_HEADER + n] = data[sent:sent + n]
            self.send_packet(bytes(pkt))
            sent += n
            seq += 1
            packets += 1
        return packets

    def read_message(self, timeout=1.5):
        first = self.read_packet(timeout)
        if first is None:
            return None
        cid, cmd = first[0:4], first[4]
        if not cmd & 0x80:
            return {"error": "first packet back was a continuation packet"}
        cmd &= 0x7F
        want = struct.unpack(">H", first[5:7])[0]
        data = bytearray(first[INIT_HEADER:INIT_HEADER + min(want, INIT_PAYLOAD)])
        packets, seq = 1, 0
        while len(data) < want:
            nxt = self.read_packet(timeout)
            if nxt is None:
                return {"error": f"message stopped at {len(data)}/{want} bytes"}
            packets += 1
            if nxt[4] != seq:
                return {"error": f"sequence {nxt[4]} where {seq} was due"}
            seq += 1
            data += nxt[CONT_HEADER:CONT_HEADER + min(want - len(data), CONT_PAYLOAD)]
        out = {"cid": cid.hex(), "cmd": cmd, "len": want, "packets": packets}
        if cmd == CTAPHID_ERROR:
            out["error_code"] = data[0]
            out["error_name"] = ERRORS.get(data[0], f"unassigned 0x{data[0]:02x}")
        else:
            # Truncated on purpose. A 1024-byte PING echoes 2 KB of hex, and a
            # transcript nobody will read is a transcript nobody checks.
            out["data_head"] = bytes(data[:16]).hex()
            out["data_len"] = len(data)
        self.last = bytes(data)
        return out

    # -- helpers every case needs ------------------------------------------
    def open_channel(self, nonce=b"\x01\x02\x03\x04\x05\x06\x07\x08"):
        r = self.init(BROADCAST, nonce)
        if not r or r.get("cmd") != CTAPHID_INIT:
            # Not a crash. A device that will not open a channel has answered
            # the question, and exiting here would turn a finding into a
            # missing row — which is what it did the first time this suite met
            # exp189.
            raise NoChannel(r)
        return bytes.fromhex(r["new_cid"])

    def init(self, cid=BROADCAST, nonce=b"\x01\x02\x03\x04\x05\x06\x07\x08"):
        self.send_message(cid, CTAPHID_INIT, nonce)
        r = self.read_message()
        if r and r.get("cmd") == CTAPHID_INIT and len(self.last) >= 17:
            d = self.last
            r["nonce_echoed"] = d[:8] == nonce
            r["new_cid"] = d[8:12].hex()
            r["protocol"] = d[12]
            r["capabilities"] = d[16]
        return r


def wants_error(reply, code):
    """The device answered with exactly the error the specification names."""
    if not reply:
        return "silence"
    if reply.get("cmd") != CTAPHID_ERROR:
        return f"cmd 0x{reply.get('cmd', 0):02x}, not an error"
    got = reply.get("error_code")
    if got != code:
        return f"{ERRORS.get(got, hex(got))}, not {ERRORS[code]}"
    return "spec"


# ---------------------------------------------------------------------------
# The cases. Each returns (result_dict, verdict).

def case_init(link, _args):
    r = link.init()
    out = {"reply": r}
    if not r or r.get("cmd") != CTAPHID_INIT:
        return out, "no INIT reply"
    if not r.get("nonce_echoed"):
        return out, "nonce not echoed"
    if r.get("len") != 17:
        return out, f"{r.get('len')} bytes, not 17"
    if r.get("new_cid") in ("ffffffff", "00000000"):
        return out, f"allocated CID {r.get('new_cid')}"
    return out, "spec"


def case_ping(link, args):
    n = int(args[0]) if args else 57
    cid = link.open_channel()
    payload = bytes((i * 7 + 3) & 0xFF for i in range(n))
    out = {"sent_bytes": n, "sent_packets": link.send_message(cid, CTAPHID_PING, payload)}
    reply = link.read_message(timeout=3.0)
    out["reply"] = reply

    if n > MAX_PING:
        # The one that can go wrong quietly: a device that truncates instead of
        # refusing has answered a question nobody asked.
        return out, wants_error(reply, ERR_INVALID_LEN)

    if not reply:
        return out, "silence"
    if reply.get("cmd") != CTAPHID_PING:
        return out, f"cmd 0x{reply.get('cmd', 0):02x}, not PING"
    out["echo_matches"] = link.last == payload
    if not out["echo_matches"]:
        return out, "echo differs from what was sent"
    return out, "spec"


def case_bad_seq(link, _args):
    cid = link.open_channel()
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = cid, 0x80 | CTAPHID_PING
    pkt[5:7] = struct.pack(">H", 200)
    link.send_packet(bytes(pkt))
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = cid, 3          # 0 was due
    link.send_packet(bytes(pkt))
    reply = link.read_message()
    return {"reply": reply}, wants_error(reply, ERR_INVALID_SEQ)


def case_busy(link, _args):
    a = link.open_channel()
    b = link.open_channel(nonce=b"\x11" * 8)
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = a, 0x80 | CTAPHID_PING
    pkt[5:7] = struct.pack(">H", 200)
    link.send_packet(bytes(pkt))                        # channel A, unfinished
    link.send_message(b, CTAPHID_PING, b"\x00" * 8)     # channel B interrupts
    reply = link.read_message()
    out = {"cid_a": a.hex(), "cid_b": b.hex(), "reply": reply}
    return out, wants_error(reply, ERR_CHANNEL_BUSY)


def case_truncated(link, _args):
    cid = link.open_channel()
    link.send_message(cid, CTAPHID_PING, b"\xaa" * 200, hold_back=100)
    reply = link.read_message(timeout=3.0)
    return {"cid": cid.hex(), "reply": reply}, wants_error(reply, ERR_MSG_TIMEOUT)


def case_unknown(link, _args):
    cid = link.open_channel()
    link.send_message(cid, CTAPHID_NOT_A_COMMAND, b"")
    reply = link.read_message()
    return {"reply": reply}, wants_error(reply, ERR_INVALID_CMD)


def case_bad_cid(link, _args):
    # A channel this device never allocated. The specification reserves 0 and
    # requires ERR_INVALID_CHANNEL for anything not open.
    link.send_message(b"\x00\x00\x00\x00", CTAPHID_PING, b"\x01\x02\x03\x04")
    reply = link.read_message()
    return {"reply": reply}, wants_error(reply, ERR_INVALID_CHANNEL)


def case_busy_recovers(link, _args):
    """After refusing an interrupting channel, the device still answers INIT.

    CTAP-HID's whole recovery story is that a client which has lost track sends
    a broadcast INIT and gets a channel. A device that answers ERR_CHANNEL_BUSY
    to *that* has told the client to go away and left it no way back except
    unplugging the board.
    """
    a = link.open_channel()
    b = link.open_channel(nonce=b"\x11" * 8)
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = a, 0x80 | CTAPHID_PING
    pkt[5:7] = struct.pack(">H", 200)
    link.send_packet(bytes(pkt))                        # channel A, unfinished
    link.send_message(b, CTAPHID_PING, b"\x00" * 8)     # channel B interrupts
    out = {"busy_reply": link.read_message()}

    r = link.init(BROADCAST, nonce=b"\x33" * 8)
    out["init_after_busy"] = r
    if not r:
        return out, "no INIT reply after a busy refusal"
    if r.get("cmd") != CTAPHID_INIT:
        name = r.get("error_name", f"cmd 0x{r.get('cmd', 0):02x}")
        return out, f"broadcast INIT refused with {name} after a busy refusal"
    return out, "spec"


def case_stray_cont(link, _args):
    cid = link.open_channel()
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = cid, 0
    link.send_packet(bytes(pkt))
    reply = link.read_message(timeout=0.8)
    # Silence is the answer. A continuation packet for a transaction nobody
    # started is a packet with nowhere to belong, and the specification has the
    # device ignore it.
    return {"reply": reply}, "spec" if reply is None else "answered a stray packet"


def case_init_resets(link, _args):
    """INIT on an open channel aborts whatever that channel was doing."""
    cid = link.open_channel()
    pkt = bytearray(PACKET)
    pkt[0:4], pkt[4] = cid, 0x80 | CTAPHID_PING
    pkt[5:7] = struct.pack(">H", 200)
    link.send_packet(bytes(pkt))                        # left unfinished
    r = link.init(cid, nonce=b"\x22" * 8)
    out = {"reply": r}
    if not r or r.get("cmd") != CTAPHID_INIT:
        return out, wants_error(r, ERR_INVALID_CMD) if r else "silence"
    if not r.get("nonce_echoed"):
        return out, "nonce not echoed"
    # And the aborted transaction must not answer afterwards.
    out["ping_after"] = link.read_message(timeout=0.8)
    if out["ping_after"] is not None:
        return out, "the aborted transaction still answered"
    return out, "spec"


CASES = {
    "init": (case_init, "17 bytes back, nonce echoed, a channel that is not broadcast"),
    "ping": (case_ping, "echo N bytes exactly; N > 1024 is ERR_INVALID_LEN, not truncation"),
    "bad-seq": (case_bad_seq, "ERR_INVALID_SEQ"),
    "busy": (case_busy, "ERR_CHANNEL_BUSY"),
    "truncated": (case_truncated, "ERR_MSG_TIMEOUT"),
    "unknown": (case_unknown, "ERR_INVALID_CMD"),
    "bad-cid": (case_bad_cid, "ERR_INVALID_CHANNEL"),
    "busy-recovers": (case_busy_recovers, "broadcast INIT still answered after a busy refusal"),
    "stray-cont": (case_stray_cont, "silence"),
    "init-resets": (case_init_resets, "INIT aborts the channel's pending transaction"),
}


def run(case, args, transport=None):
    link = Link(transport)
    fn, _ = CASES[case]
    try:
        out, verdict = fn(link, args)
    except NoChannel as e:
        out, verdict = {"reply": e.reply}, e.verdict()
    # `transport` is in every row on purpose. A verdict from `tools/vctaphid`
    # and a verdict from a board are the same JSON otherwise, and a pre-flight
    # result that cannot be told from a hardware one is how a check becomes a
    # claim nobody watched. See tools/vctaphid/README.md.
    out.update({
        "case": case,
        "device": link.path,
        "transport": link.transport.kind,
        "verdict": verdict,
    })
    return out


def main():
    argv = sys.argv[1:]
    sock = None
    if "--socket" in argv:
        i = argv.index("--socket")
        if i + 1 >= len(argv):
            raise SystemExit("--socket needs a path")
        sock = argv[i + 1]
        del argv[i:i + 2]

    if not argv or argv[0] in ("-h", "--help"):
        raise SystemExit(__doc__)
    if argv[0] == "--list":
        for name, (_, says) in CASES.items():
            print(f"{name:14} {says}")
        return
    case = argv[0]
    if case not in CASES:
        raise SystemExit(f"unknown case: {case}. Try --list.")
    print(json.dumps(run(case, argv[1:], SocketTransport(sock) if sock else None)))


if __name__ == "__main__":
    main()
