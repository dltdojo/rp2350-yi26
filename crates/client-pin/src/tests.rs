//! Named after the wrong answer each one prevents. P1-P5 are exp197's names for
//! what exp186-exp189 got wrong.

use super::*;

const OWNER: PinHash = *b"owner's-pin-hash";
const GUESS: PinHash = *b"a wrong guess!!!";
const NEW: PinHash = *b"a brand new pin!";

fn with_pin() -> PinState {
    let mut s = PinState::new();
    s.set_pin(&OWNER).unwrap();
    s
}

fn guess(s: &mut PinState, h: &PinHash) -> Result<Verdict, Refused> {
    s.begin().map(|a| a.judge(h))
}

// --- P1: setPIN on a device that already has one ---------------------------

#[test]
fn p1_a_second_set_pin_is_refused_and_the_owners_pin_survives() {
    let mut s = with_pin();
    assert_eq!(s.set_pin(&GUESS), Err(AlreadySet));
    assert_eq!(AlreadySet.code(), 0x33, "CTAP2_ERR_PIN_AUTH_INVALID");
    assert_eq!(guess(&mut s, &OWNER), Ok(Verdict::Correct), "the owner's PIN still opens it");
}

#[test]
fn p1_a_refused_set_pin_does_not_refill_a_counter_an_attacker_has_spent() {
    let mut s = with_pin();
    assert_eq!(guess(&mut s, &GUESS), Ok(Verdict::Invalid));
    let _ = s.set_pin(&GUESS);
    assert_eq!(s.retries(), MAX_RETRIES - 1);
}

// --- P2: the order ---------------------------------------------------------

#[test]
fn p2_the_counter_is_paid_before_the_answer_exists() {
    let mut s = with_pin();
    let attempt = s.begin().unwrap();
    assert_eq!(attempt.retries_to_persist(), MAX_RETRIES - 1, "decremented before any compare");
}

#[test]
fn p2_an_attempt_the_power_cut_short_is_still_spent() {
    let mut s = with_pin();
    let attempt = s.begin().unwrap();
    drop(attempt); // the power went between the decrement and the compare
    assert_eq!(s.retries(), MAX_RETRIES - 1);
}

#[test]
fn p2_a_correct_pin_gives_the_attempt_back() {
    let mut s = with_pin();
    assert_eq!(guess(&mut s, &GUESS), Ok(Verdict::Invalid));
    assert_eq!(guess(&mut s, &OWNER), Ok(Verdict::Correct));
    assert_eq!(s.retries(), MAX_RETRIES);
}

// --- P3: three in a row ----------------------------------------------------

#[test]
fn p3_malware_cannot_spend_all_eight_without_a_person() {
    let mut s = with_pin();
    let mut verdicts = [None; 3];
    for v in verdicts.iter_mut() {
        *v = Some(guess(&mut s, &GUESS).unwrap());
    }
    assert_eq!(verdicts, [Some(Verdict::Invalid), Some(Verdict::Invalid), Some(Verdict::AuthBlocked)]);
    assert_eq!(guess(&mut s, &GUESS), Err(Refused::AuthBlocked), "and nothing more until a power cycle");
    assert_eq!(guess(&mut s, &OWNER), Err(Refused::AuthBlocked), "not even the right PIN");
    assert_eq!(s.retries(), MAX_RETRIES - 3, "five left for the owner");
}

#[test]
fn p3_a_power_cycle_clears_the_run_but_not_the_counter() {
    let mut s = with_pin();
    for _ in 0..3 {
        let _ = guess(&mut s, &GUESS);
    }
    s.power_cycle();
    assert_eq!(s.retries(), MAX_RETRIES - 3);
    assert_eq!(guess(&mut s, &OWNER), Ok(Verdict::Correct));
}

#[test]
fn p3_the_last_attempt_is_blocked_not_auth_blocked() {
    // Eight mismatches, a power cycle after every third: the specification
    // checks zero before three-in-a-row, so the eighth says BLOCKED.
    let mut s = with_pin();
    let mut last = Verdict::Correct;
    for i in 0..MAX_RETRIES {
        if i > 0 && i % 3 == 0 {
            s.power_cycle();
        }
        last = guess(&mut s, &GUESS).unwrap();
    }
    assert_eq!(last, Verdict::Blocked);
    assert_eq!(guess(&mut s, &OWNER), Err(Refused::Blocked), "and only a reset brings it back");
    s.power_cycle();
    assert_eq!(guess(&mut s, &OWNER), Err(Refused::Blocked), "a power cycle does not");
}

// --- P4 is RAM, and a test cannot see RAM ----------------------------------
//
// It is exp197's model that shows it. What a test can show is the edge of
// what this crate promises: a fresh PinState is what a power cycle leaves
// when nothing is persisted, and it will take anybody's PIN.

#[test]
fn p4_a_state_nobody_persisted_takes_the_next_pin_offered() {
    let fresh = PinState::new();
    assert!(!fresh.is_set());
    let mut after_power_cycle = fresh;
    assert_eq!(after_power_cycle.set_pin(&GUESS), Ok(()));
}

// --- P5: the codes -----------------------------------------------------------

#[test]
fn p5_the_codes_are_the_specifications_table() {
    assert_eq!(code::PIN_INVALID, 0x31);
    assert_eq!(code::PIN_BLOCKED, 0x32, "exp186-exp189 sent 0x34, which is PIN_AUTH_BLOCKED");
    assert_eq!(code::PIN_AUTH_INVALID, 0x33, "exp186-exp189 sent 0x32, which is PIN_BLOCKED");
    assert_eq!(code::PIN_AUTH_BLOCKED, 0x34, "exp186-exp189 sent 0x36, which is PUAT_REQUIRED");
    assert_eq!(code::PIN_NOT_SET, 0x35);
    assert_eq!(Refused::Blocked.code(), code::PIN_BLOCKED);
    assert_eq!(Verdict::AuthBlocked.code(), Some(code::PIN_AUTH_BLOCKED));
}

// --- the rest of the lifecycle -----------------------------------------------

#[test]
fn nothing_is_attempted_before_a_pin_exists() {
    let mut s = PinState::new();
    assert_eq!(guess(&mut s, &GUESS), Err(Refused::NotSet));
    assert_eq!(s.retries(), MAX_RETRIES, "and nothing is spent");
}

#[test]
fn change_pin_needs_the_old_one_and_a_wrong_one_is_paid_for() {
    let mut s = with_pin();
    s.active_token = Some([7; 32]);
    assert_eq!(s.begin().unwrap().judge_and_change(&GUESS, &NEW), Verdict::Invalid);
    assert_eq!(s.retries(), MAX_RETRIES - 1);
    assert_eq!(s.active_token, Some([7; 32]), "a failed change leaves the token");
    assert_eq!(s.begin().unwrap().judge_and_change(&OWNER, &NEW), Verdict::Correct);
    assert!(s.active_token.is_none(), "a successful change forgets it");
    assert_eq!(guess(&mut s, &NEW), Ok(Verdict::Correct));
}

#[test]
fn reset_forgets_everything() {
    let mut s = with_pin();
    s.active_token = Some([7; 32]);
    let _ = guess(&mut s, &GUESS);
    s.reset();
    assert!(!s.is_set());
    assert_eq!(s.retries(), MAX_RETRIES);
    assert!(s.active_token.is_none());
}

#[test]
fn an_undecryptable_pin_is_a_mismatch_and_is_paid_for() {
    let mut s = with_pin();
    assert_eq!(s.begin().unwrap().mismatch(), Verdict::Invalid);
    assert_eq!(s.retries(), MAX_RETRIES - 1);
}
