import Dev.Iter

set_option maxRecDepth 100000
set_option linter.unusedSimpArgs false

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

theorem f_clean (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_CLEAN)) : Goes env base m0 scr s (.done C_CLEAN) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

theorem f_false (hp : Placed env base) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * F_FALSE)) : Goes env base m0 scr s (.done C_FALSE) :=
  fail_gen hp hcode hpc (by decide) (by decide) rfl rfl (by jump)

/-- **The end**: no script left, exactly one element and true, or the code
that says which of those failed. -/
theorem the_end (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (h : Inv base m0 scr c s) (hge : scr.length ≤ c.pc) :
    Goes env base m0 scr s (.done (finish c.st)) := by
  have hc := h.core
  have code := hc.code hp hin
  have hfit := hp.fit
  have hsl := hin.len
  simp only [SMAX] at hsl
  have hpc := hc.pcle
  -- bgeu s2, s3, END: taken
  obtain ⟨s1, e1, p1, m1, r1⟩ := brStep (prog := kernel) hp LOOP (by decide) code h.pc rfl (k' := END) (by jump)
  have tk : taken .bgeu (s.reg 18) (s.reg 19) = true := by
    rw [h.r18, hc.r19]
    simp only [taken, ult_off hfit (SCRIPT + c.pc) (SCRIPT + scr.length) (by simp only [SCRIPT]; omega)
      (by simp only [SCRIPT]; omega)]
    simp; omega
  rw [tk] at p1; simp only [↓reduceIte] at p1
  have hd := hc.depth
  simp only [DMAX] at hd
  -- sub t1, s4, s7; li t2, 84; bne t1, t2, F_CLEAN
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp END (by decide) (by rw [m1]; exact code) p1 rfl rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (END + 1) (by decide) (by rw [m2, m1]; exact code) p2 rfl rfl
  obtain ⟨s4, e4, p4, m4, r4⟩ := brStep (prog := kernel) hp (END + 2) (by decide) (by rw [m3, m2, m1]; exact code) p3 rfl
    (k' := F_CLEAN) (by jump)
  rw [show taken .bne (s3.reg 6) (s3.reg 7) = !decide (c.st.length = 1) by
    simp only [taken, bne]; rw [r3 6]; regsimp; rw [r3 7]; regsimp; rw [r2 6]; regsimp; simp only [aluR, aluI, reg_zero]
    rw [r1, r1, hc.r20, hc.r23, sub_off hfit _ _ (by omega) (by simp only [STACK]; omega),
      show (0 : Word) + (0x54 : BitVec 12).signExtend 32 = BitVec.ofNat 32 84 by decide,
      beq_ofNat _ _ (by omega) (by decide)]
    rw [show decide (STACK + 84 * c.st.length - STACK = 84) = decide (c.st.length = 1) from decide_eq_decide.mpr ⟨by omega, by omega⟩]] at p4
  have mm4 : s4.mem = s.mem := by rw [m4, m3, m2, m1]
  have e4' : run env (1 + 1 + 1 + 1) s = .running s4 := run_trans (run_trans (run_trans e1 e2) e3) e4
  match hst : c.st with
  | [e] =>
    simp only [finish]
    rw [hst] at p4; simp only [List.length_singleton, decide_true, Bool.not_true, Bool.false_eq_true, ↓reduceIte] at p4
    have st := hc.stack
    rw [hst] at st
    have slot : SlotAt s4.mem base STACK e := by rw [mm4]; simpa using st.top
    have he : e.length ≤ 80 := hc.elems e (by rw [hst]; simp)
    obtain ⟨n5, s5, e5, p5, ag5, k5⟩ := cast_block (k0 := END + 3) (tgt := F_FALSE) (r := 23) hp
      rfl rfl (by jump) rfl rfl rfl rfl rfl (by decide) rfl (by jump) (by decide) (by decide)
      (by simp only [STACK]; omega) (by simp only [STACK]; omega) (by decide) he
      p4 (by rw [mm4]; exact code)
      (by rw [r4, r3 23]; regsimp; rw [r2 23]; regsimp; rw [r1, hc.r23]) slot
    have c5 : CodeAt s5.mem base kernel := code_keep hfit (by rw [mm4]; exact code) ag5 (by simp only [STACK]; omega)
    have e5' := run_trans e4' e5
    by_cases hcast : cast e
    · simp only [hcast, ↓reduceIte] at p5 ⊢
      obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp (END + 51) (by decide) c5 p5 rfl rfl
      obtain ⟨s7, e7, p7, m7, r7⟩ := jStep (prog := kernel) hp (END + 52) (by decide) (by rw [m6]; exact c5) p6 rfl
        (k' := HALT) (by jump)
      obtain ⟨s8, e8⟩ := halt_at hp (by rw [m7, m6]; exact c5) p7 0
        (by rw [A0, r7, r6 10]; regsimp; simp only [aluI, reg_zero]; rfl)
      exact ⟨_, s8, by rw [run_add_running (run_trans (run_trans e5' e6) e7), e8]; rfl⟩
    · simp only [hcast, Bool.false_eq_true, ↓reduceIte] at p5 ⊢
      exact Goes.prepend e5' (f_false hp c5 p5)
  | [] =>
    simp only [finish]
    rw [hst] at p4; simp at p4
    exact Goes.prepend e4' (f_clean hp (by rw [mm4]; exact code) p4)
  | _ :: _ :: _ =>
    simp only [finish]
    rw [hst] at p4; simp at p4
    exact Goes.prepend e4' (f_clean hp (by rw [mm4]; exact code) p4)

/-- Every opcode moves `pc` on. -/
theorem stepOp_pc {c c' : Cfg} (h : stepOp env scr c = .next c') : c.pc + 1 ≤ c'.pc := by
  unfold stepOp at h
  generalize (scr.getD c.pc 0).toNat = op at h
  simp only [pushE] at h
  by_cases g0 : op = 0
  · simp only [g0, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g0, ↓reduceIte] at h
  by_cases g1 : op ≤ 0x4b
  · simp only [g1, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g1, ↓reduceIte] at h
  by_cases g2 : op = 0x4f
  · simp only [g2, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g2, ↓reduceIte] at h
  by_cases g3 : 0x51 ≤ op ∧ op ≤ 0x60
  · simp only [g3, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g3, ↓reduceIte] at h
  by_cases g4 : op = 0x61
  · simp only [g4, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g4, ↓reduceIte] at h
  by_cases g5 : op = 0x69
  · simp only [g5, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g5, ↓reduceIte] at h
  by_cases g6 : op = 0x75
  · simp only [g6, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g6, ↓reduceIte] at h
  by_cases g7 : op = 0x76
  · simp only [g7, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g7, ↓reduceIte] at h
  by_cases g8 : op = 0x77
  · simp only [g8, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g8, ↓reduceIte] at h
  by_cases g9 : op = 0x78
  · simp only [g9, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g9, ↓reduceIte] at h
  by_cases g10 : op = 0x7c
  · simp only [g10, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g10, ↓reduceIte] at h
  by_cases g11 : op = 0x87
  · simp only [g11, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g11, ↓reduceIte] at h
  by_cases g12 : op = 0x88
  · simp only [g12, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g12, ↓reduceIte] at h
  by_cases g13 : op = 0x8b ∨ op = 0x8c
  · simp only [g13, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g13, ↓reduceIte] at h
  by_cases g14 : op = 0x93 ∨ op = 0x94
  · simp only [g14, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g14, ↓reduceIte] at h
  by_cases g15 : op = 0xa8
  · simp only [g15, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g15, ↓reduceIte] at h
  by_cases g16 : op = 0xac
  · simp only [g16, and_self, ↓reduceIte] at h; (repeat' split at h) <;> first | (cases h; done) | (cases h; simp; try omega)
  simp only [g16, ↓reduceIte] at h
  cases h

/-- **From the top of the loop, to the verdict**: with fuel enough for what
script is left, the kernel halts with what runS says. -/
theorem runs (hp : Placed env base) (hin : Input m0 base scr st0) :
    ∀ n (c : Cfg) (s : Machine), Inv base m0 scr c s → scr.length - c.pc < n →
      ∃ k s', run env k s = .halted (BitVec.ofNat 32 (runS env scr n c)) s'
  | 0, _, _, _, h => by omega
  | n + 1, c, s, hi, hn => by
    by_cases hlt : c.pc < scr.length
    · have g := iter hp hin hi hlt
      simp only [runS, hlt, ↓reduceIte]
      cases hr : stepOp env scr c with
      | done k => rw [hr] at g; exact g
      | next c' =>
        rw [hr] at g
        obtain ⟨k1, s1, e1, hi1⟩ := g
        have := stepOp_pc hr
        have := hi1.core.pcle
        obtain ⟨k2, s2, e2⟩ := runs hp hin n c' s1 hi1 (by omega)
        exact ⟨k1 + 1 + k2, s2, by rw [run_add_running e1, e2]⟩
    · simp only [runS, hlt, ↓reduceIte]
      exact the_end hp hin hi (by omega)

/-- **INIT**: from `base`, with what the shell put in the region, to the top
of the loop with the script's first byte next and the stack as given. -/
theorem init (hp : Placed env base) (hin : Input m0 base scr st0) {s : Machine}
    (hpc : s.pc = base) (hmem : s.mem = m0) :
    ∃ s', run env 15 s = .running s' ∧ Inv base m0 scr ⟨0, st0, 0⟩ s' := by
  have hfit := hp.fit
  have code : CodeAt s.mem base kernel := hmem ▸ hin.code
  have hsl := hin.len
  have hdm := hin.dmax
  simp only [SMAX, DMAX] at hsl hdm
  have p0 : s.pc = base + BitVec.ofNat 32 (4 * 0) := by rw [hpc]; simp
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) code p0 rfl rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact code) p1 rfl rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact code) p2 rfl rfl
  have a24 : s3.reg 24 = base + BitVec.ofNat 32 TABLE := by
    rw [r3 24]; regsimp; simp only [aluR]; rw [r2 9]; regsimp; rw [r1 9]; regsimp; rw [hpc, r2 5]; regsimp
    rw [show ((0x0 : BitVec 20) ++ 0#12) = (0 : Word) by decide, show base + 0 = base by simp,
      show ((0x1 : BitVec 20) ++ 0#12) = BitVec.ofNat 32 TABLE by decide]
  have a9 : s3.reg 9 = base := by
    rw [r3 9]; regsimp; rw [r2 9]; regsimp; rw [r1 9]; regsimp; rw [hpc]
    rw [show ((0x0 : BitVec 20) ++ 0#12) = (0 : Word) by decide]; simp
  have mm3 : s3.mem = m0 := by rw [m3, m2, m1, hmem]
  obtain ⟨s4, e4, p4, m4, r4⟩ := loadStep (prog := kernel) hp 3 (by decide) (by rw [mm3]; exact hin.code) p3 rfl SLEN
    (by rw [a24]; exact addi_pos hfit _ (v := 0x400) (by decide) (by decide) (by decide)) (by decide) (by decide)
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp 4 (by decide) (by rw [m4, mm3]; exact hin.code) p4 rfl rfl
  obtain ⟨s6, e6, p6, m6, r6⟩ := regStep (prog := kernel) hp 5 (by decide) (by rw [m5, m4, mm3]; exact hin.code) p5 rfl rfl
  have a18 : s5.reg 18 = base + BitVec.ofNat 32 SCRIPT := by
    rw [r5 18]; regsimp; rw [r4 24]; regsimp; rw [a24]; exact addi_pos hfit _ (v := 0x404) (by decide) (by decide) (by decide)
  have a6 : s4.reg 6 = BitVec.ofNat 32 scr.length := by rw [r4 6]; regsimp; rw [mm3, hin.slen]
  have a19 : s6.reg 19 = base + BitVec.ofNat 32 (SCRIPT + scr.length) := by
    rw [r6 19]; regsimp; simp only [aluR]; rw [a18, r5 6]; regsimp; rw [a6, off_add hfit _ _ (by simp only [SCRIPT]; omega)]
  have mm6 : s6.mem = m0 := by rw [m6, m5, m4, mm3]
  obtain ⟨s7, e7, p7, m7, r7⟩ := loadStep (prog := kernel) hp 6 (by decide) (by rw [mm6]; exact hin.code) p6 rfl DEPTH
    (by rw [r6 18]; regsimp; rw [a18]; exact addi_pos hfit _ (v := 0x3fc) (by decide) (by decide) (by decide)) (by decide) (by decide)
  have a7 : s7.reg 7 = BitVec.ofNat 32 st0.length := by rw [r7 7]; regsimp; rw [mm6, hin.depth]
  have mm7 : s7.mem = m0 := by rw [m7, mm6]
  obtain ⟨s8, e8, p8, m8, r8⟩ := regStep (prog := kernel) hp 7 (by decide) (by rw [mm7]; exact hin.code) p7 rfl rfl
  obtain ⟨s9, e9, p9, m9, r9⟩ := regStep (prog := kernel) hp 8 (by decide) (by rw [m8, mm7]; exact hin.code) p8 rfl rfl
  obtain ⟨s10, e10, p10, m10, r10⟩ := regStep (prog := kernel) hp 9 (by decide) (by rw [m9, m8, mm7]; exact hin.code) p9 rfl rfl
  obtain ⟨s11, e11, p11, m11, r11⟩ := regStep (prog := kernel) hp 10 (by decide)
    (by rw [m10, m9, m8, mm7]; exact hin.code) p10 rfl rfl
  obtain ⟨s12, e12, p12, m12, r12⟩ := regStep (prog := kernel) hp 11 (by decide)
    (by rw [m11, m10, m9, m8, mm7]; exact hin.code) p11 rfl rfl
  obtain ⟨s13, e13, p13, m13, r13⟩ := regStep (prog := kernel) hp 12 (by decide)
    (by rw [m12, m11, m10, m9, m8, mm7]; exact hin.code) p12 rfl rfl
  obtain ⟨s14, e14, p14, m14, r14⟩ := regStep (prog := kernel) hp 13 (by decide)
    (by rw [m13, m12, m11, m10, m9, m8, mm7]; exact hin.code) p13 rfl rfl
  obtain ⟨s15, e15, p15, m15, r15⟩ := regStep (prog := kernel) hp 14 (by decide)
    (by rw [m14, m13, m12, m11, m10, m9, m8, mm7]; exact hin.code) p14 rfl rfl
  have mm15 : s15.mem = m0 := by rw [m15, m14, m13, m12, m11, m10, m9, m8, mm7]
  have a23 : s8.reg 23 = base + BitVec.ofNat 32 STACK := by
    rw [r8 23]; regsimp; rw [r7 18]; regsimp; rw [r6 18]; regsimp; rw [a18]
    exact addi_pos hfit _ (v := 0x400) (by decide) (by decide) (by decide)
  have a28 : s10.reg 28 = BitVec.ofNat 32 (84 * st0.length) := by
    rw [r10 28]; regsimp; simp only [aluR]; rw [r9 7]; regsimp; rw [r8 7]; regsimp; rw [a7, r9 28]; regsimp
    simp only [aluI, reg_zero]
    rw [show (0 : Word) + (0x54 : BitVec 12).signExtend 32 = BitVec.ofNat 32 84 by decide]
    apply BitVec.eq_of_toNat_eq; simp only [BitVec.toNat_mul, BitVec.toNat_ofNat]; omega
  have a22 : s13.reg 22 = base + BitVec.ofNat 32 TMP := by
    rw [r13 22]; regsimp; rw [r12 22]; regsimp; rw [r11 23]; regsimp; rw [r10 23]; regsimp; rw [r9 23]; regsimp; rw [a23]
    simp only [aluI]
    rw [addi_pos hfit _ (v := 0x7ff) (by decide) (by decide) (by decide),
      addi_pos hfit _ (v := 0x281) (by decide) (by decide) (by decide)]; rfl
  have run15 : run env 15 s = .running s15 := by
    rw [show 15 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + 1))))))))))))) by rfl]
    rw [run_add_running e1, run_add_running e2, run_add_running e3, run_add_running e4, run_add_running e5,
      run_add_running e6, run_add_running e7, run_add_running e8, run_add_running e9, run_add_running e10,
      run_add_running e11, run_add_running e12, run_add_running e13, run_add_running e14, e15]
  refine ⟨s15, run15, ⟨⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, by rw [mm15]; exact Agree.refl _ _ _ _, by rw [mm15]; exact hin.stack,
    hin.dmax, hin.elems, Nat.zero_le _, Nat.zero_le _⟩, by rw [p15]; rfl, ?_⟩⟩
  · rw [r15 9]; regsimp; rw [r14 9]; regsimp; rw [r13 9]; regsimp; rw [r12 9]; regsimp; rw [r11 9]; regsimp; rw [r10 9]; regsimp; rw [r9 9]; regsimp; rw [r8 9]; regsimp; rw [r7 9]; regsimp; rw [r6 9]; regsimp; rw [r5 9]; regsimp; rw [r4 9]; regsimp; exact a9
  · rw [r15 24]; regsimp; rw [r14 24]; regsimp; rw [r13 24]; regsimp; rw [r12 24]; regsimp; rw [r11 24]; regsimp; rw [r10 24]; regsimp; rw [r9 24]; regsimp; rw [r8 24]; regsimp; rw [r7 24]; regsimp; rw [r6 24]; regsimp; rw [r5 24]; regsimp; rw [r4 24]; regsimp; exact a24
  · rw [r15 19]; regsimp; rw [r14 19]; regsimp; rw [r13 19]; regsimp; rw [r12 19]; regsimp; rw [r11 19]; regsimp; rw [r10 19]; regsimp; rw [r9 19]; regsimp; rw [r8 19]; regsimp; rw [r7 19]; regsimp; exact a19
  · rw [r15 23]; regsimp; rw [r14 23]; regsimp; rw [r13 23]; regsimp; rw [r12 23]; regsimp; rw [r11 23]; regsimp; rw [r10 23]; regsimp; rw [r9 23]; regsimp; exact a23
  · rw [r15 22]; regsimp; rw [r14 22]; regsimp; exact a22
  · rw [r15 25]; regsimp; rw [r14 25]; regsimp; simp only [aluI]; rw [a22, add0w]
  · rw [r15 20]; regsimp; rw [r14 20]; regsimp; rw [r13 20]; regsimp; rw [r12 20]; regsimp; rw [r11 20]; regsimp; simp only [aluR]; rw [r10 23]; regsimp; rw [r9 23]; regsimp; rw [a23, a28, off_add hfit _ _ (by simp only [STACK]; omega)]
  · rw [r15 21]; regsimp; simp only [aluI, reg_zero]; rfl
  · rw [r15 18]; regsimp; rw [r14 18]; regsimp; rw [r13 18]; regsimp; rw [r12 18]; regsimp; rw [r11 18]; regsimp; rw [r10 18]; regsimp; rw [r9 18]; regsimp; rw [r8 18]; regsimp; rw [r7 18]; regsimp; rw [r6 18]; regsimp; rw [a18]; rfl

/-- **The kernel computes the verdict.** Started at `base` with the region as
`Input` describes it — the kernel and its table, a script of at most 1020
bytes, a stack of at most 32 elements of at most 80 bytes — the machine halts,
and its exit code is the specification's verdict, for every such script and
stack, every hash the shell gives and every answer it gives to CHECKSIG. -/
theorem kernel_verdict (hp : Placed env base) (hin : Input m0 base scr st0) {s : Machine}
    (hpc : s.pc = base) (hmem : s.mem = m0) :
    ∃ k s', run env k s = .halted (BitVec.ofNat 32 (verdict env scr st0)) s' := by
  obtain ⟨s1, e1, hi⟩ := init hp hin hpc hmem
  obtain ⟨k, s2, e2⟩ := runs hp hin (scr.length + 1) ⟨0, st0, 0⟩ s1 hi (by simp)
  exact ⟨15 + k, s2, by rw [run_add_running e1, e2]; rfl⟩

#print axioms kernel_verdict

end Exp228
