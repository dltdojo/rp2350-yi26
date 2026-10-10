// SPDX-License-Identifier: Apache-2.0
//
// exp227 — life.html in a real browser, headless, with no board: Chromium
// (Playwright's, in this machine) opens the page with navigator.usb replaced
// by a device that answers the way exp227's does — 1209:0001, serial 227, a
// CDC pair with a bulk IN endpoint — and hands back a fixture in 64-byte
// packets. What it reaches that page_test.mjs does not: the page's own code
// around the checked block — the connection, the control transfers, the
// drawing, the verdict line, Copy — running where it will run.
//
//   node page_browser.mjs PAGE FIXTURE WANT
//
// WANT is a piece of text the verdict line must contain. Prints PASS/FAIL.

import fs from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); }
catch { ({ chromium } = require(execSync('npm root -g').toString().trim() + '/playwright')); }

const [page, fixture, want] = process.argv.slice(2);
const stream = fs.readFileSync(fixture, 'utf8');

const fake = (text) => {
  const sent = [];
  window.__sent = sent;
  let at = 0;
  const device = {
    productName: 'exp227 the life on the phone', serialNumber: '227', opened: false, configuration: null,
    configurations: [{ interfaces: [
      { interfaceNumber: 0, alternates: [{ interfaceClass: 0x02, endpoints: [{ direction: 'in', type: 'interrupt', endpointNumber: 1 }] }] },
      { interfaceNumber: 1, alternates: [{ interfaceClass: 0x0a, endpoints: [
        { direction: 'out', type: 'bulk', endpointNumber: 1 }, { direction: 'in', type: 'bulk', endpointNumber: 2 }] }] },
    ] }],
    async open() { this.opened = true; },
    async selectConfiguration() { this.configuration = this.configurations[0]; },
    async claimInterface(n) { sent.push(`claim ${n}`); },
    async releaseInterface(n) { sent.push(`release ${n}`); },
    async close() { this.opened = false; },
    async controlTransferOut(setup) { sent.push(`ctl ${setup.request} ${setup.value} ${setup.index}`); return { status: 'ok' }; },
    async clearHalt() {},
    async transferIn(ep, len) {
      // The board sends nothing until DTR, as usbdev.c does.
      if (!sent.includes('ctl 34 3 0') || at >= text.length) return new Promise(() => {});
      const chunk = text.slice(at, at + Math.min(len, 64));
      at += chunk.length;
      await new Promise((r) => setTimeout(r, 0));
      window.__left = text.length - at;
      return { status: 'ok', data: new DataView(new TextEncoder().encode(chunk).buffer) };
    },
  };
  Object.defineProperty(navigator, 'usb', { value: {
    async getDevices() { return [device]; },
    async requestDevice() { return device; },
  } });
};

const browser = await chromium.launch();
const ctx = await browser.newContext();
await ctx.grantPermissions(['clipboard-read', 'clipboard-write']);
const tab = await ctx.newPage();
const errors = [];
tab.on('pageerror', (e) => errors.push(e.message));
await tab.addInitScript(fake, stream);
await tab.goto('file://' + fs.realpathSync(page));
await tab.waitForFunction(() => window.__left === 0, null, { timeout: 60000 });
await tab.waitForTimeout(200);

let failed = 0;
const check = (ok, what, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
  if (!ok) failed++;
};
const verdict = await tab.textContent('#verdict');
const sent = await tab.evaluate(() => window.__sent.join(', '));
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
await browser.close();
process.exit(failed ? 1 : 0);
