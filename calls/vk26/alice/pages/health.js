// SPDX-License-Identifier: Apache-2.0
//
// calls/vk26/alice/pages — what every alice page that judges samples judges
// them with, and the lines every alice board sends them in. vk26-alice-1's
// seam.html wrote it; vk26-alice-2's trust.html is the second to need it.
//
// BEGIN health
// ---------------------------------------------------------------------------
// SP 800-90B's repetition count and adaptive proportion tests, written here
// one sample at a time, as the standard states them and as exp114's crate
// runs them, and as alice/tools/health.py has them in Python: the run is not
// reset at a window's edge; each window's first sample is its reference; a
// window fails at a run of 21 or 589 of its 1024 samples equal to its first;
// judging stops at the first window that fails. Each experiment's
// page_test.mjs holds this to its own Python reference, on every stream.
//
//   BITS round s k w0 … w15        samples 512k to 512k + 511 of stream s:
//                                  sample i is bit i % 32 of word i / 32
//   ROUND round streams            every stream of a round run
//   FAIL …                         a check on the board failed
// ---------------------------------------------------------------------------

const HEALTH_N = 1024, HEALTH_RCT = 21, HEALTH_APT = 589;

/** Words in, samples out: sample i is bit i % 32 of word i / 32. */
function healthSamples(words) {
  const bits = new Array(32 * words.length);
  for (let i = 0; i < bits.length; i++) bits[i] = (words[i >>> 5] >>> (i & 31)) & 1;
  return bits;
}

/**
 * The first `windows` windows of `bits`, judged in turn: how many passed
 * before the first failure, and for each window reached, the run carried into
 * it from the window before, the longest run in it (carried part included),
 * how many samples equal its first, what failed, and whether the run that
 * reached 21 began in an earlier window.
 */
function healthJudge(bits, windows) {
  let last = -1, run = 0;
  const reached = [];
  for (let w = 0; w < windows; w++) {
    const start = w * HEALTH_N, ref = bits[start];
    const carried = bits[start] === last ? run : 0;
    let matches = 0, longest = 0, across = false, hit = false;
    for (let i = start; i < start + HEALTH_N; i++) {
      run = bits[i] === last ? run + 1 : 1;
      last = bits[i];
      if (run > longest) longest = run;
      if (run === HEALTH_RCT && !hit) { hit = true; across = i - HEALTH_RCT + 1 < start; }
      if (bits[i] === ref) matches++;
    }
    const fail = longest >= HEALTH_RCT ? 'run' : matches >= HEALTH_APT ? 'APT' : null;
    reached.push({ carried, longest, matches, fail, across });
    if (fail) return { passed: w, windows: reached };
  }
  return { passed: windows, windows: reached };
}

/** The 4096 bytes HASH reads for window w: its samples as little-endian words. */
function healthWindowBytes(bits, w) {
  const b = new Uint8Array(4 * HEALTH_N);
  for (let i = 0; i < HEALTH_N; i++) b[4 * i] = bits[w * HEALTH_N + i];
  return b;
}

const healthHex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');

/** A BITS, ROUND or FAIL line, or a status line from the board named `serial`; null for any other. */
function healthLine(text, serial) {
  const t = text.trim(), h = '([0-9a-f]{8})';
  let m;
  if ((m = t.match(new RegExp(`^BITS ${h} ${h} ${h}((?: [0-9a-f]{8}){16})$`))))
    return { kind: 'BITS', round: parseInt(m[1], 16), s: parseInt(m[2], 16), k: parseInt(m[3], 16),
             words: m[4].trim().split(' ').map((x) => parseInt(x, 16) >>> 0) };
  if ((m = t.match(new RegExp(`^ROUND ${h} ${h}$`))))
    return { kind: 'ROUND', round: parseInt(m[1], 16), streams: parseInt(m[2], 16) };
  if (t.startsWith(`${serial} usb=`)) return { kind: 'status' };
  if (/^FAIL /.test(t)) return { kind: 'FAIL' };
  return null;
}

/**
 * Each stream's BITS lines, gathered: add(e) a BITS line; take(round, s) its
 * samples, once, or null if any of its `lines` lines never arrived — the page
 * joined mid-stream, or a line was lost; takeWords(round, s) the same, as the
 * words the lines carried (vk26-alice-3's samples are their bytes).
 */
function healthStreams(lines) {
  const parts = new Map();
  const takeWords = (round, s) => {
    const key = `${round}:${s}`, p = parts.get(key);
    parts.delete(key);
    return !p || p.some((x) => x === null) ? null : [].concat(...p);
  };
  return {
    add(e) {
      const key = `${e.round}:${e.s}`;
      if (!parts.has(key)) parts.set(key, new Array(lines).fill(null));
      if (e.k < lines) parts.get(key)[e.k] = e.words;
    },
    takeWords,
    take(round, s) {
      const w = takeWords(round, s);
      return w === null ? null : healthSamples(w);
    },
  };
}
// END health
