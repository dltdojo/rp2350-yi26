// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-4 — drbg.html's checking, run under node: the block between
// `BEGIN drbg-check` and `END drbg-check` with core.js's cdcLines
// (../pages/pagetest.mjs: the page's own copy, in a built page) and node's
// WebCrypto, fed in 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote, from drbg.py. A board log is what Save
// gave back from a phone; it must hold whole cases, none of them wrong. Its
// mcycles are printed as the page reads them, not judged.
// Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import { pageContext, checker } from '../pages/pagetest.mjs';

const [page, dir, ...logs] = process.argv.slice(2);
const ctx = pageContext(page, 'drbg-check', ['drbgGenerate', 'drbgHex', 'drbgChecker', 'cdcLines']);
const { check, failed } = checker();

async function run(text) {
  const c = ctx.drbgChecker(), split = ctx.cdcLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = await c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.round}:${e.i}`);
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `cases ${s.cases} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] incomplete ${s.incomplete} `
  + `rounds ${s.rounds} revision ${s.revision} cycles ${s.cycleValues.map((c) => c.join('/')).join(' | ')} fails ${s.fails}`
  + `${s.firstWrong ? ` first: ${s.firstWrong.why}` : ''}`;

// SP 800-90A's arithmetic at its edges, against drbg.py's numbers: V all
// ones, so data + 1 wraps to zero and V + H + C + counter wraps past 2^440.
const ff = ctx.drbgHex('ff'.repeat(55));
const g = await ctx.drbgGenerate(ff, ff, 1, 2);
const want = fs.readFileSync(path.join(dir, 'edge.txt'), 'utf8').trim().split(' ');
const hex = (b) => Buffer.from(b).toString('hex');
check(hex(g.bits) === want[0] && hex(g.v) === want[1] && g.counter === 2,
  'V and C all ones, two blocks: the second block is the hash of 55 zeros, and the sum wraps — drbg.py\'s bits and V',
  `${hex(g.bits).slice(0, 16)}… ${hex(g.v).slice(0, 16)}…`);

let s = await fixture('good.txt');
check(s.cases === 240 && s.ok === 240 && s.wrong === 0 && s.incomplete === 0 && s.rounds === 2 && s.revision === 1
      && s.cycleValues.every((c) => c.length === 1),
  'two rounds as the board sends them, in 64-byte packets: all 240 cases generated right, each run one mcycle', brief(s));
s = await fixture('block.txt');
check(s.wrong === 1 && s.wrongAt === '0:5' && /Generate 2's block 1 is not this page's/.test(s.firstWrong.why),
  'one bit of a block of the second Generate: the page says which Generate and which block', brief(s));
s = await fixture('vnext.txt');
check(s.wrong === 1 && s.wrongAt === '0:2' && s.firstWrong.why === 'V after Generate 1 is not this page\'s',
  'one bit of V after the first Generate: caught, and the second Generate, from the page\'s own V, still right',
  brief(s));
s = await fixture('counter.txt');
check(s.wrong === 1 && /Generate 1 left the counter at 3, not 2/.test(s.firstWrong.why),
  'the first Generate leaving the counter at 3: caught', brief(s));
s = await fixture('reseed.txt');
check(s.wrong === 1 && /run 3 halted with 0: the counter 3 is past the interval, so 1/.test(s.firstWrong.why),
  'the third run generating instead of refusing: caught', brief(s));
s = await fixture('minstret.txt');
check(s.wrong === 1 && /Generate 2's minstret 4319/.test(s.firstWrong.why),
  'the second Generate\'s minstret one more than the RTL\'s: caught', brief(s));
s = await fixture('lost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 11,
  'a BLOCK line lost: that case incomplete, nothing called wrong, the other 11 generated', brief(s));
s = await fixture('midcase.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 11,
  'joined mid-case: the first case incomplete, every one after it generated', brief(s));
s = await fixture('cycles.txt');
check(s.wrong === 0 && s.ok === 24 && s.cycleValues[0].length === 2 && s.cycleValues[1].length === 1,
  'one Generate taking 30 cycles more: nothing wrong, and the page says the cycles differ', brief(s));

for (const log of logs) {
  s = await run(fs.readFileSync(log, 'utf8'));
  check(s.ok > 0 && s.wrong === 0 && !s.fails,
    `${path.basename(log)}: ${s.ok} of ${s.cases} cases from a board generated right, ${s.incomplete} incomplete, `
    + `${s.rounds} rounds; mcycle as read: ${s.cycleValues.map((c) => c.join('/')).join(', ')}`, brief(s));
}
process.exit(failed() ? 1 : 0);
