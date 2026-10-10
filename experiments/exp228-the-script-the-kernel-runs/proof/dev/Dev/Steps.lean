import Dev.Dispatch

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- From `s`, the machine does what the specification says: on to the top of
the loop with the next configuration, or a halt with the code. -/
def Goes (env : Env) (base : Word) (m0 : Word → Byte) (scr : List Byte) (s : Machine) : Res → Prop
  | .next c' => ∃ n s', run env (n + 1) s = .running s' ∧ Inv base m0 scr c' s'
  | .done k => ∃ n s', run env n s = .halted (BitVec.ofNat 32 k) s'

theorem Goes.prepend {s s1 : Machine} {n : Nat} (e : run env n s = .running s1) {r : Res}
    (h : Goes env base m0 scr s1 r) : Goes env base m0 scr s r := by
  cases r with
  | next c' =>
    obtain ⟨k, s', e', hi⟩ := h
    exact ⟨n + k, s', by rw [show n + k + 1 = n + (k + 1) by omega, run_add_running e, e'], hi⟩
  | done k =>
    obtain ⟨j, s', e'⟩ := h
    exact ⟨n + j, s', by rw [run_add_running e, e']⟩

/-- At a handler: `Core`, `pc` at instruction `k`, `s2` past the opcode, the
opcode in `t0`. -/
structure Entry (base : Word) (m0 : Word → Byte) (scr : List Byte) (c : Cfg) (op k : Nat) (s : Machine) :
    Prop where
  core : Core base m0 scr c s
  pc : s.pc = base + BitVec.ofNat 32 (4 * k)
  r18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1)
  r5 : s.reg 5 = BitVec.ofNat 32 op
  lt : c.pc < scr.length

/-! ## The halt, and the twelve ways to it -/

theorem halt_at (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * HALT)) (code : Nat) (ha : s.reg A0 = BitVec.ofNat 32 code) :
    ∃ s', run env 2 s = .halted (BitVec.ofNat 32 code) s' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp HALT (by decide) hcode hpc rfl rfl
  have t0 : s1.reg T0 = 1 := by rw [T0, r1 5]; regsimp; simp [aluI]
  have a0 : s1.reg A0 = BitVec.ofNat 32 code := by rw [A0, r1 10]; regsimp; exact ha
  refine ⟨s1, ?_⟩
  rw [show 2 = 1 + (0 + 1) by rfl, run_add_running e1,
    haltStep (prog := kernel) hp (HALT + 1) (by decide) (by rw [m1]; exact hcode) p1 rfl t0 (by decide) 0, a0]

/-- A fail stub, `li a0, code; j HALT`, then the halt. -/
theorem fail_gen (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel) {k code : Nat}
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) (hk : k + 1 < 881) (hc : code < 2048)
    (h1 : kernel.getD k .ecall = .opi .addi 10 0 (BitVec.ofNat 12 code))
    {off : BitVec 20} (h2 : kernel.getD (k + 1) .ecall = .jal 0 off)
    (hoff : BitVec.ofNat 32 (4 * (k + 1)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * HALT)) :
    ∃ n s', run env n s = .halted (BitVec.ofNat 32 code) s' := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp k (by rw [kernel_length]; omega) hcode hpc h1 rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := jStep (prog := kernel) hp (k + 1) (by rw [kernel_length]; omega)
    (by rw [m1]; exact hcode) p1 h2 hoff
  obtain ⟨s3, e3⟩ := halt_at hp (by rw [m2, m1]; exact hcode) p2 code
    (by rw [r2, A0, r1 10]; regsimp; simp [aluI, se_small _ hc])
  exact ⟨1 + (1 + 2), s3, by rw [run_add_running e1, run_add_running e2, e3]⟩

macro "fails" : tactic => `(tactic| exact fail_gen _ (by assumption) (by assumption) (by decide) (by decide) rfl rfl (by jump))

theorem f_under (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_UNDER)) : Goes env base m0 scr s (.done C_UNDER) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem f_over (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_OVER)) : Goes env base m0 scr s (.done C_OVER) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-! ## Enough elements, and room for one more -/

/-- `sub t1, s4, s7; li t2, 84k; bltu t1, t2, F_UNDER` with at least `k`
elements: on, `t1` and `t2` used. -/
theorem need_pass (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) {i k : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i + 2 < 881)
    (h1 : kernel.getD i .ecall = .op .sub 6 20 23)
    (h2 : kernel.getD (i + 1) .ecall = .opi .addi 7 0 (BitVec.ofNat 12 (84 * k)))
    {off : BitVec 12} (h3 : kernel.getD (i + 2) .ecall = .br .bltu 6 7 off)
    (hoff : BitVec.ofNat 32 (4 * (i + 2)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * F_UNDER))
    (hk : 84 * k < 2048) (hlen : k ≤ c.st.length) :
    ∃ s', run env 3 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (i + 3)) ∧ s'.mem = s.mem
      ∧ ∀ r, r ≠ 6 → r ≠ 7 → s'.reg r = s.reg r := by
  have code := hc.code hp hin
  have hd := hc.depth
  simp only [DMAX] at hd
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp i (by rw [kernel_length]; omega) code hpc h1 rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (i + 1) (by rw [kernel_length]; omega)
    (by rw [m1]; exact code) p1 h2 rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := brStep (prog := kernel) hp (i + 2) (by rw [kernel_length]; omega)
    (by rw [m2, m1]; exact code) p2 h3 hoff
  have tk : taken .bltu (s2.reg 6) (s2.reg 7) = false := by
    have v1 : s1.reg 6 = BitVec.ofNat 32 (84 * c.st.length) := by
      rw [r1 6]; regsimp; simp only [aluR, hc.r20, hc.r23]
      rw [sub_off hp.fit (STACK + 84 * c.st.length) STACK (by omega) (by simp only [STACK]; omega)]
      congr 1; omega
    have v2 : s2.reg 7 = BitVec.ofNat 32 (84 * k) := by
      rw [r2 7]; regsimp; simp [aluI, se_small _ hk]
    rw [show s2.reg 6 = s1.reg 6 by rw [r2 6]; regsimp, v1, v2]
    simp only [taken]
    rw [ult_ofNat _ _ (by omega) (by omega)]
    simp; omega
  refine ⟨s3, ?_, by rw [p3, tk]; simp, by rw [m3, m2, m1], fun r a b => ?_⟩
  · rw [show 3 = 1 + (1 + 1) by rfl, run_add_running e1, run_add_running e2, e3]
  · rw [r3, r2 r, r1 r]; simp only [a, b, false_and, ↓reduceIte]

theorem need_fail (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) {i k : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i + 2 < 881)
    (h1 : kernel.getD i .ecall = .op .sub 6 20 23)
    (h2 : kernel.getD (i + 1) .ecall = .opi .addi 7 0 (BitVec.ofNat 12 (84 * k)))
    {off : BitVec 12} (h3 : kernel.getD (i + 2) .ecall = .br .bltu 6 7 off)
    (hoff : BitVec.ofNat 32 (4 * (i + 2)) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * F_UNDER))
    (hk : 84 * k < 2048) (hlen : c.st.length < k) : Goes env base m0 scr s (.done C_UNDER) := by
  have code := hc.code hp hin
  have hd := hc.depth
  simp only [DMAX] at hd
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp i (by rw [kernel_length]; omega) code hpc h1 rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp (i + 1) (by rw [kernel_length]; omega)
    (by rw [m1]; exact code) p1 h2 rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := brStep (prog := kernel) hp (i + 2) (by rw [kernel_length]; omega)
    (by rw [m2, m1]; exact code) p2 h3 hoff
  have tk : taken .bltu (s2.reg 6) (s2.reg 7) = true := by
    have v1 : s1.reg 6 = BitVec.ofNat 32 (84 * c.st.length) := by
      rw [r1 6]; regsimp; simp only [aluR, hc.r20, hc.r23]
      rw [sub_off hp.fit (STACK + 84 * c.st.length) STACK (by omega) (by simp only [STACK]; omega)]
      congr 1; omega
    have v2 : s2.reg 7 = BitVec.ofNat 32 (84 * k) := by
      rw [r2 7]; regsimp; simp [aluI, se_small _ hk]
    rw [show s2.reg 6 = s1.reg 6 by rw [r2 6]; regsimp, v1, v2]
    simp only [taken]
    rw [ult_ofNat _ _ (by omega) (by omega)]
    simp; omega
  rw [tk] at p3; simp only [↓reduceIte] at p3
  exact Goes.prepend (show run env 3 s = .running s3 by
      rw [show 3 = 1 + (1 + 1) by rfl, run_add_running e1, run_add_running e2, e3])
    (f_under hp (by rw [m3, m2, m1]; exact code) p3)

/-- `bgeu s4, s6, F_OVER` with fewer than 32 elements: on. -/
theorem room_pass (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) {i : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i < 881)
    {off : BitVec 12} (h1 : kernel.getD i .ecall = .br .bgeu 20 22 off)
    (hoff : BitVec.ofNat 32 (4 * i) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * F_OVER))
    (hlen : c.st.length < DMAX) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (i + 1)) ∧ s'.mem = s.mem
      ∧ ∀ r, s'.reg r = s.reg r := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := brStep (prog := kernel) hp i (by rw [kernel_length]; omega)
    (hc.code hp hin) hpc h1 hoff
  have tk : taken .bgeu (s.reg 20) (s.reg 22) = false := by
    simp only [taken, hc.r20, hc.r22]
    have hd := hc.depth
    rw [ult_off hp.fit (STACK + 84 * c.st.length) TMP (by simp only [STACK, DMAX] at *; omega)
      (by simp only [TMP]; omega)]
    have hx : STACK + 84 * c.st.length < TMP := by simp only [STACK, TMP, DMAX] at *; omega
    simp [hx]
  exact ⟨s1, e1, by rw [p1, tk]; simp, m1, r1⟩

theorem room_fail (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) {i : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i < 881)
    {off : BitVec 12} (h1 : kernel.getD i .ecall = .br .bgeu 20 22 off)
    (hoff : BitVec.ofNat 32 (4 * i) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * F_OVER))
    (hlen : DMAX ≤ c.st.length) : Goes env base m0 scr s (.done C_OVER) := by
  have code := hc.code hp hin
  obtain ⟨s1, e1, p1, m1, r1⟩ := brStep (prog := kernel) hp i (by rw [kernel_length]; omega) code hpc h1 hoff
  have hd := hc.depth
  have tk : taken .bgeu (s.reg 20) (s.reg 22) = true := by
    simp only [taken, hc.r20, hc.r22]
    have hd := hc.depth
    rw [ult_off hp.fit (STACK + 84 * c.st.length) TMP (by simp only [STACK, DMAX] at *; omega)
      (by simp only [TMP]; omega)]
    have hx : ¬ STACK + 84 * c.st.length < TMP := by simp only [STACK, TMP, DMAX] at *; omega
    simp [hx]
  rw [tk] at p1; simp only [↓reduceIte] at p1
  exact Goes.prepend e1 (f_over hp (by rw [m1]; exact code) p1)

/-- The next configuration's `Core`, from this one's: the fixed registers
kept, and everything about the new stack given. -/
theorem Core.next {c c' : Cfg} {s s' : Machine} (h : Core base m0 scr c s)
    (hr : ∀ r : Reg, r = 9 ∨ r = 24 ∨ r = 19 ∨ r = 23 ∨ r = 22 ∨ r = 25 → s'.reg r = s.reg r)
    (h20 : s'.reg 20 = base + BitVec.ofNat 32 (STACK + 84 * c'.st.length))
    (h21 : s'.reg 21 = BitVec.ofNat 32 c'.sigs)
    (hag : Agree m0 s'.mem base STACK LIMIT) (hst : Holds s'.mem base c'.st) (hd : c'.st.length ≤ DMAX)
    (he : ∀ e ∈ c'.st, e.length ≤ EMAX) (hs : c'.sigs ≤ 1) (hpc : c'.pc ≤ scr.length) :
    Core base m0 scr c' s' where
  r9 := by rw [hr 9 (by decide), h.r9]
  r24 := by rw [hr 24 (by decide), h.r24]
  r19 := by rw [hr 19 (by decide), h.r19]
  r23 := by rw [hr 23 (by decide), h.r23]
  r22 := by rw [hr 22 (by decide), h.r22]
  r25 := by rw [hr 25 (by decide), h.r25]
  r20 := h20
  r21 := h21
  agree := hag
  stack := hst
  depth := hd
  elems := he
  sigs := hs
  pcle := hpc

/-! ## Back to the top -/

/-- `j LOOP`, from a machine that already holds the next configuration. -/
theorem back (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (hc : Core base m0 scr c s) (h18 : s.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc))
    {i : Nat} (hpc : s.pc = base + BitVec.ofNat 32 (4 * i)) (hi : i < 881)
    {off : BitVec 20} (h1 : kernel.getD i .ecall = .jal 0 off)
    (hoff : BitVec.ofNat 32 (4 * i) + (off ++ 0#1).signExtend 32 = BitVec.ofNat 32 (4 * LOOP)) :
    Goes env base m0 scr s (.next c) := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := jStep (prog := kernel) hp i (by rw [kernel_length]; omega)
    (hc.code hp hin) hpc h1 hoff
  exact ⟨0, s1, e1, ⟨hc.regs m1 (fun r _ => r1 r), p1, by rw [r1, h18]⟩⟩

end Exp228
