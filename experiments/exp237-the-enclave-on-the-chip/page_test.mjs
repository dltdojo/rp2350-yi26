// SPDX-License-Identifier: Apache-2.0
//
// exp237 — enclave.html's checking, run under node: the block between
// `BEGIN enclave-check` and `END enclave-check`, fed in 64-byte packets
// as the USB CDC endpoint delivers them.
//
//   node page_test.mjs PAGE CAPTURE_TXT
//

import fs from 'node:fs';
import vm from 'node:vm';

const [pagePath, capturePath] = process.argv.slice(2);
const html = fs.readFileSync(pagePath, 'utf8');
const block = html.slice(html.indexOf('// BEGIN enclave-check'), html.indexOf('// END enclave-check'));

const ctx = {};
vm.createContext(ctx);
vm.runInContext(block + '\nthis.enclaveChecker = enclaveChecker; this.enclaveLines = enclaveLines;', ctx);

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};

function feedStream(text) {
  const checker = ctx.enclaveChecker();
  const split = ctx.enclaveLines();
  for (let i = 0; i < text.length; i += 64) {
    const chunk = text.slice(i, i + 64);
    for (const ln of split(chunk)) {
      checker.feed(ln);
    }
  }
  return checker.summary();
}

// 1. Check valid capture
const captureText = fs.readFileSync(capturePath, 'utf8');
const s = feedStream(captureText);

check(s.bootOk === true, 'enclave boots with boot=ok');
check(s.pmpOk === true, 'PMP sandbox configured as 64k_napot');
check(s.instCount === 147, 'monitor verified at 147 instructions');
check(s.ops.length === 3, 'all 3 secp256k1 operations reported');
check(s.pass === true, 'enclave overall status is PASS');
check(s.secretsScrubbed === true, 'all secret registers scrubbed');
check(s.isComplete === true, 'enclave execution complete and verified');

// 2. Corrupted minstret mutant check
const badMinstret = captureText.replace('minstret=331', 'minstret=332');
const sBadMinstret = feedStream(badMinstret);
check(sBadMinstret.isComplete === false && sBadMinstret.errors.length > 0, 'catches wrong minstret count');

// 3. Corrupted a0 mutant check
const badA0 = captureText.replace('a0=0', 'a0=1');
const sBadA0 = feedStream(badA0);
check(sBadA0.isComplete === false && sBadA0.errors.length > 0, 'catches non-zero a0 return');

// 4. Corrupted status check
const badStatus = captureText.replace('status=OK', 'status=FAIL');
const sBadStatus = feedStream(badStatus);
check(sBadStatus.isComplete === false && sBadStatus.errors.length > 0, 'catches failed operation status');

process.exit(failed === 0 ? 0 : 1);

