/-
SPDX-License-Identifier: Apache-2.0

exp198: crates/client-pin, proved rather than searched.

Each definition below transcribes a function of crates/client-pin/src/lib.rs;
the line it comes from is in cited.txt beside this file, and check.sh re-reads
those lines. mutants.txt holds wrong versions of it that must not check.
Each theorem quotes the sentence it formalises.

Two simplifications, stated because a proof is exactly as strong as what it
is about:
- `retries` and `consecutive` are `Nat`, where the Rust has `u8`. The Rust
  never lets either leave 0..=8 (begin refuses at 0; consecutive stops at 3),
  so no `u8` ever wraps — but that is an argument, not part of this proof.
- The PIN hash is a `Nat`, compared by equality. The Rust compares 16 bytes in
  constant time; timing is not something this proof can see.
-/

namespace ClientPin

def MAX_RETRIES : Nat := 8
def MAX_CONSECUTIVE : Nat := 3

structure State where
  set : Bool
  hash : Nat
  retries : Nat
  consecutive : Nat
  deriving Repr, DecidableEq

inductive Refused | notSet | blocked | authBlocked
  deriving Repr, DecidableEq

inductive Verdict | correct | invalid | blocked | authBlocked
  deriving Repr, DecidableEq

/-- `PinState::begin`: refuse, or pay for the attempt before it is judged. -/
def pay (s : State) : Except Refused State :=
  if !s.set then .error .notSet
  else if s.retries = 0 then .error .blocked
  else if MAX_CONSECUTIVE ≤ s.consecutive then .error .authBlocked
  else .ok { s with retries := s.retries - 1 }

/-- `judge`: compare, and on a mismatch count it. -/
def judge (s : State) (presented : Nat) : Verdict × State :=
  if presented = s.hash then
    (.correct, { s with retries := MAX_RETRIES, consecutive := 0 })
  else
    let s' := { s with consecutive := s.consecutive + 1 }
    if s'.retries = 0 then (.blocked, s')
    else if MAX_CONSECUTIVE ≤ s'.consecutive then (.authBlocked, s')
    else (.invalid, s')

/-- `PinState::set_pin`: refused when a PIN is set. -/
def setPin (s : State) (h : Nat) : Option State :=
  if s.set then none
  else some { set := true, hash := h, retries := MAX_RETRIES, consecutive := 0 }

/-- `PinState::power_cycle`: what a boot does to a state that survives it. -/
def powerCycle (s : State) : State := { s with consecutive := 0 }

/-- Everything anybody can do to the counter. -/
inductive Event
  | guess (presented : Nat)
  | cycle
  | setPin (h : Nat)

def step (s : State) : Event → State
  | .guess p =>
    match pay s with
    | .error _ => s
    | .ok paid => (judge paid p).2
  | .cycle => powerCycle s
  | .setPin h =>
    match setPin s h with
    | none => s
    | some s' => s'

/-- How many guesses were paid for and judged. -/
def judged (s : State) : Event → Nat
  | .guess _ => match pay s with | .error _ => 0 | .ok _ => 1
  | _ => 0

def run (s : State) : List Event → State
  | [] => s
  | e :: es => run (step s e) es

def judgedAll (s : State) : List Event → Nat
  | [] => 0
  | e :: es => judged s e + judgedAll (step s e) es

/-- Every guess in the list is wrong for PIN hash `h`. -/
def allWrong (h : Nat) : List Event → Prop
  | [] => True
  | .guess p :: es => p ≠ h ∧ allWrong h es
  | _ :: es => allWrong h es

def noCycles : List Event → Prop
  | [] => True
  | .cycle :: _ => False
  | _ :: es => noCycles es

/-! ## One step at a time -/

/-- What `pay` succeeding means: a PIN, a nonzero counter, fewer than three in
a row — and the counter already one lower. -/
theorem pay_ok {s paid : State} (h : pay s = .ok paid) :
    s.set = true ∧ s.retries ≠ 0 ∧ s.consecutive < MAX_CONSECUTIVE ∧
      paid = { s with retries := s.retries - 1 } := by
  unfold pay at h
  by_cases h1 : s.set = true
  · by_cases h2 : s.retries = 0
    · simp [h1, h2] at h
    · by_cases h3 : MAX_CONSECUTIVE ≤ s.consecutive
      · simp [h1, h2, h3] at h
      · simp [h1, h2, h3] at h
        refine ⟨h1, h2, by omega, ?_⟩
        rw [← h]
        cases s
        simp at h1
        simp [h1]
  · simp [h1] at h

/-- A mismatch leaves the set flag, the hash and the counter alone. -/
theorem judge_wrong {s : State} {p : Nat} (hp : p ≠ s.hash) :
    (judge s p).2 = { s with consecutive := s.consecutive + 1 } := by
  unfold judge
  by_cases h1 : s.retries = 0 <;> by_cases h2 : MAX_CONSECUTIVE ≤ s.consecutive + 1 <;>
    simp [hp, h1, h2]


theorem setPin_refused_when_set (s : State) (h : Nat) (hs : s.set = true) :
    step s (.setPin h) = s := by
  simp [step, setPin, hs]

theorem step_keeps_set_and_hash (s : State) (e : Event) (hs : s.set = true) :
    (step s e).set = true ∧ (step s e).hash = s.hash := by
  cases e with
  | guess p =>
    simp only [step]
    split
    · exact ⟨hs, rfl⟩
    · rename_i paid hpay
      obtain ⟨_, _, _, rfl⟩ := pay_ok hpay
      by_cases hp : p = s.hash
      · unfold judge
        simp [hp, hs]
      · rw [judge_wrong (by simpa using hp)]
        simp [hs]
  | cycle => simp [step, powerCycle, hs]
  | setPin h => simp [step, setPin, hs]

/-- A wrong guess never raises the counter, and a paid one lowers it by one. -/
theorem wrong_guess_step (s : State) (p : Nat) (hp : p ≠ s.hash) :
    (step s (.guess p)).retries + judged s (.guess p) = s.retries := by
  simp only [step, judged]
  cases hpay : pay s with
  | error r => simp
  | ok paid =>
    obtain ⟨_, hr, _, rfl⟩ := pay_ok hpay
    simp only
    rw [judge_wrong (by simpa using hp)]
    simp
    omega

/-! ## Any number of events -/

/-- **A failed attempt is never given back.** "Each incorrect PIN entry
decrements the pinRetries by 1" and only a correct one resets it: across any
sequence of wrong guesses, power cycles and refused setPINs, of any length,
the counter plus the guesses judged equals the counter it started with. -/
theorem never_given_back (s : State) (es : List Event)
    (hs : s.set = true) (hw : allWrong s.hash es) :
    (run s es).retries + judgedAll s es = s.retries := by
  induction es generalizing s with
  | nil => simp [run, judgedAll]
  | cons e es ih =>
    obtain ⟨hs', hh'⟩ := step_keeps_set_and_hash s e hs
    have hw' : allWrong (step s e).hash es := by
      rw [hh']
      cases e <;> simp [allWrong] at hw ⊢ <;> first | exact hw.2 | exact hw
    have := ih (step s e) hs' hw'
    simp only [run, judgedAll]
    cases e with
    | guess p =>
      have hp : p ≠ s.hash := by simp [allWrong] at hw; exact hw.1
      have h1 := wrong_guess_step s p hp
      omega
    | cycle => simp [judged, step, powerCycle] at *; omega
    | setPin h =>
      have hr : (step s (.setPin h)).retries = s.retries := by
        rw [setPin_refused_when_set s h hs]
      simp [judged] at *; omega

/-- **Guesses are bounded.** Nobody learns the answer to more wrong guesses
than the counter held — "Once the pinRetries counter reaches 0 … can only be
enabled if authenticator is reset" — however many times the power goes. -/
theorem guesses_bounded (s : State) (es : List Event)
    (hs : s.set = true) (hw : allWrong s.hash es) :
    judgedAll s es ≤ s.retries := by
  have := never_given_back s es hs hw
  omega

/-- **Malware cannot spend the counter.** Without a power cycle, at most three
wrong guesses are ever judged: "so that malware running on the platform should
not be able to block the device without user interaction." -/
theorem malware_stops_at_three (s : State) (es : List Event)
    (hs : s.set = true) (hw : allWrong s.hash es) (hn : noCycles es)
    (hc : s.consecutive ≤ MAX_CONSECUTIVE) :
    judgedAll s es + s.consecutive ≤ MAX_CONSECUTIVE := by
  induction es generalizing s with
  | nil => simp [judgedAll]; exact hc
  | cons e es ih =>
    obtain ⟨hs', hh'⟩ := step_keeps_set_and_hash s e hs
    simp only [judgedAll]
    cases e with
    | cycle => simp [noCycles] at hn
    | setPin h =>
      rw [setPin_refused_when_set s h hs]
      simp [judged, noCycles, allWrong] at hn hw ⊢
      have := ih s hs hw hn hc
      simpa [judged] using this
    | guess p =>
      simp [noCycles, allWrong] at hn hw
      obtain ⟨hp, hw⟩ := hw
      simp only [judged, step]
      cases hpay : pay s with
      | error r =>
        simp
        exact ih s hs hw hn hc
      | ok paid =>
        obtain ⟨_, _, hlt, rfl⟩ := pay_ok hpay
        simp only
        rw [judge_wrong (by simpa using hp)]
        have := ih { s with retries := s.retries - 1, consecutive := s.consecutive + 1 }
          (by simp [hs]) (by simpa using hw) hn (by simp; omega)
        simp at this ⊢
        omega

/-- **And the hypothesis is not decoration.** Drop `noCycles` and the limit
of three is gone: a power cycle — a person, in the specification's words — is
exactly what lets a fourth wrong guess be judged. A statement is only as strong
as its hypotheses, so each one is shown to be needed. -/
theorem a_power_cycle_is_what_lifts_the_limit :
    ∃ (s : State) (es : List Event),
      s.set = true ∧ allWrong s.hash es ∧ MAX_CONSECUTIVE < judgedAll s es :=
  ⟨{ set := true, hash := 1, retries := MAX_RETRIES, consecutive := 0 },
   [.guess 0, .guess 0, .guess 0, .cycle, .guess 0],
   rfl, by simp [allWrong], by decide⟩

/-! ## The design this replaced -/

/-- exp186-exp189's setPIN: no check. -/
def oldSetPin (_ : State) (h : Nat) : State :=
  { set := true, hash := h, retries := MAX_RETRIES, consecutive := 0 }

/-- **The owner's PIN could be replaced** — a proof that it could, which is a
counterexample stated as a theorem. -/
theorem old_design_replaces_the_pin :
    ∃ s : State, s.set = true ∧ (oldSetPin s 999).hash ≠ s.hash :=
  ⟨{ set := true, hash := 123456, retries := 8, consecutive := 0 }, rfl, by decide⟩

/-! ## What each proof rests on

Printed when this file is checked. A proof that skipped a step would list
`sorryAx` here; these list only the axioms of Lean itself. -/

#print axioms never_given_back
#print axioms guesses_bounded
#print axioms malware_stops_at_three
#print axioms a_power_cycle_is_what_lifts_the_limit
#print axioms old_design_replaces_the_pin

end ClientPin
