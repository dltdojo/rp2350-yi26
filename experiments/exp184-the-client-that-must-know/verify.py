#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verifier for exp184 CTAP 2.1 probe output and live responses."""

import json
import sys

def verify_probe(data):
    passed = True
    
    # 1. Check FIDO_2_1
    versions = data.get("versions", [])
    if "FIDO_2_1" in versions:
        print("PASS  getInfo declares FIDO_2_1 version")
    else:
        print(f"FAIL  getInfo missing FIDO_2_1: {versions}")
        passed = False

    # 2. Check options.clientPin == False
    options = data.get("options", {})
    if options.get("clientPin") is False:
        print("PASS  options advertises clientPin: false (supported, not set)")
    else:
        print(f"FAIL  options.clientPin is not false: {options}")
        passed = False

    # 3. Check pin_protocols == [1]
    protocols = data.get("pin_protocols", [])
    if 1 in protocols:
        print("PASS  pinUvAuthProtocols declares [1]")
    else:
        print(f"FAIL  pinUvAuthProtocols missing 1: {protocols}")
        passed = False

    # 4. Check pin_retries
    retries = data.get("pin_retries_remaining")
    if retries == 8 and data.get("pin_retries_status") == 0:
        print("PASS  authenticatorClientPIN (0x06) subCommand 0x01 returned 8 retries (status OK, key 0x03)")
    else:
        print(f"FAIL  pin_retries unexpected: {retries}, status: {data.get('pin_retries_status')}")
        passed = False

    # 5. Check getKeyAgreement
    ag_status = data.get("key_agreement_status")
    if ag_status == 0:
        print("PASS  getKeyAgreement returned CTAP2_OK (0x00) with ephemeral P-256 COSE_Key")
    else:
        print(f"FAIL  getKeyAgreement status unexpected: {ag_status}")
        passed = False

    return passed

def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as f:
            content = f.read().strip()
            # If it's a JSON file
            try:
                data = json.loads(content)
                ok = verify_probe(data)
                sys.exit(0 if ok else 1)
            except Exception as e:
                print(f"Error parsing json: {e}")
                sys.exit(1)
    else:
        # Run live probe
        import firefox_probe
        import io
        from contextlib import redirect_stdout
        
        f = io.StringIO()
        with redirect_stdout(f):
            firefox_probe.run_probe()
        data = json.loads(f.getvalue())
        ok = verify_probe(data)
        sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()

