/-! # exp247 — exp229's kernel, behind exp236's wall

exp229 proved, in Tier 1, that its kernel computes the field: from its first word, in its
own 64 KiB, `count op - 1` instructions run and the next one halts with 0, with
`spec op a b` at R. exp236 proved, in Tier 2, that its monitor boots, boxes a payload in
`[0x80010000, 0x80020000)` and, from the trap vector, parks with what it heard. Neither is
about the other. The theorem here is about both at once: the kernel loaded where the monitor
runs its payload, from reset to the park loop, and the words the host hears on the way.

What joins them is `lean/Rv32/Join.lean`. The one thing it asks of a kernel that a Tier 1
outcome theorem does not say is that the run makes no service call before its HALT: Tier 1
would serve HASH and SIG and go on, and exp236 serves neither. For exp229 that comes from
the constant-time checker it already passes: `halts_only` is one `decide` that every
`ecall` the checker reaches, it reaches knowing `t0 = 1`. -/

namespace Exp247
open Rv32 Rv32.Priv Rv32.Refinement Rv32.Join Exp236

/-! ## Boot, and what the host hears of it

exp236's `monitor_boot` says where boot leaves the machine; these say too that it wrote no
port, asked the host nothing, and left both counters at 2: `csrwi mcountinhibit, 0` counts
itself, and so does the `mret`. The same steps as exp236's, run again for these fields. -/

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_config (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) :
    (PrivMachine.run env 20 s).io = s.io ∧ (PrivMachine.run env 20 s).host = s.host := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 20 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs] at hF
  subst hF
  exact ⟨rfl, rfl⟩

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_launch_1 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000090#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) :
    (PrivMachine.run env 12 s).io = s.io ∧ (PrivMachine.run env 12 s).host = s.host := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 12 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  exact ⟨rfl, rfl⟩

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_launch_2 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x800000c0#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) :
    (PrivMachine.run env 12 s).io = s.io ∧ (PrivMachine.run env 12 s).host = s.host := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 12 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  exact ⟨rfl, rfl⟩

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_launch_3 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x800000f0#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) :
    (PrivMachine.run env 7 s).io = s.io ∧ (PrivMachine.run env 7 s).host = s.host := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 7 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  exact ⟨rfl, rfl⟩

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_launch_4 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x8000010c#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsConfigured) :
    (PrivMachine.run env 1 s).io = s.io ∧ (PrivMachine.run env 1 s).host = s.host := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsConfigured] at hF
  subst hF
  exact ⟨rfl, rfl⟩

set_option maxHeartbeats 4000000 in
set_option maxRecDepth 100000 in
theorem ports_launch_5 (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000110#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = csrsReady) :
    (PrivMachine.run env 1 s).io = s.io ∧ (PrivMachine.run env 1 s).host = s.host ∧
    (PrivMachine.run env 1 s).csrs.minstret = 2#32 ∧ (PrivMachine.run env 1 s).csrs.mcycle = 2#32 := by
  have sm := sm_mon env M0 hW
  obtain ⟨F, hF⟩ : ∃ F, PrivMachine.run env 1 s = F := ⟨_, rfl⟩
  rw [hF]
  psimp [sm, hmem, hpc, monitorCode, hh, hm, hcs, csrsReady, csrsConfigured] at hF
  subst hF
  psimp [hpc, hmem, csrsConfigured, csrsReady]

/-- **Boot is silent.** From reset, exp236's 53 steps of boot write no port, ask the host
    nothing, and leave `minstret` and `mcycle` at 2. -/
theorem boot_ports (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) :
    (PrivMachine.run env 53 s).io = s.io ∧ (PrivMachine.run env 53 s).host = s.host ∧
    (PrivMachine.run env 53 s).csrs.minstret = 2#32 ∧ (PrivMachine.run env 53 s).csrs.mcycle = 2#32 := by
  obtain ⟨c1, c2, c3, c4, c5⟩ := monitor_boot_config env M0 s hW hmem hpc hh hm hcs
  have hC0 : Cleared 0 (PrivMachine.run env 20 s) := by
    intro r hr
    have : r = 0 := by bv_omega
    subst this
    simp
  obtain ⟨a1, a2, a3, a4, a5, a6⟩ := monitor_launch_1 env M0 _ hW c2 c1 c3 c4 c5 hC0
  obtain ⟨b1, b2, b3, b4, b5, b6⟩ := monitor_launch_2 env M0 _ hW a2 a1 a3 a4 a5 a6
  obtain ⟨e1, e2, e3, e4, e5, -⟩ := monitor_launch_3 env M0 _ hW b2 b1 b3 b4 b5 b6
  obtain ⟨g1, g2, g3, g4, g5, -⟩ := monitor_launch_4 env M0 _ hW e2 e1 e3 e4 e5
  obtain ⟨p1, p2⟩ := ports_config env M0 s hW hmem hpc hh hm hcs
  obtain ⟨p3, p4⟩ := ports_launch_1 env M0 _ hW c2 c1 c3 c4 c5
  obtain ⟨p5, p6⟩ := ports_launch_2 env M0 _ hW a2 a1 a3 a4 a5
  obtain ⟨p7, p8⟩ := ports_launch_3 env M0 _ hW b2 b1 b3 b4 b5
  obtain ⟨p9, p10⟩ := ports_launch_4 env M0 _ hW e2 e1 e3 e4 e5
  obtain ⟨p11, p12, p13, p14⟩ := ports_launch_5 env M0 _ hW g2 g1 g3 g4 g5
  rw [show 53 = 20 + 12 + 12 + 7 + 1 + 1 from rfl, PrivMachine.run_add, PrivMachine.run_add,
    PrivMachine.run_add, PrivMachine.run_add, PrivMachine.run_add]
  exact ⟨by rw [p11, p9, p7, p5, p3, p1], by rw [p12, p10, p8, p6, p4, p2], p13, p14⟩

/-! ## The kernel in the box -/

set_option maxRecDepth 100000 in
/-- Every `ecall` the constant-time checker reaches in exp229's kernel, it reaches knowing
    `t0 = 1`: the kernel calls nothing but HALT. -/
theorem halts_only : Ct.haltsOnly Exp229.kernel Exp229.pub Exp229.heads = true := by decide

/-- The box is a world exp229's proof is about: its own 64 KiB, from `0x80010000`. -/
theorem placed (env : Rv32.Env) : Placed (boxEnv env 0x80010000 0x80020000) 0x80010000#32 :=
  ⟨by decide, by decide, rfl⟩

/-- Where the kernel traps: after boot and its `count op` instructions, the last one its HALT. -/
def atTrap (env : Rv32.Env) (s : PrivMachine) (op : Nat) : PrivMachine :=
  PrivMachine.run env (53 + Exp229.count op) s

/-- Where the monitor parks: the 57 steps of exp236's HALT handler later. -/
def atPark (env : Rv32.Env) (s : PrivMachine) (op : Nat) : PrivMachine :=
  PrivMachine.run env 57 (atTrap env s op)

/-- What the host hears, the whole run: the HALT report, with `a0`, `minstret` and `mcycle`,
    then the exit code. -/
def heard (op : Nat) : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, 0#32⟩,
   ⟨0xc0000004#32, BitVec.ofNat 32 (2 + Exp229.count op)⟩, ⟨0xc0000004#32, BitVec.ofNat 32 (2 + Exp229.count op)⟩,
   ⟨0xc0000008#32, 0#32⟩]

set_option maxHeartbeats 4000000 in
/-- **The remainder behind the wall.** exp236's monitor at `0x80000000` and exp229's kernel
    at `0x80010000`, with p at PRIME, the operation at OPW and `a, b < p` at A and B; the
    machine at reset. Then:

    * after boot and the kernel's `count op` instructions -- the last its `ecall` -- the
      machine is at the trap vector, the cause an `ecall` from U-mode, and R holds
      `spec op a b`;
    * 57 steps later it is in the park loop, in M-mode, every register zero, `a0` too;
    * and from reset to there the host has heard exactly `heard op`: `HALT`, the exit
      code 0, `minstret` and `mcycle` both `2 + count op`, then 0 at the exit word. -/
theorem remainder_behind_the_wall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion)
    {op a b : Nat} (hg : Exp229.Given M0 0x80010000#32 a b) (hop : wordAt M0 0x80010000#32 0x900 = op)
    (ha : a < Exp229.P) (hb : b < Exp229.P) :
    (atTrap env s op).core.pc = 0x80000114#32 ∧ (atTrap env s op).mode = .M ∧
    (atTrap env s op).csrs.mcause = 8#32 ∧
    numAt (atTrap env s op).core.mem 0x80010000#32 0x944 8 = Exp229.spec op a b ∧
    (atPark env s op).core.pc = 0x80000234#32 ∧ (atPark env s op).halted = false ∧
    (atPark env s op).mode = .M ∧ (∀ r, (atPark env s op).core.reg r = 0#32) ∧
    (atPark env s op).io = s.io ++ heard op ∧ (atPark env s op).host = s.host := by
  obtain ⟨hbox, hpc1, hcs1, hmem1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  obtain ⟨io1, host1, mi1, cy1⟩ := boot_ports env M0 s hW hmem hpc hh hm hcs
  obtain ⟨ms0, e0, c0, m0, cy0, hcs1'⟩ := hcs1
  have hcnt : 0 < Exp229.count op := by unfold Exp229.count; split <;> (try split) <;> omega
  have htrap : atTrap env s op = PrivMachine.run env (Exp229.count op - 1 + 1) (PrivMachine.run env 53 s) := by
    rw [atTrap, PrivMachine.run_add, Nat.sub_add_cancel hcnt]
  generalize hs1 : PrivMachine.run env 53 s = s1 at hbox hpc1 hcs1' hmem1 io1 host1 mi1 cy1 htrap
  have hp := placed env
  obtain ⟨c, hrun, hhalt, hnum⟩ :=
    Exp229.field hp (s := s1.core) (op := op) hpc1 (by rw [hmem1]; exact hg) (by rw [hmem1]; exact hop) ha hb
  have hcode1 : CodeAt s1.core.mem 0x80010000#32 Exp229.kernel := by rw [hmem1]; exact hg.code
  have hq := quiet_of_ct hp Exp229.accepted halts_only (by decide) hpc1 hcode1
  have hReg : Region.within ⟨0x80010000, 0x80020000⟩ env.region := by
    rw [henv]; simp only [Region.within, monRegion]; omega
  have hinh : s1.csrs.mcountinhibit = {} := by rw [hcs1']; rfl
  obtain ⟨t1, t2, t3, t4, t5, t6, t7, t8, -, t10, t11, t12, t13, t14, t15⟩ :=
    halt_in_box env hReg (by decide) (Exp229.count op - 1) s1 hbox hinh hrun
      (by rw [Nat.sub_add_cancel hcnt]; exact hhalt) (fun i _ m hm => hq i m hm)
  rw [← htrap] at t1 t2 t3 t4 t5 t8 t10 t11 t12 t13 t14 t15
  generalize hu : atTrap env s op = u at t1 t2 t3 t4 t5 t8 t10 t11 t12 t13 t14 t15
  have hagree : Agree M0 u.core.mem 0x80000000 572 := by
    intro x h1 h2
    rw [t15 x (by omega), hmem1]
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := t10
  rw [hcs1'] at k1 k2 k3 k4 k5 k6 k7 k8 t3
  have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
    csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8
  have hpcu : u.core.pc = 0x80000114#32 := by
    rw [t3]; show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32; decide
  have hS : HState env M0 u := ⟨hW, hagree, henv, t2, t1⟩
  have hc : u.csrs.mcause = 8#32 := t8
  have ht0 : u.core.reg 5#5 = 1#32 := by rw [t4]; exact t6
  have ha0 : u.core.reg 10#5 = 0#32 := by rw [t4]; exact t7
  obtain ⟨q1, -, q3, q4, -, -, -, q8, q9, qh, qi⟩ :=
    monitor_halt env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu hc ht0
  have hpark : atPark env s op = PrivMachine.run env 57 u := by rw [atPark, hu]
  rw [hpark]
  refine ⟨hpcu, t1, hc, by rw [t5]; exact hnum, q1, q3, q4, fun r => ?_, ?_, by rw [qh, t14, host1]⟩
  · by_cases hr : r = 10#5
    · subst hr; rw [q8, ha0]
    · exact q9 r hr
  · rw [qi, t13, io1, ha0, t11, t12, mi1, cy1, heard]
    rw [Nat.sub_add_cancel hcnt, BitVec.ofNat_add]

end Exp247
#print axioms Exp229.field
#print axioms Exp236.monitor_boot
#print axioms Exp236.monitor_halt
#print axioms Rv32.Ct.ecalls_halt
#print axioms Rv32.Join.run_in_box
#print axioms Rv32.Join.halt_in_box
#print axioms Rv32.Join.quiet_of_ct
#print axioms Exp247.boot_ports
#print axioms Exp247.halts_only
#print axioms Exp247.remainder_behind_the_wall
