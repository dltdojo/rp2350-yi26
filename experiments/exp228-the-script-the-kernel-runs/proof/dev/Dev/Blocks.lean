import Dev.Mem

/-! # Words zeroed, copied, compared and or-ed: `n` of them

lean/Rv32/Blocks.lean's eight-word blocks, for any `n` and any offsets: a slot
is 21 words. -/

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {prog : List Instr}

/-- **`n` words zeroed**: `sw x0, o + 4j(rd)` for `j < n`. -/
theorem zero_n (hp : Placed env base) {k0 n : Nat} {rd : Reg} {o a : Nat}
    (hat : ∀ j < n, prog.getD (k0 + j) .ecall = .st .sw rd 0 (BitVec.ofNat 12 (o + 4 * j)))
    (hk : k0 + n ≤ prog.length) (ho : o + 4 * n ≤ 2048) (ha : a + o + 4 * n < 0x10000)
    (ha4 : (a + o) % 4 = 0) (hcd : 4 * prog.length ≤ a + o)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg rd = base + BitVec.ofNat 32 a) (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∀ j ≤ n, ∃ s', run env j s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + j))
      ∧ s'.mem = overlay s.mem (base + BitVec.ofNat 32 (a + o)) (4 * j) (fun _ => 0)
      ∧ ∀ r, s'.reg r = s.reg r := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, (overlay_zero _ _ _).symm, fun r => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, m1, r1⟩ := ih (by omega)
    have hc1 : CodeAt s1.mem base prog := by
      rw [m1]; exact code_of_overlay hp.fit hcode hcd (by omega) _
    obtain ⟨s2, e2, p2, m2, r2⟩ := storeStep hp (k0 + j) (by omega) hc1 p1 (hat j (by omega))
      (a + o + 4 * j)
      (by rw [r1, h1, se_small _ (by omega), off_add hp.fit _ _ (by omega), Nat.add_assoc])
      (by omega) (by omega) hlen
    refine ⟨s2, ?_, by rw [p2]; try congr 2, ?_, fun r => by rw [r2, r1]⟩
    · rw [run_add_running e1]; exact e2
    · rw [m2, m1, r1, reg_zero, show (0 : Word).toNat = 0 from rfl,
        ← off_add hp.fit (a + o) (4 * j) (by omega)]
      funext x
      exact overlay_step (by rw [toNat_off hp.fit _ (by omega)]; have := hp.fit; omega)
        (fun d _ => by simp) x

/-- **`n` words copied**: `lw t, so + 4j(rs); sw t, dof + 4j(rd)` for `j < n`,
from `base + src + so` to `base + dst + dof`, which dof not overlap. -/
theorem copy_n (hp : Placed env base) {k0 n : Nat} {rs rd t : Reg} {src dst so dof : Nat}
    (hat : ∀ j < n, prog.getD (k0 + 2 * j) .ecall = .ld .lw t rs (BitVec.ofNat 12 (so + 4 * j))
      ∧ prog.getD (k0 + 2 * j + 1) .ecall = .st .sw rd t (BitVec.ofNat 12 (dof + 4 * j)))
    (hk : k0 + 2 * n ≤ prog.length) (ht : t ≠ 0) (hst : rs ≠ t) (hdt : rd ≠ t)
    (hso : so + 4 * n ≤ 2048) (hdo : dof + 4 * n ≤ 2048)
    (hs : src + so + 4 * n < 0x10000) (hd : dst + dof + 4 * n < 0x10000)
    (hs4 : (src + so) % 4 = 0) (hd4 : (dst + dof) % 4 = 0)
    (hcd : 4 * prog.length ≤ dst + dof) (hsep : src + so + 4 * n ≤ dst + dof ∨ dst + dof + 4 * n ≤ src + so)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg rs = base + BitVec.ofNat 32 src) (h2 : s.reg rd = base + BitVec.ofNat 32 dst)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∀ j ≤ n, ∃ s', run env (2 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 2 * j))
      ∧ s'.mem = overlay s.mem (base + BitVec.ofNat 32 (dst + dof)) (4 * j)
          (fun d => s.mem (base + BitVec.ofNat 32 (src + so + d)))
      ∧ ∀ r, r ≠ t → s'.reg r = s.reg r := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, (overlay_zero _ _ _).symm, fun r _ => rfl⟩
  | succ j ih =>
    obtain ⟨s1, e1, p1, m1, r1⟩ := ih (by omega)
    have hc1 : CodeAt s1.mem base prog := by
      rw [m1]; exact code_of_overlay hp.fit hcode hcd (by omega) _
    obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp (k0 + 2 * j) (by omega) hc1
      (by rw [p1]) (hat j (by omega)).1 (src + so + 4 * j)
      (by rw [r1 _ hst, h1, se_small _ (by omega), off_add hp.fit _ _ (by omega), Nat.add_assoc])
      (by omega) (by omega) hlen
    have hc2 : CodeAt s2.mem base prog := by rw [m2]; exact hc1
    obtain ⟨s3, e3, p3, m3, r3⟩ := storeStep hp (k0 + 2 * j + 1) (by omega) hc2
      (by rw [p2]; try congr 2) (hat j (by omega)).2 (dst + dof + 4 * j)
      (by rw [reg_kept r2 hdt, r1 _ hdt, h2, se_small _ (by omega), off_add hp.fit _ _ (by omega),
            Nat.add_assoc])
      (by omega) (by omega) hlen
    refine ⟨s3, ?_, by rw [p3, show k0 + 2 * j + 1 + 1 = k0 + 2 * (j + 1) by omega], ?_,
      fun r hr => by rw [r3, reg_kept r2 hr, r1 _ hr]⟩
    · rw [show 2 * (j + 1) = 2 * j + (1 + 1) by omega, run_add_running e1, run_cons e2 e3]
    · have v : (s2.reg t).toNat = readLE s1.mem (base + BitVec.ofNat 32 (src + so + 4 * j)) 4 := by
        rw [reg_wrote r2 ht, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)]
      rw [m3, m2, v, m1, ← off_add hp.fit (dst + dof) (4 * j) (by omega)]
      funext x
      refine overlay_step (by rw [toNat_off hp.fit _ (by omega)]; have := hp.fit; omega)
        (fun d hd => ?_) x
      rw [readLE_four_byte _ _ _ hd, off_add hp.fit _ _ (by omega),
        overlay_off_out hp.fit _ _ (by omega) (by omega) (by omega), Nat.add_assoc]

/-- **`n` words compared, with no early exit**: `lw t, oa + 4j(ra); lw u, ob +
4j(rb); xor t, t, u; or acc, acc, t`. Afterwards `acc` is zero exactly when it
was before and every pair of words matched. -/
theorem compare_n (hp : Placed env base) {k0 n : Nat} {ra rb acc t u : Reg} {oa ob a b : Nat}
    (hat : ∀ j < n, prog.getD (k0 + 4 * j) .ecall = .ld .lw t ra (BitVec.ofNat 12 (oa + 4 * j))
      ∧ prog.getD (k0 + 4 * j + 1) .ecall = .ld .lw u rb (BitVec.ofNat 12 (ob + 4 * j))
      ∧ prog.getD (k0 + 4 * j + 2) .ecall = .op .xor t t u
      ∧ prog.getD (k0 + 4 * j + 3) .ecall = .op .or acc acc t)
    (hk : k0 + 4 * n ≤ prog.length)
    (ht : t ≠ 0) (hu : u ≠ 0) (hacc : acc ≠ 0) (htu : t ≠ u) (hrat : ra ≠ t) (hrau : ra ≠ u)
    (hrbt : rb ≠ t) (hrbu : rb ≠ u) (hact : acc ≠ t) (hacu : acc ≠ u)
    (hraa : ra ≠ acc) (hrba : rb ≠ acc)
    (hoa : oa + 4 * n ≤ 2048) (hob : ob + 4 * n ≤ 2048)
    (ha : a + oa + 4 * n < 0x10000) (hb : b + ob + 4 * n < 0x10000)
    (ha4 : (a + oa) % 4 = 0) (hb4 : (b + ob) % 4 = 0)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg ra = base + BitVec.ofNat 32 a) (h2 : s.reg rb = base + BitVec.ofNat 32 b)
    (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∀ j ≤ n, ∃ s', run env (4 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 4 * j))
      ∧ s'.mem = s.mem
      ∧ (s'.reg acc = 0 ↔ s.reg acc = 0 ∧ ∀ j' < j,
          readLE s.mem (base + BitVec.ofNat 32 (a + oa + 4 * j')) 4
            = readLE s.mem (base + BitVec.ofNat 32 (b + ob + 4 * j')) 4)
      ∧ ∀ r, r ≠ acc → r ≠ t → r ≠ u → s'.reg r = s.reg r := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, rfl, by simp, fun r _ _ _ => rfl⟩
  | succ j ih =>
    obtain ⟨s0, e0, p0, m0, z0, k0'⟩ := ih (by omega)
    have hc0 : CodeAt s0.mem base prog := by rw [m0]; exact hcode
    obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 4 * j) (by omega) hc0
      (by rw [p0]) (hat j (by omega)).1 (a + oa + 4 * j)
      (by rw [k0' _ hraa hrat hrau, h1, se_small _ (by omega), off_add hp.fit _ _ (by omega), Nat.add_assoc])
      (by omega) (by omega) hlen
    obtain ⟨s2, e2, p2, m2, r2⟩ := loadStep hp (k0 + 4 * j + 1) (by omega) (by rw [m1]; exact hc0)
      (by rw [p1]; try congr 2) (hat j (by omega)).2.1 (b + ob + 4 * j)
      (by rw [reg_kept r1 hrbt, k0' _ hrba hrbt hrbu, h2, se_small _ (by omega),
          off_add hp.fit _ _ (by omega), Nat.add_assoc])
      (by omega) (by omega) hlen
    obtain ⟨s3, e3, p3, m3, r3⟩ := regStep hp (k0 + 4 * j + 2) (by omega) (by rw [m2, m1]; exact hc0)
      (by rw [p2]; try (congr 2; omega)) (hat j (by omega)).2.2.1 rfl hlen
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep hp (k0 + 4 * j + 3) (by omega) (by rw [m3, m2, m1]; exact hc0)
      (by rw [p3]; try (congr 2; omega)) (hat j (by omega)).2.2.2 rfl hlen
    have mm : s4.mem = s.mem := by rw [m4, m3, m2, m1, m0]
    refine ⟨s4, ?_, by rw [p4, show k0 + 4 * j + 3 + 1 = k0 + 4 * (j + 1) by omega], mm, ?_, ?_⟩
    · rw [show 4 * (j + 1) = 4 * j + (1 + (1 + (1 + 1))) by omega, run_add_running e0,
        run_cons e1 (run_cons e2 (run_cons e3 e4))]
    · rw [reg_wrote r4 hacc, reg_kept r3 hact, reg_kept r2 hacu, reg_kept r1 hact, reg_wrote r3 ht,
        reg_kept r2 htu, reg_wrote r2 hu, reg_wrote r1 ht]
      simp only [aluR]
      rw [orz, z0, xorz, m1, m0]
      constructor
      · rintro ⟨⟨h0, hall⟩, hw⟩
        refine ⟨h0, fun j' hj' => ?_⟩
        rcases (by omega : j' < j ∨ j' = j) with h | h
        · exact hall j' h
        · subst h
          have := congrArg BitVec.toNat hw
          simpa [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)] using this
      · rintro ⟨h0, hall⟩
        exact ⟨⟨h0, fun j' hj' => hall j' (by omega)⟩, by rw [hall j (by omega)]⟩
    · intro r x y z
      rw [reg_kept r4 x, reg_kept r3 y, reg_kept r2 z, reg_kept r1 y, k0' r x y z]

/-- **`n` words or-ed into `acc`**: `lw t, o + 4j(ra); or acc, acc, t`.
Afterwards `acc` is zero exactly when it was before and every word was. -/
theorem or_n (hp : Placed env base) {k0 n : Nat} {ra acc t : Reg} {o a : Nat}
    (hat : ∀ j < n, prog.getD (k0 + 2 * j) .ecall = .ld .lw t ra (BitVec.ofNat 12 (o + 4 * j))
      ∧ prog.getD (k0 + 2 * j + 1) .ecall = .op .or acc acc t)
    (hk : k0 + 2 * n ≤ prog.length)
    (ht : t ≠ 0) (hacc : acc ≠ 0) (hact : acc ≠ t) (hrat : ra ≠ t) (hraa : ra ≠ acc)
    (ho : o + 4 * n ≤ 2048) (ha : a + o + 4 * n < 0x10000) (ha4 : (a + o) % 4 = 0)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (hcode : CodeAt s.mem base prog)
    (h1 : s.reg ra = base + BitVec.ofNat 32 a) (hlen : 4 * prog.length < 0x10000 := by decide) :
    ∀ j ≤ n, ∃ s', run env (2 * j) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 2 * j))
      ∧ s'.mem = s.mem
      ∧ (s'.reg acc = 0 ↔ s.reg acc = 0 ∧ ∀ j' < j,
          readLE s.mem (base + BitVec.ofNat 32 (a + o + 4 * j')) 4 = 0)
      ∧ ∀ r, r ≠ acc → r ≠ t → s'.reg r = s.reg r := by
  intro j hj
  induction j with
  | zero => exact ⟨s, rfl, by simpa using hpc, rfl, by simp, fun r _ _ => rfl⟩
  | succ j ih =>
    obtain ⟨s0, e0, p0, m0, z0, k0'⟩ := ih (by omega)
    have hc0 : CodeAt s0.mem base prog := by rw [m0]; exact hcode
    obtain ⟨s1, e1, p1, m1, r1⟩ := loadStep hp (k0 + 2 * j) (by omega) hc0
      (by rw [p0]) (hat j (by omega)).1 (a + o + 4 * j)
      (by rw [k0' _ hraa hrat, h1, se_small _ (by omega), off_add hp.fit _ _ (by omega), Nat.add_assoc])
      (by omega) (by omega) hlen
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep hp (k0 + 2 * j + 1) (by omega) (by rw [m1]; exact hc0)
      (by rw [p1]; try (congr 2; omega)) (hat j (by omega)).2 rfl hlen
    refine ⟨s2, ?_, by rw [p2, show k0 + 2 * j + 1 + 1 = k0 + 2 * (j + 1) by omega], by rw [m2, m1, m0], ?_, ?_⟩
    · rw [show 2 * (j + 1) = 2 * j + (1 + 1) by omega, run_add_running e0, run_cons e1 e2]
    · rw [reg_wrote r2 hacc, reg_kept r1 hact, reg_wrote r1 ht]
      simp only [aluR]
      rw [orz, z0, m0]
      constructor
      · rintro ⟨⟨h0, hall⟩, hw⟩
        refine ⟨h0, fun j' hj' => ?_⟩
        rcases (by omega : j' < j ∨ j' = j) with h | h
        · exact hall j' h
        · subst h
          have := congrArg BitVec.toNat hw
          simpa [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _)] using this
      · rintro ⟨h0, hall⟩
        refine ⟨⟨h0, fun j' hj' => hall j' (by omega)⟩, ?_⟩
        apply BitVec.eq_of_toNat_eq
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (readLE_four_lt _ _), hall j (by omega)]; rfl
    · intro r x y
      rw [reg_kept r2 x, reg_kept r1 y, k0' r x y]

end Exp228
