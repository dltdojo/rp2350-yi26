#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp187 verification script: On-device gesture UV and CTAP2 Authenticator Reset.
"""

import json
import sys

def verify_results(data):
    passed = True

    # 1. Initial getInfo checks
    if data.get("initial_uv_option_is_true"):
        print("PASS  getInfo advertises uv: true (Built-in UV supported)")
    else:
        print(f"FAIL  getInfo uv option unexpected: {data.get('initial_uv_option_is_true')}")
        passed = False

    if data.get("initial_client_pin_is_false"):
        print("PASS  initial clientPin is false")
    else:
        print(f"FAIL  initial clientPin unexpected: {data.get('initial_client_pin_is_false')}")
        passed = False

    # 2. setPIN check
    if data.get("set_pin_ok") and data.get("post_set_pin_client_pin_is_true"):
        print("PASS  setPIN succeeded and clientPin flipped to true")
    else:
        print(f"FAIL  setPIN failed: {data.get('set_pin_ok')}")
        passed = False

    # 3. Late Reset check (>10s window)
    if data.get("late_reset_status") == 0x30 and data.get("late_reset_rejected_with_0x30"):
        print("PASS  authenticatorReset (0x07) sent >10s after boot correctly rejected with CTAP2_ERR_NOT_ALLOWED (0x30)")
    else:
        print(f"FAIL  late reset rejection unexpected: status={data.get('late_reset_status')}")
        passed = False

    # 4. Built-in gesture UV token issuance
    if data.get("gesture_uv_token_status") == 0x00 and data.get("gesture_uv_token_issued"):
        print("PASS  getPinUvAuthTokenUsingUv (0x06) issued 32B pinUvAuthToken via on-device gesture UV")
    else:
        print(f"FAIL  gesture UV token issuance failed: status={data.get('gesture_uv_token_status')}")
        passed = False

    # 5. makeCredential with UV
    if data.get("make_cred_ok") and data.get("make_cred_uv_flag_set"):
        print("PASS  makeCredential with gesture UV succeeded with FLAG_UV (0x04)")
    else:
        print(f"FAIL  makeCredential with UV failed: ok={data.get('make_cred_ok')}, uv={data.get('make_cred_uv_flag_set')}")
        passed = False

    # 6. Timely Reset within 10s power-on window
    if data.get("timely_reset_status") == 0x00 and data.get("timely_reset_ok"):
        print("PASS  authenticatorReset (0x07) within 10s power-on window succeeded with CTAP2_OK (0x00)")
    else:
        print(f"FAIL  timely reset failed: status={data.get('timely_reset_status')}")
        passed = False

    # 7. Post-Reset validation
    if data.get("post_reset_client_pin_is_false") and data.get("post_reset_retries") == 8:
        print("PASS  post-reset state verified (clientPin wiped to false, retries reset to 8)")
    else:
        print(f"FAIL  post-reset state invalid: pin={data.get('post_reset_client_pin_is_false')}, retries={data.get('post_reset_retries')}")
        passed = False

    # 8. Master salt rotation invalidates old credentials
    if data.get("old_credential_invalidated_after_reset"):
        print("PASS  pre-reset credentials invalidated after reset (salt rotated, CTAP2_ERR_NO_CREDENTIALS)")
    else:
        print(f"FAIL  old credential was not invalidated after reset")
        passed = False

    return passed

def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r") as f:
            data = json.load(f)
        if not verify_results(data):
            sys.exit(1)
        return

    import gesture_reset_probe
    gesture_reset_probe.main()

if __name__ == "__main__":
    main()

