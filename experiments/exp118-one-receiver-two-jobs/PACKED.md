# Pack verification — exp118-one-receiver-two-jobs

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: b48be3f1a5fc58ec

Unpacked into an empty directory, `FLASH.txt` followed. Two terminals, because
something has to be listening while something else talks.

    1  unzip     firmware/exp118-one-receiver-two-jobs.uf2
    2  flash     [HUMAN STEP — machine substitute used]
    3  listen    idle: nothing received yet
    4  send 5    in #1: 5 bytes   0000  68 65 6c 6c 6f   hello
    5  send 100  in #2: 64 bytes  /  in #3: 36 bytes
    6  stop, resume  count carries on

Step 5 is the experiment and it reproduced exactly: one `printf`, two packets,
64 and 36. Nobody asked for that split and nobody can prevent it.

ONE THING THIS RUN FOUND, fixed in the walkthrough and NOT fixable in the zip.

  The firmware's own idle line reads:

      idle: nothing received yet — try  yi26 send hello

  `yi26` is this repository's host tool. It is not in the zip and cannot be —
  a zip carries no buildable source. A reader following the walkthrough is
  told by the board itself to run a command they do not have.

  Step 3 now says to ignore that line and step 4 gives the equivalent that
  needs nothing installed: `printf 'hello' > /dev/ttyACM0`. Sending a hundred
  bytes is `printf 'A%.0s' $(seq 1 100) > /dev/ttyACM0`, which stands in for
  `yi26 send`.

  Changing what the firmware prints would be a change to the experiment
  rather than to its packaging, so the fix went into the packaging: pack.sh
  now detects a firmware whose own log names `yi26` and adds a section to
  FLASH.txt saying the tool is not in the zip and what to use instead.
  **Eighteen of the fifty-two experiments trigger it.** Detected rather than
  listed, so it stays true as the firmware moves.
