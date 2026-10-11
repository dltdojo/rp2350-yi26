// SPDX-License-Identifier: Apache-2.0
//
// An appliance page in a real browser, headless, with no board: Chromium
// (Playwright's) opens the page with navigator.usb replaced by a device that
// answers the way a CDC firmware here does — 1209:0001, a CDC pair with a
// bulk IN endpoint — and hands back a stream in 64-byte packets, starting only
// once the page raises DTR, as usbdev.c does. What it reaches that a node test
// of a page's checked block does not: the page's own code around that block —
// the connection, the control transfers, the drawing, Copy — running where it
// will run.
//
//   import { openWithBoard } from '../../tools/pages/headless.mjs';
//   const run = await openWithBoard(page, stream, { productName, serialNumber });
//   ... run.tab (a Playwright page), run.errors, await run.sent(), await run.close()
//
// With stream null there is no navigator.usb at all: the page as a browser
// without WebUSB sees it.
//
// From exp227's page_browser.mjs, the second page to need it being exp228's.

import fs from 'node:fs';
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const require = createRequire(import.meta.url);

export function playwright() {
  try { return require('playwright'); }
  catch { return require(execSync('npm root -g').toString().trim() + '/playwright'); }
}

function fake([text, productName, serialNumber]) {
  const sent = [];
  window.__sent = sent;
  if (text === null) { delete Navigator.prototype.usb; return; }
  let at = 0;
  const device = {
    productName, serialNumber, opened: false, configuration: null,
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
}

/** Open the page with a fake board streaming `stream`; resolves once every byte was taken. */
export async function openWithBoard(page, stream, { productName, serialNumber }) {
  const { chromium } = playwright();
  const browser = await chromium.launch();
  const ctx = await browser.newContext();
  await ctx.grantPermissions(['clipboard-read', 'clipboard-write']);
  const tab = await ctx.newPage();
  const errors = [];
  tab.on('pageerror', (e) => errors.push(e.message));
  await tab.addInitScript(fake, [stream, productName, serialNumber]);
  await tab.goto('file://' + fs.realpathSync(page));
  if (stream !== null) await tab.waitForFunction(() => window.__left === 0, null, { timeout: 60000 });
  await tab.waitForTimeout(200);
  return {
    tab, errors,
    sent: () => tab.evaluate(() => window.__sent.join(', ')),
    close: () => browser.close(),
  };
}

/** PASS/FAIL lines, and a count of the failures. */
export function checker() {
  let failed = 0;
  const check = (ok, what, detail = '') => {
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${what}${ok || !detail ? '' : ` — ${detail}`}`);
    if (!ok) failed++;
  };
  return { check, failed: () => failed };
}
