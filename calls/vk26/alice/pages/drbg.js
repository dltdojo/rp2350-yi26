// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/pages — SP 800-90A Rev. 1's Hash_DRBG Generate (§10.1.1.4,
// no additional input), with SHA-256 and seedlen = 440 bits, written here in
// JavaScript with the browser's own SHA-256 (WebCrypto) and BigInt, sharing
// nothing with any kernel or shell. vk26-alice-4's drbg.html wrote it;
// vk26-alice-5's page is the second to need it. build.py puts it into a page.
//
//   drbgHex(s), drbgBig(bytes), drbgBytes(n, len), drbgHash(bytes)
//   drbgGenerate(v, c, counter, m)   m blocks of Hashgen(V), and V and the
//                                    counter afterwards; the reseed check aside

// BEGIN drbg
const DRBG_SEEDLEN = 55;
const DRBG_MOD = 1n << BigInt(8 * DRBG_SEEDLEN);

function drbgHex(s) {
  const b = new Uint8Array(s.length / 2);
  for (let i = 0; i < b.length; i++) b[i] = parseInt(s.slice(2 * i, 2 * i + 2), 16);
  return b;
}
function drbgBig(bytes) { let n = 0n; for (const x of bytes) n = (n << 8n) | BigInt(x); return n; }
function drbgBytes(n, len) {
  const b = new Uint8Array(len);
  for (let i = len - 1; i >= 0; i--) { b[i] = Number(n & 255n); n >>= 8n; }
  return b;
}
async function drbgHash(bytes) { return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)); }

/** SP 800-90A Rev. 1 §10.1.1.4 with no additional input, the reseed check aside:
 *  m blocks of Hashgen(V), and V and the counter afterwards. */
async function drbgGenerate(v, c, counter, m) {
  const bits = new Uint8Array(32 * m);
  let data = drbgBig(v);
  for (let i = 0; i < m; i++) {
    bits.set(await drbgHash(drbgBytes(data, DRBG_SEEDLEN)), 32 * i);
    data = (data + 1n) % DRBG_MOD;
  }
  const pre = new Uint8Array(1 + DRBG_SEEDLEN);
  pre[0] = 3;
  pre.set(v, 1);
  const h = drbgBig(await drbgHash(pre));
  const next = (drbgBig(v) + h + drbgBig(c) + BigInt(counter)) % DRBG_MOD;
  return { bits, v: drbgBytes(next, DRBG_SEEDLEN), counter: counter + 1 };
}
// END drbg
