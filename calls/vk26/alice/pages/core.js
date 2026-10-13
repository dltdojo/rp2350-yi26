// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/pages — what every one of alice's five pages does the same
// way: find the board's CDC pair, claim it, raise DTR, read 64-byte packets
// and cut them into lines; Disconnect; Copy. Each experiment's page is thin:
// its own checked block, its own drawing, and a call to `appliance`. build.py
// puts this file into the page, so that the phone opens one file.
//
// findCdc is tools/pages/log.html's, byte for byte: a page's check.sh holds it
// to that (tools/pages/pagecheck.sh's page_findcdc), on the built page.
//
//   appliance({ serial, product, page, onText, report, onStart })
//     serial    the USB serial the board must give ("vk26-alice-1")
//     product   what to call it when it does not
//     page      the first word of Copy's first line ("vk26-alice-1 seam.html p1")
//     onText    every piece of text as it arrives
//     report    the page's verdict, one line, for Copy
//   cdcLines()  USB packets in, whole lines out

const FILTERS = [{ vendorId: 0x1209, productId: 0x0001 }];
const SET_LINE_CODING        = 0x20;
const SET_CONTROL_LINE_STATE = 0x22;
const BAUD = 115200;   // nominal; 1200 would reboot some firmwares here into BOOTSEL (log.html says why)

/** USB packets in, whole lines out: a packet is 64 bytes and ends wherever it ends. */
function cdcLines() {
  let pending = '';
  return (chunk) => {
    pending += chunk;
    const parts = pending.split('\n');
    pending = parts.pop();
    return parts.map((p) => p.replace(/\r$/, '')).filter((p) => p.trim());
  };
}

function hex8(x) { return (x >>> 0).toString(16).padStart(8, '0'); }

// Copied from tools/pages/log.html, byte for byte; check.sh holds it to that.
function findCdc(dev) {
  const cfg = dev.configurations[0];
  let control = null, data = null, endpointIn = null;
  for (const iface of cfg.interfaces) {
    const alt = iface.alternates[0];
    if (alt.interfaceClass === 0x02 && control === null) control = iface.interfaceNumber;
    if (alt.interfaceClass === 0x0a && data === null) {
      data = iface.interfaceNumber;
      const ep = alt.endpoints.find((e) => e.direction === 'in' && e.type === 'bulk');
      if (ep) endpointIn = ep.endpointNumber;
    }
  }
  return { control, data, endpointIn };
}

function appliance(opt) {
  const $ = (id) => document.getElementById(id);
  let device = null, streaming = false, captured = '';
  const say = (t, k) => { const s = $('status'); s.textContent = t; s.className = k || ''; };

  async function start(dev) {
    device = dev;
    // Say what was picked before anything can fail: on a phone nobody can
    // screenshot the dialog, and "it did not connect" is not a quantity.
    say(`Picked "${dev.productName}", serial ${dev.serialNumber}. Opening…`);
    try {
      await device.open();
    } catch (e) {
      throw new Error(`cannot OPEN the device, before any interface is claimed. On Linux: "yi26 udev --install". [${e.name}: ${e.message}]`);
    }
    if (device.configuration === null) await device.selectConfiguration(1);
    const { control, data, endpointIn } = findCdc(device);
    if (control === null || data === null || endpointIn === null)
      throw new Error('no CDC interface pair with a bulk IN endpoint on this device');
    try {
      await device.claimInterface(control);
      await device.claimInterface(data);
    } catch (e) {
      throw new Error(`cannot claim the interfaces — something else owns them: another page that has the port ` +
        `open (close it), or on Linux the kernel's cdc_acm ("yi26 detach"). [${e.name}: ${e.message}]`);
    }
    const coding = new DataView(new ArrayBuffer(7));
    coding.setUint32(0, BAUD, true); coding.setUint8(4, 0); coding.setUint8(5, 0); coding.setUint8(6, 8);
    await device.controlTransferOut(
      { requestType: 'class', recipient: 'interface', request: SET_LINE_CODING, value: 0, index: control }, coding.buffer);
    // DTR: the board sends nothing until a page says it is listening.
    await device.controlTransferOut(
      { requestType: 'class', recipient: 'interface', request: SET_CONTROL_LINE_STATE, value: 0x03, index: control });

    streaming = true;
    $('connect').disabled = true;
    $('stop').disabled = false;
    const mine = dev.serialNumber === opt.serial;
    say(mine ? `Listening to "${dev.productName}". ${opt.listening || ''}`
             : `Listening — but this board says serial ${dev.serialNumber}, "${dev.productName}", not ${opt.serial}. `
               + `It will not send what this page reads: flash ${opt.serial}.uf2.`, mine ? 'ok' : 'bad');

    const dec = new TextDecoder();
    while (streaming) {
      let r;
      try {
        r = await device.transferIn(endpointIn, 64);
      } catch (e) {
        if (streaming) say(`Transfer failed: ${e.name}: ${e.message}`, 'bad');
        break;
      }
      if (r.status === 'stall') { await device.clearHalt('in', endpointIn); continue; }
      if (r.data && r.data.byteLength) {
        const text = dec.decode(r.data, { stream: true });
        captured += text;
        opt.onText(text, r.data.byteLength);
      }
    }
  }

  async function stop() {
    streaming = false;
    $('stop').disabled = true;
    try {
      if (device && device.opened) {
        const { control, data } = findCdc(device);
        if (control !== null) {
          await device.controlTransferOut(
            { requestType: 'class', recipient: 'interface', request: SET_CONTROL_LINE_STATE, value: 0x00, index: control });
          await device.releaseInterface(control);
        }
        if (data !== null) await device.releaseInterface(data);
        await device.close();
      }
    } catch (e) { /* the device may already be gone */ }
    $('connect').disabled = false;
    say('Disconnected. The board goes on without a listener.');
  }

  // Copy, in two ways, and saying which one worked. exp226's round 4 found
  // Copy doing nothing on a Pixel 9a while the log streamed and working after
  // Disconnect; nothing said why. So: the Clipboard API first, then a selected
  // textarea and execCommand, and the status line names what failed.
  async function copy() {
    const text = `#page ${opt.page}: ${opt.report()}\n` + captured;
    let first = '';
    try {
      await navigator.clipboard.writeText(text);
      say(`Copied ${text.length} characters (Clipboard API).`, 'ok');
      return;
    } catch (e) { first = `${e.name}: ${e.message}`; }
    const ta = document.createElement('textarea');
    ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.top = '0'; ta.style.opacity = '0';
    document.body.appendChild(ta); ta.focus(); ta.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
    document.body.removeChild(ta);
    say(ok ? `Copied ${text.length} characters (fallback; the Clipboard API said ${first}).`
           : `Copy failed both ways. The Clipboard API said ${first}; the fallback refused. Press Disconnect, then Copy.`,
        ok ? 'ok' : 'bad');
  }

  $('connect').onclick = async () => {
    try { await start(await navigator.usb.requestDevice({ filters: FILTERS })); }
    catch (e) { say(`${e.name}: ${e.message}`, 'bad'); }
  };
  $('stop').onclick = stop;
  $('copy').onclick = copy;

  (async () => {
    if (!('usb' in navigator)) { say('This browser has no WebUSB. Chrome on Android, or a Chromium browser.', 'bad'); $('connect').disabled = true; return; }
    const known = await navigator.usb.getDevices();
    if (known.length) {
      try { await start(known[0]); } catch (e) { say(`${e.name}: ${e.message}`, 'bad'); }
    } else {
      say('Press Connect and choose the board.');
    }
  })();
  return { say };
}
