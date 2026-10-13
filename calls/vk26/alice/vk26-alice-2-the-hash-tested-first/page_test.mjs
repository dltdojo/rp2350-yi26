// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-2 — trust.html's checking, run under node: the block between
// `BEGIN trust-check` and `END trust-check` with ../pages/health.js's and
// core.js's cdcLines (../pages/pagetest.mjs: the page's own copies, in a
// built page), fed in 64-byte packets as the USB endpoint delivers them, and
// node's WebCrypto for SHA-256 as the page has the browser's.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote. A board log is what Save gave back from
// a phone; it must hold whole streams, none of them wrong. Prints PASS/FAIL
// lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import { pageContext, inPackets, checker } from '../pages/pagetest.mjs';

const [page, dir, ...logs] = process.argv.slice(2);
const ctx = pageContext(page, 'trust-check', ['trustJudge', 'trustChecker', 'healthSamples', 'cdcLines']);
const sha256 = async (b) => new Uint8Array(await crypto.subtle.digest('SHA-256', b));
const { check, failed } = checker();

async function run(text) {
  const c = ctx.trustChecker(sha256);
  const wrongAt = await inPackets(c, ctx.cdcLines, text);
  return { ...c.summary(), wrongAt };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `streams ${s.streams} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] incomplete ${s.incomplete} `
  + `rounds ${s.rounds} refused ${s.refused} start-up ${s.startup} outputs ${s.outputs} fails ${s.fails}`
  + `${s.firstWrong ? ` first: ${s.firstWrong.why}` : ''}`;

// The page's tests against trust.py's, on every stream trust.py has, HASH honest.
let n = 0, bad = '';
for (const ln of fs.readFileSync(path.join(dir, 'judge.txt'), 'utf8').trim().split('\n')) {
  const [code, name, hex] = ln.split('|');
  const j = ctx.trustJudge(ctx.healthSamples(hex.split(' ').map((h) => parseInt(h, 16) >>> 0)), true);
  if (j.code !== Number(code)) { bad = `${name}: trust.py says ${code}, the page ${j.code}`; break; }
  n++;
}
check(!bad && n >= 14, `the page's tests stop where trust.py's do, on all ${n} of trust.py's streams`, bad);

let s = await fixture('good.txt');
check(s.streams === 10 && s.ok === 10 && s.wrong === 0 && s.incomplete === 0 && s.rounds === 2
      && s.refused === 2 && s.startup === 2 && s.outputs === 4,
  'two rounds as the board sends them, in 64-byte packets: all 10 streams judged right — the spoiled hash '
  + 'refused, the stuck source stopped at start-up, each output SHA-256 of the second window — both times', brief(s));
s = await fixture('unchecked.txt');
check(s.wrong === 1 && s.wrongAt === '0:1' && /code 2 is due — HASH fails the KAT — not 0/.test(s.firstWrong.why),
  'a kernel that never asks HASH the KAT: the spoiled stream goes on to an output, and the page says code 2 was due',
  brief(s));
s = await fixture('chip.txt');
check(s.wrong === 1 && s.wrongAt === '0:0' && /not SHA-256 of its message, and nothing spoiled it/.test(s.firstWrong.why),
  'HASH answering the KAT wrong with nothing spoiling it: the kernel stopping is right, the board is not, and the '
  + 'page says so', brief(s));
s = await fixture('skipped.txt');
check(s.wrong === 1 && s.wrongAt === '0:4' && /code 1 is due — the start-up window fails/.test(s.firstWrong.why),
  'a kernel that skips the start-up test: the stuck source gets an output, and the page says code 1 was due', brief(s));
s = await fixture('reset.txt');
check(s.wrong === 1 && s.wrongAt === '0:2' && /code 3 is due — the second window fails/.test(s.firstWrong.why),
  'a kernel that resets the run at the start-up window\'s edge: the seam stream gets an output, and the page '
  + 'says code 3 was due', brief(s));
s = await fixture('startup.txt');
check(s.wrong === 1 && s.wrongAt === '0:0' && /not SHA-256 of the second window/.test(s.firstWrong.why),
  'a kernel that hashes the start-up window it should have thrown away: caught', brief(s));
s = await fixture('digest.txt');
check(s.wrong === 1 && s.wrongAt === '0:3' && /not SHA-256 of the second window/.test(s.firstWrong.why),
  'one byte of an output flipped on the way: caught', brief(s));
s = await fixture('minstret.txt');
check(s.wrong === 1 && /minstret 52/.test(s.firstWrong.why), 'minstret one more than the RTL\'s for a stream: caught',
  brief(s));
s = await fixture('lost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9,
  'a BITS line lost: that stream incomplete, nothing called wrong, the other 9 judged', brief(s));
s = await fixture('katlost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9 && s.refused === 1,
  'the KAT line of the spoiled stream lost: that stream incomplete, not judged as if HASH were right', brief(s));
s = await fixture('midstream.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 9,
  'joined mid-stream: the first stream incomplete, every one after it judged', brief(s));

for (const log of logs) {
  s = await run(fs.readFileSync(log, 'utf8'));
  check(s.ok > 0 && s.wrong === 0 && !s.fails,
    `${path.basename(log)}: ${s.ok} of ${s.streams} streams from a board judged right, ${s.incomplete} incomplete, `
    + `${s.rounds} rounds, ${s.refused} spoiled hashes refused, ${s.outputs} outputs`, brief(s));
}
process.exit(failed() ? 1 : 0);
