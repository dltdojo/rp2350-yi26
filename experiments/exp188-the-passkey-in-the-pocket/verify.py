#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 rp2350-yi26 contributors
"""
exp188 verification script: Passkey resident keys & credMgmt.
"""

import json
import sys

def verify_results(data):
    passed = True

    # 1. Options check
    if data.get("rk_option_is_true") and data.get("cred_mgmt_option_is_true"):
        print("PASS  getInfo advertises options: { rk: true, credMgmt: true }")
    else:
        print(f"FAIL  options mismatch: rk={data.get('rk_option_is_true')}, credMgmt={data.get('cred_mgmt_option_is_true')}")
        passed = False

    # 2. PIN and Token derivation
    if data.get("set_pin_ok") and data.get("pin_uv_auth_token_derived"):
        print("PASS  PIN configured and pinUvAuthToken derived successfully")
    else:
        print(f"FAIL  PIN setup failed: pin_ok={data.get('set_pin_ok')}, token={data.get('pin_uv_auth_token_derived')}")
        passed = False

    # 3. Initial Metadata
    if data.get("initial_metadata_existing_count") == 0 and data.get("initial_metadata_remaining_count") == 16:
        print("PASS  credMgmt getCredsMetadata (0x01) reports initial existing=0, remaining=16")
    else:
        print(f"FAIL  initial metadata unexpected: existing={data.get('initial_metadata_existing_count')}, remaining={data.get('initial_metadata_remaining_count')}")
        passed = False

    # 4. Passkey Registration
    if data.get("passkey_registration_ok"):
        print("PASS  makeCredential with options: { rk: true } registered resident passkey")
    else:
        print(f"FAIL  passkey registration failed")
        passed = False

    # 5. Post-registration Metadata
    if data.get("post_registration_existing_count") == 1 and data.get("post_registration_remaining_count") == 15:
        print("PASS  credMgmt getCredsMetadata reports post-registration existing=1, remaining=15")
    else:
        print(f"FAIL  post-reg metadata unexpected: existing={data.get('post_registration_existing_count')}, remaining={data.get('post_registration_remaining_count')}")
        passed = False

    # 6. 1-Click Passkey Assertion (empty allowList)
    if (
        data.get("one_click_passkey_assertion_ok")
        and data.get("one_click_returned_user_alice")
        and data.get("one_click_returned_matching_cred_id")
    ):
        print("PASS  1-Click Passkey assertion (empty allowList) located resident key and returned user entity")
    else:
        print(f"FAIL  1-Click passkey assertion failed: ok={data.get('one_click_passkey_assertion_ok')}, user={data.get('one_click_returned_user_alice')}, cred_id={data.get('one_click_returned_matching_cred_id')}")
        passed = False

    # 7. Enumeration
    if data.get("enumerate_rps_ok") and data.get("enumerate_credentials_ok"):
        print("PASS  credMgmt enumerateRPsBegin (0x02) and enumerateCredentialsBegin (0x04) succeeded")
    else:
        print(f"FAIL  credMgmt enumeration failed: rps={data.get('enumerate_rps_ok')}, creds={data.get('enumerate_credentials_ok')}")
        passed = False

    # 8. Deletion & Cleanup
    if (
        data.get("delete_credential_ok")
        and data.get("post_deletion_existing_count") == 0
        and data.get("post_deletion_assertion_rejected_no_creds")
    ):
        print("PASS  credMgmt deleteCredential (0x06) purged passkey; metadata=0, empty assertion rejected")
    else:
        print(f"FAIL  passkey deletion/cleanup failed: del_ok={data.get('delete_credential_ok')}, meta={data.get('post_deletion_existing_count')}, rejected={data.get('post_deletion_assertion_rejected_no_creds')}")
        passed = False

    return passed

def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], "r") as f:
            data = json.load(f)
        if not verify_results(data):
            sys.exit(1)
        return

    import passkey_credmgmt_probe
    passkey_credmgmt_probe.main()

if __name__ == "__main__":
    main()

