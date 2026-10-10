import Dev.Inv

set_option maxRecDepth 100000

namespace Exp228
open Rv32

variable {env : Env} {base : Word} {m0 : Word → Byte} {scr : List Byte} {st0 : List Elem}

/-- **The dispatch**: from the top of the loop, with a script byte left, eight
instructions to the handler the table names for it, with the opcode in `t0`
and `s2` past it. -/
theorem dispatch (hp : Placed env base) (hin : Input m0 base scr st0) {c : Cfg} {s : Machine}
    (h : Inv base m0 scr c s) (hlt : c.pc < scr.length) :
    ∃ s', run env 8 s = .running s' ∧
      s'.pc = base + BitVec.ofNat 32 (table.getD (scr.getD c.pc 0).toNat 0) ∧
      Core base m0 scr c s' ∧ s'.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1) ∧
      s'.reg 5 = BitVec.ofNat 32 (scr.getD c.pc 0).toNat := by
  have hc := h.core
  have code := hc.code hp hin
  have hfit := hp.fit
  have hsl := hin.len
  simp only [SMAX] at hsl
  -- bgeu s2, s3, END: not taken
  obtain ⟨s1, e1, p1, m1, r1⟩ := brStep (prog := kernel) hp LOOP (by decide) code h.pc rfl
    (k' := END) (by jump)
  have tk : taken .bgeu (s.reg 18) (s.reg 19) = false := by
    rw [h.r18, hc.r19]
    simp only [taken, ult_off hfit (SCRIPT + c.pc) (SCRIPT + scr.length) (by simp only [SCRIPT]; omega)
      (by simp only [SCRIPT]; omega)]
    simp; omega
  rw [tk] at p1
  simp only [Bool.false_eq_true, ↓reduceIte] at p1
  -- lbu t0, 0(s2)
  obtain ⟨s2, e2, p2, m2, r2⟩ := lbuStep (prog := kernel) hp (LOOP + 1) (by decide) (by rw [m1]; exact code)
    p1 rfl (SCRIPT + c.pc) (by rw [r1, h.r18]; simp) (by simp only [SCRIPT]; omega)
  have op : (s.mem (base + BitVec.ofNat 32 (SCRIPT + c.pc))) = scr.getD c.pc 0 := by
    rw [hc.agree _ (by simp only [SCRIPT]; omega) (by left; simp only [SCRIPT, STACK]; omega)]
    exact hin.script _ hlt
  -- addi s2, s2, 1
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp (LOOP + 2) (by decide)
    (by rw [m2, m1]; exact code) p2 rfl rfl
  -- slli t1, t0, 2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp (LOOP + 3) (by decide)
    (by rw [m3, m2, m1]; exact code) p3 rfl rfl
  -- add t1, t1, s8
  obtain ⟨s5, e5, p5, m5, r5⟩ := regStep (prog := kernel) hp (LOOP + 4) (by decide)
    (by rw [m4, m3, m2, m1]; exact code) p4 rfl rfl
  have hop := (scr.getD c.pc 0).isLt
  have a2 : s2.reg 5 = BitVec.ofNat 32 (scr.getD c.pc 0).toNat := by
    rw [r2 5, m1, op]; regsimp
  have a3 : s3.reg 18 = base + BitVec.ofNat 32 (SCRIPT + c.pc + 1) := by
    rw [r3 18]; regsimp; rw [r2 18]; regsimp; rw [r1, h.r18]
    exact addi_pos hfit _ (by decide) (by decide) (by simp only [SCRIPT]; omega)
  have a4 : s4.reg 6 = BitVec.ofNat 32 (4 * (scr.getD c.pc 0).toNat) := by
    rw [r4 6]; regsimp; rw [r3 5]; regsimp; rw [a2]
    simp only [shiftI]
    apply BitVec.eq_of_toNat_eq
    simp [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]; omega
  have a5 : s5.reg 6 = base + BitVec.ofNat 32 (TABLE + 4 * (scr.getD c.pc 0).toNat) := by
    rw [r5 6]; regsimp; rw [a4, r4 24]; regsimp; rw [r3 24]; regsimp; rw [r2 24]; regsimp
    rw [r1, hc.r24]; simp only [aluR]
    rw [BitVec.add_comm, off_add hfit _ _ (by simp only [TABLE]; omega)]
  have mm5 : s5.mem = s.mem := by rw [m5, m4, m3, m2, m1]
  have ht := table_entry _ hop
  -- lw t1, 0(t1)
  obtain ⟨s6, e6, p6, m6, r6⟩ := loadStep (prog := kernel) hp (LOOP + 5) (by decide)
    (by rw [mm5]; exact code) p5 rfl (TABLE + 4 * (scr.getD c.pc 0).toNat) (by rw [a5]; simp)
    (by simp only [TABLE]; omega) (by simp only [TABLE]; omega)
  have a6 : s6.reg 6 = BitVec.ofNat 32 (table.getD (scr.getD c.pc 0).toNat 0) := by
    rw [r6 6]; regsimp
    rw [mm5, readLE_four_congr (m' := m0) (fun d hd => ?_), hin.table _ hop]
    rw [off_add hfit _ _ (by simp only [TABLE]; omega)]
    exact hc.agree _ (by simp only [TABLE]; omega) (by left; simp only [TABLE, STACK]; omega)
  -- add t1, t1, s1
  obtain ⟨s7, e7, p7, m7, r7⟩ := regStep (prog := kernel) hp (LOOP + 6) (by decide)
    (by rw [m6, mm5]; exact code) p6 rfl rfl
  have a7 : s7.reg 6 = base + BitVec.ofNat 32 (4 * (table.getD (scr.getD c.pc 0).toNat 0 / 4)) := by
    rw [r7 6]; regsimp; rw [a6, r6 9]; regsimp; rw [r5 9]; regsimp; rw [r4 9]; regsimp; rw [r3 9]; regsimp
    rw [r2 9]; regsimp; rw [r1, hc.r9]; simp only [aluR]
    rw [BitVec.add_comm, show 4 * (table.getD (scr.getD c.pc 0).toNat 0 / 4)
      = table.getD (scr.getD c.pc 0).toNat 0 by omega]
  -- jalr x0, t1, 0
  obtain ⟨s8, e8, p8, m8, r8⟩ := jalrStep (prog := kernel) hp (LOOP + 7) (by decide)
    (by rw [m7, m6, mm5]; exact code) p7 rfl a7 (by omega)
  refine ⟨s8, ?_, ?_, ?_, ?_, ?_⟩
  · rw [show 8 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + 1)))))) by rfl, run_add_running e1, run_add_running e2,
      run_add_running e3, run_add_running e4, run_add_running e5, run_add_running e6, run_add_running e7, e8]
  · rw [p8, show 4 * (table.getD (scr.getD c.pc 0).toNat 0 / 4) = table.getD (scr.getD c.pc 0).toNat 0 by omega]
  · refine hc.regs (by rw [m8, m7, m6, mm5]) (fun r hr => ?_)
    rw [r8, r7 r, r6 r, r5 r, r4 r, r3 r, r2 r, r1]
    rcases hr with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> regsimp
  · rw [r8, r7 18]; regsimp; rw [r6 18]; regsimp; rw [r5 18]; regsimp; rw [r4 18]; regsimp; exact a3
  · rw [r8, r7 5]; regsimp; rw [r6 5]; regsimp; rw [r5 5]; regsimp; rw [r4 5]; regsimp; rw [r3 5]; regsimp
    exact a2

end Exp228
