// SPDX-License-Identifier: Apache-2.0
//
// exp228 — script.html in a real browser, headless, with no board, through
// tools/pages/headless.mjs: a stand-in for exp228's device — serial 228 —
// hands back a stream in 64-byte packets. What it reaches that page_test.mjs
// does not: the page's own code around the checked block — the connection,
// the grid, a case's steps, the board's columns, Copy — running where it will
// run; and the page with no WebUSB at all, a case tapped.
//
//   node page_browser.mjs PAGE FIXTURE WANT
//
// WANT is a piece of text the verdict line must contain. Prints PASS/FAIL.

import fs from 'node:fs';
import { openWithBoard, checker } from '../../tools/pages/headless.mjs';

const [page, fixture, want] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');
const name = fixture.split('/').pop();
const { check, failed } = checker();
const board = { productName: 'exp228 the script the kernel runs', serialNumber: '228' };

let run = await openWithBoard(page, stream, board);
let { tab, errors } = run;
const sent = await run.sent();
const verdict = await tab.textContent('#verdict');
const tiles = await tab.$$eval('#grid .tile', (ts) => ts.map((t) => t.className));
const steps = await tab.$$eval('#ctrace tr', (rs) => rs.length);
const marks = await tab.textContent('#cboard');
await tab.click('#copy');
await tab.waitForTimeout(100);
const status = await tab.textContent('#status');
const clip = await tab.evaluate(() => navigator.clipboard.readText());
check(sent.startsWith('claim 0, claim 1, ctl 32 0 0, ctl 34 3 0'),
  `${name}: the page claims interfaces 0 and 1, sets the line coding, then raises DTR`, sent);
check(verdict.includes(want), `${name}: the verdict line says "${want}"`, verdict);
const accept = tiles.filter((c) => c.includes('accept')).length, reject = tiles.filter((c) => c.includes('reject')).length;
check(tiles.length === 33 && accept + reject + tiles.filter((c) => c.includes('wrong')).length === 33,
  `${name}: 33 tiles, the last round's every case on them (${accept} accepted, ${reject} rejected)`, tiles.join(' / '));
check(steps > 2 && marks.includes('✓') && errors.length === 0,
  `${name}: the case the board sent last, run here in ${steps - 1} rows, beside the board's columns; no script error`,
  `${marks.slice(0, 120)} ${errors.join('; ')}`);
check(status.startsWith('Copied') && clip.startsWith('#page exp228') && clip.endsWith(stream),
  `${name}: Copy puts the verdict and every line received on the clipboard (${clip.length} characters)`, status);
await run.close();

if (name === 'good.txt') {
  run = await openWithBoard(page, null, board);
  ({ tab, errors } = run);
  const said = await tab.textContent('#status');
  await tab.click('#grid .tile:nth-child(9)');
  const p2kh = { head: await tab.textContent('#cname'), sum: await tab.textContent('#csum'),
                 steps: await tab.textContent('#ctrace') };
  await tab.click('#grid .tile:nth-child(27)');
  const invalid = { head: await tab.textContent('#cname'), sum: await tab.textContent('#csum'),
                    steps: await tab.textContent('#ctrace') };
  check(said.includes('no WebUSB') && errors.length === 0,
    'with no WebUSB the page says so, and runs anyway', said);
  check(p2kh.head.includes('pay to key hash') && p2kh.sum.startsWith('Accepted') && p2kh.steps.includes('BIP340: valid')
        && p2kh.steps.includes('OP_EQUALVERIFY'),
    'case 8 tapped, no board: pay to key hash, run here step by step to a valid BIP340 signature, accepted',
    JSON.stringify(p2kh).slice(0, 200));
  check(invalid.head.includes('signature invalid') && invalid.sum.includes('code 8') && invalid.steps.includes('BIP340: invalid'),
    'case 26 tapped: the flipped signature, invalid by the page\'s own BIP340, rejected with code 8',
    JSON.stringify(invalid).slice(0, 200));
  await run.close();
}
process.exit(failed() ? 1 : 0);
