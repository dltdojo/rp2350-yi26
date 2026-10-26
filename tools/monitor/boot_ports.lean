/-
SPDX-License-Identifier: Apache-2.0

# Boot is silent: exp236's 53 steps of boot, read for the ports and the counters

A fragment, not a file Lean checks on its own: a generator splices it into a proof that has opened the namespace
of a monitor whose boot is exp236's word for word -- exp236's own (exp247), exp239's (exp250) -- and that namespace's
`monitorCode`, `sm_mon`, `csrsConfigured`, `csrsReady`, `Cleared`, `monitor_boot_config` and `monitor_launch_1` to
`_4`. Each theorem runs the same steps as the monitor's own boot theorems, for the fields those leave out: no word
to a port, nothing asked of the host, both counters at 2 after the `mret`.
-/

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

