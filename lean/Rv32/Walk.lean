/-
SPDX-License-Identifier: Apache-2.0

# A hash chain walked in place, anywhere

`ecall; addi t3, t3, -1; bne t3, x0, -8` at any instruction `k0` of any
program, with HASH's input and output the same 64-byte buffer at `base + B`:
`n` rounds are `n` steps along a chain, in exactly `3n` instructions, and
nothing outside the buffer's first 32 bytes changes. exp205's walk is the same
three instructions at a fixed place in `head`; exp213's key generator and
signer each walk at their own place, over their own buffer, so this is the
version with the place and the buffer as parameters.
-/
import Rv32.Wots

namespace Rv32.Wots
open Rv32

variable {env : Env} {base : Word} {prog : List Instr}

/-- The 64 bytes at `B`: the buffer's value, then 32 zeros. HASH of them is one
step along the chain. -/
theorem hash_step_mem {H : List Byte → Fin 32 → Byte} (hfit : base.toNat + 0x10000 ≤ 2^32) {B : Nat}
    (hB : B + 64 ≤ 0x10000) {M m : Word → Byte} (hz : ∀ d < 32, M (base + BitVec.ofNat 32 (B + 32 + d)) = 0)
    (hk : Keeps (base + BitVec.ofNat 32 B) 32 M m) {x : List Byte} {j : Nat}
    (hbuf : readBytes m (base + BitVec.ofNat 32 B) 32 = chain H x j) :
    let m' := writeBytes m (base + BitVec.ofNat 32 B) (H (readBytes m (base + BitVec.ofNat 32 B) 64))
    Keeps (base + BitVec.ofNat 32 B) 32 M m' ∧ readBytes m' (base + BitVec.ofNat 32 B) 32 = chain H x (j + 1) := by
  intro m'
  have hin : readBytes m (base + BitVec.ofNat 32 B) 64 = chain H x j ++ List.replicate 32 0 := by
    rw [show (64 : Nat) = 32 + 32 from rfl, readBytes_append, hbuf]
    congr 1
    apply readBytes_const
    intro d hd
    rw [off_add hfit _ _ (by omega), off_add hfit _ _ (by omega)]
    rw [hk.off hfit (by omega) (by omega) (by right; omega)]
    exact hz d hd
  refine ⟨hk.trans (keeps_writeBytes hfit _ _ (by omega) (by omega) (by omega)), ?_⟩
  show readBytes (writeBytes m _ _) _ 32 = _
  rw [readBytes_writeBytes, hin]; rfl

/-- The 13-bit offset `bne` reads for `0xffc`, by its value rather than by
`decide` on the append. -/
theorem imm_back8 : ((0xffc : BitVec 12) ++ 0#1) = BitVec.ofNat 13 8184 := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_append]; simp

/-- The branch offset `-8`, as `bne` sign-extends it. Not by `decide`, which
runs out of memory on a negative value's sign extension (see `se_neg`). -/
theorem off_back8 : ((0xffc : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 (2 ^ 32 - 8) := by
  rw [imm_back8]
  have hm : (BitVec.ofNat 13 8184).msb = true := by
    rw [BitVec.msb_eq_decide]; simp only [BitVec.toNat_ofNat, decide_eq_true_eq]; omega
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_signExtend, hm]
  simp only [BitVec.toNat_setWidth, BitVec.toNat_ofNat, ↓reduceIte]

/-- `bne ..., -8` two instructions on: back to `k`. Without `omega` on the
whole sum, whose `2^32` runs Lean out of memory. -/
theorem back8 (k : Nat) (hk : 4 * k + 8 < 2 ^ 32) :
    base + BitVec.ofNat 32 (4 * (k + 2)) + ((0xffc : BitVec 12) ++ 0#1).signExtend 32
      = base + BitVec.ofNat 32 (4 * k) := by
  have h : BitVec.ofNat 32 (4 * (k + 2)) + ((0xffc : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * k) := by
    rw [off_back8]
    apply BitVec.eq_of_toNat_eq
    rw [BitVec.toNat_add, BitVec.toNat_ofNat, BitVec.toNat_ofNat, BitVec.toNat_ofNat,
      Nat.mod_eq_of_lt (show 4 * (k + 2) < 2 ^ 32 by omega), Nat.mod_eq_of_lt (show 2 ^ 32 - 8 < 2 ^ 32 by decide),
      Nat.mod_eq_of_lt (show 4 * k < 2 ^ 32 by omega),
      show 4 * (k + 2) + (2 ^ 32 - 8) = 4 * k + 2 ^ 32 by omega, Nat.add_mod_right, Nat.mod_eq_of_lt (show 4 * k < 2 ^ 32 by omega)]
  rw [BitVec.add_assoc, h]

/-- **The walk**: `n` rounds of `ecall; addi t3, t3, -1; bne t3, x0, -8` from
instruction `k0`, `n` more steps along the chain in the buffer at `B`, in
exactly `3n` instructions; only the buffer's first 32 bytes change, and only
`t3` among the registers. -/
theorem hash_walk (hp : Placed env base) (hlen : 4 * prog.length < 0x10000) {k0 B : Nat}
    (h0 : prog.getD k0 .ecall = .ecall) (h1 : prog.getD (k0 + 1) .ecall = .opi .addi T3 T3 0xfff)
    (h2 : prog.getD (k0 + 2) .ecall = .br .bne T3 0 0xffc) (hk : k0 + 3 ≤ prog.length)
    (hB : B + 64 ≤ 0x10000) (hB4 : B % 4 = 0) (hcB : 4 * prog.length ≤ B)
    {M : Word → Byte} (hcM : CodeAt M base prog) (hz : ∀ d < 32, M (base + BitVec.ofNat 32 (B + 32 + d)) = 0)
    {x : List Byte} :
    ∀ n, 0 < n → n < 2 ^ 20 → ∀ (j : Nat) (s : Machine), s.pc = base + BitVec.ofNat 32 (4 * k0) →
      s.reg T3 = BitVec.ofNat 32 n → s.reg T0 = 0 → s.reg A0 = base + BitVec.ofNat 32 B →
      s.reg A1 = BitVec.ofNat 32 64 → s.reg A2 = base + BitVec.ofNat 32 B →
      Keeps (base + BitVec.ofNat 32 B) 32 M s.mem →
      readBytes s.mem (base + BitVec.ofNat 32 B) 32 = chain env.hash x j →
      ∃ s', run env (3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 3))
        ∧ Keeps (base + BitVec.ofNat 32 B) 32 M s'.mem
        ∧ readBytes s'.mem (base + BitVec.ofNat 32 B) 32 = chain env.hash x (j + n)
        ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro _ hn j s hpc h3 ht0 ha0 ha1 ha2 hkeep hbuf
    have hcode : CodeAt s.mem base prog := hkeep.code fit (by omega) hcB hcM
    have hexec := exec_hash (env := env) (s := s) ht0 (by rw [ha1]; rfl)
      (by rw [ha0]; exact align_off hp.align fit _ (by omega) hB4)
      (by rw [ha2]; exact align_off hp.align fit _ (by omega) hB4)
      (by rw [ha0, ha1]; exact ok_off hp _ _ (by omega) (by simp; omega))
      (by rw [ha2]; exact ok_off hp _ _ (by omega) (by omega))
    obtain ⟨s1, e1, hs1⟩ : ∃ s1, run env 1 s = .running s1 ∧
        s1 = ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next :=
      ⟨_, (stepK hp k0 (by omega) hcode hpc h0 hexec 0 hlen).trans (run_zero _ _), rfl⟩
    have step := hash_step_mem (H := env.hash) fit hB hz hkeep hbuf
    have mem1 : s1.mem = writeBytes s.mem (base + BitVec.ofNat 32 B)
        (env.hash (readBytes s.mem (base + BitVec.ofNat 32 B) 64)) := by
      rw [hs1, next_mem, ha0, ha2, ha1]; rfl
    have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (k0 + 1)) := by
      rw [hs1]; simp only [next_pc]; rw [hpc]; exact pc_next fit k0 (by omega)
    have k1 : ∀ r, s1.reg r = s.reg r := fun r => by rw [hs1]; rfl
    have hc1 : CodeAt s1.mem base prog := by rw [mem1]; exact step.1.code fit (by omega) hcB hcM
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep hp (k0 + 1) (by omega) hc1 p1 h1 rfl hlen
    have v2 : s2.reg T3 = BitVec.ofNat 32 n := by
      rw [reg_wrote r2 (by decide), k1, h3]; simp only [aluI]; exact dec_one n (by omega)
    have k2 : ∀ r, r ≠ T3 → s2.reg r = s.reg r := fun r hr => by rw [reg_kept r2 hr, k1]
    have mem2 : s2.mem = s1.mem := m2
    have hc2 : CodeAt s2.mem base prog := by rw [mem2]; exact hc1
    by_cases hz0 : n = 0
    · subst hz0
      have e3 : run env 1 s2 = .running s2.next :=
        (stepK hp (k0 + 2) (by omega) hc2 p2 h2 (exec_br_not (by rw [v2, reg_zero]; simp [taken])) 0 hlen).trans
          (run_zero _ _)
      refine ⟨s2.next, run_cons e1 (run_cons e2 e3), by simp only [next_pc, p2]; exact pc_next fit _ (by omega),
        by rw [next_mem, mem2, mem1]; exact step.1, by rw [next_mem, mem2, mem1]; exact step.2,
        fun r hr => by rw [next_reg, k2 r hr]⟩
    · have hne : BitVec.ofNat 32 n ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz0 this
      have e3 : run env 1 s2 = .running (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32)) :=
        (stepK hp (k0 + 2) (by omega) hc2 p2 h2
          (exec_br_taken (by rw [v2, reg_zero]; simp only [taken, bne_iff_ne, ne_eq]; exact hne)) 0 hlen).trans
          (run_zero _ _)
      obtain ⟨s', e', p', k', b', r'⟩ := ih (by omega) (by omega) (j + 1)
        (s2.setPc (s2.pc + ((0xffc : BitVec 12) ++ 0#1).signExtend 32))
        (by simp only [setPc_pc, p2]; exact back8 k0 (by omega))
        (by rw [setPc_reg, v2]) (by rw [setPc_reg, k2 _ (by decide), ht0])
        (by rw [setPc_reg, k2 _ (by decide), ha0]) (by rw [setPc_reg, k2 _ (by decide), ha1])
        (by rw [setPc_reg, k2 _ (by decide), ha2])
        (by rw [setPc_mem, mem2, mem1]; exact step.1) (by rw [setPc_mem, mem2, mem1]; exact step.2)
      refine ⟨s', ?_, p', k', by rw [show j + (n + 1) = j + 1 + n by omega]; exact b', ?_⟩
      · have := run_cons e1 (run_cons e2 (run_cons e3 e'))
        rwa [show 3 * n + 1 + 1 + 1 = 3 * (n + 1) by omega] at this
      · intro r hr; rw [r' r hr, setPc_reg, k2 r hr]

/-- **Skip or walk**: `beq t3, x0, 16` before the walk, at any `k0`. With
`t3 = n`, nothing is hashed when `n` is 0 and the branch jumps past the walk;
otherwise `n` rounds. Either way `1 + 3n` instructions, and the buffer is `n`
steps along. -/
theorem skip_or_walk_at (hp : Placed env base) (hlen : 4 * prog.length < 0x10000) {k0 B : Nat}
    (hb : prog.getD k0 .ecall = .br .beq T3 0 8) (h0 : prog.getD (k0 + 1) .ecall = .ecall)
    (h1 : prog.getD (k0 + 2) .ecall = .opi .addi T3 T3 0xfff) (h2 : prog.getD (k0 + 3) .ecall = .br .bne T3 0 0xffc)
    (hk : k0 + 4 ≤ prog.length) (hB : B + 64 ≤ 0x10000) (hB4 : B % 4 = 0) (hcB : 4 * prog.length ≤ B)
    {M : Word → Byte} (hcM : CodeAt M base prog) (hz : ∀ d < 32, M (base + BitVec.ofNat 32 (B + 32 + d)) = 0)
    {x : List Byte} (n : Nat) (hn : n < 2 ^ 20) {s : Machine}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k0)) (h3 : s.reg T3 = BitVec.ofNat 32 n) (ht0 : s.reg T0 = 0)
    (ha0 : s.reg A0 = base + BitVec.ofNat 32 B) (ha1 : s.reg A1 = BitVec.ofNat 32 64)
    (ha2 : s.reg A2 = base + BitVec.ofNat 32 B) (hkeep : Keeps (base + BitVec.ofNat 32 B) 32 M s.mem)
    (hbuf : readBytes s.mem (base + BitVec.ofNat 32 B) 32 = chain env.hash x 0) :
    ∃ s', run env (1 + 3 * n) s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k0 + 4))
      ∧ Keeps (base + BitVec.ofNat 32 B) 32 M s'.mem
      ∧ readBytes s'.mem (base + BitVec.ofNat 32 B) 32 = chain env.hash x n
      ∧ ∀ r, r ≠ T3 → s'.reg r = s.reg r := by
  have fit := hp.fit
  have hcode : CodeAt s.mem base prog := hkeep.code fit (by omega) hcB hcM
  by_cases hz0 : n = 0
  · subst hz0
    have e : run env 1 s = .running (s.setPc (s.pc + ((8 : BitVec 12) ++ 0#1).signExtend 32)) :=
      (stepK hp k0 (by omega) hcode hpc hb (exec_br_taken (by rw [h3, reg_zero]; simp [taken])) 0 hlen).trans
        (run_zero _ _)
    refine ⟨_, e, ?_, by rw [setPc_mem]; exact hkeep, by rw [setPc_mem]; exact hbuf, fun r _ => setPc_reg _ _ r⟩
    simp only [setPc_pc, hpc]
    rw [show ((8 : BitVec 12) ++ 0#1).signExtend 32 = BitVec.ofNat 32 16 by decide, off_add fit _ _ (by omega)]
    congr 2
  · have hne : BitVec.ofNat 32 n ≠ 0 := by
      intro e; have := congrArg BitVec.toNat e
      rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; exact hz0 this
    have e : run env 1 s = .running s.next :=
      (stepK hp k0 (by omega) hcode hpc hb
        (exec_br_not (by rw [h3, reg_zero]; simp only [taken, beq_eq_false_iff_ne, ne_eq]; exact hne)) 0 hlen).trans
        (run_zero _ _)
    obtain ⟨s', e', p', k', b', r'⟩ := hash_walk hp hlen (k0 := k0 + 1) h0 h1 h2 (by omega) hB hB4 hcB hcM hz
      (x := x) n (by omega) hn 0 s.next (by simp only [next_pc, hpc]; exact pc_next fit k0 (by omega))
      (by rw [next_reg, h3]) (by rw [next_reg, ht0]) (by rw [next_reg, ha0]) (by rw [next_reg, ha1])
      (by rw [next_reg, ha2]) (by rw [next_mem]; exact hkeep) (by rw [next_mem]; exact hbuf)
    refine ⟨s', ?_, by rw [p', show k0 + 1 + 3 = k0 + 4 by omega], k', by rw [Nat.zero_add] at b'; exact b',
      fun r hr => by rw [r' r hr, next_reg]⟩
    have := run_cons e e'
    rwa [Nat.add_comm] at this

end Rv32.Wots
