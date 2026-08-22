# exp168 — a security key that knows nothing

**This is not a security key.** It cannot register a credential, cannot log
anybody in, and contains no cryptography of any kind. It is the transport a
security key is built on, and the first experiment on the
[authenticator road](../README.md#the-authenticator-road).

> **Verified on hardware, 2026-08-22.** The host's own FIDO tooling lists it
> **without root and without any udev rule of ours**. It allocates channels,
> echoes a 1024-byte `PING` back byte-for-byte in **eighteen packets**, and
> answers six different mistakes with the six error codes the specification
> names — including one it answers with **silence**. See
> [Expected output](#expected-output).

## Why the first two experiments on this road carry no cryptography

That road's difficulty note says it plainly, and this experiment is the reason
it exists:

> A CDC device that is half-built still enumerates and still says something. A
> security key either satisfies the browser or produces *"An unknown error
> occurred"*. There is no middle, and this repository's whole method is that
> each experiment proves one thing **observably**.

So there is nothing here for a browser to accept, and nothing here to get wrong
about a key. What there *is* turns out to be the interesting part.

## What it is really about, and it is not enumeration

A CTAPHID report is 64 bytes. An **initialisation packet** spends seven of them
on a header — a four-byte channel identifier, a command byte with its top bit
set, and a sixteen-bit big-endian byte count — leaving **57 bytes of payload**.
Everything after that arrives in **continuation packets**, which spend five
bytes on a header and carry **59**.

So the number of packets a message of `N` bytes takes is not a matter of taste:

```
packets(N) = 1 + ceil(max(0, N - 57) / 59)
```

`verify.py` computes that from `N` and compares it with what happened, on both
sides. **A device that fragmented wrongly but consistently would satisfy every
"the host and the board agree" check and fail this one.**

This is [exp128](../exp128-reassemble-by-hand/)'s subject at a layer where the
specification says what the right answer is — which is the difference worth
having. exp128, [exp135](../exp135-a-packet-with-no-bytes/) and
[exp136](../exp136-joining-halfway/) had to *decide* what a boundary meant. Here
it is written down, so the failures can be graded.

## Twelve cases, and every one can come out the other way

`ctaphid.py` drives them over `/dev/hidraw`, one packet at a time.

| case | what it does | what the protocol requires |
|---|---|---|
| `init` | eight bytes of nonce on the broadcast channel | the nonce echoed, and a channel that is neither `0` nor `0xffffffff` |
| `ping 8` / `ping 57` | a message that fits one packet | **1 packet** back |
| `ping 58` | one byte more than fits | **2 packets** — the first byte that needs a continuation |
| `ping 200` | four packets' worth | **4 packets**, byte-identical |
| `ping 1024` | the largest this device will assemble | **18 packets**, byte-identical |
| `ping 2000` | larger than that | `ERR_INVALID_LEN` — refused, not truncated |
| `bad-seq` | a continuation packet numbered 3 where 0 was due | `ERR_INVALID_SEQ` |
| `busy` | a second channel interrupting a transaction | `ERR_CHANNEL_BUSY` |
| `truncated` | a byte count that promises more than is sent | `ERR_MSG_TIMEOUT`, and the channel is freed |
| `unknown` | `CTAPHID_CBOR`, which this device does not have | `ERR_INVALID_CMD` |
| `stray-cont` | a continuation packet for no transaction | **silence** |

`stray-cont` is the one worth arguing about. Every other mistake gets a number;
this one gets nothing, because the specification says a continuation packet for
a transaction that does not exist is **ignored**. A device that answered it
would be inventing a conversation it is not having — and it is the only place in
CTAPHID where silence is the specified answer, which makes it the only place
this repository's usual instinct ([exp134](../exp134-the-log-nobody-reads/): a
firmware that goes quiet has proved nothing) is wrong.

## The report descriptor is hand-written, and exp121 said it would be

[exp121](../exp121-composite-hid/) generated a keyboard's descriptor and said
why:

> Hand-rolling one is a fine exercise and a poor first descriptor change: a
> malformed report descriptor is accepted by the builder and rejected by the
> host, which looks like a hardware fault.

This is that exercise. No crate generates the FIDO one, the bytes are fixed by
the specification, and `embassy-usb`'s HID `Config` takes a raw slice — so it is
34 bytes written out with the reason for each:

```
06 d0 f1   Usage Page (0xF1D0 — the FIDO Alliance's)
09 01      Usage (U2F HID Authenticator Device)
a1 01      Collection (Application)
09 20      Usage (Input Report Data)
15 00      Logical Minimum (0)
26 ff 00   Logical Maximum (255) — two bytes, because 0xff in one is read as −1
75 08      Report Size (8 bits)
95 40      Report Count (64) — the packet size the protocol assumes
81 02      Input (Data, Variable, Absolute)
...        the same again for the Output report
c0         End Collection
```

### Those 34 bytes are what earns the access

The open question this experiment was written to settle was whether it needs a
udev rule of its own, and the answer is **no**:

```console
$ ls -l /dev/hidraw4
crw-rw----+ 1 root root 239, 4  /dev/hidraw4
$ fido2-token -L
/dev/hidraw4: vendor=0x1209, product=0x0001 (rp2350-yi26 exp168 a security key that knows nothing)
```

The `+` is an ACL. **The host's own rules already recognise the FIDO usage page
and grant the logged-in user access** — no vendor ID, no product ID, and nothing
installed for this. [exp115](../exp115-webusb-enumerate/) needed a rule of this
repository's own for raw USB; a FIDO device does not, and the two bytes
`0x06 0xD0 0xF1` are the whole difference.

## And it tells the truth about itself

`fido2-token -I` does not fail on this device. It reports it:

```console
proto: 0x02
major: 0x00
minor: 0x01
build: 0x00
caps: 0x08 (nowink, nocbor, nomsg)
```

`caps: 0x08` is `CAPABILITY_NMSG` and the *absence* of `CAPABILITY_CBOR`.
`libfido2` decodes it and prints `nocbor, nomsg` — **the device saying it knows
nothing, in the protocol's own words, and a host tool believing it.**

This was written down beforehand as an open question and came out better than
the guess: the interrogation for this experiment predicted `fido2-token -I` would
*fail*, and that how it failed would be the finding. It does not fail. It reads
a capability byte, which is what a capability byte is for.

## Still a composite device, and that is not for symmetry

The CDC log stays, and the reason is on the road rather than in this experiment.
Prior work on this chip got an authenticator working in desktop Chrome and then
failed on Android with nothing but *"An unknown error occurred while talking to
the credential manager"* — a generic message from a stricter CTAP
implementation, with the interesting detail never reaching the browser. It was
found by reading the firmware's own log on the phone.

**On this road the log is the only channel that says anything when the strict
half says no.**

## What it cost to find out

Two flashes, and both problems were the instrument.

- **The log's pacing made a legal message fail.** The first version printed a
  paced line for every packet received. A 1024-byte `PING` is eighteen of them,
  and at 60 ms a line the device spent **1.08 s** reassembling a message its own
  **750 ms** deadline then expired — `ERR_MSG_TIMEOUT` for a message that was
  entirely correct. Continuation packets are now counted and reported once, when
  the message is whole. The subject was fine; the instrument was slower than it.
- **`check.sh` failed on the firmware's own denial.** A grep for key material
  matched the word *secret* inside the line that says the device has none, and a
  byte count of the report descriptor came out 36 because two of the comments
  beside the bytes mention `0xFF` and `0xF1D0`. Both now strip what they should
  never have been reading.

## What is not verified here

- **It is not a security key**, and nothing here is a step towards trusting one.
- **No browser has seen it.** It has nothing a browser could use;
  `navigator.credentials` needs `authenticatorGetInfo`, which is the next
  experiment.
- **`MAX_MESSAGE` is 1024, not the specification's 7609.** Nothing here needs
  them, and what matters is that the limit produces `ERR_INVALID_LEN` rather
  than a truncation. A real authenticator would need more.
- **One host.** Linux, `libfido2`, `hidraw`. Whether Windows, macOS or Android
  list this device is untested, and Android is the one with a history —
  see the road.
- **Channel allocation is a counter.** It never returns a reserved or broadcast
  value and never repeats within a boot, which is all the specification asks and
  all a host uses it for. It is not unpredictable and does not need to be.
- **`CTAPHID_WINK`, `CANCEL`, `LOCK` and `KEEPALIVE` are not implemented.**
  They draw `ERR_INVALID_CMD`, which is honest and is not the same as supported.

## Running it

```console
cd experiments/exp168-a-security-key-that-knows-nothing
./check.sh          # builds, flashes, drives twelve cases, grades all of them
```

One round by hand, printing both voices:

```console
./drive.sh
```

One case:

```console
python3 ctaphid.py ping 200
python3 ctaphid.py bad-seq
```

`ctaphid.py` finds the device the way `libfido2` does — by reading every
`hidraw` node's report descriptor and looking for usage page `0xF1D0` — so it
needs no configuration and no device path.

To check a transcript you already have, on any machine, with nothing installed:

```console
python3 verify.py < capture.txt
```

`verify.py` derives the packet count from the byte count rather than reading it,
requires every echo to be byte-identical, requires each deliberate mistake to
draw the error the specification names, requires the stray continuation packet
to have drawn none, and requires the printed report descriptor to be 34 bytes
beginning with the FIDO usage page.

## Expected output

Pasted from a real run on a Pico 2, Ubuntu, 2026-08-22. Trimmed; the full
transcript, both voices, is [`capture.txt`](./capture.txt).

```console
>>> host: fido2-token -L, which finds authenticators by usage page and nothing else
    /dev/hidraw4: vendor=0x1209, product=0x0001 (rp2350-yi26 exp168 a security key that knows nothing)

>>> host: case ping 58
    {"sent_bytes": 58, "sent_packets": 2, "reply": {"cmd": 1, "len": 58, "packets": 2, ...}, "echo_matches": true}
>>> host: case ping 1024
    {"sent_bytes": 1024, "sent_packets": 18, "reply": {"cmd": 1, "len": 1024, "packets": 18, ...}, "echo_matches": true}
>>> host: case ping 2000
    {"reply": {"cmd": 63, "len": 1, "error_code": 3, "error_name": "ERR_INVALID_LEN"}}
>>> host: case bad-seq
    {"reply": {"cmd": 63, "len": 1, "error_code": 4, "error_name": "ERR_INVALID_SEQ"}}
>>> host: case busy
    {"cid_a": "...", "cid_b": "...", "reply": {"error_code": 6, "error_name": "ERR_CHANNEL_BUSY"}}
>>> host: case truncated
    {"reply": {"error_code": 5, "error_name": "ERR_MSG_TIMEOUT"}}
>>> host: case unknown
    {"reply": {"error_code": 1, "error_name": "ERR_INVALID_CMD"}}
>>> host: case stray-cont
    {"reply": null, "silence_expected": true}

>>> host: fido2-token -I, which needs a CBOR command this device does not have
    proto: 0x02
    caps: 0x08 (nowink, nocbor, nomsg)

>>> board: what it said while all of that happened
    [    3157 ms]   FIDO report descriptor: 34 bytes, hand-written, usage page 0xF1D0
    [    3337 ms]   init packet carries 57 payload bytes, cont carries 59
    [   12084 ms] in  cid 00000006 PING bcnt 1024
    [   12144 ms]   assembled 1024 bytes in 0 ms
    [   12296 ms]   PING: echoed 1024 bytes in 18 packets
```

`./check.sh` on the same board:

```console
PASS  fido2-token present (the host's own FIDO tooling, nothing installed for this)
PASS  no cryptography is in this firmware: not one crypto dependency
PASS  no key material or signing in the source, log lines and comments aside
PASS  the firmware says what it is not, in its own first lines
PASS  the report descriptor is 34 bytes, written out by hand
PASS  it begins with usage page 0xF1D0, which is what makes it a FIDO device
PASS  the descriptor is hand-written, not generated (exp121's promised exercise)
PASS  57 and 59 are derived from the header sizes, not typed
PASS  a spurious continuation packet is ignored, which the specification asks for
PASS  an unfinished transaction expires instead of holding the channel
PASS  verify.py rejects a packet count the arithmetic contradicts (got DISAGREE)
PASS  verify.py rejects a device claiming a capability it lacks (got DISAGREE)
PASS  a live round satisfies the protocol's own arithmetic
PASS  the host's FIDO tooling lists it without root and without a rule of ours
PASS  fido2-token -I reports a device that knows nothing, in the protocol's words
```

## Four things to take away

1. **A descriptor is a claim, and hosts act on it.** Thirty-four bytes turned a
   generic USB device into something the operating system grants a user access
   to and a FIDO tool will talk to. Nothing else about this board changed.
2. **Fragmentation is arithmetic, and arithmetic is checkable.** `1 + ceil((N −
   57) / 59)` is the whole of CTAPHID's framing, and computing it off the board
   catches a device that is wrong the same way twice.
3. **Silence is specified exactly once here, and everywhere else is a number.**
   Six mistakes, six error codes, and one case that must draw nothing. Knowing
   which is which is the difference between a device a host can debug and one it
   can only give up on.
4. **An honest capability byte is worth more than a feature.** This device says
   `nocbor, nomsg`, and `fido2-token` reports that instead of hanging. A device
   that had lied would have produced the road's least useful sentence: *an
   unknown error occurred*.

## Next

**One CBOR map.** `authenticatorGetInfo`, and nothing else — the first command
with a body a host parses rather than echoes, and the point at which
`fido2-token -I` stops reporting a capability byte and starts reporting what
this device can do. Still no cryptography, still no secret, still no browser.
A CBOR encoder is the shape of [`crates/fat12`](../../crates/fat12/) and
[`crates/dhcp`](../../crates/dhcp/): host tests for the bytes, and the board for
the claim.
