// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-3 — count.html's checking, run under node: the block between
// `BEGIN count-check` and `END count-check` with ../pages/health.js's and
// core.js's cdcLines (../pages/pagetest.mjs: the page's own copies, in a
// built page), fed in 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote. A board log is what Save gave back from
// a phone; it must hold whole streams, none of them wrong, and one mcycle.
// Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import { pageContext, inPackets, checker } from '../pages/pagetest.mjs';

const [page, dir, ...logs] = process.argv.slice(2);
const ctx = pageContext(page, 'count-check',
  ['countBytes', 'countHistogram', 'countMcv', 'countPerBit', 'countChecker', 'cdcLines']);
const { check, failed } = checker();

async function run(text) {
  const c = ctx.countChecker();
  const wrongAt = await inPackets(c, ctx.cdcLines, text);
  return { ...c.summary(), wrongAt };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `streams ${s.streams} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] incomplete ${s.incomplete} `
  + `rounds ${s.rounds} timed ${s.timed} cycles ${s.cycleValues.join('/')} fails ${s.fails}`
  + `${s.firstWrong ? ` first: ${s.firstWrong.why}` : ''}`;

// The page's count and estimate against count.py's, on every stream count.py has.
let n = 0, bad = '';
for (const ln of fs.readFileSync(path.join(dir, 'judge.txt'), 'utf8').trim().split('\n')) {
  const [most, h, hb, name, hex] = ln.split('|');
  const bytes = ctx.countBytes(hex.split(' ').map((x) => parseInt(x, 16) >>> 0));
  const top = Math.max(...ctx.countHistogram(bytes));
  const mine = ctx.countMcv(top, 4096).h, bit = ctx.countPerBit(bytes).h;
  if (top !== Number(most) || Math.abs(mine - Number(h)) > 1e-9 || Math.abs(bit - Number(hb)) > 1e-9) {
    bad = `${name}: count.py ${most} ${h} ${hb}, the page ${top} ${mine} ${bit}`; break;
  }
  n++;
}
check(!bad && n >= 12, `the page's count and both estimates are count.py's, on all ${n} of count.py's streams`, bad);
const ex = ctx.countMcv(8, 20);
check(Math.abs(ex.pu - 0.6895) < 5e-5 && Math.abs(ex.h - 0.5363) < 5e-5,
  `§6.3.1's own example, p̂ 0.4 of 20: p_u ${ex.pu.toFixed(4)}, H ${ex.h.toFixed(4)}`, `${ex.pu} ${ex.h}`);

let s = await fixture('good.txt');
check(s.streams === 10 && s.ok === 10 && s.wrong === 0 && s.incomplete === 0 && s.rounds === 2
      && s.cycleValues.length === 1 && s.timed === 9,
  'two rounds as the board sends them, in 64-byte packets: all 10 streams counted right, and the 9 after the '
  + 'first one mcycle — the first after boot set aside', brief(s));
s = await fixture('count.txt');
check(s.wrong === 1 && s.wrongAt === '0:1' && /counted \d+ of the value 7, this page \d+/.test(s.firstWrong.why),
  'one of the kernel\'s 256 counts one short: the page says which value', brief(s));
s = await fixture('most.txt');
check(s.wrong === 1 && s.wrongAt === '0:1' && /the largest is 440, not 439/.test(s.firstWrong.why),
  'a largest that is not the largest of the counts: caught', brief(s));
s = await fixture('minstret.txt');
check(s.wrong === 1 && /minstret/.test(s.firstWrong.why), 'minstret one more than the RTL\'s: caught', brief(s));
s = await fixture('cycles.txt');
check(s.wrong === 0 && s.cycleValues.length === 2,
  'one stream taking 4 cycles more: no count is wrong, and the page says the cycles differ', brief(s));
s = await fixture('lost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9,
  'a BITS line lost: that stream incomplete, nothing called wrong, the other 9 counted', brief(s));
s = await fixture('histlost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9,
  'a HIST line lost: that stream incomplete, not judged against counts that never came', brief(s));
s = await fixture('midstream.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9,
  'joined mid-stream: the first stream incomplete, every one after it counted', brief(s));

for (const log of logs) {
  s = await run(fs.readFileSync(log, 'utf8'));
  check(s.ok > 0 && s.wrong === 0 && !s.fails && s.cycleValues.length === 1,
    `${path.basename(log)}: ${s.ok} of ${s.streams} streams from a board counted right, ${s.incomplete} incomplete, `
    + `${s.rounds} rounds, every one of ${s.timed} timed streams ${s.cycleValues.join('/')} cycles`, brief(s));
}
process.exit(failed() ? 1 : 0);
