# exp200 — the token that opened everything

<!-- SPDX-License-Identifier: Apache-2.0 -->

**exp188 and exp189 manage discoverable credentials — list them, delete them
— behind a `pinUvAuthToken`. Read against CTAP 2.1 §6.8, the token opened
three doors it should not have: a parameter that failed to verify was let
through whenever any token existed, the MAC did not say which credential it
was for, and a token issued for logging in could delete everything. A model
shows that each fix alone stops one attacker and leaves the next; all three
are now in `crates/client-pin`, and both firmwares decide through it.**

[exp197](../exp197-the-counter-that-forgets/) found the first of these in
passing and recorded it rather than fix it under a counter's name. Reading
the rest of §6.8 before fixing it found the other two.

## What the two copies did, against CTAP 2.1

| | exp188, exp189 | CTAP 2.1 | Who could exploit it |
| --- | --- | --- | --- |
| **C1** | verify `pinUvAuthParam`; if it fails **and a token exists**, carry on — "For testing flexibility in credMgmt", said the comment. No parameter at all was treated the same way | "If pinUvAuthParam is missing from the input map, end the operation by returning CTAP2_ERR_PUAT_REQUIRED." "If pinUvAuthParam verification fails, authenticator returns CTAP2_ERR_PIN_AUTH_INVALID error." | anything on the host, once the owner had ever asked for a token — no PIN, no token |
| **C2** | the MAC is over the subcommand byte alone | `authenticate(pinUvAuthToken, deleteCredential (0x06) \|\| subCommandParams)` | anybody who saw one of the owner's deletions: the same parameter deletes any other credential |
| **C3** | any token manages credentials, and the only way to get one was `getPinToken` | "If authenticatorClientPIN's getPinToken subcommand is invoked, default permissions of mc and ga (value 0x03) are granted" and "The authenticator verifies that the pinUvAuthToken has the cm permission" | every site the owner logs into: the token a login needs could list and delete every credential on the key |

**The test agreed with the code.** exp188's `passkey_credmgmt_probe.py` computed
its MACs over the subcommand byte alone, exactly as the firmware checked them,
and passed every run. A grader written beside the thing it grades inherits its
misreading — [exp194](../exp194-the-transport-that-drifted/) found the same
shape in a transport. The probe now asks for a token per job and MACs what
the specification says.

## Step 1: the model

[`model/CredMgmt.tla`](./model/CredMgmt.tla) is who may delete a credential.
Three switches select the design, and the attacker is a fourth.

| Switch | |
| --- | --- |
| `RejectsBadParam` | does a parameter that fails to verify stop the request (C1) |
| `BindsParams` | does the MAC cover `subCommand \|\| subCommandParams` (C2) |
| `ChecksPermissions` | must the token carry `cm` (C3) |

| Attacker | |
| --- | --- |
| `malware` | software on the host with no token and no PIN |
| `observer` | sees requests on the wire and can resend a parameter it saw, but holds no token — a USB relay, or a process between the platform and the device |
| `browser` | holds a token of its own from `getPinToken`, the `mc`/`ga` a login needs |

One token exists at a time — CTAP 2.1: "all existing pinUvAuthTokens are
invalidated" when a new one is made — so a parameter is only ever good for the
token it was made with. The property is one sentence: a credential is deleted
by the owner, or by nobody.

The `observer` is an assumption, and a result turns on it: C2 matters only to
somebody who can see a request they did not make. Whether that somebody exists
on a given host is outside this repository; the specification binds the
parameters so that the answer does not matter.

## Step 2: what TLC said

| Design | malware | observer | browser |
| --- | --- | --- | --- |
| exp188/exp189 as they were | **violated**: `OwnerGetsToken -> MalwareDeletes` | **violated** | **violated**: `BrowserGetsToken -> BrowserDeletes` |
| C1 only | holds | **violated**: `OwnerGetsToken -> OwnerDeletes -> ObserverDeletes` | **violated** |
| C1 + C2 | holds | holds | **violated** |
| C1 + C3 | holds | **violated** | holds |
| C1 + C2 + C3 | holds | holds | holds |

Three things to read out of it:

1. **C1 was two steps.** The owner asks for a token once — to list their own
   credentials — and from then until the next power cycle, anything on the host
   can delete them with sixteen zero bytes for a MAC.
2. **Each fix alone is a different attacker still winning.** Fixing only the
   comment's fallback, which is what exp197 recorded, leaves the observer's
   replay and the browser's login token. Nothing short of all three holds.
3. **C3 is not about a stolen token.** The browser in the model holds its own
   token legitimately. The finding is that a token issued *for logging in* was
   also a token *for deleting*, so every site the owner used could reach every
   credential on the key.

## Step 3 and 4: the crate, and the four firmwares on it

[`crates/client-pin`](../../crates/client-pin/) already held the PIN, its
counter and the current token. It now also holds what the token may do:

- `PinState::issue(token, permissions, rp)` is the only way to make a token
  current. `getPinToken` passes `permission::DEFAULT` (`mc | ga`) and no RP.
- `check_permissions` judges a request for a token with permissions **before**
  the PIN is asked for: no `rpId` with `mc`/`ga` is `MISSING_PARAMETER`, zero is
  `INVALID_PARAMETER`, a permission for a feature not offered is
  `UNAUTHORIZED_PERMISSION` — none of which spends an attempt.
- `PinState::authorize(needs, scope, message, param)` is the decision, in §6.8's
  order: no parameter is `PUAT_REQUIRED` (C1); one that does not verify, a
  token without the permission (C3), or a token tied to another RP is
  `PIN_AUTH_INVALID`. The message is passed in parts, and the HMAC is computed
  here, because C2 was a wrong answer to "what does the MAC cover" and a caller
  computing its own MAC can get it wrong again.
- A login token is tied to the first RP it is used with, as the specification
  has it.

14 new host tests, one per way in and the rest of the token's life, named after
the wrong answer each prevents; 28 in all.

**exp188 and exp189** capture `subCommandParams` exactly as they arrived and
pass `subCommand || subCommandParams` to `authorize` with `permission::CM`.
They answer `getPinUvAuthTokenUsingPinWithPermissions` (0x09), which they
advertised with `pinUvAuthToken: true` and never implemented, and
`getPinUvAuthTokenUsingUvWithPermissions` (0x06) now requires the permissions
the specification makes mandatory there. **exp186 and exp187** issue their tokens the same way and
check `mc` and `ga` on `makeCredential` and `getAssertion`; neither offers
`cm`, because neither manages credentials. All four keep no verifier of their
own: `verify_pin_uv_auth_token`, four copies, is gone.

[`tools/ctaphid/clientpin.py`](../../tools/ctaphid/clientpin.py) gained both
halves on the host: asking for a token with permissions, and sending
credential management with the MAC over the bytes it sends.
[`credmgmt_rules_probe.py`](./credmgmt_rules_probe.py) asks a freshly flashed
exp189 all three questions. None needs a credential to exist — whether a
deletion was *authorized* shows in the answer to deleting one that is not
there: `NO_CREDENTIALS` means it was let through, `PIN_AUTH_INVALID` that it
was not — so none needs a finger.

## What this does not fix

- **The rest of §6.8 is still not implemented.** `enumerateRPsGetNextRP`,
  `enumerateCredentialsGetNextCredential` and `updateUserInformation` are
  answered as unsupported; `totalRPs` is the number of credentials, not of RPs;
  `totalCredentials` is always 1. These are wrong answers, not open doors.
- **"When a pinUvAuthToken is used with an operation that tests user presence,
  it is updated to remove all permissions except lbw."** Not done: none of
  these firmwares tracks whether a token has been used with a press.
- **Protocol 2.** Only PIN/UV auth protocol 1 exists here, and `authorize`
  refuses a parameter that is not 16 bytes.
- **`libfido2` against the new 0x09.** exp189's `roundtrip.sh` drives
  `fido2-cred` and `fido2-assert`, and `libfido2` asks a `FIDO_2_1` device for
  its token with permissions. What it did before, when 0x09 was answered as
  unsupported, and what it does now, is for the board half of that experiment.

## Try it

In `model/binds-browser.cfg` the design has C1 and C2 and still loses. Run
`../../tools/tlc/tlc.sh trace model binds-browser`, and say in one sentence
why no MAC check could ever stop that path.

## Running it

```sh
../../tools/tlc/setup.sh   # once, needs the network: TLC v1.7.4 by sha256
./check.sh                 # no board: model, citations, the crate, the four firmwares
./run.sh                   # records capture.txt; the board half runs if a board is attached
```

Java 11 or later; `python3` with `cryptography` for the board half. Any RP2350
board and **nobody**.

## Expected output

```text
=== exp200 — the token that opened everything ===
recorded at 2026-09-30T02:03:58Z from commit bfb3025

>>> steps 1 and 2: every configuration in model/expected.txt
    TLC Version 2.19, one worker, breadth first

CredMgmt   before-malware                           violated      5 states  OwnerGetsToken -> MalwareDeletes
CredMgmt   before-observer                          violated     11 states  OwnerGetsToken -> OwnerDeletes -> ObserverDeletes
CredMgmt   before-browser                           violated      8 states  BrowserGetsToken -> BrowserDeletes
CredMgmt   rejects-malware                          holds        30 states  
CredMgmt   rejects-observer                         violated     11 states  OwnerGetsToken -> OwnerDeletes -> ObserverDeletes
CredMgmt   rejects-browser                          violated      8 states  BrowserGetsToken -> BrowserDeletes
CredMgmt   binds-malware                            holds        30 states  
CredMgmt   binds-observer                           holds        30 states  
CredMgmt   binds-browser                            violated      8 states  BrowserGetsToken -> BrowserDeletes
CredMgmt   permissions-malware                      holds        30 states  
CredMgmt   permissions-observer                     violated     11 states  OwnerGetsToken -> OwnerDeletes -> ObserverDeletes
CredMgmt   permissions-browser                      holds        44 states  
CredMgmt   all-malware                              holds        30 states  
CredMgmt   all-observer                             holds        30 states  
CredMgmt   all-browser                              holds        44 states  

>>> steps 3 and 4 on a host: crates/client-pin
test tests::a_new_token_invalidates_the_last ... ok
test tests::a_power_cycle_forgets_the_token ... ok
test tests::an_undecryptable_pin_is_a_mismatch_and_is_paid_for ... ok
test tests::authenticate_is_left_16_of_hmac_sha256_over_the_parts_in_order ... ok
test tests::c1_a_parameter_that_does_not_verify_is_refused_even_with_a_token_current ... ok
test tests::c1_a_parameter_with_no_token_current_is_invalid_not_accepted ... ok
test tests::c1_no_parameter_is_puat_required_whatever_token_exists ... ok
test tests::c1_the_owner_with_a_cm_token_is_let_in ... ok
test tests::c2_a_parameter_for_one_credential_does_not_delete_another ... ok
test tests::c2_the_old_message_no_longer_verifies ... ok
test tests::c3_a_cm_token_cannot_make_credentials ... ok
test tests::c3_a_login_token_is_tied_to_the_first_rp_it_is_used_with ... ok
test tests::c3_a_token_tied_to_one_rp_reaches_that_rp_and_nothing_else ... ok
test tests::c3_get_pin_tokens_default_token_cannot_manage_credentials ... ok
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
test tests::permissions_are_checked_before_any_pin_is_asked_for ... ok
test tests::reset_forgets_everything ... ok

>>> the board half: exp189, freshly flashed, asked over hidraw
not captured: no board attached
```

The board half: **not captured yet.**
