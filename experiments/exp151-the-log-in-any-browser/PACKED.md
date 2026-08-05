# Pack verification — exp151-the-log-in-any-browser

verified: 2026-08-06
steps: 7 of 7 executed, 2 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W), NetworkManager
hash: b4d0ebfe5592e0eb

The zip built by `pack.sh` was unpacked into an empty directory and its
`FLASH.txt` was followed from step 1 to step 7, with nothing read from the
repository and no command invented that the file does not carry.

What each step actually did:

    1  unzip           CHECK.txt firmware/ FLASH.txt pages/ README.md
    2  flash           136704 bytes on the board  [HUMAN STEP — see below]
    3  find interface  enx022600000151:ethernet:connecting (getting IP configuration)
    4  share it        Connection successfully activated
    5  wait            [HUMAN STEP — see below]
    6  open the page   200, 1978 bytes
    7  put it back     connection deleted, no yi26 connection left active

The two human steps, and what stood in for them:

  * Step 2 wants a hand on BOOTSEL. The board was already running exp151, so
    the 1200-baud watcher rebooted it and `yi26 flash` did the copy — which the
    step itself offers as the without-hands route. **A first flash onto a board
    running exp101–exp104 was not tested and cannot be: there is no watcher
    there, and no substitute for the button.**
  * Step 5 wants an eye on the LED. Not observed. The step says outright that
    nothing depends on it and step 6 answers the same question, which is what
    was done: the address served a page, so the board had an address.

Nothing was missing and nothing needed fixing during this run. Two things had
been fixed earlier, on the run that produced the walkthrough: the expected
output for step 3 named only `disconnected`, when NetworkManager may equally
report `connecting (getting IP configuration)` or `connected`; and a markdown
link had been leaking into the plain-text FLASH.txt as `[text](path)`, which is
a broken promise in a file that carries no paths.
