/-! # exp254 — exp225's kernel behind exp240's monitor

exp240 boxes its payload with no byte both writable and runnable, and proves the monitor boots, runs whatever the
payload is up to its first trap, and parks. exp225 proves its kernel halts with Rule 30's history, in a 64 KiB region
of Tier 1. exp253 proves where every step of that run fetches, loads and stores. Here the three are one run: from
reset, the kernel's 3079 steps are the Tier 2 steps one for one, every one let through by the box, and the monitor
parks with HALT 0 and the history in memory. -/

namespace Exp254
open Rv32 Rv32.Priv Rv32.Refinement Rv32.Join Rv32.Reach Exp240

/-- The kernel's first word: the start of exp240's code entry. -/
abbrev base : Word := 0x80010000#32

/-- The kernel's world: Tier 2's, with the region its 64 KiB, `[0x80010000, 0x80020000)`. -/
def kenv (env : Rv32.Env) : Rv32.Env := boxEnv env 0x80010000 0x80020000

theorem placed (env : Rv32.Env) : Placed (kenv env) base := ⟨by decide, by decide, rfl⟩

theorem within (env : Rv32.Env) (henv : env.region = monRegion) :
    Region.within ⟨0x80010000, 0x80020000⟩ env.region := by
  rw [henv]; exact ⟨by decide, by decide⟩

/-- **Every step exp253 vouches for is one exp240's box lets through.** The kernel's 76 bytes are in the code entry,
`[0x80010000, 0x80010080)`; the seed and the history are in the data entry, `[0x80010000, 0x80011000)`, past the
code. -/
theorem wx_ok {env : Rv32.Env} {m : Machine} (hg : Good (kenv env) base Exp225.kernel Exp253.seed Exp253.history m) :
    WxOk 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 m := by
  refine wxOk_of_good (by decide) hg (by rw [Exp225.kernel_length]; decide) (by rw [Exp225.kernel_length]; decide)
    ⟨by decide, fun o w h1 h2 _ => ?_⟩ ⟨by decide, fun o w h1 h2 _ => ?_⟩
  · simp only [Exp253.seed] at h1 h2
    simp only [WxReadable, WxWritable, BitVec.toNat_ofNat]
    omega
  · simp only [Exp253.history] at h1 h2
    simp only [WxWritable, BitVec.toNat_ofNat]
    omega

/-- **The payload's run, to its trap.** From where boot leaves the machine -- W^X-boxed at the kernel's first word,
the CSRs `csrsBooted`, the kernel in the code, the monitor's words in place -- the kernel's 3079 steps are 3079 Tier
2 steps: every one before the last in U-mode, and the last the `ecall` that traps. At the trap vector: cause 8, `t0 =
1`, `a0 = 0`, both counters at 3081 (boot's 2 and the kernel's 3079), memory exp225's `lived` -- the history Rule
30's -- and no port touched. -/
theorem life_traps (env : Rv32.Env) (M0 : Word → Byte) (s1 : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hA : Agree M0 s1.core.mem 0x80000000 604)
    (henv : env.region = monRegion)
    (hbox : WXBoxed s1 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000)
    (hcs : s1.csrs = csrsBooted) (hpc : s1.core.pc = base) (hcode : CodeAt s1.core.mem base Exp225.kernel) :
    (∀ i, i < 3079 → (PrivMachine.run env i s1).mode = .U) ∧
    (PrivMachine.run env 3079 s1).mode = .M ∧ HState env M0 (PrivMachine.run env 3079 s1) ∧
    (PrivMachine.run env 3079 s1).core.pc = 0x80000134#32 ∧
    (PrivMachine.run env 3079 s1).csrs = csrsH (PrivMachine.run env 3079 s1).csrs.mstatus
      (PrivMachine.run env 3079 s1).csrs.mepc 8#32 3081#32 3081#32 {} 0x80008000#32 ∧
    (PrivMachine.run env 3079 s1).core.reg 5#5 = 1#32 ∧ (PrivMachine.run env 3079 s1).core.reg 10#5 = 0#32 ∧
    (PrivMachine.run env 3079 s1).core.mem = Exp225.lived s1.core.mem base Exp225.N ∧
    (PrivMachine.run env 3079 s1).io = s1.io ∧ (PrivMachine.run env 3079 s1).host = s1.host := by
  have hp := placed env
  have hR := within env henv
  obtain ⟨c, c', e, e1, hlived⟩ := Exp225.to_the_ecall hp s1.core hpc hcode
  obtain ⟨-, -, -, hall⟩ := Exp253.life_whole hp hpc hcode
  have hq : ∀ i < 3078, ∀ m, run (kenv env) i s1.core = .running m →
      (decode (fetched m) = some .ecall → m.reg T0 = 1) ∧
      WxOk 0x80010000 0x80010080 0x80010000 0x80011000 0x8001f000 0x80020000 m :=
    fun i _ m hm => ⟨quiet_of_good (hall i m hm).1, wx_ok (hall i m hm).1⟩
  have hc := (wx_ok (hall 3078 c e).1).1
  have hh1 : run (kenv env) (3078 + 1) s1.core = .halted 0 c' := by rw [run_add_running e, e1]
  have hinh : s1.csrs.mcountinhibit = {} := by rw [hcs]; rfl
  obtain ⟨t1, t2, t3, t4, t5, t6, t7, t8, t9, -, t11, t12, t13, t14, t15⟩ :=
    wx_halt_in_box env hR 3078 s1 hbox hinh e hh1 hq hc
  -- before the trap, every state is the boxed one `wx_run_in_box` describes
  have hU : ∀ i, i < 3079 → (PrivMachine.run env i s1).mode = .U := by
    intro i hi
    obtain ⟨m, hm⟩ := run_running_prefix (env := kenv env) i (3078 - i) s1.core
      (by rw [Nat.add_sub_cancel' (by omega)]; exact e)
    exact (wx_run_in_box env hR i s1 m hbox hinh hm (fun j hj => hq j (by omega))).2.1.isUMode
  have hmem : (PrivMachine.run env 3079 s1).core.mem = Exp225.lived s1.core.mem base Exp225.N := by
    rw [t5, ← hlived, t8]
  have hagree : Agree M0 (PrivMachine.run env 3079 s1).core.mem 0x80000000 604 := by
    intro x h1 h2
    rw [t5, (hall 3078 c e).2 x (by simp only [BitVec.toNat_ofNat]; omega)]
    exact hA x h1 h2
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := t11
  rw [hcs] at k1 k2 k3 k4 k5 k6 k7 k8 t3 t12 t13
  have hcsu := csrs_eq_csrsH _ k1 k2 k3 k4 k5 k6 k7 k8
  rw [t9, t12, t13] at hcsu
  refine ⟨hU, t1, ⟨hW, hagree, henv, t2, t1⟩, ?_, hcsu, by rw [t4]; exact t6, by rw [t4]; exact t7, hmem, t14, t15⟩
  rw [t3]; decide

/-- **exp225's life, behind exp240's box.** From reset -- or from any CSRs that lock no PMP entry -- with exp240's
monitor at `0x80000000` and exp225's kernel at `0x80010000`: after exactly 61 + 3079 + 57 steps the monitor is parked
with HALT 0, every register but `a0` zero. Memory but the monitor's stack and report words is exp225's `lived`:
the 1024 bytes from `0x80010200` generations 1 to 256 of Rule 30 from the seed at `0x80010100`, every other byte as it
was. And the host has heard the HALT report -- the tag, `a0 = 0`, 3081 instructions and 3081 cycles -- then 0 at the
exit word, and nothing before. -/
theorem life_behind_the_box (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hK : CodeAt M0 base Exp225.kernel)
    (hmem : s.core.mem = M0) (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hlock : PmpUnlocked s.csrs.pmpcfg0) (henv : env.region = monRegion) :
    Parked (PrivMachine.run env (61 + 3079 + 57) s) 0#32 ∧
    (∀ x, ¬ InStack x → ¬ InPorts x →
      (PrivMachine.run env (61 + 3079 + 57) s).core.mem x = Exp225.lived M0 base Exp225.N x) ∧
    (PrivMachine.run env (61 + 3079 + 57) s).io = s.io ++
      [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, 0#32⟩, ⟨0xc0000004#32, 3081#32⟩,
       ⟨0xc0000004#32, 3081#32⟩, ⟨0xc0000008#32, 0#32⟩] := by
  obtain ⟨hbox, hpc1, hcsb, hmem1, -, hio1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hlock
  obtain ⟨-, hM, hS, hpcu, hcsu, ht0, ha0, hmu, hiou, -⟩ :=
    life_traps env M0 _ hW (by rw [hmem1]; exact Agree.refl _ _ _) henv hbox hcsb hpc1 (by rw [hmem1]; exact hK)
  rw [PrivMachine.run_add, PrivMachine.run_add]
  obtain ⟨hP, -, hF, -, -, hio⟩ := monitor_traps env M0 _ hS _ _ _ _ _ hpcu hcsu
  have hmc : (PrivMachine.run env 3079 (PrivMachine.run env 61 s)).csrs.mcause = 8#32 := by rw [hcsu]; rfl
  have hn : trapSteps (PrivMachine.run env 3079 (PrivMachine.run env 61 s)) = 57 := by
    simp [trapSteps, hmc, ht0]
  have hx : exitCode (PrivMachine.run env 3079 (PrivMachine.run env 61 s)) = 0#32 := by
    simp [exitCode, hmc, ht0, ha0]
  rw [hn, hx] at hP
  rw [hn] at hF hio
  refine ⟨hP, fun x hs hp => ?_, ?_⟩
  · rw [hF x hs hp, hmu, hmem1]
  · have hmi : (PrivMachine.run env 3079 (PrivMachine.run env 61 s)).csrs.minstret = 3081#32 := by rw [hcsu]; rfl
    have hmy : (PrivMachine.run env 3079 (PrivMachine.run env 61 s)).csrs.mcycle = 3081#32 := by rw [hcsu]; rfl
    rw [hio, hiou, hio1]
    simp [trapIo, haltIo, exitCode, hmc, ht0, ha0, hmi, hmy]

end Exp254

#print axioms Exp240.monitor_boot
#print axioms Exp240.monitor_traps
#print axioms Exp225.to_the_ecall
#print axioms Exp253.life_whole
#print axioms Rv32.Join.wx_plain
#print axioms Rv32.Join.wx_run_in_box
#print axioms Rv32.Join.wx_halt_in_box
#print axioms Rv32.Join.wxOk_of_good
#print axioms Exp254.wx_ok
#print axioms Exp254.life_traps
#print axioms Exp254.life_behind_the_box
