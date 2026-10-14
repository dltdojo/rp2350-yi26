# alice/pages — what alice's five pages share

Every vk26-alice experiment has a page a person opens on a phone, with the
board plugged into it (the call's rule). The five pages differ in what they
check and what they draw, and in nothing else: they find the board's CDC
pair, claim it, raise DTR, read 64-byte packets and cut them into lines,
disconnect, copy, save. That part is here once. And the ones that judge
samples judge them the same way, SP 800-90B's two tests over BITS lines: that
part is here once too, since vk26-alice-2's page is the second to need it.

| File | What it is |
| --- | --- |
| [`core.js`](./core.js) | connecting, reading, Disconnect, Copy, Save (the same text as a file, for a log too long to paste): `appliance({ serial, page, onText, report })`, `cdcLines()`, `checkedLines(feed, after)` (each line through a page's checker, in order, shown in #raw), `findCdc` (tools/pages/log.html's, byte for byte) |
| [`core.css`](./core.css) | the look |
| [`health.js`](./health.js) | SP 800-90B's repetition count and adaptive proportion tests a sample at a time, as [`../tools/health.py`](../tools/health.py) has them in Python; the BITS, ROUND and FAIL lines; each stream's samples gathered from its BITS lines (`healthJudge`, `healthLine`, `healthStreams`, `healthWindowBytes`) |
| [`build.py`](./build.py) | one page, one file: puts `core.js`, `health.js` and `core.css` into a page, for a phone |
| [`pagetest.mjs`](./pagetest.mjs) | a page's checked block under node with health.js's and `cdcLines`, from the page itself when it is built (so a mutant of the built page is a mutant of what a phone runs); lines in 64-byte packets |
| [`browser.mjs`](./browser.mjs) | a built page in headless Chromium against a stand-in board: claims, verdict line, table, Copy, Save |

An experiment's page is thin: its own checked block (between `// BEGIN` and
`// END`, which its `page_test.mjs` runs under node), its own drawing, and
`<script src="../pages/core.js"></script>` (and `health.js`). So it runs as it is from the
repository on a desktop, and the call's judge sees the same files it does:
`judge-bundle.sh` puts every page an experiment's README links into J1's
slice, with the scripts the page loads from beside it.

A phone opening one file from its Files app cannot follow `../pages/`. So:

```sh
python3 ../pages/build.py seam.html build/seam.html
```

and the phone gets `build/seam.html`. Each experiment's `check.sh` runs its
tests on the built file too, makes its wrong pages from the built file, and
holds its `findCdc` to log.html's.

This is decision 1 of [alice's plan](../README.md#四討論的結果), option (c).
