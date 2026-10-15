// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-5 — seed.html's checking, run under node: the block between
// `BEGIN seed-check` and `END seed-check` with health.js's and drbg.js's and
// core.js's cdcLines (../pages/pagetest.mjs: the page's own copies, in a
// built page) and node's WebCrypto, fed in 64-byte packets as the USB
// endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote, from seed.py, hashdrbg.py and
// trustref.py. A board log is what Save gave back from a phone; it must hold
// whole cases and whole chains, none of them wrong. Its mcycles are printed as
// the page reads them, not judged.
// Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import { pageContext, checker } from '../pages/pagetest.mjs';

const [page, dir, ...logs] = process.argv.slice(2);
const ctx = pageContext(page, 'seed-check', ['seedChecker', 'cdcLines']);
const { check, failed } = checker();

async function run(text) {
  const c = ctx.seedChecker(), split = ctx.cdcLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = await c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.kind === 'CHAIN' ? 'chain' : 'case'} ${e.round}:${e.i}`);
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const cyc = (s) => Object.entries(s.cycleValues).map(([k, v]) => `${k} ${v.join('/') || '—'}`).join(', ');
const brief = (s) => `cases ${s.cases} ok ${s.ok} wrong ${s.wrong} incomplete ${s.incomplete}; chains ${s.chains} `
  + `ok ${s.chainsOk} wrong ${s.chainsWrong} incomplete ${s.chainsIncomplete} (bits ${s.outputs} refused ${s.refused} `
  + `stopped ${s.stopped}) [${s.wrongAt}] rounds ${s.rounds} revision ${s.revision} fails ${s.fails}; ${cyc(s)}`
  + `${s.firstWrong ? ` first: ${s.firstWrong.why}` : ''}`;
const fine = (s) => s.wrong === 0 && s.chainsWrong === 0;
const caseWrong = (s, at, re) => s.wrong === 1 && s.chainsWrong === 0 && s.wrongAt === `case ${at}` && re.test(s.firstWrong.why);
const chainWrong = (s, at, re) => s.chainsWrong === 1 && s.wrong === 0 && s.wrongAt === `chain ${at}` && re.test(s.firstWrong.why);

let s = await fixture('good.txt');
check(s.cases === 240 && s.ok === 240 && fine(s) && s.incomplete === 0 && s.chains === 4 && s.chainsOk === 4
      && s.outputs === 2 && s.refused === 2 && s.rounds === 2 && s.revision === 1 && s.last
      && Object.values(s.cycleValues).every((c) => c.length === 1),
  'two rounds as the board sends them, in 64-byte packets: all 240 NIST cases instantiated and generated right; '
  + 'each round\'s chain gave bits, its spoiled one stopped at the KAT; each run one mcycle', brief(s));

s = await fixture('state.txt');
check(caseWrong(s, '0:3', /^V after Instantiate is not this page's Hash_df/),
  'one bit of V after a NIST case\'s Instantiate: the page says it is V', brief(s));
s = await fixture('block.txt');
check(caseWrong(s, '0:5', /the second Generate's block 2 is not this page's/),
  'one bit of the second Generate\'s block 2: the page says which block', brief(s));
s = await fixture('seed.txt');
check(caseWrong(s, '0:6', /^V after Instantiate .*; C after Instantiate/),
  'the seed material sent one byte short, V and C NIST\'s: the page instantiates what it was sent, and it is not those',
  brief(s));
s = await fixture('minstret.txt');
check(caseWrong(s, '0:7', /run 0's minstret 261, not the RTL's 260/),
  'the Instantiate kernel\'s minstret one more than the RTL\'s: caught', brief(s));

s = await fixture('startup.txt');
check(chainWrong(s, '0:0', /^the digest is not SHA-256 of the second window; V or C is not this page's/),
  'the chain digesting the start-up window, and the rest made from that: the digest named, and V and C, which the page '
  + 'makes from its own digest', brief(s));
s = await fixture('digest.txt');
check(chainWrong(s, '0:0', /^the digest is not SHA-256 of the second window$/),
  'one bit of the digest flipped on the way, V, C and the bits right: caught at the digest, and only there', brief(s));
s = await fixture('nonce.txt');
check(chainWrong(s, '0:0', /^V or C is not this page's Instantiate of the digest and the nonce; block 0/),
  'Instantiate on the digest without the nonce: V, C and the bits not this page\'s', brief(s));
s = await fixture('cstate.txt');
check(chainWrong(s, '0:0', /^V or C is not this page's Instantiate/),
  'one bit of C in the chain: caught', brief(s));
s = await fixture('cblock.txt');
check(chainWrong(s, '0:0', /^block 3 is not this page's Generate$/),
  'one bit of the chain\'s block 3: the page says which block', brief(s));
s = await fixture('cminstret.txt');
check(chainWrong(s, '0:0', /Instantiate's minstret 260, not the RTL's 261/),
  'the chain\'s Instantiate counted as it is alone, 260: the RTL counts 261 there, and the page holds it to that', brief(s));
s = await fixture('unchecked.txt');
check(chainWrong(s, '0:1', /^code 2 is due, not 0; .*an output sent for a chain that should have stopped$/),
  'the spoiled chain going on to bits: a kernel that never asked the KAT is caught', brief(s));
s = await fixture('chip.txt');
check(chainWrong(s, '0:0', /^the KAT's answer is not SHA-256 of its message, and nothing spoiled it$/),
  'the KAT answered wrong with nothing spoiling it: the chain is right to stop, and the page says the board is not',
  brief(s));
s = await fixture('stopped.txt');
check(fine(s) && s.chains === 4 && s.chainsOk === 4 && s.outputs === 0 && s.refused === 2 && s.stopped === 2,
  'the TRNG stuck at 1, then a run of 21 across the seam: both chains stopped by the tests, with 1 and 3, nothing wrong',
  brief(s));
s = await fixture('lost.txt');
check(fine(s) && s.incomplete === 1 && s.ok === 11 && s.chainsIncomplete === 1 && s.chainsOk === 1,
  'a BLOCK line and a BITS line lost: that case and that chain incomplete, nothing called wrong', brief(s));
s = await fixture('midcase.txt');
check(fine(s) && s.incomplete === 1 && s.ok === 11 && s.chainsOk === 2,
  'joined mid-case: the first case incomplete, every one after it right', brief(s));
s = await fixture('cycles.txt');
check(fine(s) && s.ok === 24 && s.cycleValues.gen.length === 2 && s.cycleValues.inst.length === 1,
  'one Generate taking 30 cycles more: nothing wrong, and the page says the cycles differ', brief(s));

for (const log of logs) {
  s = await run(fs.readFileSync(log, 'utf8'));
  check(s.ok > 0 && s.chainsOk > 0 && fine(s) && !s.fails,
    `${path.basename(log)}: ${s.ok} of ${s.cases} NIST cases and ${s.chainsOk} of ${s.chains} chains from a board right `
    + `(${s.outputs} gave bits, ${s.refused} refused, ${s.stopped} stopped), ${s.incomplete + s.chainsIncomplete} `
    + `incomplete, ${s.rounds} rounds; mcycle as read: ${cyc(s)}`, brief(s));
}
process.exit(failed() ? 1 : 0);
