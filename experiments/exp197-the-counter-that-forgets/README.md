# exp197 — the counter that forgets

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Four firmwares carried their own CTAP 2.1 PIN counter, and all four made the
same five mistakes: a second `setPIN` overwrote the owner's PIN, the counter was
decremented after the compare instead of before it, three wrong PINs in a row
stopped nothing, three status codes were wrong, and everything lived in RAM.
One crate now holds the counter; a model shows which attacker each design loses
to — including the one this crate still does.**

The method is [exp195](../exp195-the-bug-the-model-saw-first/)'s, and the
extraction is the repository's rule: exp186, exp187, exp188 and exp189 each
defined `PinState`, and a second copy is the moment to extract. Reading the
four copies against the specification before extracting them is what found
the mistakes, because the specification, not the copies, decided what the
crate says.

## What the four copies did, against CTAP 2.1

| | The copies | CTAP 2.1 | Who could exploit it |
| --- | --- | --- | --- |
| **P1** | `setPIN` on a device with a PIN replaced it | "If a PIN has already been set, authenticator returns CTAP2_ERR_PIN_AUTH_INVALID error." | anything on the host, with no power cycle and no old PIN |
| **P2** | compare, and only on a mismatch, decrement | "Authenticator decrements the pinRetries counter by 1", *then* "decrypts pinHashEnc … and verifies" | nobody yet — it waits for the counter to be persisted |
| **P3** | no limit on mismatches in a row | "If the authenticator sees 3 consecutive mismatches, it returns CTAP2_ERR_PIN_AUTH_BLOCKED … so that malware running on the platform should not be able to block the device without user interaction." | malware, which could spend all eight retries |
| **P4** | `PinState` in RAM: a power cycle forgets the PIN | the counter "represents the number of attempts left before PIN is disabled" | anybody holding the board: unplug it, set a PIN of their own |
| **P5** | `PIN_BLOCKED` 0x34, `PIN_AUTH_BLOCKED` 0x36, `PIN_AUTH_INVALID` 0x32 | 0x32, 0x34, 0x33 | every platform reading the answer: a blocked device reported "power cycle needed" |

exp186's README described this as "the full CTAP 2.1 PIN lifecycle state
machine", and its probe asked the four questions it answered right. None of the
five was a question anybody had asked.

## Step 1: the model

[`model/PinRetries.tla`](./model/PinRetries.tla) is the counter against
somebody who wants the owner's PIN and never knows it. Four switches select the
design; two attackers and three properties are fixed.

| Switch | |
| --- | --- |
| `Storage` | `ram` (every firmware here) or `flash` |
| `Order` | `compare_first` (the copies) or `decrement_first` (the specification, and the crate) |
| `SetChecks` | does `setPIN` refuse a device that has a PIN |
| `Consecutive` | do three mismatches in a row stop everything |

| Attacker | |
| --- | --- |
| `malware` | software on the host: sends commands, has no hands |
| `physical` | holds the board: can also cut the power at any instant, including mid-attempt |

| Property | Whose sentence |
| --- | --- |
| `ThePinCannotBeReplaced` | "If a PIN has already been set, authenticator returns CTAP2_ERR_PIN_AUTH_INVALID error." |
| `GuessesAreBounded` | "Once the pinRetries counter reaches 0 … can only be enabled if authenticator is reset." |
| `MalwareCannotBlock` | "…so that malware running on the platform should not be able to block the device without user interaction." |

One assumption, stated in the model because a result turns on it: under
`compare_first` a physical attacker learns a guess was wrong at the moment of the
compare — from timing, or from the device starting to write its counter — and
not only from the reply. That is the classic power-analysis attack on retry
counters, and the reason the specification decrements first.

## Step 2: what TLC said

| Design | Attacker | Replaced | Guesses bounded | Malware blocks |
| --- | --- | --- | --- | --- |
| the copies (RAM, compare first, no checks) | malware | **violated**: `SetPin` | holds | **violated**: eight wrong guesses |
| | physical | **violated**: `SetPin` | holds | — |
| `crates/client-pin`, RAM | malware | holds | holds | holds |
| | physical | **violated**: `PowerCycle -> SetPin` | holds | — |
| flash, but the copies' order | physical | holds | **violated** | — |
| `crates/client-pin` + flash | either | holds | holds | holds |

Four things to read out of it:

1. **P1 is one step.** The shortest counterexample against the copies is a
   single `setPIN`. The owner's PIN protected nothing from software on the host.
2. **The crate closes every door malware had** — and leaves one open to a
   person: unplug, set a PIN. That is P4, and this experiment does not close it.
   It is the row with the violation, not a footnote.
3. **Persisting the counter without fixing the order would have made things
   worse.** The flash row with the copies' order is the only design where a
   guess is ever free: the attacker has to power-cycle every third guess anyway
   to clear the consecutive count, and cutting the power right after the third
   compare — before the decrement — gets that guess for nothing, every round.
   `crates/client-pin`'s order makes that impossible before anybody adds flash.
4. **The design that holds everywhere** is the crate plus persistence, which is
   the experiment this one leaves open.

`GuessesAreBounded` holds for the copies against a physical attacker only
because they forget the PIN: there is nothing left to guess at. A property
holding for the wrong reason is still a property holding, which is why the
table has three columns and not one.

## Step 3 and 4: the crate, and the four firmwares on it

[`crates/client-pin`](../../crates/client-pin/) is the counter as a state machine
with no dependencies:

- `set_pin` refuses a device that has a PIN (P1).
- `begin()` checks, then **decrements**, and returns an `Attempt` whose
  `retries_to_persist()` is what must be written down before `judge()` may look
  at the PIN (P2). Dropping an attempt spends it — exactly what a power cut
  would.
- `judge` counts consecutive mismatches and answers `AuthBlocked` on the third;
  `begin()` refuses until `power_cycle()` (P3).
- The status codes are the specification's table (P5).
- It says, at the top, that it keeps the state in RAM and what that costs (P4).

14 host tests, one per finding and the rest of the lifecycle, named after the
wrong answer each prevents.

exp186, exp187, exp188 and exp189 now `use client_pin::PinState` and keep no
counter of their own: `setPIN` refuses first, `getPinToken` and `changePIN` pay
before they decrypt, and every PIN status code comes from the crate. One line
kept its value and changed its name: exp188's and exp189's `credMgmt` answered
"no token" with `0x36`, declared as `PIN_AUTH_BLOCKED` — the specification's
`PUAT_REQUIRED`, which is what it meant, so it is now called that.

[`tools/ctaphid/clientpin.py`](../../tools/ctaphid/clientpin.py) is the host
side, written from the steps exp186's probe had inline, and [`pin_rules_probe.py`](./pin_rules_probe.py)
asks a freshly flashed exp189 the questions exp186's probe never did: a second
`setPIN`, three wrong PINs, the owner's PIN after them.

## Found in passing, not fixed

exp188's and exp189's `credMgmt` verify `pinUvAuthParam`, and when the check
fails **and a token exists** they carry on — "For testing flexibility in
credMgmt", says the comment. So once any client has been issued a token, any
other can enumerate and delete discoverable credentials without a valid
`pinUvAuthParam`. It is an authorization bug, not a counter bug, so it is
recorded here rather than fixed under this experiment's name.

## What a model is not

- **Not a proof.** Eight retries, three in a row, one attacker at a time.
- **Not a flash layout.** `flash` in the model is "survives the power going";
  whether a real write is atomic is a question for the experiment that adds it.
- **Not a board.** Only the board half says the four firmwares do on silicon
  what the crate does in a test.

## Try it

In `crateflash-physical-GuessesAreBounded.cfg`, set `Order = "compare_first"`
and run `../../tools/tlc/tlc.sh trace model crateflash-physical-GuessesAreBounded`.
Count the `PowerCycle`s in the trace, and find the one guess in each round the
attacker did not pay for.

## Running it

```sh
../../tools/tlc/setup.sh   # once, needs the network: TLC v1.7.4 by sha256
./check.sh                 # no board: model, citations, the crate, the four firmwares
./run.sh                   # records capture.txt; the board half runs if a board is attached
```

Java 11 or later; `python3` with `cryptography` for the board half. Any RP2350
board and **nobody**: no PIN operation waits for a person.

## Expected output

```text
=== exp197 — the counter that forgets ===
recorded at 2026-09-24T13:53:57Z from commit 02d3c8c

>>> steps 1 and 2: every configuration in model/expected.txt
    TLC Version 2.19, one worker, breadth first

PinRetries before-malware-ThePinCannotBeReplaced    violated      2 states  SetPin
PinRetries before-malware-GuessesAreBounded         holds       170 states  
PinRetries before-malware-MalwareCannotBlock        violated     89 states  Begin -> Finish -> Begin -> Finish -> Begin -> Finish -> Begin -> Finish -> Begin -> Finish -> Begin -> Finish -> Begin -> Finish -> Begin -> Finish
PinRetries before-physical-ThePinCannotBeReplaced   violated      2 states  SetPin
PinRetries before-physical-GuessesAreBounded        holds       179 states  
PinRetries crate-malware-ThePinCannotBeReplaced     holds         7 states  
PinRetries crate-malware-GuessesAreBounded          holds         7 states  
PinRetries crate-malware-MalwareCannotBlock         holds         7 states  
PinRetries crate-physical-ThePinCannotBeReplaced    violated      5 states  PowerCycle -> SetPin
PinRetries crate-physical-GuessesAreBounded         holds        39 states  
PinRetries naiveflash-malware-ThePinCannotBeReplaced holds         7 states  
PinRetries naiveflash-malware-GuessesAreBounded     holds         7 states  
PinRetries naiveflash-malware-MalwareCannotBlock    holds         7 states  
PinRetries naiveflash-physical-ThePinCannotBeReplaced holds       266 states  
PinRetries naiveflash-physical-GuessesAreBounded    violated    209 states  Begin -> Finish -> Begin -> Finish -> Begin -> PowerCycle -> Begin -> Finish -> Begin -> Finish -> Begin -> PowerCycle -> Begin -> Finish -> Begin -> Finish -> Begin
PinRetries crateflash-malware-ThePinCannotBeReplaced holds         7 states  
PinRetries crateflash-malware-GuessesAreBounded     holds         7 states  
PinRetries crateflash-malware-MalwareCannotBlock    holds         7 states  
PinRetries crateflash-physical-ThePinCannotBeReplaced holds       215 states  
PinRetries crateflash-physical-GuessesAreBounded    holds       215 states  

>>> step 3 and 4 on a host: crates/client-pin
test tests::an_undecryptable_pin_is_a_mismatch_and_is_paid_for ... ok
test tests::change_pin_needs_the_old_one_and_a_wrong_one_is_paid_for ... ok
test tests::nothing_is_attempted_before_a_pin_exists ... ok
test tests::p1_a_refused_set_pin_does_not_refill_a_counter_an_attacker_has_spent ... ok
test tests::p1_a_second_set_pin_is_refused_and_the_owners_pin_survives ... ok
test tests::p2_a_correct_pin_gives_the_attempt_back ... ok
test tests::p2_an_attempt_the_power_cut_short_is_still_spent ... ok
test tests::p2_the_counter_is_paid_before_the_answer_exists ... ok
test tests::p3_a_power_cycle_clears_the_run_but_not_the_counter ... ok
test tests::p3_malware_cannot_spend_all_eight_without_a_person ... ok
test tests::p3_the_last_attempt_is_blocked_not_auth_blocked ... ok
test tests::p4_a_state_nobody_persisted_takes_the_next_pin_offered ... ok
test tests::p5_the_codes_are_the_specifications_table ... ok
test tests::reset_forgets_everything ... ok
```

The board half: **not captured yet.**
