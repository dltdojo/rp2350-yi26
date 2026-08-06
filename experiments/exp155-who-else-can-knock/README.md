# exp155-who-else-can-knock — the first request that changes something

[exp154](../exp154-one-port-four-doors/) put four doors on one port and every
one of them read something. It said why it stopped there:

> The moment one of them writes, the question stops being *which path* and
> becomes *who is allowed to ask* — and that question deserves a measurement,
> not a paragraph.

This is the measurement. The board's LED can now be set over HTTP, two ways,
and the difference between them is the whole experiment.

```text
  GET|POST /led/<on|off|slow|fast|auto>          nothing is consulted
  POST     /control/led/<…>  + X-Yi26-Control    and an Origin that is mine
  OPTIONS  /control/led/<…>                      the question a browser asks first
  GET      /probe                                the same three knocks, from here
```

Needs: any RP2350 board, the exp102 toolchain, a host that shares its
connection, and — for the second half — a browser. Nobody has to be in the
room: the board reports the LED's state in `/status`, so **the subject is a
browser and the instrument is the board**.

## What most people expect, and what a browser actually does

The worry about putting control on HTTP is usually stated as "somebody else on
the network could do it". The real answer is narrower, closer to home, and much
more useful: **the danger is the browser the owner is already running**, and the
thing that stops it is not the method and not the network.

The same page — byte for byte, `/probe`, copied off the board — was served from
a local origin (`http://127.0.0.1:8000` by hand, `:8155` when `check.sh` does it)
and opened in Chrome. Three knocks:

| | from another origin | from the board's own origin |
| --- | --- | --- |
| `<img src="…/led/fast">` | **the LED changed** | the LED changed |
| cross-site form `POST …/led/slow` | **the LED changed** | the LED changed |
| `fetch` `POST …/control/led/off` with `X-Yi26-Control` | **refused, nothing moved** | the LED changed |

Measured on Ubuntu, 2026-08-06, with the board's own log as the witness:

```text
[   69309 ms] led: now fast — asked over GET by no stated origin
[   69334 ms] led: now slow — asked over POST by http://127.0.0.1:8000
[   69344 ms] led: refused a preflight from http://127.0.0.1:8000
```

Three lines, three lessons:

**1. CORS never stopped the request.** It governs whether a page may *read* the
reply. An `<img>` does not need to read anything — it needs the request to be
sent, and it was. A board whose state can be changed by a `GET` can be changed
by any page anywhere that can route to it, and the page does not even have to
be able to see whether it worked.

**2. The first line says `no stated origin`, and that is worse than it looks.**
A browser does not send `Origin` on a plain no-CORS `<img>` GET. So the open
door cannot refuse its caller *and cannot even name it*. There is no log line
to go back to afterwards. The form `POST` on the next line does carry an
origin — so a guard could have refused that one — but the open door does not
look, which is what makes it the open door.

**3. What stopped the third knock was being asked first.** `X-Yi26-Control` is
not a secret; its value is `1` and it is written in this README. Its *name* is
the mechanism: a header outside the handful CORS calls "simple" makes the
browser send an `OPTIONS` preflight before anything happens, and a preflight is
a question the board gets to answer. It answered by saying nothing — no
`Access-Control-Allow-Origin` — and the browser treated silence as no.

```console
$ curl -s -i -X OPTIONS -H "Origin: http://elsewhere.example" \
       http://10.42.0.250/control/led/on | head -3
HTTP/1.0 403 Forbidden
Content-Type: text/plain; charset=utf-8
Content-Length: 90

$ curl -s -i -X OPTIONS -H "Origin: http://10.42.0.250" \
       http://10.42.0.250/control/led/on | head -5
HTTP/1.0 204 No Content
Content-Type: text/plain; charset=utf-8
Content-Length: 0
Access-Control-Allow-Origin: http://10.42.0.250
Vary: Origin
```

## The honest limit, said before somebody discovers it

**An origin check is worth exactly what the browser enforcing it is worth.**
`curl` will send any `Origin` you like, and so will any program on the host:

```console
$ curl -s -X POST -H "X-Yi26-Control: 1" -H "Origin: http://10.42.0.250" \
       http://10.42.0.250/control/led/off
led: off
```

That is not a hole to patch here, it is the shape of the thing. The guard
defends against *a page in a browser*, which is the attacker that arrives
without anybody choosing it. It does not defend against a program on the
machine — and neither does a USB CDC port, which any process can open with no
gesture at all. This repository has never had a transport that did.

What would go further — a token the page is given and a program cannot guess,
`Host:` validation, TLS — is a different experiment and a much larger binary.
TLS in particular is [off this road](../README.md#the-network-road) and stays
there.

## The guard is two conditions, and either alone is nothing

```console
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
       -H "X-Yi26-Control: 1" -H "Origin: http://elsewhere.example" \
       http://10.42.0.250/control/led/off
403                       # the right header, the wrong origin

$ curl -s -o /dev/null -w '%{http_code}\n' -X POST \
       -H "Origin: http://10.42.0.250" http://10.42.0.250/control/led/off
403                       # the right origin, no header — so no preflight, so no question
```

The second one matters more than it looks. Without the header there is no
preflight, and without a preflight the board is *told* rather than *asked* —
so refusing that request is refusing the shape of it, not the origin in it.

### A `null` that was nearly granted

The first version echoed the origin back on every allowed response, and for a
request with no `Origin` at all it wrote:

```text
Access-Control-Allow-Origin: null
```

`null` is not "no origin". It is the origin a sandboxed iframe and a `file://`
page carry — so that line granted precisely the callers least able to say who
they are. Caught by reading what `curl` was actually sent rather than what the
code meant. A request with no `Origin` is not a cross-origin request and now
gets no such header at all.

## The LED, and the cost of handing over an instrument

The LED is what this whole road is read with on a phone, where there is no log
and nothing to install
([`docs/debugging-on-a-phone.md`](../../docs/debugging-on-a-phone.md)). exp154
refused to spend it. This experiment spends it, on one condition:

**The handover does not start until the board has an address.** Until then,
*dark = no link* and *slow = still asking* are the only instrument anybody has,
and a page that could overwrite them would be taking the instrument away at the
exact moment it is the only one. Once a browser can reach the board at all,
those two states have already been proven by the request arriving.

And the cost is stated rather than hidden: **a page can now set the LED to
something indistinguishable from a network state.** `slow` looks like "still
asking"; `off` looks like "no link". That is what handing over an instrument
means. `/led/auto` gives it back, and `check.sh` gives it back when it is done.

## Running it

```sh
cargo build --release
elf2flash convert -b rp2350 \
    target/thumbv8m.main-none-eabihf/release/exp155-who-else-can-knock \
    target/exp155.uf2
yi26 flash target/exp155.uf2

nmcli connection add type ethernet ifname enx022600000155 \
      con-name yi26-exp155 ipv4.method shared
nmcli connection up yi26-exp155

yi26 log --seconds 30        # it prints the address, and keeps printing it
./check.sh                   # board half and browser half
```

Put the connection back with `nmcli connection delete yi26-exp155`.

Open `http://<address>/` in any browser and the LED controls are five ordinary
links. That is the demonstration this pair of experiments was built for: **one
USB cable carrying a user interface, a control channel and a log at once**, with
nothing installed on the host and no device claimed by anything.

## Expected output

`./check.sh`, captured on Ubuntu against a real Pico 2 with Chrome present,
2026-08-06. Run three times in a row for the same result.

```console
PASS  toolchain present (cargo, elf2flash)
PASS  builds (162816 byte .uf2)
PASS  linked at 0x10000000 — an ordinary image
PASS  carries the 1200-baud reboot watcher — the next flash is hands-free
PASS  crates/http-route passes its own tests
PASS  crates/log-ring passes its own tests
PASS  crates/mdns passes its own tests
PASS  the parser can find a named header — the whole of what exp154 was missing
PASS  an unfinished header block is never read as an empty one
PASS  the worker waits for the whole header block before deciding anything
PASS  a header value that could forge a log line is not a value
PASS  /led/… changes the board and consults nothing — the thing being measured
PASS  /control/led/… needs the header AND an origin that is this board's
PASS  the header's name is the mechanism — a non-simple header forces a preflight
PASS  the preflight answers and does nothing — asking is not acting
PASS  a request with no Origin is answered with no Origin header, not with 'null'
PASS  a refusal sends no CORS header at all — a browser reads silence as no
PASS  the LED is only the caller's once there is an address
PASS  ...and the cost of handing it over is written down where it happens
PASS  asking for the state it is already in is transient, not retained
PASS  the only retained http: line is the one that should never happen
PASS  no script in the index or the log page
PASS  /probe is named as the exception, and as an instrument rather than a page
NOTE  enumerated as: exp155 who else can knock
PASS  the board has an address and says so — http://10.42.0.250
PASS  GET /led/fast changed the board — no header, no permission, no question
PASS  POST /led/on did the same — the method was never the boundary
PASS  the guarded door opens for a request with the header and no stated origin
PASS  a foreign Origin is refused even with the header — 403, and nothing moved
PASS  the right origin without the header is refused too — both halves are needed
PASS  a preflight from elsewhere gets 403 and no Allow-Origin — and the LED did not move
PASS  a preflight from this board's own origin is answered 204 with that one origin echoed
PASS  /probe is served, and points at this board by absolute address
PASS  a page from http://127.0.0.1:8155 changed this board's LED — twice, by <img> and by form POST
PASS  ...and its fetch to the guarded door was turned away (12 → 13)
PASS  the guarded door was never opened by a page that did not come from here
PASS  the identical page served from this board opened the guarded door — only the origin differed
NOTE  the LED has been given back to the network reporter.
NOTE  what this script cannot see: that the pin lights an LED. exp103 and
      exp127 established that, and this experiment does not re-establish it.
```

## Two things the harness taught, both worth keeping

**A page is not a witness to what a board received.** `/probe` prints what its
own browser told it, and `--dump-dom` returns before the third knock has been
answered — the DOM says `starting…` while the requests are still in flight. The
check polls `/status` instead. That is `AGENTS.md`'s rule about reading the log
with `yi26` rather than with a browser, in a new place: *the thing under test
cannot be the measuring instrument.*

**A leaked server looks exactly like a failed experiment.** The first version
started the foreign origin in a subshell, so the trap killed the subshell and
not the `python` under it; the next run got a 404 from a server still holding
the port over a deleted directory, and three checks failed as though the finding
had not reproduced. `--directory` instead of a `cd`, so the thing killed is the
thing started.

## What this does not answer

- **`Host:` validation**, and therefore DNS rebinding. The parser can now read a
  header, so this is no longer blocked by the parser — it is simply not what
  this experiment measured.
- **Any defence against a program on the host.** Stated above, and it applies to
  every transport in this repository.
- **Whether another browser agrees.** These are Chrome's CORS and Private
  Network Access rules. They are the same everywhere Chromium is; Firefox and
  Safari have not been tried here.
