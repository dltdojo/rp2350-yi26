# Pack verification — exp124-msc-scsi

verified: 2026-08-06
steps: 5 of 5 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: fc29b3afa1021639

Unpacked into an empty directory, `FLASH.txt` followed.

    1  unzip      firmware/exp124-msc-scsi.uf2
    2  flash      [HUMAN STEP — machine substitute used]
    3  a disk     sda  64K  (no label)  exp124 ram disk
    4  the log    INQUIRY -> yi26 / exp124 ram disk
                  TEST UNIT READY -> ok
                  READ CAPACITY -> last LBA 127, 512 bytes each = 64 KiB
    5  the census 5 TEST UNIT READY, 5 READ(10), 4 MODE SENSE(6),
                  2 READ CAPACITY, 1 PREVENT ALLOW MEDIUM REMOVAL, 1 INQUIRY

Identical counts in both runs, and the comparison with exp123 — verified an
hour earlier on the same host and cable — is the reason to walk them as a
pair:

    exp123 (refuse everything)   4 INQUIRY, 4 REQUEST SENSE, nothing else
    exp124 (answer)              18 commands of six kinds

The host asks the next question only when the last one was answered. Written
as a protocol diagram that is a truism; read as two command censuses from the
same machine an hour apart, it is a measurement.

Nothing was missing and nothing needed fixing. The walkthrough was spliced in
before `## Two ways to do it` rather than before `## Expected output`, because
this README has no section by that name — worth noting only because the same
splice failed silently the first time and had to be checked rather than
assumed.

The empty LABEL column is correct and the walkthrough says so: a disk with no
filesystem on it. Desktops offer to format it; exp125 is where the volume gets
one, laid down by hand.
