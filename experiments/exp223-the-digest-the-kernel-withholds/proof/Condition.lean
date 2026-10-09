/-
SPDX-License-Identifier: Apache-2.0

# exp223 — the digest the kernel withholds

exp222's two SP 800-90B health tests, then exp208's SHA-256 over the same
samples, as one kernel: one entry, one run, one halt. The digest exists only
if the samples passed, and it is SHA-256 of exactly the samples the tests
judged.

  0x0000  the front, 34 instructions:
            0      auipc s0, 0
            1-2    s1 = base + 0x3000          the samples
            3-29   the tests: lean/Rv32/Health.lean's `front`
            30     beq s6, x0 → 0x1000         healthy: on to SHA-256
            31-33  HALT 1
  0x1000  exp208's SHA-256 kernel, its 1008 bytes unchanged
  0x2000  K, IV and the length (4096), as exp208's kernel reads them
  0x2140  the digest, written; 0x2200 to 0x2440 its scratch
  0x3000  the samples: 1024 words, one sample each in bit 0 — and, as they
          are, the 4096 bytes SHA-256 is computed over

Each half is proved where it was proved before: the tests from their first
instruction in lean/Rv32/Health.lean, SHA-256 in lean/Rv32/Sha.lean, which
`Placed` puts at the start of a 64 KiB region of its own. Here that region
starts at 0x1000, so the kernel's region is 128 KiB, and lean/Rv32/Within.lean
carries each half's run into it.
-/
import Rv32.Health
import Rv32.Within
import Rv32.Sha
import Rv32.Asm

namespace Exp223
open Rv32
open Rv32.Health (S0 S1 S6 T1 front N)

def setup : List Instr := [ .auipc S0 0, .lui T1 3, .op .add S1 S0 T1 ]

def verdict : List Instr := [ .br .beq S6 0 0x7c4 ]

def fail : List Instr := [ .opi .addi A0 0 1, .opi .addi T0 0 1, .ecall ]

/-- The front: where the samples are, the tests, and the branch. -/
def kernel : List Instr := setup ++ front ++ verdict ++ fail

theorem kernel_length : kernel.length = 34 := by decide

def SHA : Nat := 0x1000
def DATA : Nat := 0x2000
def DIGEST : Nat := 0x2140
def SAMPLES : Nat := 0x3000

/-- A word as four bytes, little-endian. -/
def wordBytes (w : Word) : List UInt8 :=
  let n := w.toNat
  [n % 256, n / 256 % 256, n / 65536 % 256, n / 16777216].map UInt8.ofNat

/-- What exp208's kernel reads at its `R`: K, IV, and the message's length. -/
def data : List UInt8 := (Sha.K ++ Sha.IV ++ [4096]).flatMap wordBytes

def bytes : List UInt8 := toBytes kernel

/-- `kernel.bin`: the front, SHA-256 at 0x1000, the data at 0x2000. -/
def image : ByteArray :=
  ⟨(bytes ++ List.replicate (SHA - bytes.length) 0 ++ Sha.bytes
    ++ List.replicate (DATA - SHA - Sha.bytes.length) 0 ++ data).toArray⟩

/-- **Healthy**: neither test fails over the 1024 samples at `base + 0x3000`. -/
abbrev Healthy (m : Word → Byte) (base : Word) : Prop := Health.Healthy m base SAMPLES

/-- The samples as SHA-256 sees them: the 4096 bytes of the 1024 words. -/
def samples (m : Word → Byte) (base : Word) : List Byte := readBytes m (base + BitVec.ofNat 32 SAMPLES) 4096

/-! ## The region: 128 KiB, holding each half's 64 KiB

`Wide` and `low`, the first 64 KiB, are lean/Rv32/Within.lean's. -/

/-- SHA-256's region: the 64 KiB from its first instruction. -/
def env1 (env : Env) (base : Word) : Env := ⟨⟨base.toNat + SHA, base.toNat + SHA + 0x10000⟩, env.hash⟩

variable {env : Env} {base : Word}

theorem sha_toNat (hw : Wide env base) : (base + BitVec.ofNat 32 SHA).toNat = base.toNat + SHA :=
  toNat_off hw.fit64 SHA (by decide)

theorem placed1 (hw : Wide env base) : Placed (env1 env base) (base + BitVec.ofNat 32 SHA) :=
  ⟨by rw [sha_toNat hw]; have := hw.align; simp only [SHA]; omega,
   by rw [sha_toNat hw]; have := hw.fit; simp only [SHA]; omega, by rw [sha_toNat hw]; rfl⟩

theorem within1 (hw : Wide env base) : (env1 env base).region.within env.region := by
  simp only [env1, Region.within, hw.region]; have := hw.fit; simp only [SHA]; omega

theorem halted1 (hw : Wide env base) {n : Nat} {c : Word} {s s' : Machine}
    (h : run (env1 env base) n s = .halted c s') : run env n s = .halted c s' :=
  (run_within (env := env1 env base) (env' := env) rfl (within1 hw) n s).2 c s' h

/-! ## The front -/

/-- Where the kernel has the tests: instruction 3 on. -/
theorem at_front : Health.At kernel 3 := ⟨by decide, by decide, by decide⟩

/-- Three instructions: the samples' pointer. -/
theorem setup_run {e : Env} (hp : Placed e base) (s : Machine) (hpc : s.pc = base)
    (hcode : CodeAt s.mem base kernel) :
    ∃ s', run e 3 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * 3) ∧ s'.mem = s.mem
      ∧ s'.reg S1 = base + BitVec.ofNat 32 SAMPLES := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hcode (by simp [hpc])
      (i := .auipc S0 0) (by decide) rfl
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hcode) p1
      (i := .lui T1 3) (by decide) rfl
  obtain ⟨s3, e3, p3, m3, r3⟩ := regStep (prog := kernel) hp 2 (by decide) (by rw [m2, m1]; exact hcode) p2
      (i := .op .add S1 S0 T1) (by decide) rfl
  refine ⟨s3, ?_, p3, by rw [m3, m2, m1], ?_⟩
  · rw [show 3 = 1 + (1 + 1) by rfl]; exact run_cons e1 (run_cons e2 e3)
  · rw [reg_wrote r3 (by decide)]
    simp only [aluR]; rw [reg_kept r2 (by decide), reg_wrote r1 (by decide), reg_wrote r2 (by decide), hpc]
    simp [SAMPLES]

theorem to_sha (base : Word) :
    base + BitVec.ofNat 32 (4 * 30) + ((0x7c4 : BitVec 12) ++ 0#1).signExtend 32 = base + BitVec.ofNat 32 SHA := by
  rw [BitVec.add_assoc]; congr 1

/-- **The front decides.** Unhealthy: HALT 1 after exactly 17425
instructions, memory untouched. Healthy: 17422 instructions on, the run is at
SHA-256's first instruction, memory untouched. -/
theorem front_decides {e : Env} (hp : Placed e base) (s : Machine) (hpc : s.pc = base)
    (hcode : CodeAt s.mem base kernel) :
    (¬ Healthy s.mem base → ∃ s', run e 17425 s = .halted 1 s' ∧ s'.mem = s.mem) ∧
    (Healthy s.mem base → ∃ s', run e 17422 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 SHA
      ∧ s'.mem = s.mem) := by
  obtain ⟨s3, e3, p3, m3, h1⟩ := setup_run hp s hpc hcode
  have hc3 : CodeAt s3.mem base kernel := by rw [m3]; exact hcode
  obtain ⟨sV, eV, pV, mV, gV, _⟩ := Health.front_run hp at_front (by decide) (by decide) s3 p3 hc3 h1
  rw [m3] at mV gV
  have hcV : CodeAt sV.mem base kernel := by rw [mV]; exact hcode
  have pV' : sV.pc = base + BitVec.ofNat 32 (4 * 30) := pV
  have tk : taken .beq (sV.reg S6) (sV.reg 0) = decide (Healthy s.mem base) := by
    rw [gV, reg_zero]
    by_cases hh : Health.Healthy s.mem base SAMPLES <;> simp [hh, taken, Healthy]
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · have tf : taken .beq (sV.reg S6) (sV.reg 0) = false := by rw [tk]; simp [hn]
    obtain ⟨s1, e1, p1, m1, -⟩ : ∃ s1, run e 1 sV = .running s1 ∧ s1.pc = base + BitVec.ofNat 32 (4 * 31)
        ∧ s1.mem = sV.mem ∧ True :=
      ⟨sV.next, (stepK hp 30 (by decide) hcV pV' (i := .br .beq S6 0 0x7c4) (by decide) (exec_br_not tf) 0).trans
        (run_zero _ _), by rw [next_pc, pV']; exact pc_next hp.fit 30 (by decide), by rw [next_mem], trivial⟩
    have hc1 : CodeAt s1.mem base kernel := by rw [m1]; exact hcV
    obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 31 (by decide) hc1 p1
      (i := .opi .addi A0 0 1) (by decide) rfl
    obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 32 (by decide) (by rw [m2]; exact hc1) p2
      (i := .opi .addi T0 0 1) (by decide) rfl
    have t0 : s4.reg T0 = 1 := by rw [reg_wrote r4 (by decide)]; simp only [aluI, reg_zero]; decide
    have a0 : s4.reg A0 = 1 := by
      rw [reg_kept r4 (by decide), reg_wrote r2 (by decide)]; simp only [aluI, reg_zero]; decide
    have hc4 : CodeAt s4.mem base kernel := by rw [m4, m2]; exact hc1
    have e5 : run e 1 s4 = .halted (s4.reg A0) s4 := by
      have : kernel[33]'(by decide) = .ecall := by decide
      exact run_code_halt 0 (by decide) hc4 p4
        (by rw [p4]; exact align_off hp.align hp.fit _ (by decide) (by decide))
        (by rw [p4]; exact ok_off hp _ 4 (by decide) (by decide)) (by rw [this]; exact exec_halt t0)
    rw [a0] at e5
    refine ⟨s4, ?_, by rw [m4, m2, m1, mV]⟩
    rw [show 17425 = 3 + ((7 + 17 * N + 3) + (1 + (1 + (1 + 1)))) by decide, run_add_running e3,
      run_add_running eV, run_add_running e1, run_add_running e2, run_add_running e4, e5]
  · have tt : taken .beq (sV.reg S6) (sV.reg 0) = true := by rw [tk]; simp [hy]
    refine ⟨sV.setPc (sV.pc + ((0x7c4 : BitVec 12) ++ 0#1).signExtend 32), ?_,
      by rw [setPc_pc, pV', to_sha], by rw [setPc_mem, mV]⟩
    rw [show 17422 = 3 + ((7 + 17 * N + 3) + 1) by decide, run_add_running e3, run_add_running eV]
    exact (stepK hp 30 (by decide) hcV pV' (i := .br .beq S6 0 0x7c4) (by decide) (exec_br_taken tt) 0).trans
      (run_zero _ _)

/-! ## The kernel, whole -/

theorem off_sha (hw : Wide env base) (c : Nat) (hc : SHA + c < 0x10000) :
    base + BitVec.ofNat 32 SHA + BitVec.ofNat 32 c = base + BitVec.ofNat 32 (SHA + c) :=
  off_add (hw.fit64) SHA c hc

/-- **The kernel conditions what it does not withhold.** From `base`, in a
128 KiB region, with the front at `base`, exp208's SHA-256 kernel at
`base + 0x1000` and its K, IV and length 4096 at `base + 0x2000`:
- if the 1024 samples at `base + 0x3000` fail either test, it halts with 1
  after exactly 17425 instructions, and memory is just as it was — no digest,
  not a byte written;
- if they pass both, it halts with 0 after exactly 334284 = 17422 + 4990 +
  4873 · 64, the 32 bytes at `base + 0x2140` are SHA-256 of the samples'
  4096 bytes, and nothing outside the digest and SHA-256's scratch changed. -/
theorem conditions (hw : Wide env base) (s : Machine) (hpc : s.pc = base)
    (hfront : CodeAt s.mem base kernel) (hsha : CodeAt s.mem (base + BitVec.ofNat 32 SHA) Sha.kernel)
    (hK : ∀ t < 64, Sha.wordAt s.mem (base + BitVec.ofNat 32 (DATA + 4 * t)) = Sha.K.getD t 0)
    (hIV : ∀ j < 8, Sha.wordAt s.mem (base + BitVec.ofNat 32 (DATA + 0x100 + 4 * j)) = Sha.IV.getD j 0)
    (hlen : Sha.wordAt s.mem (base + BitVec.ofNat 32 (DATA + 0x120)) = 4096) :
    (¬ Healthy s.mem base → ∃ s', run env 17425 s = .halted 1 s' ∧ s'.mem = s.mem) ∧
    (Healthy s.mem base → ∃ s', run env 334284 s = .halted 0 s' ∧
      readBytes s'.mem (base + BitVec.ofNat 32 DIGEST) 32 = Sha.sha256 (samples s.mem base) ∧
      Keeps (base + BitVec.ofNat 32 DIGEST) 0x300 s.mem s'.mem) := by
  obtain ⟨fn, fy⟩ := front_decides hw.placed s hpc hfront
  refine ⟨fun hn => ?_, fun hy => ?_⟩
  · obtain ⟨s', e', m'⟩ := fn hn
    exact ⟨s', hw.halted e', m'⟩
  · obtain ⟨sB, eB, pB, mB⟩ := fy hy
    have hp1 := placed1 hw
    obtain ⟨s', e', d', k'⟩ := Sha.computes hp1 sB pB (by rw [mB]; exact hsha)
      (fun t ht => by
        rw [off_sha hw _ (by simp only [SHA]; omega), show SHA + (0x1000 + 4 * t) = DATA + 4 * t by
          simp only [SHA, DATA]; omega, mB]; exact hK t ht)
      (fun j hj => by
        rw [off_sha hw _ (by simp only [SHA]; omega), show SHA + (0x1100 + 4 * j) = DATA + 0x100 + 4 * j by
          simp only [SHA, DATA]; omega, mB]; exact hIV j hj)
      (n := 64) (by rw [off_sha hw _ (by decide), mB]; exact hlen) (by decide)
    rw [off_sha hw _ (by decide), off_sha hw _ (by decide), mB] at d'
    rw [off_sha hw _ (by decide), mB] at k'
    refine ⟨s', ?_, d', k'⟩
    rw [show 334284 = 17422 + (4990 + 4873 * 64) by decide, run_add_running (hw.running eB)]
    exact halted1 hw e'

/-! ## The bytes are the kernel -/

theorem bytes_words : ∀ k (h : k < kernel.length),
    (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
      = (encode kernel[k]).toNat := by
  decide

set_option maxRecDepth 20000 in
set_option maxHeartbeats 0 in
theorem sha_words : ∀ k (h : k < Sha.kernel.length),
    (Sha.bytes.getD (4 * k) 0).toNat + 256 * (Sha.bytes.getD (4 * k + 1) 0).toNat
      + 65536 * (Sha.bytes.getD (4 * k + 2) 0).toNat + 16777216 * (Sha.bytes.getD (4 * k + 3) 0).toNat
      = (encode Sha.kernel[k]).toNat := by
  decide

/-- Four bytes of `data` from `d`, put back together. -/
def dataWord (d : Nat) : Nat :=
  (data.getD d 0).toNat + 256 * (data.getD (d + 1) 0).toNat
    + 65536 * (data.getD (d + 2) 0).toNat + 16777216 * (data.getD (d + 3) 0).toNat

theorem data_K : ∀ t < 64, dataWord (4 * t) = (Sha.K.getD t 0).toNat := by decide
theorem data_IV : ∀ j < 8, dataWord (0x100 + 4 * j) = (Sha.IV.getD j 0).toNat := by decide
theorem data_len : dataWord 0x120 = 4096 := by decide

/-- A word of the data, in memory loaded from an image that holds it at 0x2000. -/
theorem word_of_image (hfit : base.toNat + 0x10000 ≤ 2^32) (img : ByteArray) (hsize : DATA + 292 ≤ img.size)
    (himg : ∀ d (h : d < 292), img.get (DATA + d) (by omega) = data.getD d 0) (d : Nat) (hd : d + 4 ≤ 292) :
    Sha.wordAt (memOfImage base img) (base + BitVec.ofNat 32 (DATA + d)) = BitVec.ofNat 32 (dataWord d) := by
  unfold Sha.wordAt
  rw [readLE_image hfit img _ (by simp only [DATA]; omega) (by omega)]
  have g : ∀ j (hj : j < 4) (h' : DATA + d + j < img.size), img.get (DATA + d + j) h' = data.getD (d + j) 0 := by
    intro j hj h'
    rw [← himg (d + j) (by omega)]
    congr 1; omega
  rw [g 1 (by decide), g 2 (by decide), g 3 (by decide), himg d (by omega)]
  rfl

/-- **From the state the shell builds**: any image that holds the front at
0, exp208's 1008 bytes at 0x1000 and the data at 0x2000 — the samples where
the shell put them. -/
theorem from_boot (hw : Wide env base) (img : ByteArray) (hsize : DATA + 292 ≤ img.size)
    (hfront : ∀ d (h : d < 136), img.get d (by simp only [DATA] at hsize; omega) = bytes.getD d 0)
    (hsha : ∀ d (h : d < 1008), img.get (SHA + d) (by simp only [DATA, SHA] at hsize ⊢; omega) = Sha.bytes.getD d 0)
    (hdata : ∀ d (h : d < 292), img.get (DATA + d) (by omega) = data.getD d 0) :
    let m0 := memOfImage base img
    (¬ Healthy m0 base → ∃ s', run env 17425 (boot env.region img) = .halted 1 s' ∧ s'.mem = m0) ∧
    (Healthy m0 base → ∃ s', run env 334284 (boot env.region img) = .halted 0 s' ∧
      readBytes s'.mem (base + BitVec.ofNat 32 DIGEST) 32 = Sha.sha256 (samples m0 base) ∧
      Keeps (base + BitVec.ofNat 32 DIGEST) 0x300 m0 s'.mem) := by
  intro m0
  have hfit := hw.fit64
  have hpc : (boot env.region img).pc = base := by simp [boot, hw.region]
  have hmem : (boot env.region img).mem = m0 := by simp [boot, hw.region, m0]
  have c0 : CodeAt m0 base kernel :=
    code_of_image hfit (by decide) bytes_words img (by rw [kernel_length]; simp only [DATA] at hsize; omega)
      (fun d h => hfront d (by rw [kernel_length] at h; omega))
  have c1 : CodeAt m0 (base + BitVec.ofNat 32 SHA) Sha.kernel :=
    code_of_image_at hfit SHA (by rw [Sha.kernel_length]; decide) sha_words img
      (by rw [Sha.kernel_length]; simp only [DATA, SHA] at hsize ⊢; omega)
      (fun d h => hsha d (by rw [Sha.kernel_length] at h; omega))
  have w := word_of_image hfit img hsize hdata
  have w := conditions hw (boot env.region img) hpc (by rw [hmem]; exact c0) (by rw [hmem]; exact c1)
    (fun t ht => by
      rw [hmem, w (4 * t) (by omega), data_K t ht]; simp)
    (fun j hj => by
      rw [hmem, show DATA + 0x100 + 4 * j = DATA + (0x100 + 4 * j) by omega, w _ (by omega), data_IV j hj]; simp)
    (by rw [hmem, w 0x120 (by decide), data_len]; rfl)
  rw [hmem] at w
  exact w

#print axioms Exp223.front_decides
#print axioms Exp223.conditions
#print axioms Exp223.bytes_words
#print axioms Exp223.sha_words
#print axioms Exp223.from_boot

end Exp223

def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Exp223.image
  | _ => pure ()
  for (i, k) in Exp223.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
