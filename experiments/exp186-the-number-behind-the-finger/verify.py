#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp186 verification script: CTAP 2.1 Full PIN Lifecycle State Machine.
"""

import json
import sys

def verify_results(data):
    passed = True

    # 1. Check initial state
    if data.get("initial_client_pin_is_false"):
        print("PASS  initial clientPin is false")
    else:
        print(f"FAIL  initial clientPin unexpected: {data.get('initial_client_pin_is_false')}")
        passed = False

    if data.get("initial_retries") == 8:
        print("PASS  initial retries remaining is 8")
    else:
        print(f"FAIL  initial retries unexpected: {data.get('initial_retries')}")
        passed = False

    # 2. Check setPIN
    if data.get("set_pin_ok"):
        print("PASS  setPIN succeeded (0x00)")
    else:
        print("FAIL  setPIN failed")
        passed = False

    if data.get("post_client_pin_is_true"):
        print("PASS  clientPin is true after setPIN")
    else:
        print(f"FAIL  clientPin did not flip to true")
        passed = False

    # 3. Check bad PIN handling
    if data.get("bad_pin_status") == 0x31 and data.get("bad_pin_decremented_retries"):
        print("PASS  wrong PIN rejected with CTAP2_ERR_PIN_INVALID (0x31) and decremented retries to 7")
    else:
        print(f"FAIL  wrong PIN handling: status={data.get('bad_pin_status')}, retries={data.get('bad_pin_decremented_retries')}")
        passed = False

    # 4. Check good PIN token retrieval
    if data.get("good_pin_status") == 0x00 and data.get("good_pin_reset_retries") and data.get("token_derived_prefix"):
        print("PASS  correct PIN issued pinUvAuthToken and reset retries to 8")
    else:
        print(f"FAIL  good PIN token retrieval failed: status={data.get('good_pin_status')}")
        passed = False

    # 5. Check PIN-authenticated makeCredential (FLAG_UV = 0x04)
    if data.get("make_cred_ok") and data.get("make_cred_uv_flag_set"):
        print("PASS  makeCredential with pinUvAuthParam succeeded with FLAG_UV (0x04)")
    else:
        print(f"FAIL  makeCredential with pinUvAuthParam failed: ok={data.get('make_cred_ok')}, uv={data.get('make_cred_uv_flag_set')}")
        passed = False

    # 6. Check PIN-authenticated getAssertion (FLAG_UV = 0x04)
    if data.get("get_assert_ok") and data.get("get_assert_uv_flag_set"):
        print("PASS  getAssertion with pinUvAuthParam succeeded with FLAG_UV (0x04)")
    else:
        print(f"FAIL  getAssertion with pinUvAuthParam failed: ok={data.get('get_assert_ok')}, uv={data.get('get_assert_uv_flag_set')}")
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
    import pin_lifecycle_probe
    pin_lifecycle_probe.main()

if __name__ == "__main__":
    main()

