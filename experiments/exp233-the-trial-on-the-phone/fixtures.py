#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""exp233 — what trial.html is tested against, written by exp232's cure.py,
which shares nothing with the page: the lines exp232's and exp234's boards
send (tools/hazard3/shell/trial_chip.h's formats), right and wrong in each of
the ways the page must tell apart; and exp234's world.py, for the rate.

  fixtures.py DIR      writes DIR/*.txt, one stream each; DIR/words.txt, random
                       words with cure.py's patient for each; DIR/search.txt,
                       cure.py's search and the protocol's SHA-256 (not a
                       stream: searchline.txt is the stream with a wrong SEARCH);
                       DIR/rate.txt, exp234's divisions for each width and the
                       rate M7 predicts, as an exact fraction
"""
import hashlib
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "exp232-the-cure-the-proof-predicts"))
import cure  # noqa: E402

sys.path.insert(0, os.path.join(HERE, "..", "exp234-the-rate-the-proof-predicts"))
import world  # noqa: E402

SEARCH = cure.search()   # (answer, accepted, relapsing, loophole): about five seconds, so once

OUT = cure.WORDS
STATUS = ("{} usb=6 setups=31 stalls=3 dropped=0 errors=0 ref=00000000 sys=00000000 xosc=00000000 "
          "pll=00000001 usb_khz=48000 sys_khz=10954 sys48_khz=48006 ref_khz=10953 sof_khz=47999 lives={} minstret={}")
MINSTRET = {"exp232": 3084, "exp234": 4046}


def protocol_sha(answer):
    words = [answer, cure.DAYS, cure.DETECT, cure.TISSUE_MIN, max(cure.WIDTHS), cure.MUT_BITS,
             cure.CANDIDATES, cure.SEARCH_SEED]
    return hashlib.sha256(b"".join(w.to_bytes(4, "little") for w in words)).hexdigest()


def stream(words, with_word=True, board="exp232"):
    """[(n, kind, line)]: what trial_chip.h sends for these patients, in order,
    on exp232's board or exp234's."""
    answer, accepted, relapsing, loophole = SEARCH
    head = [f"SEARCH tried={cure.CANDIDATES} accepted={accepted} relapsing={relapsing} answer={answer:08x} "
            f"doses={cure.pc(answer)} loophole={loophole:08x} minstret={MINSTRET[board]}",
            f"PLAN sha256={protocol_sha(answer)}"]
    arm, outcome, predicted, out = [0, 0], [[0] * 3, [0] * 3], [0, 0], []
    for n, r in enumerate(words, 1):
        a, w, at, hist, model, ever = cure.world(r, answer)
        mo, wo = cure.outcome(model), cure.outcome(hist)
        arm[a] += 1
        outcome[a][wo] += 1
        predicted[a] += mo == 0
        out += [(n, "SEARCH", head[0]), (n, "PLAN", head[1])]
        out.append((n, "PATIENT", f"PATIENT n={n}" + (f" word={r:08x}" if with_word else "")
                    + f" arm={'treated' if a else 'control'} width={w} at={at} model={OUT[mo]} world={OUT[wo]}"
                    f" resistant={int(ever)} t24={cure.pc(hist[cure.DAYS - 1][0])}"
                    f" tissue={min(cure.pc(h) for _, h in hist[:cure.DAYS])} t64={cure.pc(hist[-1][0])}"))
        out.append((n, "TRIAL", f"TRIAL treated={arm[1]} cured={outcome[1][0]} relapsed={outcome[1][1]} "
                    f"missed={outcome[1][2]} predicted={predicted[1]} control={arm[0]} control_missed={outcome[0][2]}"))
        out += [(n, "status", STATUS.format(board, n, MINSTRET[board]))] * 3
    return out


def first(items, n, kind, f):
    """The first line of `kind` for patient n changed by f; everything else as it was."""
    done = False
    res = []
    for m, k, line in items:
        if not done and m == n and k == kind:
            line, done = f(line), True
        res.append((m, k, line))
    assert done
    return res


def write(d):
    os.makedirs(d, exist_ok=True)

    def save(name, items):
        with open(os.path.join(d, name), "w", newline="") as f:
            f.write("".join(line + "\r\n" for _, _, line in items))

    rng = random.Random(233)
    words = [rng.getrandbits(32) for _ in range(40)]
    answer = SEARCH[0]
    good = stream(words)
    save("good.txt", good)
    save("old.txt", stream(words, with_word=False))
    # Joined at patient 9: TRIAL's counts include eight the page never saw.
    save("joined.txt", [x for x in good if x[0] >= 9])
    # The patients the world and the model part on, and one of them to spoil.
    parted = [n for n, r in enumerate(words, 1) if (lambda p: p[0] and cure.outcome(p[4]) != cure.outcome(p[3]))(cure.world(r, answer))]
    p = parted[0]
    save("t24.txt", first(good, p, "PATIENT", lambda l: l.replace(" t24=", " t24=1", 1)))
    save("word.txt", first(good, p, "PATIENT", lambda l: l.replace(f"word={words[p - 1]:08x}", f"word={words[p - 1] ^ 2:08x}")))
    # A treated patient the world cured, sent as if it had missed: not the first,
    # so a TRIAL line before it lets the page check the one after it moved by one.
    cured = next(n for n, r in enumerate(words, 1) if n > 1 and r & 1 and cure.outcome(cure.world(r, answer)[3]) == 0)
    save("world.txt", first(good, cured, "PATIENT", lambda l: l.replace(" world=cured", " world=missed")))
    save("plan.txt", first(good, 1, "PLAN", lambda l: l[:-1] + ("0" if l[-1] != "0" else "1")))
    save("searchline.txt", first(good, 1, "SEARCH", lambda l: l.replace("relapsing=34", "relapsing=0")))
    save("trial.txt", first(good, 5, "TRIAL", lambda l: l.replace(" cured=", " cured=1", 1)))
    save("control.txt", [(n, k, l.replace(f"control_missed={sum(1 for x in words[:n] if not x & 1)}",
                                          f"control_missed={sum(1 for x in words[:n] if not x & 1) - 1}") if k == "TRIAL" and n == 6 else l)
                         for n, k, l in good])
    save("lost.txt", [x for x in good if not (x[0] == 12 and x[1] == "PATIENT")])
    save("minstret.txt", first(good, 2, "status", lambda l: l.replace("minstret=3084", "minstret=3085")))
    # exp234's board: the same trial, its own name and count; and a stream
    # whose SEARCH says exp234's count where its status lines say exp232.
    w234 = stream(words, board="exp234")
    save("exp234.txt", w234)
    save("board.txt", first(good, 3, "SEARCH", lambda l: l.replace("minstret=3084", "minstret=4046")))
    save("status234.txt", first(w234, 2, "status", lambda l: l.replace("minstret=4046", "minstret=3084")))

    with open(os.path.join(d, "words.txt"), "w") as f:
        for r in [0, 1, 0xffffffff] + [rng.getrandbits(32) for _ in range(3000)]:
            a, w, at, hist, model, ever = cure.world(r, answer)
            f.write(f"{r:08x} {a} {w} {at} {cure.outcome(model)} {cure.outcome(hist)} {int(ever)} "
                    f"{cure.pc(hist[cure.DAYS - 1][0])} {min(cure.pc(h) for _, h in hist[:cure.DAYS])} {cure.pc(hist[-1][0])}\n")
    a, acc, rel, lo = SEARCH
    with open(os.path.join(d, "search.txt"), "w") as f:
        f.write(f"{cure.CANDIDATES} {acc} {rel} {a:08x} {lo:08x} {protocol_sha(a)}\n")
    p = world.predicted(a)
    with open(os.path.join(d, "rate.txt"), "w") as f:
        f.write(" ".join(str(world.divisions(w, a)) for w in cure.WIDTHS) + f" {p.numerator} {p.denominator}\n")
    return parted, cured


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    parted, cured = write(sys.argv[1])
    print(f"{sys.argv[1]}: 40 patients, the model and the world part on {len(parted)} treated: {parted}; "
          f"patient {cured} is the first the world cured")
