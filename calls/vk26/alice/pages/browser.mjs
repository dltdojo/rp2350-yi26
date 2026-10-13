// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/pages — an alice page, built, in a real browser, headless,
// with no board, through tools/pages/headless.mjs: a stand-in for the
// experiment's device hands back a fixture in 64-byte packets. What it
// reaches that an experiment's page_test.mjs does not: the page's own code
// around its checked block — core.js and health.js put in by build.py, the
// connection, the control transfers, the browser's WebCrypto, the table, the
// verdict line, Copy, Save — running where it will run. vk26-alice-1 wrote it
// for seam.html; vk26-alice-2's trust.html is the second page to need it.
//
//   node browser.mjs PAGE FIXTURE WANT ROWS SERIAL PRODUCT
//
// WANT is a piece of text the verdict line must contain; ROWS how many
// streams the table (#streams) must show; SERIAL and PRODUCT the stand-in's
// USB strings, the experiment's. Prints PASS/FAIL.

import fs from 'node:fs';
import path from 'node:path';
import { openWithBoard, checker } from '../../../../tools/pages/headless.mjs';

const [page, fixture, want, rows, serial, product] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');
const run = await openWithBoard(page, stream, { productName: product, serialNumber: serial });
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
const [dl] = await Promise.all([tab.waitForEvent('download'), tab.click('#save')]);
const saved = fs.readFileSync(await dl.path(), 'utf8');
const savedStatus = await tab.textContent('#status');

const name = fixture.split('/').pop();
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
check(shown === Number(rows) && errors.length === 0,
  `${name}: the table shows the last round's ${rows} streams, and no script error`, `${shown} rows; ${errors.join('; ')}`);
check(status.startsWith('Copied') && clip.startsWith(`#page ${serial} ${path.basename(page)}`) && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
check(saved === clip && dl.suggestedFilename().startsWith(`${serial}-`) && savedStatus.startsWith(`Saved ${saved.length} characters`),
  `${name}: Save downloads the same text as a file, ${dl.suggestedFilename().replace(/-\d{4}-.*/, '-<time>.txt')}, and says how long it is`,
  savedStatus);
await run.close();
process.exit(failed() ? 1 : 0);
