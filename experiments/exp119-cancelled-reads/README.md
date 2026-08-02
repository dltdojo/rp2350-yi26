# exp119-cancelled-reads — the read that was cancelled

exp118 ended on an open question and refused to guess at it. Its `select` loop
drops an unfinished `read_packet` every time a control event wins. **Does a
packet die with it?**

This experiment cancels twenty thousand reads on purpose and counts what went
missing.

Needs: any RP2350 board, and the exp102 toolchain. No browser.

## The answer is in the driver, and worth reading before measuring

`embassy-rp`'s OUT endpoint read is three steps:

```rust
let val = poll_fn(|cx| {                       // 1. wait
    EP_OUT_WAKERS[index].register(cx.waker());
    let val = T::dpram().ep_out_buffer_control(index).read();
    if val.available(0) { Poll::Pending } else { Poll::Ready(val) }
}).await;

self.buf.read(&mut buf[..rx_len]);             // 2. copy out of DPRAM
w.set_available(0, true);                      // 3. re-arm the endpoint
```

**There is exactly one `await`, and it happens before anything is consumed.**
Steps 2 and 3 are straight-line code with no suspension point between them, so
a dropped future cannot land in the middle of them.

And what step 1 waits on is not a software flag but the hardware's own
buffer-control register. Nobody clears it: the packet sits in DPRAM with
`available == 0` until some `read()` copies it out. A cancelled read leaves
that register exactly as it found it, and the next read sees the same packet.

That is a **different mechanism** from the one exp118 depends on. There, a
control event survives cancellation because `embassy-usb` latches it in an
`AtomicBool` cleared only when observed. Here it survives because the state was
never in software to begin with. Same guarantee, unrelated reasons — which is
exactly why neither may be assumed from the other, and why this was measured.

## Why "nothing was lost" would otherwise prove nothing

A run that loses nothing because no read was ever cancelled is not evidence of
anything. So the number that matters most here is not `gaps` — it is
**`cancels`**.

In the loop, a control event can only win the `select` while a `read_packet` is
being polled. That is what a cancellation *is*, so counting the wins counts the
cancellations exactly, with no extra machinery. A run reporting `cancels: 0`
tested nothing, and the firmware says so in those words rather than printing a
reassuring zero next to it.

`yi26 flood --storm` exists to keep that number large. A second thread toggles
**RTS** for the whole of the send; every toggle is a `SET_CONTROL_LINE_STATE`,
and every one of those fires `control_changed()`.

RTS and not DTR, deliberately. Both fire the same event, but `crates/usb-log`
refuses to write while DTR is low — a DTR storm would silence the log the
measurement is read from. **The instrument would have been destroyed by the
experiment.**

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — exp118's loop with counters instead of a hex
  dump. Nothing in the hot loop logs, for the reason exp110's probe exists.
- [`tools/yi26`](../../tools/README.md) — gained `flood`. There is no shell
  equivalent and that is the point: it has to write at full speed *while*
  toggling RTS on the same open port, and if the two are not simultaneous
  nothing gets cancelled.

## Two ways to do it

```sh
./run.sh      # guided: a quiet run that proves nothing, then one that does
./check.sh    # verdict: floods under a storm, checks the control variable first
```

## Expected output

Captured from a real Pico 2 on Ubuntu. First the quiet run:

```text
sent 20001 packets (1280064 bytes), 0 RTS toggles during the send
[      37 ms] exp119 up. Counting packets, and counting cancelled reads.
[    1037 ms] idle: nothing received — try  yi26 flood --storm
[    2742 ms] run starts: counters cleared by sequence 0
[    3037 ms] rx 2478 (+2478/s)  gaps 0  repeats 0  cancels 0  runts 0
[    3037 ms]    -> 0 cancelled reads: this run has tested nothing
[    4037 ms] rx 10710 (+8232/s)  gaps 0  repeats 0  cancels 0  runts 0
[    4037 ms]    -> 0 cancelled reads: this run has tested nothing
[    5037 ms] rx 18956 (+8246/s)  gaps 0  repeats 0  cancels 0  runts 0
[    5037 ms]    -> 0 cancelled reads: this run has tested nothing
[    6037 ms] rx 20000 (+1044/s)  gaps 0  repeats 0  cancels 0  runts 0
[    6038 ms]    -> 0 cancelled reads: this run has tested nothing
[    7038 ms] settled: 20000 packets, nothing further arriving
[    7038 ms]    -> 0 cancelled reads: this run has tested nothing
```

Twenty thousand packets, not one lost, and **the run is worthless**. Every line
says so.

Then the same load with the reads being cancelled underneath it:

```text
sent 20001 packets (1280064 bytes), 19135 RTS toggles during the send
[    8252 ms] run starts: counters cleared by sequence 0
[    9038 ms] rx 6440 (+6440/s)  gaps 0  repeats 0  cancels 6185  runts 0
[    9038 ms]    -> 6185 reads cancelled, nothing lost
[   10038 ms] rx 14848 (+8408/s)  gaps 0  repeats 0  cancels 14164  runts 0
[   10038 ms]    -> 14164 reads cancelled, nothing lost
[   11038 ms] rx 20000 (+5152/s)  gaps 0  repeats 0  cancels 19134  runts 0
[   11038 ms]    -> 19134 reads cancelled, nothing lost
[   12038 ms] settled: 20000 packets, nothing further arriving
[   12038 ms]    -> 19134 reads cancelled, nothing lost
```

**19,134 cancelled reads. Zero gaps, zero repeats, zero runts.** Nearly every
packet in the run had a read dropped out from under it, and not one byte went
missing.

### Does it cost time instead?

Data is not the only thing a cancellation could cost. Same load, timed end to
end, twice each:

| Storm | Run 1 | Run 2 |
| --- | --- | --- |
| none | 3688 ms | 3596 ms |
| `--storm` | 3600 ms | 3594 ms |

No measurable difference. That says the bottleneck is somewhere other than the
cancellations — **not** that cancellation is free in general. Twenty thousand
of them hid inside the noise of this particular workload, which is a narrower
claim and the only one the numbers support.

## What this does not establish

Measured on RP2350, reading `embassy-rp`'s source. Neither generalises. A
different HAL can have its await *after* it has taken the data, and that
version would lose a packet on every cancellation — with the same API, the same
`select`, and no warning. The habit worth taking from this is not "cancellation
is safe"; it is **look at where the await is**.

## Make it yours

1. Set `--packets 200000` and leave it. Rare failures do not show up in short
   runs, and this is a cheap way to look for one.
2. Comment out the `RESET_SEQ` branch and run `flood` twice. The second run
   reports one gigantic gap — which is what a real loss would look like, and
   worth seeing once so the healthy output means something.
3. Swap `--storm`'s RTS for DTR in `tools/yi26/src/logread.rs` and watch the
   log die. That is the instrument being destroyed by the measurement, and it
   takes one word to cause.
4. Make the counter task slow — add a `Timer::after_micros(200)` after each
   packet. Nothing is lost, because bulk endpoints NAK rather than drop; find
   where the cost went instead.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `cancels 0` with `--storm` | RTS toggles are not reaching the device | `yi26 flood --explain`, then check `yi26 doctor` |
| One enormous `gaps` number | Two runs without a reset between them | Sequence 0 clears the counters; `flood` always sends it first |
| The log goes silent mid-run | The queue overflowed while DTR was low | `crates/usb-log` holds 16 lines; read for a second first |
| `settled:` never appears | Packets are still arriving | It is edge-triggered on the count going quiet — wait a second |

## Next

**exp117** is the one that still needs a person: a browser sending the
1200-baud request, which closes the loop that lets a phone reflash a board with
no toolchain and no second computer.
