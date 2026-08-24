#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Test makeCredential waiting for BOOTSEL button press."""

import os
import struct
import sys
import time
from firefox_probe import Link, CTAPHID_INIT, CTAPHID_CBOR, BROADCAST, AUTHENTICATOR_MAKE_CREDENTIAL, cbor_decode

def main():
    link = Link()
    link.drain()
    
    # 1. INIT
    nonce = os.urandom(8)
    link.send_message(BROADCAST, CTAPHID_INIT, nonce)
    r = link.read_message()
    if not r or r[:8] != nonce:
        print("INIT failed")
        return
    cid = r[8:12]
    
def cbor_uint(v):
    if v < 24:
        return bytes([v])
    return bytes([24, v])

def cbor_nint(v):
    val = -1 - v
    if val < 24:
        return bytes([(1 << 5) | val])
    return bytes([(1 << 5) | 24, val])

def cbor_bytes(b):
    if len(b) < 24:
        return bytes([(2 << 5) | len(b)]) + b
    return bytes([(2 << 5) | 24, len(b)]) + b

def cbor_text(s):
    b = s.encode()
    if len(b) < 24:
        return bytes([(3 << 5) | len(b)]) + b
    return bytes([(3 << 5) | 24, len(b)]) + b

def cbor_array(items):
    return bytes([(4 << 5) | len(items)]) + b"".join(items)

def cbor_map(pairs):
    return bytes([(5 << 5) | len(pairs)]) + b"".join(k + v for k, v in pairs)

def build_mc():
    cdh = os.urandom(32)
    pairs = [
        (cbor_uint(1), cbor_bytes(cdh)),
        (cbor_uint(2), cbor_map([(cbor_text("id"), cbor_text("webauthn.io")), (cbor_text("name"), cbor_text("webauthn.io"))])),
        (cbor_uint(3), cbor_map([(cbor_text("id"), cbor_bytes(b"user123")), (cbor_text("name"), cbor_text("testuser"))])),
        (cbor_uint(4), cbor_array([cbor_map([(cbor_text("alg"), cbor_nint(-7)), (cbor_text("type"), cbor_text("public-key"))])])),
    ]
    return cbor_map(pairs)

def main():
    link = Link()
    link.drain()
    
    # 1. INIT
    nonce = os.urandom(8)
    link.send_message(BROADCAST, CTAPHID_INIT, nonce)
    r = link.read_message()
    if not r or r[:8] != nonce:
        print("INIT failed")
        return
    cid = r[8:12]
    
    # 2. makeCredential
    mc_cbor = build_mc()
    print("Sending makeCredential... PLEASE WATCH THE BOARD LED!")
    print("If LED is SOLID ON, press BOOTSEL button now (within 5 seconds)!")
    link.send_message(cid, CTAPHID_CBOR, bytes([AUTHENTICATOR_MAKE_CREDENTIAL]) + mc_cbor)
    
    resp = link.read_message(timeout=6.0)
    if resp is None:
        print("Timed out waiting for presence or response")
    elif resp[0] == 0:
        print("SUCCESS! Credential created successfully!")
    else:
        print(f"Error from authenticator: status={resp[0]:#04x}")

if __name__ == "__main__":
    main()
