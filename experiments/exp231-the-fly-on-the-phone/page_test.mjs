// SPDX-License-Identifier: Apache-2.0
//
// exp231 — fly.html's checking, run under node: the block between
// `BEGIN fly-check` and `END fly-check`, taken out of the page itself, fed in
// 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote: streams rule30.py and fly.py made, right
// and wrong, and pairs.txt — random pairs of words with rule30.py's next
// generation of the first and fly.py's counts between them. A board log is
// what Copy gave back from a phone; it must hold steps, none of them wrong.
// Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const [page, dir, ...logs] = process.argv.slice(2);
const html = fs.readFileSync(page, 'utf8');
const block = html.slice(html.indexOf('// BEGIN fly-check'), html.indexOf('// END fly-check'));
const ctx = {};
vm.createContext(ctx);
vm.runInContext(block + '\nthis.rule30 = rule30; this.flySees = flySees; this.flyChecker = flyChecker; this.flyLines = flyLines;', ctx);

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};

function run(text) {
  const c = ctx.flyChecker(), split = ctx.flyLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.round}:${e.g}`);
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `rows ${s.rows} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] unchecked ${s.unchecked} gaps ${s.gaps} `
  + `seen ${s.seenUp}/${s.seenStill}/${s.seenDown} totals ${s.totals}/${s.totalsWrong} wrong `
  + `seams ${s.seams}/${s.seamsWrong} wrong, minstret wrong ${s.minstretWrong}, rounds ${s.rounds}`;

let pairs = 0, bad = '';
for (const ln of fs.readFileSync(path.join(dir, 'pairs.txt'), 'utf8').trim().split('\n')) {
  const [x, y, r30, up, down] = ln.split(' ').map((h) => parseInt(h, 16) >>> 0);
  const saw = ctx.flySees(x, y);
  if (ctx.rule30(x) !== r30 || saw.up !== up || saw.down !== down) {
    bad = `pair ${pairs + 1}, ${ln}: the page says ${(ctx.rule30(x) >>> 0).toString(16)} ${saw.up} ${saw.down}`;
    break;
  }
  pairs++;
}
check(!bad && pairs === 5007, "the page's Rule 30 is rule30.py's, and its fly counts fly.py's, on all 5007 pairs tried", bad);

let s = fixture('good.txt');
check(s.rows === 512 && s.ok === 512 && s.wrong === 0 && s.unchecked === 0 && s.gaps === 0 && s.seams === 1 && !s.seamsWrong
      && s.totals === 2 && !s.totalsWrong && s.seenUp === 511 && s.seenStill === 1 && s.seenDown === 0 && !s.minstretWrong,
  'two rounds as the board sends them, in 64-byte packets: all 512 steps agree, 511 seen moving up, 1 not, none down; '
  + 'both FLY lines\' totals add up', brief(s));
s = fixture('midround.txt');
check(s.rows === 412 && s.unchecked === 1 && s.ok === 411 && s.wrong === 0 && s.totals === 1,
  'joined at step 100 of round 0: that one unchecked, the 411 after it checked; only round 1\'s totals checked', brief(s));
s = fixture('joined.txt');
check(s.rows === 100 && s.unchecked === 1 && s.ok === 99 && s.totals === 0 && s.seenUp === 100,
  'steps 63 to 162 of round 0 alone, as round 1 on a board: the first unchecked, the 99 after it checked, no totals', brief(s));
s = fixture('flipped.txt');
check(s.wrong === 2 && s.wrongAt === '0:37 0:38' && s.firstWrong && /Rule 30/.test(s.firstWrong.why) && /counts/.test(s.firstWrong.why),
  'one bit of generation 37 flipped on the way: 37 is wrong, frame and counts, and 38, which does not follow from it', brief(s));
s = fixture('miscount.txt');
check(s.wrong === 1 && s.wrongAt === '0:50' && !/Rule 30/.test(s.firstWrong.why) && s.totalsWrong === 1,
  "step 50's up count one more than the fly saw: that step is wrong, its generation is not, and round 0's total is off", brief(s));
s = fixture('crossed.txt');
check(s.wrong === 1 && s.wrongAt === '0:60' && s.seenDown === 1,
  'step 60 sent as if seen moving down, up and down crossed: it is wrong, and counted as seen down', brief(s));
s = fixture('lost.txt');
check(s.gaps === 1 && s.unchecked === 1 && s.wrong === 0 && s.rows === 511 && s.totals === 1,
  "step 120 lost: a gap, 121 unchecked, nothing called wrong, round 0's totals not checked", brief(s));
s = fixture('total.txt');
check(s.totalsWrong === 1 && s.wrong === 0,
  "a FLY line whose down total is one more than its steps add up to is caught", brief(s));
s = fixture('minstret.txt');
check(s.minstretWrong === 1, "a FLY line with minstret 70928 is caught", brief(s));

for (const log of logs) {
  s = run(fs.readFileSync(log, 'utf8'));
  check(s.rows > 0 && s.wrong === 0 && !s.seamsWrong && !s.minstretWrong && !s.totalsWrong && !s.fails && !s.seenDown,
    `${path.basename(log)}: ${s.ok} of ${s.rows} steps from a board agree, ${s.unchecked} unchecked; `
    + `seen moving up ${s.seenUp}, not moving ${s.seenStill}, down ${s.seenDown}; ${s.totals} rounds' totals add up`, brief(s));
}
process.exit(failed ? 1 : 0);
