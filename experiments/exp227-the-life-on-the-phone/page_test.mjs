// SPDX-License-Identifier: Apache-2.0
//
// exp227 — life.html's checking, run under node: the block between
// `BEGIN life-check` and `END life-check`, taken out of the page itself, fed in
// 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote: streams rule30.py made, right and wrong,
// and pairs.txt, rule30.py's next generation of 5005 words. A board log is
// what Copy gave back from a phone; it must hold generations, none of them
// wrong. Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const [page, dir, ...logs] = process.argv.slice(2);
const html = fs.readFileSync(page, 'utf8');
const block = html.slice(html.indexOf('// BEGIN life-check'), html.indexOf('// END life-check'));
const ctx = {};
vm.createContext(ctx);
vm.runInContext(block + '\nthis.rule30 = rule30; this.lifeChecker = lifeChecker; this.lifeLines = lifeLines;', ctx);

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};

function run(text) {
  const c = ctx.lifeChecker(), split = ctx.lifeLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.round}:${e.g}`);
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `rows ${s.rows} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] unchecked ${s.unchecked} gaps ${s.gaps} `
  + `seams ${s.seams}/${s.seamsWrong} wrong, minstret wrong ${s.minstretWrong}, lives ${s.lives}`;

let pairs = 0, bad = '';
for (const ln of fs.readFileSync(path.join(dir, 'pairs.txt'), 'utf8').trim().split('\n')) {
  const [x, y] = ln.split(' ').map((h) => parseInt(h, 16) >>> 0);
  if (ctx.rule30(x) !== y) { bad = `word ${pairs + 1}, ${ln}: the page says ${(ctx.rule30(x) >>> 0).toString(16)}`; break; }
  pairs++;
}
check(!bad && pairs === 5005, "the page's Rule 30 is rule30.py's on all 5005 words tried", bad);

let s = fixture('good.txt');
check(s.rows === 512 && s.ok === 512 && s.wrong === 0 && s.unchecked === 0 && s.gaps === 0 && s.seams === 1 && !s.seamsWrong,
  'two lives as the board sends them, in 64-byte packets: all 512 generations Rule 30\'s, the seam between them too', brief(s));
s = fixture('midlife.txt');
check(s.rows === 412 && s.unchecked === 1 && s.ok === 411 && s.wrong === 0,
  'joined at generation 100 of life 0: that one unchecked, the 411 after it checked', brief(s));
s = fixture('flipped.txt');
check(s.wrong === 2 && s.wrongAt === '0:37 0:38' && s.firstWrong && s.firstWrong.g === 37,
  'one bit of generation 37 flipped on the way: 37 is wrong, and 38, which does not follow from it', brief(s));
s = fixture('lost.txt');
check(s.gaps === 1 && s.unchecked === 1 && s.wrong === 0 && s.rows === 511,
  'generation 120 lost: a gap, 121 unchecked, nothing called wrong', brief(s));
s = fixture('badseam.txt');
check(s.seamsWrong === 1 && s.wrong === 0,
  "life 1 grown from a seed that is not life 0's last generation: the seam is wrong, the life itself is Rule 30's", brief(s));
s = fixture('minstret.txt');
check(s.minstretWrong === 1, 'a LIFE line with minstret 3083 is caught', brief(s));
s = fixture('lifeline.txt');
check(s.wrong === 1 && s.wrongAt === '0:255',
  "a LIFE line that disagrees with generation 255: that generation is marked", brief(s));

for (const log of logs) {
  s = run(fs.readFileSync(log, 'utf8'));
  check(s.rows > 0 && s.wrong === 0 && !s.seamsWrong && !s.minstretWrong && !s.fails,
    `${path.basename(log)}: ${s.ok} of ${s.rows} generations from a board are Rule 30's, ${s.unchecked} unchecked, `
    + `${s.seams} seams between lives, ${s.lives} LIFE lines`, brief(s));
}
process.exit(failed ? 1 : 0);
