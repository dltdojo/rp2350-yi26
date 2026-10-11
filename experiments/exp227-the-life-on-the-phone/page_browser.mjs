// SPDX-License-Identifier: Apache-2.0
//
// exp227 — life.html in a real browser, headless, with no board, through
// tools/pages/headless.mjs: a stand-in for exp227's device — serial 227 —
// hands back a fixture in 64-byte packets. What it reaches that page_test.mjs
// does not: the page's own code around the checked block — the connection, the
// control transfers, the drawing, the verdict line, Copy — running where it
// will run.
//
//   node page_browser.mjs PAGE FIXTURE WANT
//
// WANT is a piece of text the verdict line must contain. Prints PASS/FAIL.

import fs from 'node:fs';
import { openWithBoard, checker } from '../../tools/pages/headless.mjs';

const [page, fixture, want] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');
const run = await openWithBoard(page, stream, { productName: 'exp227 the life on the phone', serialNumber: '227' });
const { tab, errors } = run;
const { check, failed } = checker();
const verdict = await tab.textContent('#verdict');
const sent = await run.sent();
const inked = await tab.evaluate(() => {
  const c = document.getElementById('life'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
  const bg = [d[0], d[1], d[2]];
  let n = 0;
  for (let i = 0; i < d.length; i += 4) if (d[i] !== bg[0] || d[i + 1] !== bg[1] || d[i + 2] !== bg[2]) n++;
  return n;
});
await tab.click('#copy');
await tab.waitForTimeout(100);
const status = await tab.textContent('#status');
const clip = await tab.evaluate(() => navigator.clipboard.readText());

const name = fixture.split('/').pop();
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
check(inked > 0 && errors.length === 0, `${name}: the canvas has the life on it (${inked} pixels), and no script error`, errors.join('; '));
check(status.startsWith('Copied') && clip.startsWith('#page exp227') && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
await run.close();
process.exit(failed() ? 1 : 0);
