// SPDX-License-Identifier: Apache-2.0
//
// exp233 — trial.html's checking, run under node: the block between
// `BEGIN trial-check` and `END trial-check`, taken out of the page itself, fed
// in 64-byte packets as the USB endpoint delivers them.
//
//   node page_test.mjs PAGE FIXTURES [BOARD-LOG...]
//
// FIXTURES is what fixtures.py wrote from exp232's cure.py: streams right and
// wrong, words.txt — random words with cure.py's patient for each — and
// search.txt, cure.py's search and protocol hash; and from exp234's world.py,
// rate.txt, the divisions and the rate M7 predicts. A board log is what a
// phone gave back from exp232's board or exp234's; every patient in it must
// agree.
// Prints PASS/FAIL lines; exits 1 if any failed.

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';

const [page, dir, ...logs] = process.argv.slice(2);
const html = fs.readFileSync(page, 'utf8');
const block = html.slice(html.indexOf('// BEGIN trial-check'), html.indexOf('// END trial-check'));
const ctx = {};
vm.createContext(ctx);
vm.runInContext(block + '\nthis.search = search; this.plan = plan; this.patient = patient; this.trialChecker = trialChecker;'
  + ' this.trialLines = trialLines; this.sha256 = sha256; this.prediction = prediction; this.wilson = wilson;', ctx);

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};

function run(text) {
  const c = ctx.trialChecker(), split = ctx.trialLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = c.feed(l);
      if (e.verdict === 'wrong') wrong.push(e.kind + (e.n !== undefined ? e.n : ''));
    }
  return { ...c.summary(), wrongAt: wrong.join(' ') };
}
const fixture = (name) => run(fs.readFileSync(path.join(dir, name), 'utf8'));
const brief = (s) => `patients ${s.patients} ok ${s.ok} partial ${s.partial} wrong ${s.wrong} [${s.wrongAt}] gaps ${s.gaps} `
  + `search ${s.searches}/${s.searchWrong} plan ${s.plans}/${s.planWrong} trials ${s.trials}/${s.trialsWrong} `
  + `minstret ${s.minstretWrong} bad ${s.bad} parted ${s.discordant}`;
const clean = (s) => !s.wrong && !s.searchWrong && !s.planWrong && !s.trialsWrong && !s.minstretWrong && !s.bad && !s.fails;

const [tried, accepted, relapsing, answer, loophole, sha] = fs.readFileSync(path.join(dir, 'search.txt'), 'utf8').trim().split(' ');
const m = ctx.search();
check(m.tried === +tried && m.accepted === +accepted && m.relapsing === +relapsing
      && m.answer === parseInt(answer, 16) && m.loophole === parseInt(loophole, 16),
  `the page's own search is cure.py's: ${m.tried} tried, ${m.accepted} accepted, ${m.relapsing} relapsing, `
  + `answer ${answer}, loophole ${loophole}`, JSON.stringify(m));
check(ctx.plan(m.answer) === sha && ctx.sha256(new TextEncoder().encode('abc')).startsWith('ba7816bf'),
  `the page's own SHA-256 of the protocol is cure.py's, ${sha.slice(0, 16)}…`, ctx.plan(m.answer));

const rate = fs.readFileSync(path.join(dir, 'rate.txt'), 'utf8').trim().split(' ').map(Number);
const pr = ctx.prediction(m.answer), exact = rate[6] / rate[7];
check(pr.divisions.join(' ') === rate.slice(0, 6).join(' ') && Math.abs(pr.rate - exact) < 1e-12,
  `the page's own prediction is exp234's: divisions ${pr.divisions.join(', ')}, the treated failing `
  + `${rate[6]}/${rate[7]} = ${(100 * pr.rate).toFixed(3)}%`, `${pr.divisions} ${pr.rate} ${exact}`);
const [lo, hi] = ctx.wilson(4, 30), [lo0, hi0] = ctx.wilson(0, 0);
// 0.053097 and 0.296813: Python's statistics.NormalDist, z = inv_cdf(0.975), into Wilson's formula.
check(Math.abs(lo - 0.053097) < 1e-5 && Math.abs(hi - 0.296813) < 1e-5 && lo0 === 0 && hi0 === 1,
  `the page's 95% interval for 4 of 30 is ${(100 * lo).toFixed(1)}%–${(100 * hi).toFixed(1)}%, Wilson's`, `${lo} ${hi}`);

let n = 0, bad = '';
for (const ln of fs.readFileSync(path.join(dir, 'words.txt'), 'utf8').trim().split('\n')) {
  const f = ln.split(' '), p = ctx.patient(parseInt(f[0], 16) >>> 0, m.answer);
  const got = [p.arm, p.width, p.at, p.modelOutcome, p.worldOutcome, p.resistant, p.t24, p.tissue, p.t64].join(' ');
  if (got !== f.slice(1).join(' ')) { bad = `word ${f[0]}: cure.py ${f.slice(1).join(' ')}, the page ${got}`; break; }
  n++;
}
check(!bad && n === 3003, `the page's model and world are cure.py's, every number, for all ${n} random words`, bad);

let s = fixture('good.txt');
check(clean(s) && s.patients === 40 && s.ok === 40 && s.gaps === 0 && s.trials === 40 && s.discordant === 2
      && s.searches === 40 && s.plans === 40,
  '40 patients as exp232\'s board sends them, in 64-byte packets: all replayed and agreeing, every SEARCH, PLAN and TRIAL; '
  + 'the model and the world part on 2', brief(s));
s = fixture('old.txt');
check(clean(s) && s.ok + s.partial === 40 && s.partial > 0,
  `the same with no word on the lines, as exp232's first build: ${s.ok} checked whole, ${s.partial} treated with `
  + 'resistance checked as far as the model', brief(s));
s = fixture('joined.txt');
check(clean(s) && s.first === 9 && s.patients === 32 && s.trial.treated + s.trial.control === 40,
  'joined at patient 9: 32 seen, the board\'s TRIAL still counting all 40', brief(s));
s = fixture('t24.txt');
check(s.wrong === 1 && /^PATIENT3$/.test(s.wrongAt) && /t24/.test(s.firstWrong.why),
  'a parted patient\'s tumour at 24 changed: that patient is wrong, and says t24', brief(s));
s = fixture('word.txt');
check(s.wrong === 1 && /^PATIENT3$/.test(s.wrongAt),
  'a parted patient\'s word changed by one bit: its replay no longer agrees', brief(s));
s = fixture('world.txt');
check(s.wrong >= 1 && /PATIENT/.test(s.wrongAt) && s.trialsWrong === 1,
  'a cured patient sent as missed: the patient is wrong, and the TRIAL after it moved the wrong way', brief(s));
s = fixture('plan.txt');
check(s.planWrong === 1 && s.wrong === 0, 'a PLAN line one digit off is caught', brief(s));
s = fixture('searchline.txt');
check(s.searchWrong === 1 && /relapsing/.test(s.firstWrong.why), 'a SEARCH line saying no schedule relapses is caught', brief(s));
s = fixture('trial.txt');
check(s.trialsWrong >= 1 && s.wrong === 0, 'a TRIAL line with one cured too many is caught', brief(s));
s = fixture('control.txt');
check(s.trialsWrong >= 1 && /M3/.test(s.firstWrong.why), 'a TRIAL line with a control that met the endpoint is caught, by M3', brief(s));
s = fixture('lost.txt');
check(s.gaps === 1 && s.patients === 39 && clean(s), 'patient 12\'s line lost: a gap, nothing called wrong', brief(s));
s = fixture('minstret.txt');
check(s.minstretWrong === 1, 'a status line with minstret 3085 is caught', brief(s));
s = fixture('exp234.txt');
check(clean(s) && s.board === 'exp234' && s.ok === 40 && s.discordant === 2,
  'the same 40 patients from exp234\'s board — its name, minstret 4046 — all agree: the world is the same world', brief(s));
s = fixture('board.txt');
check(s.minstretWrong === 1 && s.searchWrong === 1 && s.board === 'exp232',
  'a SEARCH with exp234\'s minstret in a stream from exp232 is caught', brief(s));
s = fixture('status234.txt');
check(s.minstretWrong === 1 && s.board === 'exp234', 'an exp234 status line with exp232\'s minstret is caught', brief(s));

for (const log of logs) {
  s = run(fs.readFileSync(log, 'utf8'));
  check(s.patients > 0 && clean(s),
    `${path.basename(log)}: ${s.ok} of ${s.patients} patients from a board agree with the page`
    + (s.partial ? `, ${s.partial} partly (no word)` : '') + `; search, plan and every TRIAL count agree; `
    + `the model and the world part on ${s.discordant}`, brief(s));
}
process.exit(failed ? 1 : 0);
