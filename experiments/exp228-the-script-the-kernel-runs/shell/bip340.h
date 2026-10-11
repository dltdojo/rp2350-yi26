// SPDX-License-Identifier: Apache-2.0
//
// exp228 — BIP340 Schnorr signature verification over secp256k1, the shell's
// answer to the kernel's CHECKSIG. See bip340.c.
#pragma once
#include <stdint.h>

// 1 when sig (64 bytes) is a valid BIP340 signature of the msg_len bytes at
// msg under the x-only public key pk (32 bytes), 0 otherwise.
int bip340_verify(const uint8_t pk[32], const uint8_t *msg, uint32_t msg_len, const uint8_t sig[64]);
