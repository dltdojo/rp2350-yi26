#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Put two devices' self-descriptions side by side, and sort the gap by kind.

    python3 compare.py board.json yubikey.json

The finding is not that a commercial key does more — of course it does. It is
*what kind* of thing each difference is. Every capability the board lacks falls
into one of four buckets, and the counts are the argument:

  code          exp174 could implement this; it is software it chose not to write
  certification this needs an authority or a secret the device structurally
                lacks — an attestation identity, a FIDO certification
  silicon       this needs hardware the chip does not have or cannot defend
  policy        a configuration or limit, not a capability

The point the whole authenticator road builds to: **almost the entire gap is
`code`.** The distance from this board to a commercial key's *feature list* is
mostly labour. The one part that is not — a real, verifiable attestation
identity — is exactly the part [exp175](../exp175-the-secret-is-the-file/)
proved this chip cannot honestly keep, because a secret in the image is a secret
anyone with the image has.

The kind assigned to each field is a claim, not a measurement, and it is written
down here field by field so it can be argued with. Where a field is genuinely
two kinds — clientPin is code to implement and also the CTAP 2.1 field that trips
Android's strict parser — the more fundamental kind is chosen and the note says
why.
"""
import json
import sys

# Each entry: (label, kind, note). The note is the defence of the kind.
CAPABILITY_KINDS = {
    "FIDO_2_1_PRE": ("code", "CTAP 2.1 preview commands — more protocol, all implementable"),
    "U2F_V2": ("code", "the CTAP1/U2F legacy path; exp168's capability byte already says nomsg by choice"),
    "credProtect": ("code", "an extension: a policy flag on a credential, pure software"),
    "hmac-secret": ("code", "an extension: HMAC over a per-credential key, pure software"),
    "eddsa": ("code", "a second signature algorithm; the board offers only ES256 because it wrote only ES256"),
    "rk": ("code", "resident credentials need on-device storage, which exp145 already built for other data"),
    "clientPin": ("code", "implementable — and the exact CTAP 2.1 surface that trips Android's strict parser, which is why the road cut it deliberately"),
    "credentialMgmtPreview": ("code", "management of resident credentials; software, and moot until rk exists"),
    "wink": ("code", "a courtesy blink; the board has an LED and simply does not claim it"),
    "msg": ("code", "the CTAP1/U2F transport, declined in exp168's capability byte"),
    "pin_protocols": ("code", "the wire format for PIN; software, gated on clientPin"),
    "algorithms_advertised": ("code", "the board does not list its algorithms in getInfo; a field it could fill"),
    "aaguid": ("certification", "getInfo advertises a real, model-identifying AAGUID; the registration backs it with an x5c certificate from a manufacturer CA. Both need an attestation key that stays secret in a certified device, which exp175 showed this chip cannot keep. (Note: in a fido-u2f attestation the authData AAGUID field is zeroed by spec, so the certificate, not that field, is the real discriminator.)"),
    "max_cred_count_list": ("policy", "a limit that follows from having resident-credential storage at all"),
    "max_cred_len": ("policy", "a length limit, meaningful only once credentials are stored"),
    "pin_retries": ("policy", "a counter that exists only once a PIN does"),
}


def load(path):
    return json.load(open(path))


def diff_lists(a, b):
    """Items in b's list that a's lacks."""
    return [x for x in b if x not in a]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    board, yubi = load(sys.argv[1]), load(sys.argv[2])

    missing = []  # (label, kind, note)

    for field in ("versions", "extensions"):
        for item in diff_lists(board.get(field, []), yubi.get(field, [])):
            kind, note = CAPABILITY_KINDS.get(item, ("code", "unclassified — defaulting to code"))
            missing.append((item, kind, note))

    # Options are not a flat list: `nork`/`noplat`/`up` are the device's own
    # negatives or shared traits, not capabilities the board is missing. Only a
    # positive capability the board lacks is a gap.
    POSITIVE = {"rk", "clientPin", "credentialMgmtPreview", "uv", "bioEnroll",
                "largeBlobs", "credMgmt", "setMinPINLength"}
    for opt in yubi.get("options", []):
        if opt in POSITIVE and opt not in board.get("options", []):
            kind, note = CAPABILITY_KINDS.get(opt, ("code", "a positive option the board does not offer"))
            missing.append((opt, kind, note))

    # Algorithms: the board DOES es256 — it simply does not advertise an
    # algorithms list. So the gap is the missing advertisement plus any
    # algorithm beyond es256, not es256 itself.
    if not board.get("algorithms") and yubi.get("algorithms"):
        kind, note = CAPABILITY_KINDS["algorithms_advertised"]
        missing.append(("(no algorithms advertised)", kind, note))
    for alg in yubi.get("algorithms", []):
        if alg != "es256" and alg not in board.get("algorithms", []):
            kind, note = CAPABILITY_KINDS.get(alg, ("code", "an additional signature algorithm"))
            missing.append((alg, kind, note))

    # Scalars the board leaves unset that the key sets.
    for field, label in (("pin_protocols", "pin_protocols"),
                         ("max_cred_count_list", "max_cred_count_list"),
                         ("max_cred_len", "max_cred_len"),
                         ("pin_retries", "pin_retries")):
        bv, yv = board.get(field), yubi.get(field)
        if (bv in (None, "0", "undefined")) and yv not in (None, "0", "undefined"):
            kind, note = CAPABILITY_KINDS.get(label, ("policy", ""))
            missing.append(("%s=%s" % (label, yv), kind, note))

    # The identity axis, always reported because it is the one that matters.
    if board.get("aaguid_is_zero") and not yubi.get("aaguid_is_zero"):
        kind, note = CAPABILITY_KINDS["aaguid"]
        missing.append(("aaguid %s" % yubi.get("aaguid"), kind, note))

    counts = {}
    for _, kind, _ in missing:
        counts[kind] = counts.get(kind, 0) + 1

    result = {
        "board": board["device"],
        "commercial_key": yubi["device"],
        "board_versions": board.get("versions"),
        "key_versions": yubi.get("versions"),
        "gap": [{"capability": c, "kind": k, "note": n} for c, k, n in missing],
        "counts_by_kind": counts,
        "total": len(missing),
    }
    print(json.dumps(result, indent=2))

    # The sentence the road builds to, printed for a human.
    code = counts.get("code", 0)
    cert = counts.get("certification", 0)
    print("\n%d of %d differences are code the board could write; "
          "%d %s certification the chip cannot honestly anchor (see exp175)."
          % (code, len(missing), cert, "is" if cert == 1 else "are"),
          file=sys.stderr)


if __name__ == "__main__":
    main()
