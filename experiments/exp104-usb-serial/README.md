# exp104-usb-serial — the board talks back

exp103's blink worked, but it was mute: you could watch it, not ask it
anything. This experiment gives the board a **USB serial port**, so it
reappears in `lsusb` and prints to your terminal.

Still no extra hardware. The same USB cable that flashes the firmware now
carries the conversation — one of the nicer facts about the RP2350.

Needs: any RP2350 board and the exp102 toolchain. The serial port is a chip
feature, so this one is board-independent — the LED blink is incidental.
See [Boards](../README.md#boards).

## The code IS the walkthrough

Read [`src/main.rs`](./src/main.rs). It is exp103's blink plus a USB stack,
and only what is new is commented in depth — the descriptor buffers, the
`bind_interrupts!` macro, why the USB device runs in its own task, and why
the firmware waits for a connection before printing.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, watch it enumerate, read its output
./check.sh    # verdict: builds and converts; also checks the port if flashed
```

## What's actually happening (the manual version)

```sh
cargo build --release
elf2flash convert -b rp2350 \
  target/thumbv8m.main-none-eabihf/release/exp104-usb-serial \
  target/exp104-usb-serial.uf2
# unplug → hold BOOTSEL → plug in
cp target/exp104-usb-serial.uf2 /media/$USER/RP2350/
lsusb -d 1209:0001                        # the board is a USB device again
ls -l /dev/serial/by-id/                  # stable name for its serial port
cat /dev/serial/by-id/usb-rp2350-yi26_*   # listen
```

## The three ideas to take away

1. **One cable, two jobs.** The same USB connection flashes the firmware and
   carries the serial conversation. No debug probe, no second cable, no
   adapter. This is why this repository can teach a lot before asking you to
   buy anything.

2. **The board is a USB device because your code makes it one.** The
   descriptors in `src/main.rs` — vendor ID, product string, device class —
   are exactly what `lsusb` reports back. Change the product string, reflash,
   and `lsusb` changes. The USB stack costs about 7 KB of flash and one task.

3. **Printing is your debugger now.** From here on, an experiment can explain
   itself instead of signalling in blink patterns. That changes what is
   practical to build next.

## About the USB IDs

`1209:0001` comes from [pid.codes](https://pid.codes), a registry that issues
USB IDs for open-source hardware. Using a real vendor's ID for your own device
is both rude and confusing to hosts — pid.codes exists so hobby and learning
projects have an honest option.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Nothing arrives from `cat` | Not in the `dialout` group | `sudo usermod -aG dialout $USER`, then log out/in |
| No `/dev/ttyACM*` after flashing | Enumeration failed | `dmesg \| tail` right after plugging in |
| `lsusb` shows nothing at all | Flash did not take | Redo BOOTSEL and re-run `./run.sh` |
| Output stops when you close the terminal | Normal | The firmware waits for a connection before printing |
| Port name changes between reboots | `ttyACM0` is not stable | Use `/dev/serial/by-id/...`, as the scripts do |

## Make it yours

In `src/main.rs`, change `config.product` to your own string, then re-run
`./run.sh` and look at `lsusb -d 1209:0001`. The device tells the host what to
call it, and you just changed what it says.

## Next

The board can talk, but it cannot listen — `_receiver` is dropped in
`main.rs`. Reading what the host types is what turns this into a two-way link,
and the 1200-baud trick over that same port is what finally retires the
BOOTSEL button.
