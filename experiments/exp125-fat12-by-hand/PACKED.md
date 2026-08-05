# Pack verification — exp125-fat12-by-hand

verified: 2026-08-06
steps: 5 of 5 executed, 1 marked HUMAN STEP
host: Ubuntu, Pico 2 (non-W)
hash: c771478ad9e57b27

Unpacked into an empty directory, `FLASH.txt` followed.

    1  unzip        firmware/exp125-fat12-by-hand.uf2
    2  flash        [HUMAN STEP — machine substitute used]
    3  a filesystem sda vfat FAT12 YI26 EXP125 2635-1225 62K 1%
                    mounted at /media/$USER/YI26 EXP125, unprompted
    4  read a file  README.TXT, 324 bytes, and it says what it is
    5  why FAT12    125 clusters, which is under 4085

The trio closes here, and all three were walked on the same host within two
hours:

    exp123  refuse everything   no disk at all
    exp124  answer             sda 64K, no filesystem
    exp125  lay down bytes     sda vfat FAT12, labelled, mounted, with a file

Step 4 is the one worth doing slowly. The text arrives through a filesystem
nobody implemented: there is no FAT driver in this firmware, only bytes placed
where the specification says a boot sector, a file allocation table and a root
directory go. The kernel did the rest.

Step 5 is the detail that is easy to read past. FAT12 is not a flag in the
boot sector — the cluster count IS the format. 125 clusters is under 4085, so
every FAT entry is twelve bits. Nothing declares it and everything depends on
it.

Nothing was missing and nothing needed fixing. The splice had to try three
anchors: these READMEs do not share a section layout, and assuming they do has
now failed twice (exp124, exp125), so the script checks its own result.
