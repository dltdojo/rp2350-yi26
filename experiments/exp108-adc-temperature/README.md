# exp108-adc-temperature — the chip takes its own temperature

The RP2350 has a temperature sensor inside it, wired to ADC channel 4. No
wiring, no parts, no breadboard: read one channel, do three lines of
arithmetic from the datasheet, and the log tells you how warm the chip is.

This is the classic first analogue task on any microcontroller, and the first
number in this repository that came from outside the program.

Needs: any RP2350 board, and the exp102 toolchain.

## Why this comes after exp107

Everything logged so far was something the firmware computed — a counter, a
timestamp, how late a wakeup was. You could check those by reading the code.

A measurement is different. The hardware hands you a number between 0 and
4095, and whether it means 43 °C or nothing at all depends on arithmetic you
supply. There is no LED that could show it and no way to tell a correct
reading from a broken one except by knowing what it should look like. That is
exactly what exp107 built the log for.

## The code IS the walkthrough

- [`src/main.rs`](./src/main.rs) — one task, one conversion function. The
  function is the experiment; read its comment before its body.

## Two ways to do it

```sh
./run.sh      # guided: build, flash, read the sensor, then warm the chip
./check.sh    # verdict: builds, and checks the running board if there is one
```

## The arithmetic

The sensor is not a thermometer. It is a diode, and the datasheet gives two
facts about it:

- it reads **0.706 V at 27 °C**, and
- the voltage falls about **1.721 mV for every degree** it warms.

The ADC does not report volts either — it reports where the voltage sits
across its 3.3 V range, in 4096 steps. So:

```rust
let volts = raw as f32 * (3.3 / 4096.0);
27.0 - (volts - 0.706) / 0.001_721
```

Convert the count to volts, see how far that is from the known point, divide
by the slope, subtract. The sign flips because warmer means a *lower* voltage
and therefore a *smaller* count — worth checking against the log below:
`raw 843` gives 42.58 °C and `raw 841` gives 43.52 °C. Smaller count, higher
temperature. If your numbers move the other way, that sign is where to look.

## Do this, in order

Everything here works from a `.zip` built by `pack.sh` alone — no checkout, no
compiler, no `yi26`. The instrument is `cat`.

WHAT YOU NEED
  * A Raspberry Pi Pico 2 and a USB data cable. Nothing else — the sensor is
    inside the chip, and there is no part to add.
  * Ubuntu. `cat` and `stty` are already there.

1. UNPACK IT.

       unzip exp108-adc-temperature.zip
       cd exp108-adc-temperature

2. PUT THE FIRMWARE ON THE BOARD. **[HUMAN STEP]** Hold BOOTSEL, plug in, let
   go, and copy:

       cp firmware/exp108-adc-temperature.uf2 /media/$USER/RP2350/

   *Without hands:* a board already running exp105 or later takes
   `yi26 flash`, which needs the repository.

3. READ THE TEMPERATURE. Give the board five seconds first — Ubuntu's
   ModemManager opens each new `ttyACM` for a moment and `stty` will block
   behind it.

       sleep 5
       stty -F /dev/ttyACM0 -icrnl
       timeout 6 cat /dev/ttyACM0

   Expect:

       [      37 ms] exp108 up. Reading ADC channel 4 — the sensor inside the chip.
       [      37 ms] temp: raw 852 of 4095 -> 38.37 C
       [    1037 ms] temp: raw 844 of 4095 -> 42.11 C
       [    2037 ms] temp: raw 844 of 4095 -> 42.11 C

   **Around 40 °C, not room temperature.** That is not a broken sensor: it is
   a chip that has been running, and a Pico 2 doing almost nothing still sits
   well above the air around it. If you were expecting 22 °C you were
   expecting a thermometer, and this is a chip reporting on itself.

   The first reading is usually the odd one out. It is taken before anything
   has settled, and the ones after it agree with each other.

4. WATCH IT MOVE. **[HUMAN STEP]** Pinch the black chip in the middle of the
   board between finger and thumb for a few seconds while the log is running.
   The number climbs several degrees and then falls back when you let go.

   *Without a finger:* leave `cat` running for a minute and watch the raw
   count drift by one or two — the same sensor, moving more slowly. The
   arithmetic is what is being checked here, and it is checked by the numbers
   being plausible and stable, not by their reacting to you.

IF IT DOES NOT WORK
  * `stty` prints nothing and never returns — ModemManager. Ctrl-C, wait,
    retry.
  * Every line double-spaced — `-icrnl` was skipped.
  * The temperature reads a wild number like −40 or 200 — that is the
    arithmetic, not the sensor. The conversion in `src/main.rs` is the
    datasheet's, and it is one line worth reading.

## Expected output

Captured from a real Pico 2 on Ubuntu.

```
[      37 ms] exp108 up. Reading ADC channel 4 — the sensor inside the chip.
[      37 ms] temp: raw 843 of 4095 -> 42.58 C
[    1037 ms] temp: raw 841 of 4095 -> 43.52 C
[    2037 ms] temp: raw 841 of 4095 -> 43.52 C
[    3037 ms] temp: raw 841 of 4095 -> 43.52 C
[    4037 ms] temp: raw 841 of 4095 -> 43.52 C
```

Around 43 °C, and that is a chip which has been running a while — not the
room. A Pico 2 doing nothing but blinking still sits well above ambient.

## What this number is and is not

The two constants in the conversion are **typical values for the part**, not a
calibration of the chip in front of you. The RP2350 datasheet is explicit that
absolute accuracy without per-chip calibration is poor, and "poor" here means
several degrees, not a rounding error.

So do not use this to decide whether a room is comfortable. What it is good
for is **change**: warm the chip and the number moves the right way by roughly
the right amount. Almost every real use of an on-chip sensor is a change — is
it hotter than it was, is it climbing, has it crossed a limit you established
by experiment on this board — and none of those need an accurate absolute
value.

The other thing to notice is that the reading is not perfectly steady. It sits
on `raw 841` above but flickers to `842` and back over a longer capture. That
wobble is the ADC and the sensor together, and it is real: an analogue
measurement is a number with noise on it, always. exp111 does something
deliberately unwise with that noise.

## Make it yours

1. Pinch the chip — the black square in the middle of the board — between
   finger and thumb, and watch. The number should climb within a couple of
   seconds and fall back slowly when you let go. That is the sensor working,
   and you have just calibrated your trust in it more usefully than any
   datasheet could.
2. In `src/main.rs`, print only `raw` and delete the conversion. Now try to
   tell whether the chip is warming. It is perfectly possible — the count
   falls — and it is much harder to read at a glance. That difference is what
   the arithmetic buys.
3. Change the timer to `Duration::from_millis(50)`. Watch how much more the
   reading moves when you sample it faster. Nothing about the chip changed;
   you are just seeing noise that waiting a second was hiding.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `raw 0` every time | Reading a GPIO channel, not the sensor | `Channel::new_temp_sensor(p.ADC_TEMP_SENSOR)` |
| Hundreds of degrees | Wrong slope or step in the conversion | Check `3.3 / 4096.0`, and that it is `27.0 - …` not `27.0 + …` |
| Reads well below room temperature | Suspect nothing — see "what this number is not" | Compare *changes*, not absolutes |
| `Permission denied` on the port right after flashing | The device node was just recreated and udev has not caught up | Wait a second and try again |
| No log lines at all | Nothing draining, or the port is held | `yi26 doctor`; exp107 explains the queue |

## Next

**exp109** reads the other thing on this chip that produces numbers you did
not compute — the hardware random number generator. It is a far less
well-behaved peripheral than this one, and finding out why is the experiment.
