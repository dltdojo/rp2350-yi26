#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Check exp168's transcript against the protocol, off the board.

    python3 verify.py < capture.txt

Prints OK, DISAGREE or INCOMPLETE on the last line.

Two voices, on two interfaces: `>>> host:` lines and the JSON under them come
from a CTAPHID client talking to /dev/hidraw, and the `[ ms]` lines come from
the board's own CDC log. Neither is trusted about the other.

The derivation that matters is arithmetic, not agreement. A CTAPHID
initialisation packet carries 57 payload bytes and each continuation packet
carries 59, so the number of packets a message of N bytes takes is

    1 + ceil(max(0, N - 57) / 59)

and that is computed here from N rather than read from the log. A device that
fragmented wrongly but consistently would satisfy every "the host and the board
agree" check and fail this one.

Also derived:

  - every echo came back byte-identical, for every length below the limit;
  - each deliberate mistake drew the error code the specification names, and
    the codes are not interchangeable;
  - a continuation packet for a transaction nobody started drew **silence**,
    which is the one place CTAPHID prescribes no answer;
  - the report descriptor the board printed is 34 bytes and begins with usage
    page 0xF1D0, which is the only reason a host's FIDO tooling looks at it;
  - the capability byte says `nocbor` and `nomsg`, which is this device
    declaring in the protocol's own words that it knows nothing.
"""

import json
import math
import re
import sys


class NotCanonical(Exception):
    """Valid CBOR that CTAP2 will not accept, which is a different thing from
    invalid CBOR and is the one this device could plausibly emit."""


def decode(b, at=0, depth=0):
    """A CBOR reader that **fails on anything non-canonical**.

    It is not a general decoder and must not become one: every branch that a
    permissive reader would accept and normalise is a branch where a device
    could be quietly wrong. Shortest-form arguments, definite lengths and
    ascending map keys are checked here rather than assumed, because the board
    is the thing under test and this is the only independent opinion about its
    bytes.
    """
    if at >= len(b):
        raise NotCanonical("ran off the end")
    ib = b[at]
    mt, ai = ib >> 5, ib & 0x1F
    at += 1
    if ai < 24:
        arg = ai
    elif ai == 24:
        arg = b[at]
        if arg < 24:
            raise NotCanonical(f"{arg} written in two bytes; it fits in one")
        at += 1
    elif ai == 25:
        arg = int.from_bytes(b[at:at + 2], "big")
        if arg <= 0xFF:
            raise NotCanonical(f"{arg} written in three bytes; it fits in fewer")
        at += 2
    elif ai == 26:
        arg = int.from_bytes(b[at:at + 4], "big")
        if arg <= 0xFFFF:
            raise NotCanonical(f"{arg} written in five bytes; it fits in fewer")
        at += 4
    elif ai == 27:
        arg = int.from_bytes(b[at:at + 8], "big")
        if arg <= 0xFFFFFFFF:
            raise NotCanonical(f"{arg} written in nine bytes; it fits in fewer")
        at += 8
    elif ai == 31:
        raise NotCanonical("an indefinite length, which CTAP2 forbids")
    else:
        raise NotCanonical(f"reserved additional information {ai}")

    if mt == 0:
        return arg, at
    if mt == 2:
        return bytes(b[at:at + arg]), at + arg
    if mt == 3:
        return b[at:at + arg].decode(), at + arg
    if mt == 4:
        out = []
        for _ in range(arg):
            v, at = decode(b, at, depth + 1)
            out.append(v)
        return out, at
    if mt == 5:
        out, last = {}, None
        for _ in range(arg):
            k, at = decode(b, at, depth + 1)
            if not isinstance(k, int):
                raise NotCanonical("a map key that is not an unsigned integer")
            if last is not None and k <= last:
                raise NotCanonical(f"map key {k} does not follow {last}")
            last = k
            v, at = decode(b, at, depth + 1)
            out[k] = v
        return out, at
    if mt == 7:
        if arg == 20:
            return False, at
        if arg == 21:
            return True, at
        raise NotCanonical(f"simple value {arg}, which this subset does not use")
    raise NotCanonical(f"major type {mt}, which this subset does not use")

INIT_PAYLOAD, CONT_PAYLOAD = 57, 59

#: What each case must produce. `None` means no reply at all.
EXPECTED = {
    "init": ("reply", 6),
    "ping 58": ("echo", 58),
    "ping 1024": ("echo", 1024),
    "ping 2000": ("error", "ERR_INVALID_LEN"),
    "bad-seq": ("error", "ERR_INVALID_SEQ"),
    "busy": ("error", "ERR_CHANNEL_BUSY"),
    "truncated": ("error", "ERR_MSG_TIMEOUT"),
    "unknown": ("error", "ERR_INVALID_CMD"),
    "stray-cont": ("silence", None),
    "getinfo": ("ctap", "CTAP2_OK"),
    "getinfo-params": ("ctap", "CTAP1_ERR_INVALID_LENGTH"),
    "ctap-unknown": ("ctap", "CTAP1_ERR_INVALID_COMMAND"),
    # **The eight this experiment exists for.** Three different statuses, and
    # which one comes back is the finding: a request this device could not read,
    # one that was missing something, and one it read in full and refused
    # anyway are three different answers, and exp169 could only give the first.
    # **CTAP2_OK now.** exp170 refused this having understood it; this one
    # makes the credential, and the transcript carries a relying party's
    # verdict on the bytes rather than the board's opinion of them.
    "mc-good": ("ctap", "CTAP2_OK"),
    "mc-lying-length": ("ctap", "CTAP2_ERR_INVALID_CBOR"),
    "mc-noncanonical": ("ctap", "CTAP2_ERR_INVALID_CBOR"),
    "mc-trailing": ("ctap", "CTAP2_ERR_INVALID_CBOR"),
    "mc-missing-cdh": ("ctap", "CTAP2_ERR_MISSING_PARAMETER"),
    "mc-missing-params": ("ctap", "CTAP2_ERR_MISSING_PARAMETER"),
    "mc-no-es256": ("ctap", "CTAP2_ERR_UNSUPPORTED_ALGORITHM"),
    "mc-many-algs": ("ctap", "CTAP2_OK"),
    # **The round trip.** Register, then assert with the credential that came
    # back, and verify the assertion against the public key registration handed
    # over. If the board derived a different key the second time, this fails and
    # there is nowhere for it to hide.
    "ga-roundtrip": ("ctap", "CTAP2_OK"),
    "ga-decoys": ("ctap", "CTAP2_OK"),
    "ga-forged": ("ctap", "CTAP2_ERR_NO_CREDENTIALS"),
    "ga-other-rp": ("ctap", "CTAP2_ERR_NO_CREDENTIALS"),
    "ga-wrong-length": ("ctap", "CTAP2_ERR_NO_CREDENTIALS"),
    "ga-empty-allow": ("ctap", "CTAP2_ERR_NO_CREDENTIALS"),
    "ga-no-allow": ("ctap", "CTAP2_ERR_NO_CREDENTIALS"),
}

CASE = re.compile(r"^>>> host: case (?P<case>.+?)\s*$")


def packets_for(n):
    """How many packets a message of n bytes must take. The whole of CTAPHID's
    fragmentation, in one line, computed rather than observed."""
    if n <= INIT_PAYLOAD:
        return 1
    return 1 + math.ceil((n - INIT_PAYLOAD) / CONT_PAYLOAD)


def main():
    lines = [l.rstrip("\n") for l in sys.stdin]
    problems, notes = [], []

    seen = {}
    info_seen = []
    case = None
    for l in lines:
        m = CASE.match(l)
        if m:
            case = m.group("case")
            continue
        stripped = l.strip()
        if case and stripped.startswith("{"):
            try:
                seen[case] = json.loads(stripped)
            except json.JSONDecodeError:
                problems.append(f"{case}: the client's output is not JSON")
            case = None

    missing = [c for c in EXPECTED if c not in seen]
    if missing:
        print(f"cases with no result in this transcript: {', '.join(missing)}")
        print("INCOMPLETE")
        return 1

    for name, (kind, want) in EXPECTED.items():
        d = seen[name]
        r = d.get("reply")
        if kind == "silence":
            if r is not None:
                problems.append(f"{name}: expected no reply, got {r}")
            continue
        if r is None:
            problems.append(f"{name}: no reply at all")
            continue
        if kind == "error":
            if r.get("error_name") != want:
                problems.append(f"{name}: expected {want}, got {r.get('error_name')}")
            continue
        if kind == "ctap":
            # A CTAP2 reply is a CTAPHID_CBOR message, not a CTAPHID_ERROR one.
            # A device that answered a CTAP2 command with a transport error
            # would look "refused" to a careless reading and be wrong about
            # which layer said no — exp136's concern, one layer up again.
            if r.get("cmd") != 0x10:
                problems.append(f"{name}: answered on command {r.get('cmd')}, not CTAPHID_CBOR")
            if d.get("status_name") != want:
                problems.append(f"{name}: expected {want}, got {d.get('status_name')}")
            body = d.get("cbor", "")
            if want == "CTAP2_OK" and name.startswith("ga-"):
                a = d.get("assertion")
                if not a:
                    problems.append(f"{name}: CTAP2_OK with no assertion to check")
                    continue
                if not a.get("signature_valid"):
                    problems.append(
                        f"{name}: the assertion does not verify against the key from registration"
                    )
                if not a.get("tamper_rejected"):
                    problems.append(f"{name}: a flipped bit still verified — the check proves nothing")
                if not a.get("rp_id_hash_matches"):
                    problems.append(f"{name}: rpIdHash is not the relying party that was asked for")
                if not a.get("credential_id_echoed"):
                    problems.append(f"{name}: the credential the device chose is not the one offered")
                # Attested credential data belongs to registration. A device
                # that copied its own makeCredential path would attach a public
                # key nobody asked for.
                if a.get("attested_data"):
                    problems.append(f"{name}: the AT flag is set in an assertion")
                if a.get("auth_data_len") != 37:
                    problems.append(
                        f"{name}: authenticator data is {a.get('auth_data_len')} bytes, not 37"
                    )
                if a.get("credential_type") != "public-key":
                    problems.append(f"{name}: credential type is {a.get('credential_type')}")
                if a.get("trailing"):
                    problems.append(f"{name}: {a['trailing']} bytes after the response map")
                notes.append(
                    f"{name}: verified against the registered key, authData "
                    f"{a.get('auth_data_len')} B, UP={int(bool(a.get('user_present')))}"
                )
                continue
            if want == "CTAP2_OK" and name.startswith("mc-"):
                # A credential, checked by the host's own elliptic-curve
                # library and not by the one that made it.
                c = d.get("credential")
                if not c:
                    problems.append(f"{name}: CTAP2_OK with no credential to check")
                    continue
                if not c.get("signature_valid"):
                    problems.append(f"{name}: the attestation signature does not verify")
                if not c.get("tamper_rejected"):
                    problems.append(f"{name}: a flipped bit still verified — the check proves nothing")
                if not c.get("rp_id_hash_matches"):
                    problems.append(f"{name}: rpIdHash is not SHA-256 of the relying party id")
                if c.get("cose_alg") != -7 or c.get("cose_kty") != 2 or c.get("cose_crv") != 1:
                    problems.append(f"{name}: the COSE key is not P-256 ES256")
                if c.get("coordinate_bytes") != [32, 32]:
                    problems.append(f"{name}: the public key coordinates are not 32 bytes each")
                if c.get("fmt") != "packed":
                    problems.append(f"{name}: attestation format is {c.get('fmt')}, not packed")
                # Self attestation and a non-zero AAGUID are a contradiction the
                # specification forbids, and it is the kind a device gets wrong
                # by copying somebody else's constant.
                if not c.get("att_has_x5c") and not c.get("aaguid_all_zero"):
                    problems.append(f"{name}: self attestation with a non-zero AAGUID")
                if c.get("att_has_x5c"):
                    problems.append(f"{name}: a certificate appeared, and this device has none")
                if c.get("user_verified"):
                    problems.append(f"{name}: the UV bit is set and this device cannot verify anybody")
                if c.get("trailing"):
                    problems.append(f"{name}: {c['trailing']} bytes after the response map")
                if not c.get("attested_data"):
                    problems.append(f"{name}: the AT flag is clear, so there is no credential in it")
                notes.append(
                    f"{name}: UP={int(bool(c.get('user_present')))} "
                    f"credId={c.get('credential_id_len')}B signCount={c.get('sign_count')}"
                )
                continue
            if want != "CTAP2_OK":
                # A refusal carries a status byte and nothing else. Bytes after
                # it are a response the host will try to parse.
                if body:
                    problems.append(f"{name}: a refusal carried {len(body) // 2} bytes of CBOR")
                continue
            if not body:
                problems.append(f"{name}: CTAP2_OK with no response body")
                continue
            try:
                info, at = decode(bytes.fromhex(body))
            except NotCanonical as e:
                problems.append(f"{name}: the response is not canonical CBOR: {e}")
                continue
            if at != len(body) // 2:
                problems.append(f"{name}: {len(body) // 2 - at} trailing bytes after the map")
            if not isinstance(info, dict):
                problems.append(f"{name}: the response is not a map")
                continue
            # The three keys this device sends, each checked for what it means
            # rather than for being present.
            if 0x03 not in info:
                problems.append(f"{name}: no aaguid, which getInfo requires")
            elif len(info[0x03]) != 16:
                problems.append(f"{name}: the aaguid is {len(info[0x03])} bytes, not 16")
            elif any(info[0x03]):
                notes.append("the aaguid is not all-zero: this device claims a model")
            if 0x01 not in info:
                problems.append(f"{name}: no versions field, which getInfo requires")
            else:
                notes.append(f"versions: {info[0x01] or 'none claimed'}")
            if 0x05 in info:
                notes.append(f"maxMsgSize: {info[0x05]}")
            info_seen.append(info)
            continue
        if kind == "reply":
            if r.get("cmd") != want:
                problems.append(f"{name}: expected command {want:#04x}, got {r.get('cmd')}")
            if not d["reply"].get("nonce_echoed", d.get("nonce_echoed")):
                problems.append(f"{name}: the nonce was not echoed")
            continue

        # An echo. Three separate things have to hold, and only the first is
        # what a naive check would look at.
        if r.get("len") != want:
            problems.append(f"{name}: {r.get('len')} bytes back, {want} sent")
        if not d.get("echo_matches"):
            problems.append(f"{name}: the bytes that came back are not the bytes that went out")
        for side, key in (("sent", "sent_packets"), ("received", "packets")):
            got = d.get(key) if key in d else r.get(key)
            need = packets_for(want)
            if got != need:
                problems.append(f"{name}: {got} packets {side}, arithmetic says {need}")

    # ---- channels ---------------------------------------------------------
    cids = [d["reply"]["cid"] for d in seen.values() if d.get("reply")]
    if "00000000" in cids:
        problems.append("a reserved channel identifier was allocated")
    inits = [d for n, d in seen.items() if n == "init"]
    if inits and inits[0]["reply"].get("new_cid") in ("00000000", "ffffffff"):
        problems.append("INIT allocated a reserved or broadcast channel")

    # ---- the board's own voice --------------------------------------------
    board = [l.strip() for l in lines if re.match(r"^\s*\[\s*\d+ ms\]", l)]
    if any("lines lost" in l for l in board):
        problems.append("the board's log has a gap: usb-log dropped lines")
    desc = "".join(
        re.sub(r"^\[\s*\d+ ms\]\s+", "", l) for l in board if re.search(r"^\[\s*\d+ ms\]\s+[0-9a-f]{20,}$", l)
    )
    if desc:
        if len(desc) != 68:
            problems.append(f"the printed report descriptor is {len(desc) // 2} bytes, not 34")
        if not desc.startswith("06d0f10901"):
            problems.append("the report descriptor does not begin with usage page 0xF1D0")
        notes.append(f"report descriptor: {len(desc) // 2} bytes, usage page 0xF1D0")
    else:
        problems.append("the board never printed its report descriptor")

    caps = next((l for l in lines if "caps:" in l), None)
    if caps is None:
        problems.append("fido2-token -I did not report the device's capabilities")
    else:
        # This device has CBOR now and still has no MSG, and both halves are
        # checked: a capability byte that under-claims is as wrong as one that
        # over-claims, because a host acts on it either way.
        if "cbor" not in caps or "nocbor" in caps:
            problems.append(f"the capability byte does not announce CBOR: {caps.strip()}")
        if "nomsg" not in caps:
            problems.append(f"the device claims CTAP1/U2F, which it does not have: {caps.strip()}")
        notes.append(caps.strip())

    # **The board's own report of what it read.** A status byte says a request
    # was refused; only the log says the device understood it, and a device that
    # refused everything without reading would produce the same statuses.
    if not any("rp.id" in l for l in lines):
        problems.append("no request was ever reported as parsed: the statuses could be reflexes")
    else:
        notes.append(next(l for l in lines if "rp.id" in l).strip())
    if not any("(ES256)" in l for l in lines):
        problems.append("ES256 was never recognised in a request that offered it")
    if not any("the private key is not stored" in l for l in lines):
        problems.append("the log never says the key was derived rather than kept")
    if not any("the same key as at registration" in l for l in lines):
        problems.append("no assertion was made, so nothing showed the key coming back")
    # A refusal has to happen *before* any key is derived. A device that derived
    # first and checked afterwards would produce the same status and would have
    # done the work an attacker wanted it to do.
    if not any("no key is derived at all" in l for l in lines):
        problems.append("nothing shows a forged credential being refused before a derivation")
    timing = next((l for l in lines if "derive " in l and " sign " in l), None)
    if timing:
        notes.append(timing.split("] ")[-1].strip())
    else:
        problems.append("no derive/sign timing in the transcript")
    # A refusal that is not a parse failure has to be distinguishable in the log
    # as well as in the status byte.
    if not any("nothing was read past the buffer" in l for l in lines):
        problems.append("no hostile request was refused, so the bounds check is untested here")

    listed = next((l for l in lines if "/dev/hidraw" in l and "vendor=" in l), None)
    if listed is None:
        problems.append("fido2-token -L did not list the device")
    else:
        notes.append("listed by the host's own FIDO tooling, unprivileged")

    for n in notes:
        print(f"note: {n}")
    print(
        "OPEN: the device secret is a compiled-in test key, so every credential "
        "here is reproducible by anybody holding the firmware"
    )

    if problems:
        for p in problems:
            print(f"  - {p}")
        print("DISAGREE")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
