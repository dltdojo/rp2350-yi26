# alice/pages — what alice's five pages share

Every vk26-alice experiment has a page a person opens on a phone, with the
board plugged into it (the call's rule). The five pages differ in what they
check and what they draw, and in nothing else: they find the board's CDC
pair, claim it, raise DTR, read 64-byte packets and cut them into lines,
disconnect, copy. That part is here once.

| File | What it is |
| --- | --- |
| [`core.js`](./core.js) | connecting, reading, Disconnect, Copy: `appliance({ serial, page, onText, report })`, `cdcLines()`, `findCdc` (tools/pages/log.html's, byte for byte) |
| [`core.css`](./core.css) | the look |
| [`build.py`](./build.py) | one page, one file: puts `core.js` and `core.css` into a page, for a phone |

An experiment's page is thin: its own checked block (between `// BEGIN` and
`// END`, which its `page_test.mjs` runs under node), its own drawing, and
`<script src="../pages/core.js"></script>`. So it runs as it is from the
repository on a desktop, and the call's judge sees the same files it does:
`judge-bundle.sh` puts every page an experiment's README links into J1's
slice, with the scripts the page loads from beside it.

A phone opening one file from its Files app cannot follow `../pages/`. So:

```sh
python3 ../pages/build.py seam.html build/seam.html
```

and the phone gets `build/seam.html`. Each experiment's `check.sh` runs its
tests on the built file too, and holds its `findCdc` to log.html's.

This is decision 1 of [alice's plan](../README.md#四討論的結果), option (c).
