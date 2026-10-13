// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-1 — seam.html's checking, run under node: the block between
// `BEGIN seam-check` and `END seam-check`, taken out of the page itself, with
// ../pages/core.js's cdcLines (the page's own copy, in a built page), fed in 64-byte packets as the USB endpoint
// delivers them, and node's WebCrypto for SHA-256 as the page has the
// browser's.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote. A board log is what Copy gave back from
// a phone; it must hold whole streams, none of them wrong. Prints PASS/FAIL
// lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const [page, dir, ...logs] = process.argv.slice(2);
const html = fs.readFileSync(page, 'utf8');
const block = html.slice(html.indexOf('// BEGIN seam-check'), html.indexOf('// END seam-check'));
// cdcLines from the page when build.py has put core.js in it, else from core.js itself.
const core = html.includes('function cdcLines(') ? html
  : fs.readFileSync(new URL('../pages/core.js', import.meta.url), 'utf8');
const lines = core.slice(core.indexOf('function cdcLines('), core.indexOf('\n}\n', core.indexOf('function cdcLines(')) + 3);
const ctx = { crypto: globalThis.crypto };
vm.createContext(ctx);
vm.runInContext(block + lines + '\nthis.seamJudge = seamJudge; this.seamChecker = seamChecker; this.seamSamples = seamSamples;'
  + ' this.cdcLines = cdcLines; this.SEAM_INSTRET = SEAM_INSTRET;', ctx);
const sha256 = async (b) => new Uint8Array(await crypto.subtle.digest('SHA-256', b));

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};

async function run(text) {
  const c = ctx.seamChecker(sha256), split = ctx.cdcLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = await c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.round}:${e.s}`);
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `streams ${s.streams} ok ${s.ok} wrong ${s.wrong} [${s.wrongAt}] incomplete ${s.incomplete} `
  + `rounds ${s.rounds} across ${s.seamCaught} fails ${s.fails}${s.firstWrong ? ` first: ${s.firstWrong.why}` : ''}`;

// The page's tests against seam.py's, on every stream seam.py has.
let n = 0, bad = '', across = [];
for (const ln of fs.readFileSync(path.join(dir, 'judge.txt'), 'utf8').trim().split('\n')) {
  const [code, name, hex] = ln.split('|');
  const j = ctx.seamJudge(ctx.seamSamples(hex.split(' ').map((h) => parseInt(h, 16) >>> 0)));
  if (j.code !== Number(code)) { bad = `${name}: seam.py says ${code}, the page ${j.code}`; break; }
  if (j.code && j.windows[j.windows.length - 1].across) across.push(name);
  n++;
}
check(!bad && n >= 14, `the page's tests stop where seam.py's do, on all ${n} of seam.py's streams`, bad);
check(across.join(', ') === 'seam 11+10, seam 1+20, seam 15+6 at window 4',
  `the page says which stopped on a run begun in the window before: ${across.join(', ')}`, across.join(', '));

let s = await fixture('good.txt');
check(s.streams === 12 && s.ok === 12 && s.wrong === 0 && s.incomplete === 0 && s.rounds === 2 && s.seamCaught === 2,
  'two rounds as the board sends them, in 64-byte packets: all 12 streams judged right, each digest SHA-256\'s, '
  + 'and the seam stream stopped by its run across the edge both times', brief(s));
s = await fixture('digest.txt');
check(s.wrong === 1 && s.wrongAt === '0:1' && /window 1's digest/.test(s.firstWrong.why),
  'one byte of a digest flipped on the way: that stream is wrong, and the page says which digest', brief(s));
s = await fixture('reset.txt');
check(s.wrong === 1 && s.wrongAt === '0:1' && /stop at window 2/.test(s.firstWrong.why),
  'a kernel that resets the run at each edge passes the seam stream: the page says its samples stop at window 2', brief(s));
s = await fixture('latch.txt');
check(s.wrong === 1 && s.wrongAt === '0:3' && /stop at window 1/.test(s.firstWrong.why),
  'a kernel that writes the next window after a failure: caught at the stuck stream', brief(s));
s = await fixture('minstret.txt');
check(s.wrong === 1 && /minstret/.test(s.firstWrong.why), 'minstret one more than the RTL\'s for a stream: caught', brief(s));
s = await fixture('lost.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 11,
  'a BITS line lost: that stream incomplete, nothing called wrong, the other 11 judged', brief(s));
s = await fixture('midstream.txt');
check(s.incomplete === 1 && s.wrong === 0 && s.ok === 11,
  'joined mid-stream: the first stream incomplete, every one after it judged', brief(s));

for (const log of logs) {
  s = await run(fs.readFileSync(log, 'utf8'));
  check(s.ok > 0 && s.wrong === 0 && !s.fails,
    `${path.basename(log)}: ${s.ok} of ${s.streams} streams from a board judged right, ${s.incomplete} incomplete, `
    + `${s.rounds} rounds, ${s.seamCaught} stopped across an edge`, brief(s));
}
process.exit(failed ? 1 : 0);
