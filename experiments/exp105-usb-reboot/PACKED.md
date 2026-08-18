# Pack verification — exp105-usb-reboot

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: f0b7e00a48276f26

The zip was unpacked into an empty directory and its `FLASH.txt` followed from
step 1 to step 6, with nothing read from the repository.

What each step actually did:

    1  unzip           firmware/exp105-usb-reboot.uf2, SHA256SUMS
    2  flash           38400 bytes  [HUMAN STEP — see below]
    3  confirm         1209:0001 Generic pid.codes Test PID, /dev/ttyACM0
    4  touch at 1200   2e8a:000f Raspberry Pi RP2350 Boot; no /dev/ttyACM*
    5  the boot drive  sda1 vfat FAT16 RP2350, 127.8M, INDEX.HTM INFO_UF2.TXT
    6  close the loop  1209:0001 back, /dev/ttyACM0 back, 2e8a:000f gone

Steps 4 and 6 together are the experiment: into the bootloader and back out of
it with nothing pressed.

The one human step: step 2 wants a hand on BOOTSEL, and unlike every later
experiment there is deliberately no without-hands route — that is what this
firmware is adding. The board used here was running exp152, which does have
the watcher, so what was executed was the copy onto an already-mounted RP2350
drive rather than the button press that normally precedes it. **The button
itself was not pressed and cannot be pressed from here.**

ONE THING THIS RUN FOUND AND FIXED, and it would have hit every reader.

  `stty -F /dev/ttyACM0 1200` hung with no output and no error. Nothing was
  wrong with the board: Ubuntu runs ModemManager, which opens every new ttyACM
  device for a few seconds to see whether it is a modem, and the touch was
  issued inside that window. The `open()` queued behind it and never returned.
  Waiting and re-running it worked instantly.

  This is worse than an ordinary flake because of WHERE it lands: the reader
  arrives at step 4 seconds after step 2 put a fresh firmware on the board,
  which is exactly the window ModemManager is probing in. The first run of
  this walkthrough did not hit it only because a flashing tool had already
  been talking to the port.

  Step 4 now opens with `sleep 5` and says why, and the troubleshooting list
  names the symptom — prints nothing, never returns — rather than the cause,
  because the symptom is what somebody has in front of them.
