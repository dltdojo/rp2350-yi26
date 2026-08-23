#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""The same question, asked of a third device — and the first one that is not ours.

exp176 held this board up next to a commercial key and sorted the fourteen
differences by kind: ten were code the board could write, three were policy
numbers, one was certification. exp178 then showed that a library closes all ten
of the code ones and none of the certification one.

This is the same list again, ruled on by a **third answer running on the same
silicon**: pico-fido, a different team's firmware, on the same Pico 2 that ran
exp174. The question exp176 could not ask is the one this answers — of the ten
differences called "code the board could write", how many has somebody else
actually written, on this chip?

The list is read out of exp176's own comparison.json. If that categorisation
changes, this changes with it and check.sh fails rather than quietly
disagreeing with the file it cites.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EXP176 = os.path.join(HERE, "..", "exp176-the-same-question-of-two-devices")


def load(*parts):
    return json.load(open(os.path.join(*parts)))


def base_option(name):
    """`noclientPin` and `clientPin` are the same option in two states.

    `fido2-token -I` prints an unset boolean option with a `no` prefix, so
    comparing the printed strings would report a device as *having* a
    capability the other lacks when both have it and one has it switched off.
    Names are compared on their base; the state is reported separately.
    """
    return name[2:] if name.startswith("no") and name[2:] in KNOWN_OPTIONS else name


KNOWN_OPTIONS = {"rk", "up", "uv", "plat", "clientPin", "credMgmt", "authnrCfg",
                 "alwaysUv", "largeBlobs", "pinUvAuthToken", "setMinPINLength",
                 "makeCredUvNotRqd", "credentialMgmtPreview", "perCredMgmtRO",
                 "uvToken", "config", "bioEnroll", "userVerificationMgmtPreview"}


def has_version(dev, prefix):
    return any(v.startswith(prefix) for v in dev["versions"])


def closes(capability, pf, cose):
    """Does pico-fido close this one, and on what evidence?

    Written out per capability rather than inferred, for the reason exp176 wrote
    its categorisation by hand: a tick nobody can argue with is a tick nobody
    checked.
    """
    options = pf["options"]
    # The names libfido2 printed, and the numbers the device actually sent.
    # They disagree, and the numbers win: see algorithms.py for why.
    algs = " ".join(pf["algorithms"])
    names = ", ".join(a["name"] for a in cose)
    rules = {
        "U2F_V2": ("U2F_V2" in pf["versions"], "in its version list"),
        "FIDO_2_1_PRE": (has_version(pf, "FIDO_2_1"),
                         "and past it — it claims %s"
                         % ", ".join(v for v in pf["versions"] if v.startswith("FIDO_2_"))),
        "credProtect": ("credProtect" in pf["extensions"], "an extension it announces"),
        "hmac-secret": ("hmac-secret" in pf["extensions"], "an extension it announces"),
        "rk": ("rk" in options, "resident credentials, on the same 4 MiB of flash"),
        "clientPin": (any(o.endswith("clientPin") for o in options),
                      "the option is present (as `noclientPin`: supported, none set)"),
        "credentialMgmtPreview": (
            "credMgmt" in options or "credentialMgmtPreview" in options,
            "as `credMgmt`, the full command rather than the preview"),
        "(no algorithms advertised)": (len(cose) > 0,
                                       "it advertises %s" % names),
        "eddsa": (any(a["cose"] == -8 for a in cose),
                  "it offers %s — three ECDSA curves and no Ed25519. "
                  "`fido2-token -I` prints the third as `unknown`, which is "
                  "libfido2 not naming COSE -36; asking the device for the "
                  "numbers is what turns a guess into a ruling" % names),
        "pin_protocols=1": ("1" in pf["pin_protocols"],
                            "protocols %s" % pf["pin_protocols"]),
    }
    return rules.get(capability)


def main():
    board = load(EXP176, "board.json")
    key = load(EXP176, "yubikey.json")
    pf = load(HERE, "picofido.json")
    cose = load(HERE, "algorithms.json")["algorithms"]
    gap = load(EXP176, "comparison.json")

    ok = True
    result = {"third_device": "pico-fido 8.0 on the same Pico 2",
              "closed": [], "open": [], "beyond_the_commercial_key": []}

    def check(cond, msg):
        nonlocal ok
        print(("PASS  " if cond else "FAIL  ") + msg)
        ok = ok and cond

    # --- of the ten exp176 called code, how many did somebody else write? ---
    code = [g for g in gap["gap"] if g["kind"] == "code"]
    for entry in code:
        cap = entry["capability"]
        rule = closes(cap, pf, cose)
        if rule is None:
            check(False, f"{cap}: no rule written for it — exp176's list moved")
            continue
        done, why = rule
        (result["closed"] if done else result["open"]).append(
            {"capability": cap, "why": why})
        # Not a check: a capability somebody else did not write is a result,
        # and marking it FAIL would make the script's verdict depend on how
        # complete a third party's firmware happens to be.
        print(f"      {cap}: {'written' if done else 'NOT written'} — {why}")

    result["counts"] = {"code_in_exp176": len(code),
                        "closed": len(result["closed"]),
                        "open": len(result["open"])}
    result["algorithms_measured"] = cose
    print("      %d of %d written by another team on the same chip; %d not"
          % (len(result["closed"]), len(code), len(result["open"])))

    # --- and what it does that the commercial key does not ------------------
    # exp176's gap ran one way, because one device was plainly smaller. On the
    # same silicon a third team overshoots the key on several axes, which is
    # the fact that makes "code the board could write" a real claim rather than
    # a generous one.
    for label, mine, theirs in (("versions", pf["versions"], key["versions"]),
                                ("extensions", pf["extensions"], key["extensions"]),
                                # pico-fido's side is the numbers the device
                                # sent, lowercased to match libfido2's spelling
                                # on the other side.
                                ("algorithms", [a["name"].lower() for a in cose],
                                 [a.split(" ")[0] for a in key["algorithms"]]),
                                ("options", [base_option(o) for o in pf["options"]],
                                 [base_option(o) for o in key["options"]])):
        extra = [v for v in mine if v not in theirs]
        missing = [v for v in theirs if v not in mine]
        if extra:
            result["beyond_the_commercial_key"].append({label: extra})
            print(f"NOTE  {label} pico-fido has and the commercial key does not: "
                  + ", ".join(extra))
        if missing:
            result.setdefault("short_of_the_commercial_key", []).append({label: missing})
            print(f"NOTE  {label} the commercial key has and pico-fido does not: "
                  + ", ".join(missing))

    # --- the identity axis, which is the one that does not close ------------
    result["aaguid"] = {"board": board["aaguid"], "pico_fido": pf["aaguid"],
                        "commercial_key": key["aaguid"]}
    check(not pf["aaguid_is_zero"],
          "pico-fido claims a real AAGUID (%s) where the board claims none"
          % pf["aaguid"])
    # And this is the sentence the whole rung exists for.
    result["aaguid_note"] = (
        "An AAGUID is sixteen bytes a firmware asserts about itself, identical "
        "on every board that flashes the same image. Claiming one is code — "
        "which is why this is not a counterexample to exp176 calling the "
        "difference certification. What exp176 named was the authority behind "
        "it and the secret it has to be kept with, and neither is a thing a "
        "firmware can assert about itself. Without Secure Lock, which this "
        "road does not burn, exp175 applies to this image exactly as it "
        "applied to ours.")

    json.dump(result, open(os.path.join(HERE, "comparison.json"), "w"), indent=2)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
