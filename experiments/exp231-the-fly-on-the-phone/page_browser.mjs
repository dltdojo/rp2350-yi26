// SPDX-License-Identifier: Apache-2.0
//
// exp231 — fly.html in a real browser, headless, with no board, through
// tools/pages/headless.mjs: a stand-in for exp231's device — serial 231 —
// hands back a fixture in 64-byte packets. What it reaches that page_test.mjs
// does not: the page's own code around the checked block — the connection, the
// control transfers, the drawing, the verdict line, Copy — running where it
// will run; and for good.txt, the page with no WebUSB at all, playing Demo.
//
//   node page_browser.mjs PAGE FIXTURE WANT [TOTALS]
//
// WANT is a piece of text the verdict line must contain, TOTALS one the line
// under the rows must. Prints PASS/FAIL.

import fs from 'node:fs';
import { openWithBoard, checker } from '../../tools/pages/headless.mjs';

const [page, fixture, want, totals] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');
const name = fixture.split('/').pop();
const board = { productName: 'exp231 the fly on the phone', serialNumber: '231' };
const { check, failed } = checker();

const inked = (tab) => tab.evaluate(() => {
  const c = document.getElementById('fly'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  const bg = [d[0], d[1], d[2]];
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] !== bg[0] || d[i + 1] !== bg[1] || d[i + 2] !== bg[2]) n++;
  return n;
});

let run = await openWithBoard(page, stream, board);
let { tab, errors } = run;
const verdict = await tab.textContent('#verdict');
const saw = await tab.textContent('#saw');
const under = await tab.textContent('#totals');
const sent = await run.sent();
const ink = await inked(tab);
if (totals) check(under.includes(totals), `${name}: under the rows, "${totals}"`, under);
await tab.click('#copy');
await tab.waitForTimeout(100);
const status = await tab.textContent('#status');
const clip = await tab.evaluate(() => navigator.clipboard.readText());
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
check(ink > 0 && saw.includes('moving left') && errors.length === 0,
  `${name}: the rows and the fly's meter are drawn (${ink} pixels), the last step said "${saw}", no script error`,
  `${saw} ${errors.join('; ')}`);
check(status.startsWith('Copied') && clip.startsWith('#page exp231 fly.html') && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
await run.close();

if (name === 'good.txt') {
  run = await openWithBoard(page, null, board);
  ({ tab, errors } = run);
  const said = await tab.textContent('#status');
  await tab.click('#demo');
  await tab.waitForTimeout(1300);
  const v = await tab.textContent('#verdict'), status2 = await tab.textContent('#status');
  const demoInk = await inked(tab);
  await tab.click('#copy');
  await tab.waitForTimeout(100);
  const clip2 = await tab.evaluate(() => navigator.clipboard.readText());
  check(said.includes('no WebUSB') && said.includes('Demo still works'), 'with no WebUSB the page says so, and offers Demo', said);
  check(status2.startsWith('Demo') && /Demo: [1-9]\d* steps computed in this page/.test(v) && demoInk > 0 && errors.length === 0,
    `Demo plays from one live cell at the board's pace, drawn (${demoInk} pixels), and says it checks nothing: "${v.slice(0, 60)}…"`,
    `${status2} / ${v} ${errors.join('; ')}`);
  check(/^#page exp231 fly.html p\d+ DEMO, no board/.test(clip2) && clip2.includes('\nSEED 00000000 00010000'),
    'Copy during Demo says DEMO, no board, on its first line', clip2.slice(0, 120));
  await run.close();
}
process.exit(failed() ? 1 : 0);
