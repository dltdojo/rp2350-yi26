// SPDX-License-Identifier: Apache-2.0
//
// exp228 — script.html's checking, run under node: the block between
// `BEGIN script-check` and `END script-check`, taken out of the page itself,
// fed in 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what page_cases.py --fixtures wrote: script.py's verdicts,
// hashlib's digests, BIP340's vectors and reference.py's signatures, and
// streams as board_chip.c prints them, right and wrong. A board log is what a
// phone gave back; every CASE line in it must be as the page says. Prints
// PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const [page, dir, ...logs] = process.argv.slice(2);
const html = fs.readFileSync(page, 'utf8');
const block = html.slice(html.indexOf('// BEGIN script-check'), html.indexOf('// END script-check'));
const ctx = { TextEncoder };
vm.createContext(ctx);
vm.runInContext(block + '\nthis.api = { sha256, bip340Verify, scriptRun, scriptChecker, scriptLines, fromHex, toHex, CASES, MSG_HEX };', ctx);
const api = ctx.api;

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};
const jsonl = (name) => fs.readFileSync(path.join(dir, name), 'utf8').trim().split('\n').map((l) => JSON.parse(l));

// SHA-256 against hashlib, every length from 0 to 200 bytes.
let bad = '';
const shas = jsonl('sha256.jsonl');
for (const t of shas) {
  const got = api.toHex(api.sha256(api.fromHex(t.in)));
  if (got !== t.out) { bad = `${t.in.length / 2} bytes: ${got}, not ${t.out}`; break; }
}
check(!bad && shas.length === 201, `the page's SHA-256 is hashlib's on every length from 0 to 200 bytes`, bad);

// BIP340 against its test vectors and reference.py's signatures.
bad = '';
const sigs = jsonl('bip340.jsonl');
let yes = 0;
for (const t of sigs) {
  const got = api.bip340Verify(api.fromHex(t.pk), api.fromHex(t.msg), api.fromHex(t.sig));
  if (got !== t.ok) { bad = `${t.from}: the page says ${got}, BIP340 says ${t.ok}`; break; }
  yes += got;
}
const vectors = sigs.filter((t) => t.from.startsWith('vector')).length;
check(!bad, `the page's BIP340 gives all ${vectors} of BIP340's test vectors and ${sigs.length - vectors} signatures `
  + `reference.py made the result they should have (${yes} valid)`, bad);

// The subset against script.py: the hand cases, the arithmetic at the edges, the fuzzed.
const [nHand, nArith, nFuzz] = fs.readFileSync(path.join(dir, 'counts.txt'), 'utf8').trim().split(' ').map(Number);
const msg = api.fromHex(api.MSG_HEX);
const verdicts = jsonl('verdicts.jsonl');
const wrong = [];
verdicts.forEach((t, k) => {
  const r = api.scriptRun(api.fromHex(t.script), t.stack.map(api.fromHex), msg);
  if (r.code !== t.code || r.sigs !== t.sigs || r.valid !== t.valid)
    wrong.push(`#${k} ${t.script.slice(0, 24)}: page ${r.code}/${r.sigs}/${r.valid}, script.py ${t.code}/${t.sigs}/${t.valid}`);
});
check(!wrong.length && verdicts.length === nHand + nArith + nFuzz,
  `the page's interpreter is script.py's on all ${verdicts.length} scripts — ${nHand} by hand, ${nArith} of arithmetic `
  + `at the edges, ${nFuzz} fuzzed — code, signatures checked and valid`, `${wrong.length} differ, first ${wrong[0]}`);
check(api.CASES.length === nHand && api.CASES.every((c, k) => c.script === verdicts[k].script),
  `the page holds the ${nHand} hand cases, in order`);

// Streams as a board sends them.
function feedText(text) {
  const c = api.scriptChecker(api.CASES), split = api.scriptLines(), at = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = c.feed(l);
      if (e.verdict === 'wrong') at.push(`${e.round}:${e.i}`);
    }
  return { ...c.summary(), wrongAt: at.join(' ') };
}
const stream = (name) => feedText(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `cases ${s.cases} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] rounds ${s.rounds} whole ${s.roundsWhole} `
  + `wrong ${s.roundsWrong} status ${s.statuses}/${s.statusBad} bad, FAIL ${s.fails}`;

let s = stream('good.txt');
check(s.cases === 66 && s.ok === 66 && s.roundsWhole === 2 && !s.roundsWrong && !s.statusBad && s.statuses > 0,
  'two rounds as the board sends them, in 64-byte packets: all 66 cases as they should be, both rounds whole', brief(s));
s = stream('code.txt');
check(s.wrong === 1 && s.wrongAt === '3:6' && s.roundsWhole === 1 && s.roundsWrong === 1,
  'case 6 halting with 1: that case is wrong, and its round', brief(s));
s = stream('want.txt');
check(s.wrong === 1 && s.wrongAt === '3:11', 'case 11 carrying the verdict 0 where it is 6: wrong', brief(s));
s = stream('minstret.txt');
check(s.wrong === 1 && s.wrongAt === '4:12', 'case 12 counting one instruction more than the model: wrong', brief(s));
s = stream('sigs.txt');
check(s.wrong === 1 && s.wrongAt === '3:8', "case 8's valid signature reported invalid: wrong", brief(s));
s = stream('name.txt');
check(s.wrong === 1 && s.wrongAt === '4:2', 'case 2 under another name: wrong', brief(s));
s = stream('missing.txt');
check(s.wrong === 0 && s.cases === 65 && s.roundsWhole === 1 && !s.roundsWrong,
  'case 20 of round 3 lost on the way: nothing wrong, and round 3 not seen whole', brief(s));
s = stream('dropped.txt');
check(s.statusBad === 1 && s.wrong === 0, 'a status line saying four lines were dropped is counted', brief(s));
s = stream('fail.txt');
check(s.fails === 1, "a FAIL line from speak.h is counted", brief(s));

for (const log of logs) {
  s = feedText(fs.readFileSync(log, 'utf8'));
  check(s.cases > 0 && s.wrong === 0 && !s.fails && !s.statusBad,
    `${path.basename(log)}: all ${s.cases} cases from a board as the page says; rounds seen whole: ${s.roundsWhole}; `
    + `${s.statuses} status lines`, brief(s));
}
process.exit(failed ? 1 : 0);
