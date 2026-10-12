// SPDX-License-Identifier: Apache-2.0
//
// exp233 — trial.html in a real browser, headless, with no board, through
// tools/pages/headless.mjs: a stand-in for exp232's device — serial 232 — or
// exp234's — serial 234 — hands back a stream in 64-byte packets. What it reaches that page_test.mjs
// does not: the page's own code around the checked block — the connection,
// the control transfers, the trial panel, the rate M7 predicts beside the
// board's, the search panel, the two lives drawn
// for every treated patient the model and the world part on, the verdict line,
// Copy — running where it will run; and for good.txt, the page with no WebUSB
// at all, playing Demo.
//
//   node page_browser.mjs PAGE STREAM WANT CHARTS [SERIAL]
//
// WANT is a piece of text the verdict line must contain, CHARTS how many
// patients must be drawn, SERIAL the board's, 232 if not given. Prints
// PASS/FAIL.

import fs from 'node:fs';
import { openWithBoard, checker } from '../../tools/pages/headless.mjs';

const [page, file, want, charts, serial = '232'] = process.argv.slice(2);
const stream = fs.readFileSync(file, 'utf8');
const name = file.split('/').pop();
const board = serial === '234' ? { productName: 'exp234 the rate the proof predicts', serialNumber: '234' }
  : { productName: 'exp232 the cure the proof predicts', serialNumber: '232' };
const { check, failed } = checker();

const drawn = (tab) => tab.evaluate(() => [...document.querySelectorAll('#charts canvas')].map((c) => {
  const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data, bg = [d[0], d[1], d[2]];
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] !== bg[0] || d[i + 1] !== bg[1] || d[i + 2] !== bg[2]) n++;
  return n;
}));

let run = await openWithBoard(page, stream, board);
let { tab, errors } = run;
const verdict = await tab.textContent('#verdict');
const trial = await tab.textContent('#trial');
const search = await tab.textContent('#search');
const rate = await tab.textContent('#rate');
const listening = await tab.textContent('#status');
const sent = await run.sent();
const inks = await drawn(tab);
const captions = await tab.evaluate(() => [...document.querySelectorAll('#charts figcaption')].map((f) => f.textContent));
await tab.click('#copy');
await tab.waitForTimeout(100);
const status = await tab.textContent('#status');
const clip = await tab.evaluate(() => navigator.clipboard.readText());
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
check(listening.startsWith(`Listening to "exp${serial}`),
  `${name}: serial ${serial} is a board the page knows: "${listening.slice(0, 40)}…"`, listening);
check(/12\.7% of treated patients not cured/.test(rate) && /leaves 0, 0, 1, 2, 3, 8 dividing cells/.test(rate)
      && /The board so far: \d+ of \d+ treated not cured, [\d.]+% \(95% interval [\d.]+%–[\d.]+%; expected [\d.]+\)/.test(rate),
  `${name}: the rate panel says "${(rate.match(/The board so far[^(]*/) || [''])[0].trim()}" beside the predicted 12.7%`, rate);
check(/the proof predicts \d+ cured · the world cured \d+/.test(trial) && /this page agrees/.test(search) && !/disagrees/.test(search),
  `${name}: the trial panel says "${trial.match(/Treated[^C]*/)[0].trim()}", and the search and the protocol agree with the page's own`,
  `${trial} / ${search}`);
check(inks.length === +charts && inks.every((n) => n > 0) && captions.every((c) => /Model: cured\. World: (missed|relapsed)/.test(c))
      && errors.length === 0,
  `${name}: ${inks.length} patients drawn where the model said cured and the world did not (${inks.join(', ')} pixels), no script error`,
  `${inks} ${captions.join(' | ')} ${errors.join('; ')}`);
check(status.startsWith('Copied') && clip.startsWith('#page exp233 trial.html') && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
await run.close();

if (name === 'good.txt') {
  run = await openWithBoard(page, null, board);
  ({ tab, errors } = run);
  const said = await tab.textContent('#status');
  await tab.click('#demo');
  await tab.waitForTimeout(3400);
  const v = await tab.textContent('#verdict'), status2 = await tab.textContent('#status'), t = await tab.textContent('#trial');
  await tab.click('#copy');
  await tab.waitForTimeout(100);
  const clip2 = await tab.evaluate(() => navigator.clipboard.readText());
  check(said.includes('no WebUSB') && said.includes('Demo still works'), 'with no WebUSB the page says so, and offers Demo', said);
  check(status2.startsWith('Demo') && /Demo: [2-9] patients computed in this page, so nothing here is checked/.test(v)
        && /the proof predicts/.test(t) && errors.length === 0,
    `Demo draws patients at about the board's pace and says it checks nothing: "${v.slice(0, 64)}…"`,
    `${status2} / ${v} / ${t} ${errors.join('; ')}`);
  check(/^#page exp233 trial.html p\d+ DEMO, no board/.test(clip2) && clip2.includes('\nSEARCH tried=1024'),
    'Copy during Demo says DEMO, no board, on its first line', clip2.slice(0, 120));
  await run.close();
}
process.exit(failed() ? 1 : 0);
