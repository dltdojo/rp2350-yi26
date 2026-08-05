# Pack verification — exp121-composite-hid

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W), user in the `input` group
hash: b5bc5f12bdaa2d4a

Unpacked into an empty directory, `FLASH.txt` followed. Two firmware images,
differing only in which order the two functions are declared.

    1  unzip          two .uf2 and SHA256SUMS
    2  flash default  [HUMAN STEP — machine substitute used]
    3  two devices    CDC 0, CDC-Data 1, HID 2
                      usb-rp2350-yi26_exp121_composite_hid_121-if02-event-kbd
                      /dev/ttyACM0
    4  make it type   144 bytes of events out of the kernel's input layer
    5  flash hid-first  HID 0, CDC 1, CDC-Data 2
    6  the filename   usb-rp2350-yi26_exp121_composite_hid_121-event-kbd

Step 6 is the finding and it is sharper than expected. The by-id name lost its
`-if02-` between the two builds, because the HID function stopped being
interface 2. One line moved in the source; the interface numbers moved, so the
endpoint numbers moved, so the path the host names the device by moved.
Anything that hard-coded that path is broken, and nothing in the firmware's
own log would say so.

`yi26 send k` was replaced by `printf 'k' > /dev/ttyACM0`, and reading the
keypress by `cat /dev/input/by-id/*exp121*event-kbd` into a file and looking
at its size. Both need nothing installed.

Nothing was missing and nothing needed fixing. Two things were carried in from
earlier walkthroughs before the run rather than after it: the ModemManager
wait, and the warning not to look at a desktop indicator for Scroll Lock —
GNOME does nothing with that key, so a working keypress and a broken one look
identical there, which is why step 4 reads event bytes instead.

The `input` group requirement is a permission and not a person, which is why
this experiment is PRESENCE 1 despite involving a keyboard. It was already
satisfied on this machine; a reader who lacks it gets told exactly what to
run.
