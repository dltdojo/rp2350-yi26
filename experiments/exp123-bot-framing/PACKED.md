# Pack verification — exp123-bot-framing

verified: 2026-08-06
steps: 6 of 6 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: c5d436731fd7116a

Unpacked into an empty directory, `FLASH.txt` followed.

    1  unzip        firmware/exp123-bot-framing.uf2
    2  flash        [HUMAN STEP — machine substitute used]
    3  no disk      no sda, no icon, no dialog
    4  but bound    /sys/bus/usb/drivers/usb-storage/1-7:1.2
    5  what it asked cbw #1 INQUIRY, cbw #2 REQUEST SENSE, ...
    6  the census   8 command blocks in six seconds: 4 INQUIRY, 4 REQUEST SENSE

Steps 3 and 4 together are the point, and they reproduced exactly: no block
device, and yet the storage driver did bind. Those are different outcomes and
only the board's log tells them apart. The host attached, asked what the
device was, was refused, asked why, was refused, and gave up after four
tries.

The census is the sharp part. **TEST UNIT READY, READ CAPACITY and READ were
never sent at all** — this host does not get as far as asking whether the
medium is ready when it cannot get past INQUIRY. Both runs, the same eight
blocks and the same two kinds.

Nothing was missing and nothing needed fixing. The step-6 troubleshooting
warns to read soon, because the whole negotiation is over within two seconds
of enumeration and the kernel buffer holds only the last little while —
carried in from exp107 and exp113 rather than discovered again here.

The sysfs path `1-7:1.2` is this machine's and will differ on any other, which
step 4 says.
