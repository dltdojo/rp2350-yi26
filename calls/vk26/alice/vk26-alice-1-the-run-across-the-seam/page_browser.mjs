// SPDX-License-Identifier: Apache-2.0
//
// vk26-alice-1 — the built seam.html in a real browser, headless, with no
// board, through tools/pages/headless.mjs: a stand-in for vk26-alice-1's
// device — serial vk26-alice-1 — hands back a fixture in 64-byte packets.
// What it reaches that page_test.mjs does not: the page's own code around the
// checked block — ../pages/core.js put in by build.py, the connection, the
// control transfers, the browser's WebCrypto, the table, the verdict line,
// Copy — running where it will run.
//
//   node page_browser.mjs PAGE FIXTURE WANT ROWS
//
// WANT is a piece of text the verdict line must contain; ROWS how many
// streams the table must show. Prints PASS/FAIL.

import fs from 'node:fs';
import { openWithBoard, checker } from '../../../../tools/pages/headless.mjs';

const [page, fixture, want, rows] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');
const run = await openWithBoard(page, stream, { productName: 'vk26-alice-1 the run across the seam',
                                                serialNumber: 'vk26-alice-1' });
const { tab, errors } = run;
const { check, failed } = checker();
await tab.waitForFunction((w) => document.getElementById('verdict').textContent.includes(w), want, { timeout: 20000 })
  .catch(() => {});
const verdict = await tab.textContent('#verdict');
const sent = await run.sent();
const shown = await tab.evaluate(() => document.querySelectorAll('#streams tbody tr').length);
await tab.click('#copy');
await tab.waitForTimeout(100);
const status = await tab.textContent('#status');
const clip = await tab.evaluate(() => navigator.clipboard.readText());

const name = fixture.split('/').pop();
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
check(shown === Number(rows) && errors.length === 0,
  `${name}: the table shows the last round's ${rows} streams, and no script error`, `${shown} rows; ${errors.join('; ')}`);
check(status.startsWith('Copied') && clip.startsWith('#page vk26-alice-1 seam.html') && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
await run.close();
process.exit(failed() ? 1 : 0);
