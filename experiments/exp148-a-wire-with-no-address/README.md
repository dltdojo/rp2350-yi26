# exp148-a-wire-with-no-address — a link is not a network

The board grows a **CDC-NCM virtual Ethernet adapter**, runs `embassy-net` over
it, and asks for an address by DHCP. Then it reports how far that got — in the
log, and on the LED.

It stops there on purpose. No sockets, no server, no page. The whole experiment
is the gap between two things that are usually said in one breath:

1. **A driver on the host claimed the interface.**
2. **Somebody handed out an address.**

The first is a fact about USB and it happens on its own. The second is a
*conversation*, and a conversation needs the other end to be willing. Whether it
is depends entirely on the host — and that is why this is the first experiment
on the network road rather than a footnote in the middle of it.

```text
  dark   no host driver has claimed the NCM data interface
  slow   link up, no address — asking, nobody answering
  fast   address leased
```

## Why an LED, again

Same reason as [exp147](../exp147-two-firmwares-one-phone/): the host this
experiment most needs an answer from is a **phone**, and on a phone there is no
log to read, no `ip addr` to type, and nothing to install. There is a board, a
cable, and somebody looking at it.

[`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md) adds the
second reason, learned the hard way: an LED is the one instrument a sleeping
phone cannot interrupt.

The CDC-ACM log is still here and is still where the desktop half reads its
answer. `yi26` is the instrument; the LED is the product.

## How the firmware can see a driver bind

This is the part worth reading the code for, because it is not obvious that a
USB device can know this at all.

A CDC-NCM function has two interfaces. The data one is declared with **two alt
settings** — a zero-bandwidth setting 0, and setting 1 with the bulk endpoints.
A host that has merely enumerated the device leaves it on 0. A host whose driver
has decided to *own* this function selects 1, which is what turns the endpoints
on.

`embassy-usb` surfaces exactly that moment:

```rust
state_chan.set_link_state(LinkState::Down);
self.rx_usb.wait_connection().await.unwrap();
state_chan.set_link_state(LinkState::Up);
```

so `Stack::is_link_up()` answers "has a host driver claimed me". `is_config_up()`
answers the separate question "do I have an address". Two bits, and this
firmware never collapses them:

```rust
match (stack.is_link_up(), stack.is_config_up()) {
    (false, _)    => dark,
    (true, false) => slow,
    (true, true)  => fast,
}
```

## What it cost

Measured on this machine, against [exp147](../exp147-two-firmwares-one-phone/) —
the nearest thing to the same firmware without a network, since both are CDC-ACM
plus the log crates plus the reboot watcher:

| | exp147 | exp148 | delta |
| --- | --- | --- | --- |
| flash | 22,784 B | 40,192 B | **+17,408 B** |
| static RAM (`.bss`) | 11,632 B | 21,336 B | **+9,704 B** |

Most of the RAM is one line: `State<MTU, 4, 4>` is four receive and four
transmit buffers of a whole 1,514-byte Ethernet frame each — about 12 KiB,
allocated whether or not a single frame ever arrives.

The number worth keeping is the one *not* in that table: an A/B slot is
**65,536 bytes**, so a firmware with a whole TCP/IP stack in it still fits one
with 25 KiB spare. A network image does not put the exp142–exp147 road out of
reach. `check.sh` measures that rather than trusting it, because exp150 adds TCP
and an HTTP server to this same base and the claim has an expiry date.

## Flashing it over a partition table takes nothing special

A board that came from exp147 has a **table in sector 0**, and this is an
ordinary image that wants sector 0 for itself. That turns out not to need a
step:

```sh
yi26 bootsel
yi26 pflash target/exp148.uf2
```

PICOBOOT erases every sector it is about to write, and sector 0 is the first of
them, so the table is gone by the time the image lands on top of it. No
`yi26 nuke` — that was in this README's first draft and a board disproved it.

Worth pausing on, because it is the other half of a finding this repository
already had. [exp144](../exp144-one-file-either-half/) established that the
ROM's own **drive** will not take a dropped `.uf2` while a table exists.
PICOBOOT is not the drive and does not consult the table at all. Same board,
same table, two completely different answers depending on which door you use —
and it is why [`pflash.html`](../../tools/pages/pflash.html) can do this from a
phone with no nuke button anywhere in it.

## Expected output

Captured on Ubuntu, 2026-08-05, against an official Pico 2 that was running
exp147's A/B pair a moment earlier.

```console
$ yi26 bootsel
board is in BOOTSEL mode (1200-baud touch)

$ yi26 pflash target/exp148.uf2
flashed 40192 bytes to 0x10000000 over PICOBOOT (10 sectors erased), and rebooted into it. No drive, no drag-and-drop.

$ yi26 log --seconds 8
[      38 ms] exp148 up. CDC-ACM for this log, CDC-NCM for the link.
[      38 ms]   our MAC 02:26:00:00:02:48, the host's end 02:26:00:00:01:48
[      38 ms]   LED: dark = no link, slow = link but no address, fast = address.
[      38 ms] 0 ms  link DOWN — no host driver has claimed the NCM data interface
[     438 ms] 400 ms  link UP, no address — DHCP is asking and nobody is answering
[    5439 ms] 5400 ms  link UP, no address — DHCP is asking and nobody is answering
[   10439 ms] 10401 ms  link UP, no address — DHCP is asking and nobody is answering
```

That transition is the whole of achievement one, and the board did nothing to
earn it — the kernel did it. **How long it takes is the host's business, not
the firmware's**: two runs on this same machine took 400 ms and 1,400 ms, so
treat it as "shortly after enumeration" rather than as a number.

```console
$ ip -brief link show enx022600000148
enx022600000148  UP    02:26:00:00:01:48 <BROADCAST,MULTICAST,UP,LOWER_UP>

$ basename "$(readlink -f /sys/class/net/enx022600000148/device/driver)"
cdc_ncm
```

The interface name is not a coincidence: udev names a USB Ethernet device
`enx` + the MAC the firmware advertises for the host's end. `check.sh` checks
that `run.sh` greps for the name this firmware actually produces.

### The finding: the deadlock is not a phone problem

The prediction going in was that a **phone** would leave the board at "link up,
no address", because Android runs a DHCP *client* on a USB Ethernet gadget and
so does this board — two clients, no server.

The Ubuntu machine does the same thing:

```console
$ nmcli -t -f DEVICE,TYPE,STATE device | grep enx
enx022600000148:ethernet:connecting (getting IP configuration)
```

NetworkManager's default for a new wired interface is to be a DHCP client. So
the slow blink is not the phone's peculiarity — **it is what every host does
until somebody tells it otherwise**, and this repository's own laptop needed
telling too.

That makes exp149 a stronger requirement than it looked. A board that hands out
its own address does not merely rescue the phone case; it removes a manual step
from every host.

## Turning on the other half, on a desktop

This is a change to *your* network configuration, so neither `run.sh` nor
`check.sh` will make it without asking:

```sh
nmcli connection add type ethernet ifname enx022600000148 \
      con-name yi26-exp148 ipv4.method shared
nmcli connection up yi26-exp148
```

NetworkManager then runs dnsmasq and puts this host on `10.42.0.1`. Within a few
seconds the third state arrives:

```console
$ ip -brief addr show enx022600000148
enx022600000148  UP    10.42.0.1/24 fe80::6dab:b65b:8ecf:3472/64

$ yi26 log --seconds 7
[ 1229687 ms] 1229631 ms  link UP, address 10.42.0.204/24
[ 1229687 ms]         gateway 10.42.0.1
[ 1234688 ms] 1234631 ms  link UP, address 10.42.0.204/24
[ 1234688 ms]         gateway 10.42.0.1
```

To undo the change:

```sh
nmcli connection delete yi26-exp148
```

The lease takes a few seconds, not instants. A script that gives up too early
reads as a firmware bug, which is a mistake worth not repeating.

### Three achievements, and still nothing to talk to

The board has a link, an address and a gateway. The host can resolve it:

```console
$ ip neigh show | grep 10.42.0.204
10.42.0.204 dev enx022600000148 lladdr 02:26:00:00:02:48 REACHABLE
```

And it does not answer a ping:

```console
$ ping -c 3 -W 2 10.42.0.204
3 packets transmitted, 0 received, 100% packet loss, time 2045ms
```

Not a fault, and worth sitting with. ARP is answered by the interface layer, so
`REACHABLE` comes for free. **ICMP is not** — `auto-icmp-echo-reply` is a
feature this `Cargo.toml` does not enable, and there is no socket of any kind in
this firmware. The board is fully addressable and entirely mute.

That is exp148's thesis arriving a third time. A wire is not an address, an
address is not a service, and each of those steps is somebody else's decision
before it is yours.

## The phone, which is the point

Nothing in this repository can do this part and nothing in it can see the
result. The firmware is already flashed; the phone needs no app, no browser and
no permission dialog.

Plug it in and read the LED:

| | |
| --- | --- |
| **dark** | Android did not bind a driver — the network road stops here |
| **slow** | Android bound it, and neither end will hand out an address |
| **fast** | something on the phone is a DHCP server — unexpected, and good |

Then look at the status bar too, and check whether **Wi-Fi survived**. A phone
that adopts this as its default network is the risk that decides whether
[exp151](../README.md#the-network-road) can exist at all: a board that reaches
the internet needs the host to still have one.

## What this experiment does not do

- **No sockets.** `Cargo.toml` does not enable `tcp`, and `check.sh` fails if it
  ever does. Sockets are exp150.
- **No static address.** A static address would make the board "have an address"
  on a host where nothing is listening, which answers the question by fiat and
  teaches nothing. Asking is the subject.
- **No two boards.** This repository has two Pico 2s that are never on the same
  bench, so nothing here has ever had two RP2350s talk to each other, and this
  does not either.

## Make it yours

- Change `BLINK_LINK` / `BLINK_ADDRESS` if the two rates are hard to tell apart
  on your board's LED. `check.sh` pins the current pair, so change both places.
- Change `HOST_MAC` / `OUR_MAC` and watch the host's interface name change with
  it. Keep the `0x02` in the first byte: that bit is what says "this address was
  made up locally", and without it the firmware is claiming a range somebody
  bought.
- Drop `N_RX`/`N_TX` from 4 to 2 and watch `.bss` fall by about 3 KiB. Nothing
  in this experiment moves enough traffic to notice.

## Troubleshooting

**The LED never leaves dark.** No driver bound the interface. On Linux check
`lsmod | grep cdc_ncm` and `dmesg | tail`. The board agrees with you — it is not
guessing.

**The LED is stuck on slow.** That is the normal state, not a fault. Nothing on
the host is a DHCP server yet.

**No interface appeared at all but the log is fine.** The CDC-ACM half and the
CDC-NCM half are separate functions; one working says nothing about the other.
`lsusb -v` will show four interfaces.

## Next

[exp149](../README.md#the-network-road) — the board hands out the address
itself, which is the only version of this that works on a phone.
