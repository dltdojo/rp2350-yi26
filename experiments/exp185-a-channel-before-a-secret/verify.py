#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp185 verification script: PIN Protocol 1 Key Agreement, ECDH, AES-256-CBC, and HMAC validation.
"""

import json
import os
import sys

def verify_results(data):
    passed = True

    # 1. Check getInfo FIDO_2_1
    versions = data.get("versions", [])
    if "FIDO_2_1" in versions:
        print("PASS  getInfo declares FIDO_2_1 version")
    else:
        print(f"FAIL  getInfo missing FIDO_2_1: {versions}")
        passed = False

    # 2. Check pinUvAuthProtocols declares [1]
    protocols = data.get("pin_protocols", [])
    if 1 in protocols:
        print("PASS  pinUvAuthProtocols declares [1]")
    else:
        print(f"FAIL  pinUvAuthProtocols missing 1: {protocols}")
        passed = False

    # 3. Check getKeyAgreement
    ag_status = data.get("key_agreement_status")
    if ag_status == 0:
        print("PASS  getKeyAgreement returned CTAP2_OK (0x00) with ephemeral P-256 COSE_Key")
    else:
        print(f"FAIL  getKeyAgreement failed: status={ag_status}")
        passed = False

    # 4. Check tunnel_verify_ok (ECDH sharedSecret + HMAC pinAuth + AES-256-CBC decrypt)
    if data.get("tunnel_verify_ok") and data.get("tunnel_verify_status") == 0:
        print("PASS  PIN Protocol 1 tunnel verified (ECDH + HMAC pinAuth + AES-256-CBC)")
    else:
        print(f"FAIL  tunnel verification failed: status={data.get('tunnel_verify_status')}")
        passed = False

    # 5. Check bad_auth_rejected (tampered pinAuth correctly rejected)
    if data.get("bad_auth_rejected") and data.get("bad_auth_status") == 0x32:
        print("PASS  tampered pinAuth correctly rejected with CTAP2_ERR_PIN_AUTH_INVALID (0x32)")
    else:
        print(f"FAIL  tampered pinAuth rejection unexpected: status={data.get('bad_auth_status')}")
        passed = False

    return passed

def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r") as f:
            data = json.load(f)
        if not verify_results(data):
            sys.exit(1)
        return

    # Live hardware verification
    import pin_channel_probe
    pin_channel_probe.run_test()

if __name__ == "__main__":
    main()

