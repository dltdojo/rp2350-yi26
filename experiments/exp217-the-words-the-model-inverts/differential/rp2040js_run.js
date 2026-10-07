// SPDX-License-Identifier: Apache-2.0
//
// exp217 — the same cases on rp2040js (tools/pio-emulators), Wokwi's RP2040
// emulator: its PIO0 state machine 0, configured through its own register
// fields and stepped one call at a time. Reads cases.py's lines on
// stdin, prints Run.lean's trace format.
//
//   node rp2040js_run.js < cases
'use strict';
const path = require('path');
const { RP2040 } = require(path.join(__dirname, '../../../tools/pio-emulators/node_modules/rp2040js'));

const nums = (s) => s.trim().split(/\s+/).filter((t) => t.length).map(Number);

function runCase(line) {
  const [c, prog, st, tx, ext, steps] = line.replace(/^.*#/, '').split('|').map(nums);
  const mcu = new RP2040();
  const pio = mcu.pio[0];
  const sm = pio.machines[0];
  prog.forEach((w, i) => { pio.instructions[i] = w; });
  const [wb, wt, inBase, outBase, outCount, setBase, setCount, jmpPin, inRight, outRight, pushT, pullT, statusN] = c;
  sm.execCtrl = (jmpPin << 24) | (wt << 12) | (wb << 7) | statusN;
  sm.shiftCtrl = ((pullT & 31) << 25) | ((pushT & 31) << 20) | (outRight << 19) | (inRight << 18);
  sm.pinCtrl = (setCount << 26) | ((outCount & 63) << 20) | (inBase << 15) | (setBase << 5) | outBase;
  for (let i = 0; i < mcu.gpio.length; i++) {
    mcu.gpio[i].padValue |= 0x40;
    mcu.gpio[i].setInputValue(!!((ext[0] >>> i) & 1));
  }
  [sm.pc, sm.x, sm.y, sm.inputShiftReg, sm.inputShiftCount, sm.outputShiftReg, sm.outputShiftCount] = st;
  tx.forEach((w) => sm.txFIFO.push(w));
  const items = (f) => { const a = []; for (let k = 0; k < f.used; k++) a.push(f.buffer[(f.start + k) % f.buffer.length] >>> 0); return a; };
  const lines = [];
  for (let n = 0; n < steps[0]; n++) {
    sm.step();
    lines.push(`${sm.pc} ${sm.x >>> 0} ${sm.y >>> 0} ${sm.inputShiftReg >>> 0} ${sm.inputShiftCount} ` +
      `${sm.outputShiftReg >>> 0} ${sm.outputShiftCount} ${pio.pinValues >>> 0} ${pio.pinDirections >>> 0} ${pio.irq} ` +
      `[${items(sm.txFIFO).join(',')}] [${items(sm.rxFIFO).join(',')}]`);
  }
  return lines;
}

const input = require('fs').readFileSync(0, 'utf8').split('\n').filter((l) => l.trim().length);
input.forEach((line, n) => { console.log(`case ${n}`); runCase(line).forEach((l) => console.log(l)); });
