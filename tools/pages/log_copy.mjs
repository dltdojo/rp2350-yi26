// SPDX-License-Identifier: Apache-2.0
//
// log.html's Copy, as a phone gave it in exp232's round 1: the Clipboard API
// refusing while the log streams. Build b3 called it alone and unguarded, so
// Copy did nothing and said nothing, and the log came back only by pressing
// Disconnect and selecting the whole page. Here the API refuses the same way,
// still connected; Copy and Copy as JSON must each get the text out by the
// fallback, all of it, and say so.
//
//   node log_copy.mjs PAGE       PASS/FAIL lines; exit 0 = all pass

import { checker, openWithBoard } from './headless.mjs';

const page = process.argv[2];
const lines = ['SEARCH tried=1024 accepted=367 relapsing=34', 'PLAN sha256=4cccf5ca', 'PATIENT n=1 arm=treated'];
const stream = lines.map((l) => l + '\r\n').join('');
const { check, failed } = checker();

const run = await openWithBoard(page, stream, { productName: 'exp232 the cure the proof predicts', serialNumber: '232' });
await run.tab.evaluate(() => {
  navigator.clipboard.writeText = () => Promise.reject(new DOMException('Document is not focused.', 'NotAllowedError'));
  window.__copied = [];
  document.addEventListener('copy', () => window.__copied.push(document.activeElement.value || ''));
});

await run.tab.click('#copy');
await run.tab.waitForTimeout(200);
let copied = await run.tab.evaluate(() => window.__copied);
let said = await run.tab.textContent('#status');
check(copied.length === 1 && lines.every((l) => copied[0].includes(l)),
  'Copy, the Clipboard API refusing while connected, puts every line on the clipboard by the fallback',
  `copied ${JSON.stringify(copied)}`);
check(/fallback; the Clipboard API said NotAllowedError/.test(said), 'and says which way, and what the API said', said);

await run.tab.click('#copyjson');
await run.tab.waitForTimeout(200);
copied = await run.tab.evaluate(() => window.__copied);
said = await run.tab.textContent('#status');
check(copied.length === 2 && lines.every((l) => copied[1].includes(JSON.stringify(l).slice(1, -1))),
  'Copy as JSON gets out the same way', `copied ${JSON.stringify(copied.slice(1))}`);
check(/Copied 3 lines as JSON \(fallback/.test(said), 'and says so', said);
check(run.errors.length === 0, 'no script errors', run.errors.join('; '));
await run.close();
process.exit(failed() ? 1 : 0);
