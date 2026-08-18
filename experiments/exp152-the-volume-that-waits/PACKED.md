# Pack verification — exp152-the-volume-that-waits

verified: 2026-08-06
steps: 10 of 10 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W), NetworkManager
hash: 61c99a29a672b2f1

The zip built by `pack.sh` was unpacked into an empty directory and its
`FLASH.txt` was followed from step 1 to step 10, with nothing read from the
repository and no command invented that the file does not carry.

What each step actually did:

     1  unzip            CHECK.txt firmware/ FLASH.txt pages/ README.md
     2  flash            154624 bytes on the board  [HUMAN STEP — see below]
     3  find interface   enx022600000152:ethernet:connecting (getting IP configuration)
     4  share it         Connection successfully activated
     5  look, no address sda         0B       exp152 waiting
     6  look again       sda        64K YI26 BOARD exp152 waiting
     7  open the drive   /media/$USER/YI26 BOARD, mounted read-only, unprompted
     8  read the address http://10.42.0.250/
     9  open the page    200, 2189 bytes
    10  put it back      unmounted, connection deleted

Steps 5 and 6 are the experiment, and they came out as the file says they
would: a reader with no card, and then a 64 KiB volume that had not been
changed because it had not existed.

The one human step, and what stood in for it:

  * Step 2 wants a hand on BOOTSEL. The board was already running exp152, so
    the 1200-baud watcher rebooted it and `yi26 flash` did the copy — which the
    step itself offers as the without-hands route. **A first flash onto a board
    running exp101–exp104 was not tested and cannot be: there is no watcher
    there, and no substitute for the button.**

The LED is mentioned in steps 5 and 6 and was not observed. It is not load
bearing in either: `lsblk` is the instrument in both, and the LED is written
beside it as the thing a person can see across a room.

Nothing was missing and nothing needed fixing during this run. Three things had
been fixed earlier, on the run that produced the walkthrough: step 3 claimed
`disconnected` when NetworkManager may report `connecting (getting IP
configuration)`; steps 5 and 6 had approximate `lsblk` output rather than what
the command prints; and step 4's expected message was in this machine's locale
rather than in English.
