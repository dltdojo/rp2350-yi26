# Pack verification — exp128-reassemble-by-hand

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: 0250f8379cde7185

Unpacked into an empty directory, `FLASH.txt` followed. Two terminals.

    1  unzip       two .uf2 and SHA256SUMS
    2  flash       [HUMAN STEP — machine substitute used]
    3  listen      "A message ends at the first packet under 64 bytes."
    4  send 5      msg #1: 5 bytes, 1 packet: 5   ->  short
    5  send 64     +64 full packet, 64 held — the message may not be over
                   send anything short and it will complete — wrongly
    6  send 1      msg #2: 65 bytes, 2 packets: 64 1

Step 5 is a result that looks like a failure and is the finding: **no message
arrives, and not late — never.** The firmware holds 64 bytes and cannot know
whether they are a whole message or the start of a longer one, because a
full-sized packet means "there may be more" and the thing that would say
otherwise is a zero-length packet this host does not send.

Step 6 is the damage. One unrelated byte terminated somebody else's data and
produced a 65-byte "message" that was never sent as one. The board's
reassembly is correct at every step; the rule is what is wrong, and only a
length prefix or a delimiter fixes it.

**This is a property of the host's USB stack, not of the board.** On a stack
that sends a terminating zero-length packet, step 5 would complete and step 6
would say something else. The walkthrough asks the reader to report which
answer they got, because this is the experiment here most likely to differ
elsewhere.

ONE THING THIS RUN FOUND AND FIXED. `firmware/` carries two images:
`exp128-reassemble-by-hand.uf2` (built today) and `exp128.uf2` (three days
older, and **different bytes** — not a duplicate, so the packer's
deduplication correctly left both). Nothing said which to flash. The
walkthrough now names the long one before step 1 and says what the short one
is. Same species as exp112's third image, and the reason the fix is in the
walkthrough rather than the packer: pack.sh cannot know which of two genuinely
different images an experiment meant.
