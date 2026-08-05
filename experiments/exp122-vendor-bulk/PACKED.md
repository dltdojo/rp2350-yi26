# Pack verification — exp122-vendor-bulk

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W), udev rule 70-rp2350-yi26.rules present
hash: f66003d6e88052f3

Unpacked into an empty directory, `FLASH.txt` followed, including pasting the
raw-USB client straight out of it.

    1  unzip        firmware/exp122-vendor-bulk.uf2
    2  flash        [HUMAN STEP — machine substitute used]
    3  the interface CDC 0, CDC-Data 1, Vendor Specific 2 (EP 0x02 out, 0x83 in)
    4  write client pasted from FLASH.txt, parsed clean
    5  talk to it   sent 5 bytes, got back 5: b'HELLO'
    6  both at once sent 10 bytes, got back 10: b'TWO OWNERS'
                    and the board's own log, over CDC, while it happened:
                    idle: 2 echoes on the vendor interface, 0 CDC packets

`yi26 echo` had no shell equivalent at all — the vendor interface has no
device node, because class 255 means "ask the vendor" and no kernel driver
claims it. There is nothing to open. The replacement opens the raw USB device
under /dev/bus/usb and does the four ioctls a USB library would have done:
claim interface, bulk write, bulk read, release. Twenty-five lines, standard
library, no pyusb — which is not installed here and would have been another
thing to install.

Step 6 is the experiment and the board confirmed it from the other side: the
serial log kept running, on interfaces 0 and 1 held by the kernel, while a
Python process held interface 2. Two owners, one device, USB arbitrating at
the interface rather than at the device.

Nothing was missing and nothing needed fixing. exp119's heredoc lesson was
applied before the run — the block sits at the left margin — and the packed
FLASH.txt reproduced it at column zero, so it pasted and parsed first time.

A NOTE ON THE DELIMITER. Writing this walkthrough broke my own tooling once:
the inner heredoc was called PY, and so was the outer one I was writing it
with, so the first PY closed both. The one in the zip is called VECHO. It is
the same class of mistake as exp119's indentation — a document that carries a
program has to survive being handled by the things that handle documents.

The udev rule is the one prerequisite this experiment cannot do without, and
it is a permission rather than a person, which is why this is PRESENCE 1.
