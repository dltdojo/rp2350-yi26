// SPDX-License-Identifier: Apache-2.0
//
// exp237 — enclave.html's checking, run under node: the block between
// `BEGIN enclave-check` and `END enclave-check`, fed in 64-byte packets
// as the USB CDC endpoint delivers them.
//
//   node page_test.mjs PAGE REPORT_TXT
//
// REPORT_TXT is one report in the firmware's format. The committed one is the
// emulator's (emutest.py --lines); a capture from the board, when there is one,
// goes through the same checks. The firmware repeats its report, so the stream
// is the report twice.

import fs from 'node:fs';
import vm from 'node:vm';

const [pagePath, reportPath] = process.argv.slice(2);
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
    for (const ln of split(text.slice(i, i + 64))) checker.feed(ln);
  }
  return checker.summary();
}

const one = fs.readFileSync(reportPath, 'utf8');
const stream = one + one;

const s = feedStream(stream);
check(s.bootOk && s.pmpOk, 'the PMP readback is 0x1f and 0x08015fff');
check(s.ops.length === 3, 'three kernel operations reported', `${s.ops.length}`);
check(s.secretsScrubbed === true, 'the canary left no register non-zero');
check(s.faultsHeld === true, 'all three attacks were refused');
check(s.pass === true, 'the firmware says PASS');
check(s.isComplete === true, 'the report is complete and every number holds', s.errors.join('; '));

// A report the page joined late: no ENCLAVE line, so nothing it says is trusted.
const late = feedStream(one.slice(one.indexOf('\nOP ') + 1));
check(late.isComplete === false, 'a report whose start was missed is not complete');

// Each of these changes one thing, and the page must refuse every one.
const mutants = [
  ['minstret under the model', one.replace('minstret=333', 'minstret=330')],
  ['minstret far over the model', one.replace('minstret=333', 'minstret=345')],
  ['minstret not repeatable', one.replace('again=240', 'again=241')],
  ['model is not exp229\'s', one.replace('model=331', 'model=335')],
  ['a0 not zero', one.replace('a0=0', 'a0=1')],
  ['an operation failed', one.replace('status=OK', 'status=FAIL')],
  ['PMP readback is not the NAPOT entry', one.replace('pmpaddr0=0x08015fff', 'pmpaddr0=0x1fffffff')],
  ['PMP flagged bad', one.replace('pmp=64k_napot', 'pmp=BAD')],
  ['a caller-saved register left non-zero', one.replace('caller_saved_nonzero=0', 'caller_saved_nonzero=3')],
  ['a callee-saved register not restored', one.replace('callee_saved_bad=0', 'callee_saved_bad=1')],
  ['the canary exit code is not the payload\'s', one.replace('exit=0x5a', 'exit=0x00')],
  ['the read attack did not fault with a load access fault', one.replace('mcause=5', 'mcause=2')],
  ['the write attack left the monitor changed', one.replace(/(TEST fault_write [^\n]*)monitor_intact=yes/, '$1monitor_intact=no')],
  ['the bad call was taken for a halt', one.replace(/(TEST fault_badcall [^\n]*?)a0=1/, '$1a0=0')],
  ['an attack is missing', one.replace(/TEST fault_write[^\n]*\n/, '')],
  ['STATUS PASS over a failed test', one.replace('status=OK\nSTATUS PASS', 'status=FAIL\nSTATUS PASS')],
  ['STATUS FAIL', one.replace('STATUS PASS', 'STATUS FAIL first=3')],
];
for (const [what, text] of mutants) {
  check(text !== one, `mutant is a change: ${what}`);
  check(feedStream(text + text).isComplete === false, `refused: ${what}`);
}

process.exit(failed === 0 ? 0 : 1);
