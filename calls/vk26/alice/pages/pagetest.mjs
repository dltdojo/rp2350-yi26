// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/pages — a page's checked code under node, for each
// experiment's page_test.mjs. vk26-alice-2's is the second to need it.
//
//   pageContext(page, block, names)
//                a node context holding health.js's block, the page's own
//                `// BEGIN block` … `// END block`, and core.js's cdcLines,
//                with each of `names` on it. From the page itself when
//                build.py has put them in it — a built page, or a copy of one
//                a mutant changed — else from beside this file; and node's
//                WebCrypto and TextEncoder as the page has the browser's
//   inPackets(c, cdcLines, text)
//                text through cdcLines in 64-byte packets, as the USB endpoint
//                delivers them, each line awaited by c.feed; every stream it
//                calls wrong, as round:s
//   checker()    tools/pages/headless.mjs's: PASS/FAIL lines

import fs from 'node:fs';
import vm from 'node:vm';

export { checker } from '../../../../tools/pages/headless.mjs';

const between = (text, begin, end) => {
  const i = text.indexOf(begin), j = text.indexOf(end, i);
  return i < 0 || j < 0 ? null : text.slice(i, j);
};
const shared = (file) => fs.readFileSync(new URL(file, import.meta.url), 'utf8');

export function pageContext(page, block, names) {
  const html = fs.readFileSync(page, 'utf8');
  const health = between(html, '// BEGIN health', '// END health')
    ?? between(shared('health.js'), '// BEGIN health', '// END health');
  const own = between(html, `// BEGIN ${block}`, `// END ${block}`);
  if (own === null) throw new Error(`${page} has no // BEGIN ${block} … // END ${block}`);
  const core = html.includes('function cdcLines(') ? html : shared('core.js');
  const at = core.indexOf('function cdcLines(');
  const lines = core.slice(at, core.indexOf('\n}\n', at) + 3);
  const ctx = { crypto: globalThis.crypto, TextEncoder };
  vm.createContext(ctx);
  vm.runInContext(`${health}\n${own}\n${lines}\n${names.map((n) => `this.${n} = ${n};`).join(' ')}`, ctx);
  return ctx;
}

export async function inPackets(c, cdcLines, text) {
  const split = cdcLines(), wrong = [];
  for (let i = 0; i < text.length; i += 64)
    for (const l of split(text.slice(i, i + 64))) {
      const e = await c.feed(l);
      if (e.verdict === 'wrong') wrong.push(`${e.round}:${e.s}`);
    }
  return wrong.join(' ');
}
