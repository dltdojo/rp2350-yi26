/-! # exp255 — exp225's kernel behind exp240's monitor, round after round

exp240 proved its monitor round after round: from a machine `Ready` -- the monitor's words in place, the code what it
was loaded with, no PMP entry locked -- a round leaves it `Ready` again, and so does anything the host writes but the
monitor's words and the code. exp254 proved one round of exp225's kernel from reset. A reset is a round's start: here
every round of any number of them, whatever the host wrote between, parks with HALT 0 and the history Rule 30 of the
seed it found; and with the host rounds.py is, the rounds together are Rule 30 from the first seed, generation after
generation. -/

namespace Exp255
open Rv32 Rv32.Priv Rv32.Refinement Exp240 Exp254

/-- Where a round of exp225's kernel from `p` ends: reset, boot, 3079 steps of the kernel to its trap, the monitor's
handling of it. -/
def lifeRound (env : Rv32.Env) (p : PrivMachine) : PrivMachine := parkedAfter env (payloadAt env (resetOf p) 3079)

/-- What the host hears of a round: the HALT report -- the tag, `a0 = 0`, 3081 instructions, 3081 cycles -- then 0 at
the exit word. -/
def heard : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, 3081#32⟩,
   ⟨0xc0000004#32, 3081#32⟩, ⟨0xc0000008#32, 0#32⟩]

/-- **One round, from any machine that is `Ready` with the kernel in its code.** It is a round in exp240's sense -- its
first trap is the kernel's 3079th step -- and the only one there is from that machine. It parks with HALT 0; memory but
the monitor's stack and report words is exp225's `lived` of the memory the round started with, the history Rule 30 of
the seed it found; and the host hears the HALT report and 0. -/
theorem life_round (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p)
    (hK : CodeAt C base Exp225.kernel) :
    Round env p (lifeRound env p) ∧ (∀ q, Round env p q → q = lifeRound env p) ∧
    Parked (lifeRound env p) 0#32 ∧
    (∀ x, ¬ InStack x → ¬ InPorts x → (lifeRound env p).core.mem x = Exp225.lived p.core.mem base Exp225.N x) ∧
    (lifeRound env p).io = p.io ++ heard := by
  have hb : base.toNat = 0x80010000 := rfl
  have hKp : CodeAt p.core.mem base Exp225.kernel := by
    refine CodeAt.congr (by rw [Exp225.kernel_length]; decide) (fun x h1 h2 => (hR.code x ?_ ?_).symm) hK
    · omega
    · rw [Exp225.kernel_length] at h2; omega
  obtain ⟨hbox, hpc1, hcsb, hmem1, -, -, -⟩ :=
    monitor_boot env p.core.mem (resetOf p) hR.words rfl rfl rfl rfl hR.unlocked
  obtain ⟨hU, hM, -, -, hcsu, ht0, -⟩ := life_traps env p.core.mem _ hR.words
    (by rw [hmem1]; exact Agree.refl _ _ _) hR.region hbox hcsb hpc1 (by rw [hmem1]; exact hKp)
  have hmc : (PrivMachine.run env 3079 (PrivMachine.run env 61 (resetOf p))).csrs.mcause = 8#32 := by
    rw [hcsu]; rfl
  have hn : trapSteps (payloadAt env (resetOf p) 3079) = 57 := by simp [payloadAt, trapSteps, hmc, ht0]
  have hq : lifeRound env p = PrivMachine.run env (61 + 3079 + 57) (resetOf p) := by
    unfold lifeRound parkedAfter
    rw [hn]
    unfold payloadAt
    rw [PrivMachine.run_add, PrivMachine.run_add]
  obtain ⟨hP, hmem, hio⟩ :=
    life_behind_the_box env p.core.mem (resetOf p) hR.words hKp rfl rfl rfl rfl hR.unlocked hR.region
  refine ⟨⟨3079, ⟨by decide, hM, hU⟩, rfl⟩, fun q ⟨k, ⟨_, hkM, hkU⟩, hq'⟩ => ?_, by rw [hq]; exact hP,
    fun x hs hp => by rw [hq]; exact hmem x hs hp, by rw [hq, hio]; rfl⟩
  have hk : k = 3079 := by
    rcases Nat.lt_trichotomy k 3079 with h | h | h
    · have := hU k h; rw [hkM] at this; cases this
    · exact h
    · have := hkU 3079 h; rw [hM] at this; cases this
  subst hk
  exact hq'

/-- **Every round, whatever came before it.** From a machine `Ready` with the kernel in its code, after any number of
rounds and of the host's writes between them -- to the registers, the CSRs but a lock, any byte but the monitor's
words and the code -- the next round is there and is the only one, it parks with HALT 0, and its history is Rule 30
of the seed it found. -/
theorem life_rounds (env : Rv32.Env) (C : Word → Byte) (p q : PrivMachine) (hR : Ready env C p)
    (hK : CodeAt C base Exp225.kernel) (h : Rounds env p q) :
    Round env q (lifeRound env q) ∧ (∀ r, Round env q r → r = lifeRound env q) ∧
    Parked (lifeRound env q) 0#32 ∧
    (∀ x, ¬ InStack x → ¬ InPorts x → (lifeRound env q).core.mem x = Exp225.lived q.core.mem base Exp225.N x) ∧
    (lifeRound env q).io = q.io ++ heard :=
  life_round env C q (monitor_rounds env C p q h hR) hK

/-! ## The host rounds.py is -/

/-- Rounds, then rounds: still rounds. -/
theorem Rounds.trans {env : Rv32.Env} {p q r : PrivMachine} (h1 : Rounds env p q) (h2 : Rounds env q r) :
    Rounds env p r := by
  induction h1 with
  | refl => exact h2
  | step hr _ ih => exact Rounds.step hr (ih h2)
  | host hw _ ih => exact Rounds.host hw (ih h2)

/-- The seed word, `base + 0x100`, and the history's last word, `base + 0x5fc`. -/
abbrev seedAt : Word := 0x80010100#32
abbrev lastAt : Word := 0x800105fc#32

/-- The host's one write between rounds: the history's last word, as the next seed. -/
def nextSeed (p : PrivMachine) : PrivMachine :=
  { p with core := { p.core with
      mem := writeLE p.core.mem seedAt (readLE p.core.mem lastAt 4) 4 } }

/-- `n` rounds of rounds.py from `p`: a round, then the host's write, `n` times. -/
def chain (env : Rv32.Env) (p : PrivMachine) : Nat → PrivMachine
  | 0 => p
  | n + 1 => nextSeed (lifeRound env (chain env p n))

/-- `gen` adds up. -/
theorem gen_add (x : Word) (a b : Nat) : Exp225.gen x (a + b) = Exp225.gen (Exp225.gen x a) b := by
  induction b with
  | zero => rfl
  | succ b ih => show Exp225.life (Exp225.gen x (a + b)) = Exp225.life _; rw [ih]

/-- Word `i` of the history in `lived` is generation `i + 1` of the seed. -/
theorem history_word (m : Word → Byte) (i : Nat) (hi : i < 256) :
    readLE (Exp225.lived m base Exp225.N) (base + BitVec.ofNat 32 (0x200 + 4 * i)) 4 =
      (Exp225.gen (Exp225.seedOf m base) (i + 1)).toNat := by
  have hv := (Exp225.gen (Exp225.seedOf m base) (i + 1)).isLt
  rw [show (Exp225.gen (Exp225.seedOf m base) (i + 1)).toNat =
      (Exp225.gen (Exp225.seedOf m base) (i + 1)).toNat % 4294967296 by omega, ← readLE_writeLE_self m]
  apply readLE_four_congr
  intro d hd
  rw [writeLE4_apply, BitVec.add_assoc, ← BitVec.ofNat_add]
  have e : (base + BitVec.ofNat 32 (0x200 + 4 * i + d) - (base + BitVec.ofNat 32 (0x200 + 4 * i))).toNat = d := by
    rw [toNat_sub_off (by decide) _ _ (by omega), toNat_off (by decide) _ (by omega)]
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
    omega
  rw [e]
  simp only [hd, ↓reduceIte]
  unfold Exp225.lived
  have h1 : Exp225.HIST ≤ 0x200 + 4 * i + d := by simp only [Exp225.HIST]; omega
  have h2 : 0x200 + 4 * i + d < Exp225.HIST + 4 * Exp225.N := by simp only [Exp225.HIST, Exp225.N]; omega
  have e1 : (0x200 + 4 * i + d - Exp225.HIST) / 4 + 1 = i + 1 := by simp only [Exp225.HIST]; omega
  have e2 : (0x200 + 4 * i + d - Exp225.HIST) % 4 = d := by simp only [Exp225.HIST]; omega
  rw [overlay_off_in (by decide) _ _ (by omega) h1 h2]
  simp only [Exp225.hist, e1, e2]

/-- Word `i` of a round's history, read from where the round parks: generation `i + 1` of the seed it found. -/
theorem round_history (env : Rv32.Env) (C : Word → Byte) (q : PrivMachine) (hR : Ready env C q)
    (hK : CodeAt C base Exp225.kernel) (i : Nat) (hi : i < 256) :
    readLE (lifeRound env q).core.mem (base + BitVec.ofNat 32 (0x200 + 4 * i)) 4 =
      (Exp225.gen (Exp225.seedOf q.core.mem base) (i + 1)).toNat := by
  rw [← history_word _ i hi]
  apply readLE_four_congr
  intro d hd
  have hx : (base + BitVec.ofNat 32 (0x200 + 4 * i) + BitVec.ofNat 32 d).toNat = 0x80010200 + 4 * i + d := by
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega
  refine (life_round env C q hR hK).2.2.2.1 _ ?_ ?_ <;> simp only [InStack, InPorts, hx] <;> omega

/-- The host's write between rounds is one exp240 allows: it touches the seed word alone, which is neither the
monitor's nor the code, and locks nothing. -/
theorem nextSeed_host (env : Rv32.Env) (C : Word → Byte) (r : PrivMachine) (hR : Ready env C r) :
    HostWrite r (nextSeed r) := by
  refine ⟨hR.unlocked, fun x hx => ?_⟩
  show writeLE r.core.mem seedAt _ 4 x = r.core.mem x
  rw [writeLE4_apply]
  have : ¬ (x - seedAt).toNat < 4 := by
    have := x.isLt
    simp only [BitVec.toNat_sub, BitVec.toNat_ofNat]
    omega
  simp only [this, ↓reduceIte]

/-- **rounds.py, round after round.** From a machine `Ready` with the kernel in its code, and the host copying each
round's last generation into the seed: after `n` rounds the machine is reached by exp240's `Rounds`, its seed is
generation `256 n` of the first seed, and round `n + 1` parks with HALT 0 with generations `256 n + 1` to `256 n +
256` of the first seed as its history. -/
theorem life_forever (env : Rv32.Env) (C : Word → Byte) (p : PrivMachine) (hR : Ready env C p)
    (hK : CodeAt C base Exp225.kernel) (n : Nat) :
    Rounds env p (chain env p n) ∧
    Exp225.seedOf (chain env p n).core.mem base = Exp225.gen (Exp225.seedOf p.core.mem base) (256 * n) ∧
    Parked (lifeRound env (chain env p n)) 0#32 ∧
    (∀ i, i < 256 → readLE (lifeRound env (chain env p n)).core.mem (base + BitVec.ofNat 32 (0x200 + 4 * i)) 4 =
      (Exp225.gen (Exp225.seedOf p.core.mem base) (256 * n + i + 1)).toNat) := by
  have key : ∀ n, Rounds env p (chain env p n) ∧
      Exp225.seedOf (chain env p n).core.mem base = Exp225.gen (Exp225.seedOf p.core.mem base) (256 * n) := by
    intro n
    induction n with
    | zero => exact ⟨Rounds.refl _, rfl⟩
    | succ n ih =>
      obtain ⟨hr, hs⟩ := ih
      have hRn := monitor_rounds env C p _ hr hR
      have hround := (life_round env C _ hRn hK).1
      have hR' := (monitor_round_ready env C _ _ hRn hround).1
      refine ⟨Rounds.trans hr (Rounds.step hround (Rounds.host (nextSeed_host env C _ hR') (Rounds.refl _))), ?_⟩
      show BitVec.ofNat 32 (readLE (writeLE _ seedAt _ 4) (base + BitVec.ofNat 32 Exp225.SEED) 4) = _
      rw [show base + BitVec.ofNat 32 Exp225.SEED = seedAt from rfl, readLE_writeLE_self,
        show lastAt = base + BitVec.ofNat 32 (0x200 + 4 * 255) from rfl, round_history env C _ hRn hK 255 (by decide),
        ofNat_toNat_mod, hs, ← gen_add]
      congr 1
  obtain ⟨hr, hs⟩ := key n
  have hRn := monitor_rounds env C p _ hr hR
  refine ⟨hr, hs, (life_round env C _ hRn hK).2.2.1, fun i hi => ?_⟩
  rw [round_history env C _ hRn hK i hi, hs, ← gen_add, Nat.add_assoc]

end Exp255

#print axioms Exp254.life_traps
#print axioms Exp254.life_behind_the_box
#print axioms Exp240.monitor_rounds
#print axioms Exp255.life_round
#print axioms Exp255.life_rounds
#print axioms Exp255.history_word
#print axioms Exp255.life_forever
