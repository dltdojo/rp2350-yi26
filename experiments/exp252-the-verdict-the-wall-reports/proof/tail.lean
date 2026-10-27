/-! # exp252 — the verdict the wall reports

exp228 proved its kernel's verdict in Tier 1, for every world. exp251 read the same run in a world that does not
serve `HASH`: every `ecall` is `HALT`, or `HASHB` or `CHECKSIG` with its ranges in the box. exp238 proved what its
monitor does with each of those, in Tier 2, with a host that writes back. This joins them, one Tier 1 step at a time:

  * a plain step is one Tier 2 step (lean/Rv32/Join.lean's `plain_in_box`), from a core alike to the Tier 1 one in
    the box -- only there, since the monitor writes its own stack and the ports;
  * a `HASHB` or a `CHECKSIG` is the trap, exp238's served call and its way back, and leaves the two alike, given a host
    that writes `env.hash` of what it is asked to hash and answers `env.sig` of what it is asked to check;
  * the `HALT` is the trap and exp238's HALT: the monitor parks with the kernel's `a0`, the verdict.

`env.hash` and `env.sig` name the host's two functions. Tier 2 never reads them: a U-mode `ecall` traps before it
is executed, and the monitor makes none. -/

namespace Exp252
open Rv32 Rv32.Priv Rv32.Refinement Rv32.Join Exp238

/-- The kernel's base, the box, and the kernel's world: Tier 1, the box its region. -/
abbrev base : Word := 0x80010000#32
abbrev box : Region := ⟨0x80010000, 0x80020000⟩
def kenv (env : Rv32.Env) : Rv32.Env := boxEnv env 0x80010000 0x80020000

/-- **The host hashes what it is asked to.** Asked for `HASHB` of `a1` bytes at `a0`, it writes `env.hash` of them. -/
def HostHashes (env : Rv32.Env) (s : PrivMachine) : Prop :=
  ∀ io a0 a1 a2 M, s.digest (io ++ [⟨0xc0000010#32, a0⟩, ⟨0xc0000014#32, a1⟩, ⟨0xc0000018#32, a2⟩,
    ⟨0xc000001c#32, 2#32⟩]) M = env.hash (readBytes M a0 a1.toNat)

/-- **The host checks what it is asked to.** Asked for `CHECKSIG` of the 32 bytes at `a0` and the 64 at `a1`, it
answers 1 if `env.sig` says so, and 0. -/
def HostChecks (env : Rv32.Env) (s : PrivMachine) : Prop :=
  ∀ io a0 a1 M, s.host (io ++ [⟨0xc0000010#32, a0⟩, ⟨0xc0000014#32, a1⟩, ⟨0xc000001c#32, 3#32⟩]) M 0xc000001c#32 =
    if env.sig (readBytes M a0 32) (readBytes M a1 64) then 1#32 else 0#32

/-- A Tier 2 state running the payload, its core alike in the box to the Tier 1 core `m`. -/
def Sim (M0 : Word → Byte) (t : PrivMachine) (m : Machine) : Prop := Running M0 t ∧ BoxEq box m t.core

/-- A byte of the box is none of the monitor's stack, the ports or the service port. -/
theorem box_not_monitor {x : Word} (h1 : 0x80010000 ≤ x.toNat) (h2 : x.toNat < 0x80020000) :
    ¬ InStack x ∧ ¬ InPorts x ∧ ¬ InSvc x := by
  simp only [InStack, InPorts, InSvc]; omega

/-- Two memories the same on `[a, a + n)` read the same bytes there. -/
theorem readBytes_box {m m' : Word → Byte} {a : Word} {n : Nat} (ha : 0x80010000 ≤ a.toNat ∧ a.toNat + n ≤ 0x80020000)
    (h : ∀ x : Word, 0x80010000 ≤ x.toNat → x.toNat < 0x80020000 → m x = m' x) :
    readBytes m a n = readBytes m' a n := by
  apply readBytes_congr
  intro d hd
  have : (a + BitVec.ofNat 32 d).toNat = a.toNat + d := by
    have := a.isLt
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat]; omega
  exact h _ (by omega) (by omega)

/-! ## The trap -/

set_option maxHeartbeats 4000000 in
/-- At a Tier 1 `ecall`, Tier 2 traps: one step to the trap vector, in M-mode, cause 8, `mepc` the `ecall`'s,
`mpp` U-mode, the kernel's registers and memory, the CSRs boot set. -/
theorem at_trap (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode)
    (henv : env.region = monRegion) {t : PrivMachine} {m : Machine} (hS : Sim M0 t m)
    (hd : decode (fetched m) = some .ecall) (hok : box.ok m.pc 4) :
    HState env M0 (PrivMachine.run env 1 t) ∧ (PrivMachine.run env 1 t).core.pc = 0x80000114#32 ∧
    (PrivMachine.run env 1 t).csrs.mstatus.mpp = .U ∧
    (PrivMachine.run env 1 t).csrs = csrsH (PrivMachine.run env 1 t).csrs.mstatus (PrivMachine.run env 1 t).csrs.mepc
      (PrivMachine.run env 1 t).csrs.mcause (PrivMachine.run env 1 t).csrs.minstret (PrivMachine.run env 1 t).csrs.mcycle
      {} 0x80008000#32 ∧
    (PrivMachine.run env 1 t).csrs.mcause = 8#32 ∧ (PrivMachine.run env 1 t).csrs.mepc = m.pc ∧
    (PrivMachine.run env 1 t).core.mem = t.core.mem ∧ (∀ r, (PrivMachine.run env 1 t).core.reg r = m.reg r) ∧
    (PrivMachine.run env 1 t).io = t.io := by
  obtain ⟨⟨hBox, hag, ms0, e0, c0, mi0, cy0, hcs0⟩, hEq⟩ := hS
  have hf : fetched m = fetched t.core := fetched_boxEq (by decide) hEq hok
  have hin : 0x80010000 ≤ t.core.pc.toNat ∧ t.core.pc.toNat + 4 ≤ 0x80020000 := by rw [← hEq.pc]; exact hok
  have h1 : PrivMachine.run env 1 t = raiseTrap t CAUSE_ECALL_UMODE := by
    rw [run_succ_step env 0 t hBox.notHalted]; exact ecall_trap env t hBox (hf ▸ hd) hin
  rw [h1]
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := kept_trap t CAUSE_ECALL_UMODE
  rw [hcs0] at k1 k2 k3 k4 k5 k6 k7 k8
  refine ⟨⟨hW, hag, henv, hBox.notHalted, rfl⟩, ?_, ?_, csrs_eq_csrsH _ k1 k2 k3 k4 k5 k6 k7 k8, rfl, ?_, rfl,
    fun r => (hEq.regs r).symm, rfl⟩
  · simp only [raiseTrap]; rw [hcs0]; show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32; decide
  · simp [raiseTrap, bumpCounters, hBox.isUMode]
  · simp only [raiseTrap, bumpCounters]; rw [hEq.pc]

/-! ## One Tier 1 step -/

set_option maxHeartbeats 4000000 in
/-- **A plain step.** -/
theorem sim_plain (env : Rv32.Env) (M0 : Word → Byte) (henv : env.region = monRegion) {t : PrivMachine}
    {m m' : Machine} (hS : Sim M0 t m) (hs : step (kenv env) m = .running m')
    (he : decode (fetched m) ≠ some .ecall) : Sim M0 (PrivMachine.run env 1 t) m' := by
  obtain ⟨⟨hBox, hag, ms0, e0, c0, mi0, cy0, hcs0⟩, hEq⟩ := hS
  have hReg : Region.within ⟨0x80010000, 0x80020000⟩ env.region := by
    rw [henv]; simp only [Region.within, monRegion]; omega
  have hinh : t.csrs.mcountinhibit = {} := by rw [hcs0]; rfl
  obtain ⟨r1, r2, r3, -, -, -, r7⟩ := plain_in_box env hReg (by decide) t hBox hinh hEq hs he
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := r3
  rw [hcs0] at k1 k2 k3 k4 k5 k6 k7 k8
  refine ⟨⟨r2, fun x h1 h2 => ?_, _, _, _, _, _, csrs_eq_csrsH _ k1 k2 k3 k4 k5 k6 k7 k8⟩, r1⟩
  rw [r7 x (by omega)]; exact hag x h1 h2

set_option maxHeartbeats 8000000 in
/-- **A `HASHB`.** The trap, exp238's served call and its way back, 44 steps: the core alike to the one Tier 1's
`HASHB` leaves, the host's 32 bytes `env.hash` of the input, as Tier 1's are. -/
theorem sim_hashb (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode)
    (henv : env.region = monRegion) {t : PrivMachine} {m m' : Machine} (hS : Sim M0 t m) (hH : HostHashes env t)
    (hs : step (kenv env) m = .running m') (hd : decode (fetched m) = some .ecall) (h2 : m.reg T0 = 2)
    (hin : 0x80010000 ≤ (m.reg A0).toNat ∧ (m.reg A0).toNat + (m.reg A1).toNat ≤ 0x80020000)
    (hout : 0x80010000 ≤ (m.reg A2).toNat ∧ (m.reg A2).toNat + 32 ≤ 0x80020000) :
    Sim M0 (PrivMachine.run env 44 t) m' := by
  obtain ⟨hal, hok⟩ := fetch_ok_of_running hs
  have hEq := hS.2
  obtain ⟨hSu, hpcu, hmpp, hcsu, hcau, hepc, hmemu, hregu, -⟩ := at_trap env M0 hW henv hS hd hok
  generalize hu : PrivMachine.run env 1 t = u at hSu hpcu hmpp hcsu hcau hepc hmemu hregu
  have hdu : u.digest = t.digest := by rw [← hu]; exact (run_host_digest env 1 t).2
  have e5 : u.core.reg 5#5 = 2#32 := by rw [hregu]; exact h2
  have e10 : u.core.reg 10#5 = m.reg A0 := hregu 10#5
  have e11 : u.core.reg 11#5 = m.reg A1 := hregu 11#5
  have e12 : u.core.reg 12#5 = m.reg A2 := hregu 12#5
  obtain ⟨q1, q2, q3, q4, q5, -, -, -, -, -, -, -, -, -, -, qA, q14, q15⟩ :=
    monitor_hashb_ok env M0 u hSu u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
      hpcu hcsu hcau e5 (by rw [e10, e11]; exact hin) (by rw [e12]; exact hout) hmpp
  have hall : PrivMachine.run env 44 t = PrivMachine.run env 43 u := by
    rw [← hu, ← PrivMachine.run_add]
  rw [hall]
  -- what Tier 1's HASHB did
  have hm' : m' = ({ m with mem := writeBytes m.mem (m.reg A2) ((kenv env).hash (readBytes m.mem (m.reg A0) (m.reg A1).toNat)) } : Machine).next := by
    rw [step_at_ecall hal hok hd, exec_hashb (env := kenv env) h2 hin hout] at hs
    cases hs; rfl
  subst hm'
  refine ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, ?_, fun r => ?_, fun x h1 h2 => ?_⟩
  · rw [q1, hepc]; rfl
  · rw [q15 r]; simp only [regsUpd]; rw [hregu]; rfl
  · obtain ⟨n1, n2, n3⟩ := box_not_monitor h1 h2
    rw [q14 x n1 n2 n3, hdu, hH, hmemu, e10, e11, e12]
    have hrb : readBytes (PrivMachine.run env 31 u).core.mem (m.reg A0) (m.reg A1).toNat =
        readBytes m.mem (m.reg A0) (m.reg A1).toNat := by
      apply readBytes_box hin
      intro y y1 y2
      obtain ⟨o1, o2, o3⟩ := box_not_monitor y1 y2
      rw [qA y o1 o2 o3, hmemu]; exact (hEq.mem y y1 y2).symm
    rw [hrb]
    simp only [Machine.next, Machine.setPc, Rv32.writeBytes, kenv, boxEnv]
    split
    · rfl
    · exact hEq.mem x h1 h2

set_option maxHeartbeats 8000000 in
/-- **A `CHECKSIG`.** The trap, exp238's served call and its way back, 48 steps: the core alike to the one Tier 1's
`CHECKSIG` leaves, `a0` the host's answer, `env.sig`'s, as Tier 1's is. -/
theorem sim_checksig (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode)
    (henv : env.region = monRegion) {t : PrivMachine} {m m' : Machine} (hS : Sim M0 t m) (hC : HostChecks env t)
    (hs : step (kenv env) m = .running m') (hd : decode (fetched m) = some .ecall) (h3 : m.reg T0 = 3)
    (hkey : 0x80010000 ≤ (m.reg A0).toNat ∧ (m.reg A0).toNat + 32 ≤ 0x80020000)
    (hsig : 0x80010000 ≤ (m.reg A1).toNat ∧ (m.reg A1).toNat + 64 ≤ 0x80020000) :
    Sim M0 (PrivMachine.run env 48 t) m' := by
  obtain ⟨hal, hok⟩ := fetch_ok_of_running hs
  have hEq := hS.2
  obtain ⟨hSu, hpcu, hmpp, hcsu, hcau, hepc, hmemu, hregu, -⟩ := at_trap env M0 hW henv hS hd hok
  generalize hu : PrivMachine.run env 1 t = u at hSu hpcu hmpp hcsu hcau hepc hmemu hregu
  have hhu : u.host = t.host := by rw [← hu]; exact (run_host_digest env 1 t).1
  have e5 : u.core.reg 5#5 = 3#32 := by rw [hregu]; exact h3
  have e10 : u.core.reg 10#5 = m.reg A0 := hregu 10#5
  have e11 : u.core.reg 11#5 = m.reg A1 := hregu 11#5
  have hrb : ∀ M : Word → Byte, Frame u.core.mem M → ∀ (a : Word) (n : Nat),
      0x80010000 ≤ a.toNat ∧ a.toNat + n ≤ 0x80020000 → readBytes M a n = readBytes m.mem a n := by
    intro M hM a n ha
    apply readBytes_box ha
    intro y y1 y2
    obtain ⟨o1, o2, o3⟩ := box_not_monitor y1 y2
    rw [hM y o1 o2 o3, hmemu]; exact (hEq.mem y y1 y2).symm
  obtain ⟨-, -, -, -, -, -, -, -, -, -, -, -, -, -, -, hA34, -⟩ :=
    monitor_checksig_ask env M0 u hSu u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
      hpcu hcsu hcau e5 (by rw [e10]; exact hkey) (by rw [e11]; exact hsig)
  have hans : BitVec.ult 1#32 (u.host (u.io ++ [⟨0xc0000010#32, u.core.reg 10#5⟩, ⟨0xc0000014#32, u.core.reg 11#5⟩,
      ⟨0xc000001c#32, 3#32⟩]) (PrivMachine.run env 34 u).core.mem 0xc000001c#32) = false := by
    rw [hhu, hC]; split <;> decide
  obtain ⟨q1, q2, q3, q4, q5, -, -, -, -, -, -, -, -, -, -, -, q14, q15⟩ :=
    monitor_checksig_ok env M0 u hSu u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle
      hpcu hcsu hcau e5 (by rw [e10]; exact hkey) (by rw [e11]; exact hsig) hmpp hans
  have hall : PrivMachine.run env 48 t = PrivMachine.run env 47 u := by
    rw [← hu, ← PrivMachine.run_add]
  rw [hall]
  have hm' : m' = (m.setReg A0 (if (kenv env).sig (readBytes m.mem (m.reg A0) 32) (readBytes m.mem (m.reg A1) 64)
      then 1 else 0)).next := by
    rw [step_at_ecall hal hok hd, exec_checksig (env := kenv env) h3 hkey hsig] at hs
    cases hs; rfl
  subst hm'
  refine ⟨⟨uboxed_of_csrsH q5 q4 q3, q2, _, _, _, _, _, q5⟩, ?_, fun r => ?_, fun x h1 h2 => ?_⟩
  · rw [q1, hepc]; rfl
  · rw [q15 r]
    by_cases hr : r = 10#5
    · subst hr
      have l : ∀ v : Word, (m.setReg A0 v).next.reg 10#5 = v := fun v => by
        simp [Machine.next, Machine.setPc, reg_setReg, A0]
      have r10 : ∀ (f : Reg → Word) (w : Word), regsUpd f [(10, w)] 10#5 = w := fun f w => by simp [regsUpd]
      rw [l, r10, hhu, e10, e11, hC, hrb _ hA34 _ _ hkey, hrb _ hA34 _ _ hsig]
      rfl
    · have hr' : ¬ (10 = r.toNat) := fun h => hr (BitVec.eq_of_toNat_eq (by simpa using h.symm))
      simp [regsUpd, hr', Machine.next, Machine.setPc, reg_setReg, hregu, hr, A0]
  · obtain ⟨n1, n2, n3⟩ := box_not_monitor h1 h2
    rw [q14 x n1 n2 n3, hmemu]
    simp only [Machine.next, Machine.setPc, Machine.setReg]
    exact hEq.mem x h1 h2

set_option maxHeartbeats 8000000 in
/-- **The `HALT`.** The trap and exp238's HALT, 62 steps: the monitor parks with the kernel's `a0`, and the last word
the host hears is it, at the exit word. -/
theorem sim_halt (env : Rv32.Env) (M0 : Word → Byte) (hW : WordsAt M0 0x80000000#32 monitorCode)
    (henv : env.region = monRegion) {t : PrivMachine} {m : Machine} (hS : Sim M0 t m)
    (hd : decode (fetched m) = some .ecall) (h1 : m.reg T0 = 1) (hal : m.pc.toNat % 4 = 0) (hok : box.ok m.pc 4) :
    Parked (PrivMachine.run env 62 t) (m.reg A0) ∧
    (PrivMachine.run env 62 t).io.getLast? = some ⟨0xc0000008#32, m.reg A0⟩ := by
  obtain ⟨hSu, hpcu, -, hcsu, hcau, -, -, hregu, -⟩ := at_trap env M0 hW henv hS hd hok
  generalize hu : PrivMachine.run env 1 t = u at hSu hpcu hcsu hcau hregu
  have e5 : u.core.reg 5#5 = 1#32 := by rw [hregu]; exact h1
  obtain ⟨q1, -, q3, q4, q5, -, qi, q6, q7, q8, q9, -, -, q12⟩ :=
    monitor_halt env M0 u hSu u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu hcau e5
  have hall : PrivMachine.run env 62 t = PrivMachine.run env 61 u := by
    rw [← hu, ← PrivMachine.run_add]
  rw [hall, ← hregu A0]
  exact ⟨parked_halt q1 q3 q4 q5 q6 q7 q8 q9 q12, by rw [qi]; simp; rfl⟩

/-! ## The whole run -/

set_option maxHeartbeats 8000000 in
/-- **The verdict the wall reports.** exp238's monitor at `0x80000000`, exp228's kernel at `0x80010000` with its
table, a script and a stack as `Input` describes them; the machine at reset; a world whose shell does not serve
`HASH`, and a host that hashes and checks what it is asked. Then the monitor parks with exit code
`verdict (kenv env) scr st0` -- the specification's, with `env.hash` and `env.sig` -- and the last word the host hears
is that code, at the exit word. -/
theorem verdict_behind_the_wall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion) (hsv : env.servesHash = false)
    {scr : List Byte} {st0 : List Exp228.Elem} (hin : Exp228.Input M0 base scr st0)
    (hH : HostHashes env s) (hC : HostChecks env s) :
    ∃ N, Parked (PrivMachine.run env N s) (BitVec.ofNat 32 (Exp228.verdict (kenv env) scr st0)) ∧
      (PrivMachine.run env N s).io.getLast? =
        some ⟨0xc0000008#32, BitVec.ofNat 32 (Exp228.verdict (kenv env) scr st0)⟩ := by
  obtain ⟨hbox, hpc1, ⟨ms0, e0, c0, m0, cy0, hcs1⟩, hmem1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  generalize hs1 : PrivMachine.run env 53 s = s1 at hbox hpc1 hcs1 hmem1
  have hp : Placed (kenv env) base := ⟨by decide, by decide, rfl⟩
  obtain ⟨k, s', hk, hcalls⟩ := Exp251.calls_the_script_makes hp hsv hin hpc1 hmem1
  obtain ⟨j, hj, mj, hmj, hj1⟩ := Reach.run_halt_step k s1.core hk
  have inbox : ∀ {a : Word} {n : Nat}, Exp251.InBox base a n → 0x80010000 ≤ a.toNat ∧ a.toNat + n ≤ 0x80020000 := by
    intro a n h
    simp only [Exp251.InBox, BitVec.toNat_ofNat] at h
    exact ⟨by omega, by omega⟩
  -- every state up to the halting step has a Tier 2 state alike to it, some steps from reset
  have hhost : ∀ N, HostHashes env (PrivMachine.run env N s) ∧ HostChecks env (PrivMachine.run env N s) := by
    intro N
    obtain ⟨e1, e2⟩ := run_host_digest env N s
    exact ⟨fun io a0 a1 a2 M => by rw [e2]; exact hH io a0 a1 a2 M, fun io a0 a1 M => by rw [e1]; exact hC io a0 a1 M⟩
  have sim : ∀ i, i ≤ j → ∀ mi, run (kenv env) i s1.core = .running mi →
      ∃ N, Sim M0 (PrivMachine.run env N s) mi := by
    intro i
    induction i with
    | zero =>
      intro _ mi hmi
      simp only [run] at hmi
      cases hmi
      refine ⟨53, ?_⟩
      rw [hs1]
      exact ⟨⟨hbox, by rw [hmem1]; exact Agree.refl _ _ _, ms0, e0, c0, m0, cy0, hcs1⟩, BoxEq.refl _ _⟩
    | succ i ih =>
      intro hi mi hmi
      obtain ⟨mp, hmp⟩ := run_running_prefix i 1 s1.core hmi
      obtain ⟨N, hN⟩ := ih (by omega) mp hmp
      have hstep : step (kenv env) mp = .running mi := by
        rw [run_add_running hmp] at hmi
        simp only [run] at hmi
        revert hmi
        cases step (kenv env) mp <;> simp
      by_cases hd : decode (fetched mp) = some .ecall
      · rcases hcalls i (by omega) mp hmp hd with h1 | ⟨h2, a, b⟩ | ⟨h3, a, b⟩
        · exact absurd hstep (step_not_running hd h1)
        · refine ⟨N + 44, ?_⟩
          rw [PrivMachine.run_add]
          exact sim_hashb env M0 hW henv hN (hhost N).1 hstep hd h2 (inbox a) (inbox b)
        · refine ⟨N + 48, ?_⟩
          rw [PrivMachine.run_add]
          exact sim_checksig env M0 hW henv hN (hhost N).2 hstep hd h3 (inbox a) (inbox b)
      · exact ⟨N + 1, by rw [PrivMachine.run_add]; exact sim_plain env M0 henv hN hstep hd⟩
  obtain ⟨N, hN⟩ := sim j (Nat.le_refl _) mj hmj
  have hst : step (kenv env) mj = .halted (BitVec.ofNat 32 (Exp228.verdict (kenv env) scr st0)) s' := by
    rw [run_add_running hmj] at hj1
    simp only [run] at hj1
    revert hj1
    cases step (kenv env) mj <;> simp
  obtain ⟨hd, h1, h0, -, hal, hok⟩ := step_halted hst
  obtain ⟨p1, p2⟩ := sim_halt env M0 hW henv hN hd h1 hal hok
  rw [h0] at p1 p2
  exact ⟨N + 62, by rw [PrivMachine.run_add]; exact p1, by rw [PrivMachine.run_add]; exact p2⟩

end Exp252

#print axioms Exp251.calls_the_script_makes
#print axioms Exp238.monitor_hashb_ok
#print axioms Exp238.monitor_checksig_ok
#print axioms Exp238.monitor_halt
#print axioms Rv32.Join.plain_in_box
#print axioms Exp252.sim_plain
#print axioms Exp252.sim_hashb
#print axioms Exp252.sim_checksig
#print axioms Exp252.sim_halt
#print axioms Exp252.verdict_behind_the_wall
