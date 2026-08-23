#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
otp_audit.py — RP2350 OTP & Secure Lock Dry-Run Auditor

Reads or simulates RP2350 OTP fuse rows, maps Secure Boot (BOOTKEY) and
Secure Lock (CRIT1/CRIT2) registers, and visualizes what bits would be
permanently burned to activate hardware protection — without writing a single bit.
"""

import sys
import json
import argparse
from typing import Dict, List, Tuple

# RP2350 OTP Layout Reference
OTP_ROWS = 4096
ROW_BOOTKEY0 = 0x000
ROW_BOOTKEY1 = 0x002
ROW_BOOTKEY2 = 0x004
ROW_BOOTKEY3 = 0x006
ROW_AES_XIP_KEY0 = 0x008
ROW_CRIT1 = 0x010
ROW_CRIT2 = 0x011

CRIT1_SECURE_BOOT_ENABLE = (1 << 0)
CRIT2_DEBUG_DISABLE = (1 << 1)
CRIT2_NONSECURE_OTP_DISABLE = (1 << 2)

def generate_simulated_otp() -> List[int]:
    """Simulate a standard stock Pico 2 OTP memory map (23 active rows, rest 0)."""
    otp = [0] * OTP_ROWS
    # Standard factory configuration rows (chip ID, wafer info)
    for r in range(0x018, 0x02F):
        otp[r] = 0x12345678 ^ (r * 0x1111)
    return otp

def audit_otp(otp_map: List[int], pubkey_hash: bytes = None, aes_key: bytes = None) -> Dict:
    """Analyze current OTP state and compute the Secure Lock diff."""
    if pubkey_hash is None:
        pubkey_hash = b"\xaa" * 32
    if aes_key is None:
        aes_key = b"\xbb" * 32

    current_crit1 = otp_map[ROW_CRIT1]
    current_crit2 = otp_map[ROW_CRIT2]

    secure_boot_active = bool(current_crit1 & CRIT1_SECURE_BOOT_ENABLE)
    secure_lock_active = bool(current_crit2 & CRIT2_DEBUG_DISABLE)

    # Calculate what would be written
    dry_run_writes = []

    # 1. BOOTKEY0 (8 rows of 32 bits = 256 bits)
    for i in range(8):
        row_idx = ROW_BOOTKEY0 + i
        val = int.from_bytes(pubkey_hash[i*4:(i+1)*4], "little")
        if otp_map[row_idx] != val:
            dry_run_writes.append({
                "row": f"0x{row_idx:03x}",
                "name": f"BOOTKEY0[{i}]",
                "current": f"0x{otp_map[row_idx]:08x}",
                "target": f"0x{val:08x}",
                "purpose": "Public key SHA-256 hash for Secure Boot"
            })

    # 2. AES XIP Key
    for i in range(8):
        row_idx = ROW_AES_XIP_KEY0 + i
        val = int.from_bytes(aes_key[i*4:(i+1)*4], "little")
        if otp_map[row_idx] != val:
            dry_run_writes.append({
                "row": f"0x{row_idx:03x}",
                "name": f"AES_XIP_KEY[{i}]",
                "current": f"0x{otp_map[row_idx]:08x}",
                "target": f"0x{val:08x}",
                "purpose": "Hardware AES-256 Flash decryption key"
            })

    # 3. CRIT1 & CRIT2
    target_crit1 = current_crit1 | CRIT1_SECURE_BOOT_ENABLE
    if current_crit1 != target_crit1:
        dry_run_writes.append({
            "row": f"0x{ROW_CRIT1:03x}",
            "name": "CRIT1 (Configuration Fuse 1)",
            "current": f"0x{current_crit1:08x}",
            "target": f"0x{target_crit1:08x}",
            "purpose": "Enforce Bootrom signature check on boot"
        })

    target_crit2 = current_crit2 | CRIT2_DEBUG_DISABLE | CRIT2_NONSECURE_OTP_DISABLE
    if current_crit2 != target_crit2:
        dry_run_writes.append({
            "row": f"0x{ROW_CRIT2:03x}",
            "name": "CRIT2 (Critical Fuse 2)",
            "current": f"0x{current_crit2:08x}",
            "target": f"0x{target_crit2:08x}",
            "purpose": "Lock SWD debug ports & disable non-secure OTP reads"
        })

    return {
        "status": {
            "secure_boot_active": secure_boot_active,
            "secure_lock_active": secure_lock_active,
            "total_otp_rows": OTP_ROWS,
            "programmed_rows": sum(1 for x in otp_map if x != 0),
        },
        "dry_run_plan": dry_run_writes
    }

def print_audit_report(report: Dict):
    st = report["status"]
    print("=" * 70)
    print("       RP2350 OTP & Secure Lock Hardware Audit Report (DRY-RUN)")
    print("=" * 70)
    print(f"Total OTP Rows       : {st['total_otp_rows']}")
    print(f"Programmed Rows      : {st['programmed_rows']} / {st['total_otp_rows']}")
    print(f"Secure Boot Active   : {'YES' if st['secure_boot_active'] else 'NO (Stock/Unfused)'}")
    print(f"Secure Lock Active   : {'YES' if st['secure_lock_active'] else 'NO (SWD/OTP Readable)'}")
    print("-" * 70)
    print("FUSE PROGRAMMING PLAN (What would be permanently burned):")
    print(f"{'Row':<8} {'Register / Target':<25} {'Current':<12} {'Target':<12} {'Purpose'}")
    print("-" * 70)
    for p in report["dry_run_plan"]:
        print(f"{p['row']:<8} {p['name']:<25} {p['current']:<12} {p['target']:<12} {p['purpose']}")
    print("=" * 70)
    print("SAFETY GUARD: No OTP fuses were programmed. All checks performed in dry-run mode.")

def main():
    parser = argparse.ArgumentParser(description="Audit RP2350 OTP and simulate Secure Lock")
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    args = parser.parse_args()

    otp_map = generate_simulated_otp()
    report = audit_otp(otp_map)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_audit_report(report)

if __name__ == "__main__":
    main()
