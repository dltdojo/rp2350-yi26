//! Named after the wrong answer each one prevents. P1-P5 are exp197's names for
//! what exp186-exp189 got wrong.

use super::*;

const OWNER: PinHash = *b"owner's-pin-hash";
const GUESS: PinHash = *b"a wrong guess!!!";
const NEW: PinHash = *b"a brand new pin!";
const TOKEN: Token = [7; 32];

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
    s.issue(TOKEN, permission::DEFAULT, None);
    assert_eq!(s.begin().unwrap().judge_and_change(&GUESS, &NEW), Verdict::Invalid);
    assert_eq!(s.retries(), MAX_RETRIES - 1);
    assert!(s.has_token(), "a failed change leaves the token");
    assert_eq!(s.begin().unwrap().judge_and_change(&OWNER, &NEW), Verdict::Correct);
    assert!(!s.has_token(), "a successful change forgets it");
    assert_eq!(guess(&mut s, &NEW), Ok(Verdict::Correct));
}

#[test]
fn reset_forgets_everything() {
    let mut s = with_pin();
    s.issue(TOKEN, permission::DEFAULT, None);
    let _ = guess(&mut s, &GUESS);
    s.reset();
    assert!(!s.is_set());
    assert_eq!(s.retries(), MAX_RETRIES);
    assert!(!s.has_token());
}

#[test]
fn an_undecryptable_pin_is_a_mismatch_and_is_paid_for() {
    let mut s = with_pin();
    assert_eq!(s.begin().unwrap().mismatch(), Verdict::Invalid);
    assert_eq!(s.retries(), MAX_RETRIES - 1);
}

// --- exp200: what a token may authorize -------------------------------------
//
// C1-C3 are exp200's names for what exp188's and exp189's credMgmt got wrong.

const RP_A: RpIdHash = [0xAA; 32];
const RP_B: RpIdHash = [0xBB; 32];
const GET_CREDS_METADATA: &[u8] = &[0x01];
const DELETE: &[u8] = &[0x06];
// {2: {"id": h'01'}} and {2: {"id": h'02'}}, as the platform would encode them.
const PARAMS_1: &[u8] = &[0xa1, 0x02, 0xa1, 0x62, 0x69, 0x64, 0x41, 0x01];
const PARAMS_2: &[u8] = &[0xa1, 0x02, 0xa1, 0x62, 0x69, 0x64, 0x41, 0x02];

fn cm_token() -> PinState {
    let mut s = with_pin();
    s.issue(TOKEN, permission::CM, None);
    s
}

#[test]
fn authenticate_is_left_16_of_hmac_sha256_over_the_parts_in_order() {
    let key: Token = core::array::from_fn(|i| i as u8);
    // Python: hmac.new(bytes(range(32)), b"\x06" + bytes.fromhex("a1024101"), sha256).digest()[:16]
    let want = [
        0x5e, 0xfc, 0xfa, 0x30, 0x53, 0x84, 0xd9, 0x7a, 0xa0, 0x5f, 0x25, 0x5e, 0xc5, 0x25, 0xcc, 0x8f,
    ];
    assert_eq!(authenticate(&key, &[&[0x06], &[0xa1, 0x02, 0x41, 0x01]]), want);
    assert_eq!(authenticate(&key, &[&[0x06, 0xa1, 0x02, 0x41, 0x01]]), want, "parts are concatenated");
}

#[test]
fn c1_a_parameter_that_does_not_verify_is_refused_even_with_a_token_current() {
    let mut s = cm_token();
    assert_eq!(
        s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&[0u8; 16])),
        Err(Denied::PinAuthInvalid)
    );
    assert_eq!(Denied::PinAuthInvalid.code(), 0x33, "CTAP2_ERR_PIN_AUTH_INVALID");
}

#[test]
fn c1_no_parameter_is_puat_required_whatever_token_exists() {
    let mut s = cm_token();
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], None), Err(Denied::PuatRequired));
    assert_eq!(Denied::PuatRequired.code(), 0x36, "CTAP2_ERR_PUAT_REQUIRED");
}

#[test]
fn c1_a_parameter_with_no_token_current_is_invalid_not_accepted() {
    let mut s = with_pin();
    let param = authenticate(&TOKEN, &[GET_CREDS_METADATA]);
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&param)), Err(Denied::PinAuthInvalid));
}

#[test]
fn c1_the_owner_with_a_cm_token_is_let_in() {
    let mut s = cm_token();
    let param = authenticate(&TOKEN, &[GET_CREDS_METADATA]);
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&param)), Ok(()));
}

#[test]
fn c2_a_parameter_for_one_credential_does_not_delete_another() {
    let mut s = cm_token();
    let for_1 = authenticate(&TOKEN, &[DELETE, PARAMS_1]);
    assert_eq!(s.authorize(permission::CM, Scope::Rp(&RP_A), &[DELETE, PARAMS_1], Some(&for_1)), Ok(()));
    assert_eq!(
        s.authorize(permission::CM, Scope::Rp(&RP_A), &[DELETE, PARAMS_2], Some(&for_1)),
        Err(Denied::PinAuthInvalid),
        "the MAC covers subCommandParams, so it names the credential"
    );
}

#[test]
fn c2_the_old_message_no_longer_verifies() {
    let mut s = cm_token();
    let byte_only = authenticate(&TOKEN, &[DELETE]);
    assert_eq!(
        s.authorize(permission::CM, Scope::Rp(&RP_A), &[DELETE, PARAMS_1], Some(&byte_only)),
        Err(Denied::PinAuthInvalid),
        "exp188's probe and firmware agreed on this, and both were wrong"
    );
}

#[test]
fn c3_get_pin_tokens_default_token_cannot_manage_credentials() {
    let mut s = with_pin();
    s.issue(TOKEN, permission::DEFAULT, None);
    let param = authenticate(&TOKEN, &[GET_CREDS_METADATA]);
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&param)), Err(Denied::PinAuthInvalid));
}

#[test]
fn c3_a_cm_token_cannot_make_credentials() {
    let mut s = cm_token();
    let param = authenticate(&TOKEN, &[&[0x11; 32]]);
    assert_eq!(s.authorize(permission::MC, Scope::Rp(&RP_A), &[&[0x11; 32]], Some(&param)), Err(Denied::PinAuthInvalid));
}

#[test]
fn c3_a_token_tied_to_one_rp_reaches_that_rp_and_nothing_else() {
    let mut s = with_pin();
    s.issue(TOKEN, permission::CM, Some(RP_A));
    let meta = authenticate(&TOKEN, &[GET_CREDS_METADATA]);
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&meta)), Err(Denied::PinAuthInvalid), "metadata is every RP's");
    let del = authenticate(&TOKEN, &[DELETE, PARAMS_1]);
    assert_eq!(s.authorize(permission::CM, Scope::Rp(&RP_B), &[DELETE, PARAMS_1], Some(&del)), Err(Denied::PinAuthInvalid));
    assert_eq!(s.authorize(permission::CM, Scope::Rp(&RP_A), &[DELETE, PARAMS_1], Some(&del)), Ok(()));
}

#[test]
fn c3_a_login_token_is_tied_to_the_first_rp_it_is_used_with() {
    let mut s = with_pin();
    s.issue(TOKEN, permission::DEFAULT, None);
    let cdh: &[u8] = &[0x22; 32];
    let param = authenticate(&TOKEN, &[cdh]);
    assert_eq!(s.authorize(permission::GA, Scope::Rp(&RP_A), &[cdh], Some(&param)), Ok(()));
    assert_eq!(s.authorize(permission::GA, Scope::Rp(&RP_A), &[cdh], Some(&param)), Ok(()), "again, same RP");
    assert_eq!(s.authorize(permission::GA, Scope::Rp(&RP_B), &[cdh], Some(&param)), Err(Denied::PinAuthInvalid));
}

#[test]
fn a_new_token_invalidates_the_last() {
    let mut s = cm_token();
    let old = authenticate(&TOKEN, &[GET_CREDS_METADATA]);
    s.issue([9; 32], permission::CM, None);
    assert_eq!(s.authorize(permission::CM, Scope::AllRps, &[GET_CREDS_METADATA], Some(&old)), Err(Denied::PinAuthInvalid));
}

#[test]
fn a_power_cycle_forgets_the_token() {
    let mut s = cm_token();
    s.power_cycle();
    assert!(!s.has_token());
}

#[test]
fn permissions_are_checked_before_any_pin_is_asked_for() {
    let offered = permission::MC | permission::GA | permission::CM;
    assert_eq!(check_permissions(permission::CM, false, offered), Ok(permission::CM), "cm needs no rpId");
    assert_eq!(check_permissions(permission::MC, false, offered), Err(BadRequest::MissingRpId));
    assert_eq!(check_permissions(0, false, offered), Err(BadRequest::Zero));
    assert_eq!(check_permissions(permission::LBW, false, offered), Err(BadRequest::Unauthorized));
    assert_eq!(check_permissions(permission::CM | 0x80, false, offered), Ok(permission::CM), "undefined bits are ignored");
    assert_eq!(check_permissions(permission::CM, false, permission::DEFAULT), Err(BadRequest::Unauthorized), "no credMgmt, no cm");
    assert_eq!(BadRequest::Unauthorized.code(), 0x40, "CTAP2_ERR_UNAUTHORIZED_PERMISSION");
}
