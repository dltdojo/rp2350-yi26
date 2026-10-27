/-! # exp250 — exp223's kernel, behind exp239's wall

exp223 proved what its kernel's run ends with, in a 128 KiB world of its own. exp248 and exp249 proved what every
step of it touches: the front reads only the samples and writes nothing up to SHA-256; SHA-256 stores only into its
digest, H, schedule and padding block. exp239 proved what its monitor does from reset to the payload and from the
trap vector to the park, with the payload's memory scrubbed. This joins them, from reset to the park:

  * the front's steps and SHA-256's, as one run in exp239's 64 KiB box: `kernel_reach`;
  * that run the same as the one exp223 proved, in its 128 KiB world: `kernel_same`, on lean/Rv32/Reach.lean's
    `run_same`, since no step asks the larger world for anything the box would refuse;
  * the HALT that ends it, the trap exp239's handler is proved from: lean/Rv32/Join.lean's `halt_in_box`;
  * and the monitor's park, with the digest kept or the scratch scrubbed.

The kernel's run is the same for healthy samples and for unhealthy ones; what differs is where it ends. -/

namespace Exp250
open Rv32 Rv32.Priv Rv32.Refinement Rv32.Join Rv32.Reach Exp239

/-! ## Boot is silent -/

-- SPLICE: tools/monitor/boot_ports.lean

/-! ## The kernel's run in the box -/

/-- The payload's box: Tier 1 with exp239's PMP entry as its region. -/
def boxE (env : Rv32.Env) : Rv32.Env := boxEnv env 0x80010000 0x80020000

/-- exp223's world: 128 KiB from the payload's base. -/
def wideE (env : Rv32.Env) : Rv32.Env := { env with region := ⟨0x80010000, 0x80030000⟩ }

/-- The kernel's base, and SHA-256's within it. -/
abbrev base : Word := 0x80010000#32
abbrev shaBase : Word := 0x80010000#32 + BitVec.ofNat 32 0x1000

theorem wide (env : Rv32.Env) : Wide (wideE env) base := ⟨by decide, by decide, rfl⟩

theorem host_front (env : Rv32.Env) : Ct.Hosted (boxE env) base Exp223.kernel.length :=
  ⟨by decide, by decide, by simp only [boxE, boxEnv, Exp223.kernel_length]; decide⟩

theorem host_sha (env : Rv32.Env) : Ct.Hosted (boxE env) shaBase Sha.kernel.length :=
  ⟨by decide, by decide, by simp only [boxE, boxEnv, Sha.kernel_length]; decide⟩

/-- A step of the kernel's run: the front's, as exp248 checked it, or SHA-256's, as exp249 did. -/
def G (env : Rv32.Env) (m : Machine) : Prop :=
  Good (boxE env) base Exp223.kernel Exp248.samples Exp248.nowhere m ∨
  Good (boxE env) shaBase Sha.kernel Exp249.loads Exp249.stores m

/-- **Every step of exp223's kernel, in the box.** From its first word, the kernel and SHA-256 in memory and the
length word 4096: every state of the run is one the front's checker vouches for, or -- once the run has reached
SHA-256's first word -- one SHA-256's does. -/
theorem kernel_reach (env : Rv32.Env) {s : Machine} (hpc : s.pc = base) (hfront : CodeAt s.mem base Exp223.kernel)
    (hsha : CodeAt s.mem shaBase Sha.kernel) (hlen : readLE s.mem (shaBase + BitVec.ofNat 32 0x1120) 4 = 4096) :
    ∀ n m, run (boxE env) n s = .running m → G env m := by
  intro n m hm
  rcases Exp248.front_reach (host_front env) hpc hfront n with hall | ⟨j, hj, mj, hmj, hpcj, hmemj, -⟩
  · exact Or.inl (hall n (Nat.le_refl _) m hm).1
  · have e : run (boxE env) (j + (n - j)) s = run (boxE env) (n - j) mj := run_add_running hmj
    rw [Nat.add_sub_cancel' hj] at e
    rw [e] at hm
    exact Or.inr (Exp249.sha_reach (host_sha env) hpcj (by rw [hmemj]; exact hsha) (by rw [hmemj]; exact hlen)
      _ m hm).1

theorem box_within (env : Rv32.Env) : (boxE env).region.within (wideE env).region := by
  simp only [boxE, boxEnv, wideE, Region.within]; omega

/-- **The run exp223 proved is the run in the box.** In exp223's 128 KiB world and in the box, the kernel takes the
same steps: every one of them is one the checkers vouch for, inside the box. -/
theorem kernel_same (env : Rv32.Env) {s : Machine} (hpc : s.pc = base) (hfront : CodeAt s.mem base Exp223.kernel)
    (hsha : CodeAt s.mem shaBase Sha.kernel) (hlen : readLE s.mem (shaBase + BitVec.ofNat 32 0x1120) 4 = 4096) :
    ∀ N, run (wideE env) N s = run (boxE env) N s := fun N =>
  run_same (env := boxE env) (env' := wideE env) (G env)
    (fun m hg => hg.elim
      (fun h => step_same (env := boxE env) (env' := wideE env) ⟨rfl, rfl, rfl⟩ (box_within env) (host_front env) (by rw [Exp223.kernel_length]; decide)
        (by simp only [WinIn, boxE, boxEnv, Exp248.samples]; decide)
        (by simp only [WinIn, boxE, boxEnv, Exp248.nowhere]; decide) (by decide) (by decide) h)
      (fun h => step_same (env := boxE env) (env' := wideE env) ⟨rfl, rfl, rfl⟩ (box_within env) (host_sha env) (by rw [Sha.kernel_length]; decide)
        (by simp only [WinIn, boxE, boxEnv, Exp249.loads]; decide)
        (by simp only [WinIn, boxE, boxEnv, Exp249.stores]; decide) (by decide) (by decide) h))
    N s (fun i _ m hm => kernel_reach env hpc hfront hsha hlen i m hm)

/-! ## Reset to park -/

/-- Where the kernel traps: after boot and its `j + 1` steps, the last its HALT. -/
def trapAt (env : Rv32.Env) (s : PrivMachine) (j : Nat) : PrivMachine := PrivMachine.run env (53 + (j + 1)) s

/-- What the host hears, the whole run: the HALT report -- the tag, `a0`, then `minstret` and `mcycle`, both `3 + j`
-- and `a0` to the exit word. -/
def heard (a0 : Word) (j : Nat) : List IoEvent :=
  [⟨0xc0000004#32, 0x48414c54#32⟩, ⟨0xc0000004#32, a0⟩, ⟨0xc0000004#32, BitVec.ofNat 32 (3 + j)⟩,
   ⟨0xc0000004#32, BitVec.ofNat 32 (3 + j)⟩, ⟨0xc0000008#32, a0⟩]

set_option maxHeartbeats 4000000 in
/-- **Behind the wall, whatever the kernel ends with.** exp239's monitor and exp223's kernel loaded; the machine at
reset. If exp223's run, in its own world, halts with `code` within `N` steps, then after boot the kernel traps at
some `j + 1 ≤ N`: at the trap vector, an `ecall` from U-mode, memory as the kernel's HALT left it. From there the
monitor parks with `code`, memory scrubbed as exp239 says, the host having heard exactly `heard code j`. -/
theorem behind (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion)
    (hfront : CodeAt M0 base Exp223.kernel) (hsha : CodeAt M0 shaBase Sha.kernel)
    (hlen : readLE M0 (shaBase + BitVec.ofNat 32 0x1120) 4 = 4096)
    {N : Nat} {code : Word} {s' : Machine}
    (hrun : run (wideE env) N (PrivMachine.run env 53 s).core = .halted code s') :
    ∃ j, j < N ∧
      (trapAt env s j).core.pc = 0x80000114#32 ∧ (trapAt env s j).mode = .M ∧
      (trapAt env s j).csrs.mcause = 8#32 ∧ (trapAt env s j).core.mem = s'.mem ∧
      ∃ N', Parked (PrivMachine.run env N' (trapAt env s j)) code ∧
        Scrubbed code s'.mem (PrivMachine.run env N' (trapAt env s j)).core.mem ∧
        (PrivMachine.run env N' (trapAt env s j)).io = s.io ++ heard code j ∧
        (PrivMachine.run env N' (trapAt env s j)).host = s.host := by
  obtain ⟨hbox, hpc1, hcs1, hmem1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  obtain ⟨io1, host1, mi1, cy1⟩ := boot_ports env M0 s hW hmem hpc hh hm hcs
  obtain ⟨ms0, e0, c0, m0, cy0, hcs1'⟩ := hcs1
  have htrap : ∀ j, trapAt env s j = PrivMachine.run env (j + 1) (PrivMachine.run env 53 s) := fun j => by
    rw [trapAt, PrivMachine.run_add]
  generalize hs1 : PrivMachine.run env 53 s = s1 at hbox hpc1 hcs1' hmem1 io1 host1 mi1 cy1 hrun htrap
  have hf1 : CodeAt s1.core.mem base Exp223.kernel := by rw [hmem1]; exact hfront
  have hs1' : CodeAt s1.core.mem shaBase Sha.kernel := by rw [hmem1]; exact hsha
  have hl1 : readLE s1.core.mem (shaBase + BitVec.ofNat 32 0x1120) 4 = 4096 := by rw [hmem1]; exact hlen
  rw [kernel_same env hpc1 hf1 hs1' hl1] at hrun
  obtain ⟨j, hj, c, hc, hh'⟩ := run_halt_step N s1.core hrun
  have hstep : step (boxE env) c = .halted code s' := by
    have e := hh'
    rw [run_add_running hc] at e
    simp only [run] at e
    revert e
    cases step (boxE env) c <;> simp
  obtain ⟨-, -, -, hsc, -, -⟩ := step_halted hstep
  subst hsc
  have hReg : Region.within ⟨0x80010000, 0x80020000⟩ env.region := by
    rw [henv]; simp only [Region.within, monRegion]; omega
  have hinh : s1.csrs.mcountinhibit = {} := by rw [hcs1']; rfl
  have hq : ∀ i < j, ∀ m, run (boxEnv env 0x80010000 0x80020000) i s1.core = .running m →
      decode (fetched m) = some .ecall → m.reg T0 = 1 :=
    fun i _ m hm => (kernel_reach env hpc1 hf1 hs1' hl1 i m hm).elim quiet_of_good quiet_of_good
  obtain ⟨t1, t2, t3, t4, t5, t6, t7, t8, -, t10, t11, t12, t13, t14, t15⟩ :=
    halt_in_box env hReg (by decide) j s1 hbox hinh hc hh' hq
  rw [← htrap j] at t1 t2 t3 t4 t5 t8 t10 t11 t12 t13 t14 t15
  refine ⟨j, hj, ?_⟩
  generalize hu : trapAt env s j = u at t1 t2 t3 t4 t5 t8 t10 t11 t12 t13 t14 t15 ⊢
  have hagree : Agree M0 u.core.mem 0x80000000 624 := by
    intro x h1 h2
    rw [t15 x (by omega), hmem1]
  obtain ⟨k1, k2, k3, k4, k5, k6, k7, k8⟩ := t10
  rw [hcs1'] at k1 k2 k3 k4 k5 k6 k7 k8 t3
  have hcsu : u.csrs = csrsH u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle {} 0x80008000#32 :=
    csrs_eq_csrsH u.csrs k1 k2 k3 k4 k5 k6 k7 k8
  have hpcu : u.core.pc = 0x80000114#32 := by
    rw [t3]; show (0x80000114#32 &&& ~~~3#32) = 0x80000114#32; decide
  have hS : HState env M0 u := ⟨hW, hagree, henv, t2, t1⟩
  obtain ⟨N', hP, -, hSc, hhost, hio⟩ :=
    monitor_scrubs env M0 u hS u.csrs.mstatus u.csrs.mepc u.csrs.mcause u.csrs.minstret u.csrs.mcycle hpcu hcsu
  have hc8 : u.csrs.mcause = 8#32 := t8
  have h5 : u.core.reg 5#5 = 1#32 := by rw [t4]; exact t6
  have h10 : u.core.reg 10#5 = code := by rw [t4]; exact t7
  have hex : exitCode u = code := by simp only [exitCode, hc8, h5, h10, and_self, ↓reduceIte]
  rw [hex] at hP hSc
  refine ⟨hpcu, t1, hc8, t5, N', hP, by rw [← t5]; exact hSc, ?_, by rw [hhost, t14, host1]⟩
  rw [hio, t13, io1]
  simp only [trapIo, hc8, h5, and_self, ↓reduceIte, haltIo, h10, t11, t12, mi1, cy1, hex, heard, List.cons_append,
    List.nil_append]
  have e : 2#32 + BitVec.ofNat 32 (j + 1) = BitVec.ofNat 32 (3 + j) := by
    apply BitVec.eq_of_toNat_eq
    simp only [BitVec.toNat_add, BitVec.toNat_ofNat]
    omega
  rw [e]

/-- The 32 bytes from `base + 0x2140` are the digest window. -/
theorem in_digest {d : Nat} (hd : d < 32) :
    InDigest (base + BitVec.ofNat 32 Exp223.DIGEST + BitVec.ofNat 32 d) := by
  simp only [InDigest, Exp223.DIGEST, BitVec.toNat_add, BitVec.toNat_ofNat]
  omega

/-- exp223's length hypothesis, a word, read as the number the checker's `Pub.consts` asks for. -/
theorem len_word (M0 : Word → Byte) (hlen : Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x120)) = 4096) :
    readLE M0 (shaBase + BitVec.ofNat 32 0x1120) 4 = 4096 := by
  have h : (Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x120))).toNat = 4096 := by rw [hlen]; rfl
  simp only [Sha.wordAt, BitVec.toNat_ofNat] at h
  have := readLE_four_lt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x120))
  rw [show shaBase + BitVec.ofNat 32 0x1120 = base + BitVec.ofNat 32 (Exp223.DATA + 0x120) by decide]
  omega

set_option maxHeartbeats 4000000 in
/-- **The digest the wall keeps.** exp239's monitor at `0x80000000`, exp223's kernel at `0x80010000` with K, IV,
the length 4096 and 1024 samples that pass both health tests; the machine at reset. Then the kernel traps after
boot and at most 334284 steps, at the trap vector, an `ecall` from U-mode, with SHA-256 of the samples at
`+0x2140`; and the monitor parks with exit code 0, that digest still there, the confidential scratch -- the
schedule and the samples -- zero, the host having heard exactly `heard 0 j`. -/
theorem digest_behind_the_wall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion)
    (hfront : CodeAt M0 base Exp223.kernel) (hsha : CodeAt M0 (base + BitVec.ofNat 32 Exp223.SHA) Sha.kernel)
    (hK : ∀ t < 64, Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 4 * t)) = Sha.K.getD t 0)
    (hIV : ∀ j < 8, Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x100 + 4 * j)) = Sha.IV.getD j 0)
    (hlen : Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x120)) = 4096)
    (hy : Exp223.Healthy M0 base) :
    ∃ j, j < 334284 ∧
      (trapAt env s j).core.pc = 0x80000114#32 ∧ (trapAt env s j).csrs.mcause = 8#32 ∧
      readBytes (trapAt env s j).core.mem (base + BitVec.ofNat 32 Exp223.DIGEST) 32 = Sha.sha256 (Exp223.samples M0 base) ∧
      ∃ N, Parked (PrivMachine.run env N (trapAt env s j)) 0#32 ∧
        readBytes (PrivMachine.run env N (trapAt env s j)).core.mem (base + BitVec.ofNat 32 Exp223.DIGEST) 32 =
          Sha.sha256 (Exp223.samples M0 base) ∧
        (∀ x, InConf x → (PrivMachine.run env N (trapAt env s j)).core.mem x = 0) ∧
        (PrivMachine.run env N (trapAt env s j)).io = s.io ++ heard 0#32 j ∧
        (PrivMachine.run env N (trapAt env s j)).host = s.host := by
  obtain ⟨-, hpc1, -, hmem1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  have hlen' := len_word M0 hlen
  obtain ⟨-, hyes⟩ := Exp223.conditions (wide env) (PrivMachine.run env 53 s).core hpc1
    (by rw [hmem1]; exact hfront) (by rw [hmem1]; exact hsha) (by rw [hmem1]; exact hK)
    (by rw [hmem1]; exact hIV) (by rw [hmem1]; exact hlen)
  obtain ⟨s', hrun, hdig, -⟩ := hyes (by rw [hmem1]; exact hy)
  rw [hmem1] at hdig
  obtain ⟨j, hj, p1, -, p3, p4, N, hP, hSc, hio, hhost⟩ :=
    behind env M0 s hW hmem hpc hh hm hcs henv hfront hsha hlen' hrun
  refine ⟨j, hj, p1, p3, by rw [p4]; exact hdig, N, hP, ?_, hSc.1, hio, hhost⟩
  rw [← hdig]
  apply readBytes_congr
  intro d hd
  rw [hSc.2.1 _ (in_digest hd)]
  simp

set_option maxHeartbeats 4000000 in
/-- **No digest gets out.** The same, with samples that fail a health test: the kernel traps after boot and at most
17425 steps, and the monitor parks with exit code 1, the confidential scratch and the digest window both zero,
every other byte but the monitor's own stack and report words as it was at reset, the host having heard exactly
`heard 1 j`. -/
theorem no_digest_behind_the_wall (env : Rv32.Env) (M0 : Word → Byte) (s : PrivMachine)
    (hW : WordsAt M0 0x80000000#32 monitorCode) (hmem : s.core.mem = M0)
    (hpc : s.core.pc = 0x80000040#32) (hh : s.halted = false) (hm : s.mode = .M)
    (hcs : s.csrs = {}) (henv : env.region = monRegion)
    (hfront : CodeAt M0 base Exp223.kernel) (hsha : CodeAt M0 (base + BitVec.ofNat 32 Exp223.SHA) Sha.kernel)
    (hK : ∀ t < 64, Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 4 * t)) = Sha.K.getD t 0)
    (hIV : ∀ j < 8, Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x100 + 4 * j)) = Sha.IV.getD j 0)
    (hlen : Sha.wordAt M0 (base + BitVec.ofNat 32 (Exp223.DATA + 0x120)) = 4096)
    (hn : ¬ Exp223.Healthy M0 base) :
    ∃ j, j < 17425 ∧
      (trapAt env s j).core.pc = 0x80000114#32 ∧ (trapAt env s j).csrs.mcause = 8#32 ∧
      ∃ N, Parked (PrivMachine.run env N (trapAt env s j)) 1#32 ∧
        (∀ x, InConf x ∨ InDigest x → (PrivMachine.run env N (trapAt env s j)).core.mem x = 0) ∧
        (∀ x, ¬ InConf x → ¬ InDigest x → ¬ InStack x → ¬ InPorts x →
          (PrivMachine.run env N (trapAt env s j)).core.mem x = M0 x) ∧
        (PrivMachine.run env N (trapAt env s j)).io = s.io ++ heard 1#32 j ∧
        (PrivMachine.run env N (trapAt env s j)).host = s.host := by
  obtain ⟨-, hpc1, -, hmem1, -⟩ := monitor_boot env M0 s hW hmem hpc hh hm hcs
  have hlen' := len_word M0 hlen
  obtain ⟨hno, -⟩ := Exp223.conditions (wide env) (PrivMachine.run env 53 s).core hpc1
    (by rw [hmem1]; exact hfront) (by rw [hmem1]; exact hsha) (by rw [hmem1]; exact hK)
    (by rw [hmem1]; exact hIV) (by rw [hmem1]; exact hlen)
  obtain ⟨s', hrun, hsm⟩ := hno (by rw [hmem1]; exact hn)
  rw [hmem1] at hsm
  obtain ⟨j, hj, p1, -, p3, -, N, hP, ⟨hconf, hdig, hrest⟩, hio, hhost⟩ :=
    behind env M0 s hW hmem hpc hh hm hcs henv hfront hsha hlen' hrun
  refine ⟨j, hj, p1, p3, N, hP, ?_, ?_, hio, hhost⟩
  · rintro x (hx | hx)
    · exact hconf x hx
    · rw [hdig x hx]; simp
  · intro x h1 h2 h3 h4
    rw [hrest x h1 h2 h3 h4, hsm]

end Exp250

#print axioms Rv32.Reach.step_same
#print axioms Rv32.Reach.run_same
#print axioms Rv32.Reach.run_halt_step
#print axioms Rv32.Join.quiet_of_good
#print axioms Rv32.Join.halt_in_box
#print axioms Exp223.conditions
#print axioms Exp248.front_reach
#print axioms Exp249.sha_reach
#print axioms Exp239.monitor_scrubs
#print axioms Exp250.boot_ports
#print axioms Exp250.kernel_reach
#print axioms Exp250.kernel_same
#print axioms Exp250.behind
#print axioms Exp250.digest_behind_the_wall
#print axioms Exp250.no_digest_behind_the_wall
