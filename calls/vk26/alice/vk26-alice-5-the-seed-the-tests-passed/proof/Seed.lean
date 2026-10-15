/-
SPDX-License-Identifier: Apache-2.0

# vk26-alice-5 — the seed the tests passed

SP 800-90A Rev. 1's Hash_DRBG Instantiate (§10.1.1.2) with SHA-256, seedlen =
440 bits, no personalization beyond what the seed material carries:

  V = Hash_df(seed_material, 440),  C = Hash_df(0x00 ‖ V, 440),  counter = 1

where Hash_df (§10.3.1) is, for 440 bits, two hashes:
Hash(0x01 ‖ 0x000001b8 ‖ input) ‖ Hash(0x02 ‖ 0x000001b8 ‖ input), cut to 55
bytes. This kernel runs after vk26-alice-2's (`Alice.Trust`), on the region
that one leaves: its digest of the tested window is at 0x2400, and the seed
material is that digest, the nonce after it, and any personalization string
after that. It lays the state out where vk26-alice-4's Generate
(`Alice.Drbg`) keeps it. Offsets from `base`:

  0x23fb  Hash_df's counter byte and 00 00 01 b8, then the seed material at 0x2400
  0x2480  m, the interval (words), and the seed material's length S
  0x43a   Hash_df's prefix for C: counter, 00 00 01 b8, 00, then V at 0x440
  out:    m, the interval and the counter 1 at 0x400; 0x03 at 0x43f; V at
          0x440; C at 0x480; 23 and 51 zeros at 0x500 and 0x540; the number
          1 at 0x580 — what `Drbg.generate_run` asks of a region

   0-2     s0 = base, s1 = base + 0x2000
   3-6     00 00 01 b8 to 0x23fc; s2 = 5 + S
   7-20    V: HASHB(0x23fb, 5 + S) to 0x440 with counter 1, to 0x460 with 2
   21-41   C: the prefix; HASHB(0x43a, 61) to 0x480 with 1, to 0x4a0 with 2
   42-43   0x03 to 0x43f
   44-49   46 words of zeros from 0x500
   50-51   1 to 0x5b6
   52-57   m, the interval, and 1 to 0x400
   58-60   HALT 0
-/
import Alice.Trust
import Alice.Drbg

set_option maxRecDepth 20000

namespace Seed
open Rv32 Rv32.Health
open Drbg (View setB setH setW Holds word digs beN view_writeByte view_writeBytes view_writeLE readBytes_view
  readLE_view View.congr)

/-- `HASHB(a0 = rs + off, a1 = len, a2 = s0 + dst)` with Hash_df's counter `k`
stored first at `rs + off`. -/
def dfHash (k : Nat) (rs : Reg) (off : BitVec 12) (len : Reg) (lenImm : BitVec 12) (dst : BitVec 12) : List Instr :=
  [ .opi .addi T1 0 (BitVec.ofNat 12 k), .st .sb rs T1 off,
    .opi .addi A0 rs off, .opi .addi A1 len lenImm, .opi .addi A2 S0 dst, .opi .addi T0 0 2, .ecall ]

def kernel : List Instr :=
  [ .auipc S0 0, .lui T0 2, .op .add S1 S0 T0,
    .lui T1 0xb8010, .st .sw S1 T1 0x3fc, .ld .lw S2 S1 0x488, .opi .addi S2 S2 5 ]
  ++ dfHash 1 S1 0x3fb S2 0 0x440 ++ dfHash 2 S1 0x3fb S2 0 0x460
  ++ [ .st .sb S0 0 0x43b, .st .sb S0 0 0x43c, .opi .addi T1 0 1, .st .sb S0 T1 0x43d,
       .opi .addi T1 0 0xb8, .st .sb S0 T1 0x43e, .st .sb S0 0 0x43f ]
  ++ dfHash 1 S0 0x43a 0 61 0x480 ++ dfHash 2 S0 0x43a 0 61 0x4a0
  ++ [ .opi .addi T1 0 3, .st .sb S0 T1 0x43f,
       .opi .addi A0 S0 0x500, .opi .addi T2 0 46,
       .st .sw A0 0 0, .opi .addi A0 A0 4, .opi .addi T2 T2 0xfff, .br .bne T2 0 (BitVec.ofInt 12 (2 * (46 - 49 : Int))),
       .opi .addi T1 0 1, .st .sb S0 T1 0x5b6,
       .ld .lw T1 S1 0x480, .st .sw S0 T1 0x400, .ld .lw T1 S1 0x484, .st .sw S0 T1 0x404,
       .opi .addi T1 0 1, .st .sw S0 T1 0x408,
       .opi .addi A0 0 0, .opi .addi T0 0 1, .ecall ]

theorem kernel_length : kernel.length = 61 := by decide

def bytes : List UInt8 := toBytes kernel

def image : ByteArray := ⟨bytes.toArray⟩

/-! ## One of Hash_df's hashes -/

variable {env : Env} {base : Word}

theorem hlen : 4 * kernel.length < 0x10000 := by rw [kernel_length]; decide

theorem seed_code (hp : Placed env base) {M0 m : Word → Byte} {F0 G : Nat → Byte}
    (hc0 : CodeAt M0 base kernel) (hv0 : View M0 base F0) (hv : View m base G)
    (hG : ∀ o, o < 4 * 61 → G o = F0 o) : CodeAt m base kernel :=
  Ct.code_keep hp.fit hlen (fun o' ho' => by
    rw [kernel_length] at ho'
    rw [hv o' (by omega), hv0 o' (by omega), hG o' ho']) hc0

/-- Hash_df's counter byte `k` to offset `c`, then HASHB of the `n` bytes
from `c` to offset `dd`: seven instructions, `dfHash`. -/
theorem df_run (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 61 → F o = F0 o)
    {p k c n dd : Nat} {rs len : Reg} {off lenImm dst : BitVec 12}
    (hseg1 : (kernel.drop p).take 1 = [.opi .addi T1 0 (BitVec.ofNat 12 k)])
    (hsb : kernel.getD (p + 1) .ecall = .st .sb rs T1 off)
    (hseg2 : (kernel.drop (p + 2)).take 4 =
      [.opi .addi A0 rs off, .opi .addi A1 len lenImm, .opi .addi A2 S0 dst, .opi .addi T0 0 2])
    (hec : kernel.getD (p + 6) .ecall = .ecall) (hp7 : p + 7 ≤ 61) (hk : k < 256)
    (hkw : (0 : Word) + (BitVec.ofNat 12 k).signExtend 32 = BitVec.ofNat 32 k)
    (hrs1 : rs ≠ T1) (hlen1 : len ≠ A0) (hlen2 : len ≠ T1)
    (hc : 4 * 61 ≤ c) (hn1 : 1 ≤ n) (hcn : c + n ≤ 0x10000) (hdd : dd + 32 ≤ 0x10000)
    {s : Machine} (hpc : s.pc = base + BitVec.ofNat 32 (4 * p)) (hmem : View s.mem base F)
    (hs0 : s.reg S0 = base) (hoff : s.reg rs + off.signExtend 32 = base + BitVec.ofNat 32 c)
    (hn : s.reg len + lenImm.signExtend 32 = BitVec.ofNat 32 n)
    (hdst : dst.signExtend 32 = BitVec.ofNat 32 dd) :
    ∃ s', run env 7 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (p + 7))
      ∧ View s'.mem base (setH (setB F c (BitVec.ofNat 8 k)) dd
          (env.hash ((List.range n).map (fun d => setB F c (BitVec.ofNat 8 k) (c + d)))))
      ∧ ∀ r, r ≠ T1 → r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T0 → s'.reg r = s.reg r := by
  have hcode : CodeAt s.mem base kernel := seed_code hp hc0 hv0 hmem hFc
  have e1 := run_line hp [.opi .addi T1 0 (BitVec.ofNat 12 k)] rfl p s hseg1
    (by simp only [List.length_cons, List.length_nil, kernel_length]; omega) hcode hpc hlen
  generalize hs1 : s.line [.opi .addi T1 0 (BitVec.ofNat 12 k)] = s1 at e1
  have t1 : s1.reg T1 = BitVec.ofNat 32 k := by
    have : s1.reg T1 = 0 + (BitVec.ofNat 12 k).signExtend 32 := by
      rw [← hs1]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]
    rw [this, hkw]
  have k1 : ∀ r, r ≠ T1 → s1.reg r = s.reg r := fun r a => by
    rw [← hs1]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have p1 : s1.pc = base + BitVec.ofNat 32 (4 * (p + 1)) := by
    rw [← hs1]; exact line_pc_at _ hpc (by simp only [List.length_cons, List.length_nil]; omega)
  have ms1 : s1.mem = s.mem := by rw [← hs1, line_mem]
  obtain ⟨s2, e2, p2, m2, r2⟩ := sbStep hp (p + 1) (by rw [kernel_length]; omega) (by rw [ms1]; exact hcode) p1
    hsb c (by rw [k1 rs hrs1, hoff]) (by omega) hlen
  have mv2 : View s2.mem base (setB F c (BitVec.ofNat 8 k)) := by
    rw [m2, ms1, t1, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]
    exact view_writeByte hp.fit hmem (by omega) _
  have hc2 : CodeAt s2.mem base kernel := seed_code hp hc0 hv0 mv2 (fun o ho => by
    simp only [setB, show ¬ o = c by omega, ↓reduceIte]; exact hFc o ho)
  have e3 := run_line hp [.opi .addi A0 rs off, .opi .addi A1 len lenImm, .opi .addi A2 S0 dst, .opi .addi T0 0 2]
    rfl (p + 2) s2 hseg2 (by simp only [List.length_cons, List.length_nil, kernel_length]; omega) hc2
    (by rw [p2]) hlen
  generalize hs3 : s2.line [.opi .addi A0 rs off, .opi .addi A1 len lenImm, .opi .addi A2 S0 dst, .opi .addi T0 0 2]
    = s3 at e3
  have k2 : ∀ r, r ≠ T1 → s2.reg r = s.reg r := fun r a => by rw [r2, k1 r a]
  have q0 : s3.reg A0 = base + BitVec.ofNat 32 c := by
    have : s3.reg A0 = s2.reg rs + off.signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0]
    rw [this, k2 rs hrs1, hoff]
  have q1 : s3.reg A1 = BitVec.ofNat 32 n := by
    have : s3.reg A1 = (s2.setReg A0 (s2.reg rs + off.signExtend 32)).reg len + lenImm.signExtend 32 := by
      rw [← hs3]; simp (config := {decide := true}) [Machine.line, Machine.alu, aluI, reg_setReg, A1, A2, T0]
    rw [this, reg_setReg]; simp only [hlen1, false_and, ↓reduceIte]; rw [k2 len hlen2, hn]
  have q2 : s3.reg A2 = base + BitVec.ofNat 32 dd := by
    have : s3.reg A2 = s2.reg S0 + dst.signExtend 32 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0, S0]
    rw [this, k2 S0 (by decide), hs0, hdst]
  have q3 : s3.reg T0 = 2 := by
    rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, A1, A2, T0]
  have k3 : ∀ r, r ≠ A0 → r ≠ A1 → r ≠ A2 → r ≠ T0 → s3.reg r = s2.reg r := fun r a b c' d => by
    rw [← hs3]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl | rfl | rfl <;> simp [rdOf] <;>
      first | exact fun e => a e.symm | exact fun e => b e.symm | exact fun e => c' e.symm | exact fun e => d e.symm
  have p3 : s3.pc = base + BitVec.ofNat 32 (4 * (p + 2 + 4)) := by
    rw [← hs3]; exact line_pc_at _ (by rw [p2]) (by simp only [List.length_cons, List.length_nil]; omega)
  have ms3 : s3.mem = s2.mem := by rw [← hs3, line_mem]
  have hrd : readBytes s3.mem (s3.reg A0) (s3.reg A1).toNat
      = (List.range n).map (fun d => setB F c (BitVec.ofNat 8 k) (c + d)) := by
    rw [q0, q1, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega), ms3, readBytes_view hp.fit mv2 c hcn]
  have e4 := stepK (prog := kernel) hp (p + 6) (by rw [kernel_length]; omega) (by rw [ms3]; exact hc2)
    (by rw [p3]) hec
    (exec_hashb (env := env) (s := s3) q3
      (by rw [q0, q1, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)]; exact ok_off hp _ _ (by omega) hcn)
      (by rw [q2]; exact ok_off hp _ _ (by omega) hdd)) 0 hlen
  rw [run_zero] at e4
  generalize hs4 : ({ s3 with mem := writeBytes s3.mem (s3.reg A2) (env.hash (readBytes s3.mem (s3.reg A0) (s3.reg A1).toNat)) } : Machine).next = s4 at e4
  refine ⟨s4, ?_, ?_, ?_, fun r a b c' d e => ?_⟩
  · have e1' : run env 1 s = .running s1 := e1
    have e3' : run env 4 s2 = .running s3 := e3
    rw [show 7 = 1 + (1 + (4 + (0 + 1))) by rfl, run_add_running e1', run_add_running e2, run_add_running e3', e4]
  · rw [← hs4, next_pc]; simp only; rw [p3]; exact pc_next hp.fit _ (by omega)
  · rw [← hs4]; simp only [next_mem]; rw [hrd, q2, ms3]
    exact view_writeBytes hp.fit mv2 hdd _
  · have : s4.reg r = s3.reg r := by rw [← hs4]; rfl
    rw [this, k3 r b c' d e, k2 r a]

/-! ## The specification: Hash_df, and Instantiate -/

def SEED : Nat := 0x2400
def PI : Nat := 0x2480

/-- Hash_df's prefix for 440 bits (§10.3.1): the counter, then 440 as four bytes. -/
def pre (k : Nat) : List Byte := [BitVec.ofNat 8 k, 0, 0, 1, 0xb8]

/-- The seed material: the `S` bytes from 0x2400. -/
def seedOf (F : Nat → Byte) (S : Nat) : List Byte := (List.range S).map (fun d => F (SEED + d))

/-- The first 55 of two hashes' 64 bytes, as a number: Hash_df's 440 bits. -/
def two (h1 h2 : Fin 32 → Byte) : Nat :=
  beN (fun d => if hd : d < 32 then (h1 ⟨d, hd⟩).toNat else if hd2 : d - 32 < 32 then (h2 ⟨d - 32, hd2⟩).toNat else 0) 55

/-- **V = Hash_df(seed_material, 440)** (§10.1.1.2 step 3). -/
def dfV (H : List Byte → Fin 32 → Byte) (seed : List Byte) : Nat := two (H (pre 1 ++ seed)) (H (pre 2 ++ seed))

/-- **C = Hash_df(0x00 ‖ V, 440)** (§10.1.1.2 step 5). -/
def dfC (H : List Byte → Fin 32 → Byte) (v : Nat) : Nat := two (H (pre 1 ++ 0 :: digs v)) (H (pre 2 ++ 0 :: digs v))

/-- 55 bytes, the first 32 one hash's and the next 23 another's, hold `two`. -/
theorem holds_two {F : Nat → Byte} {X : Nat} {h1 h2 : Fin 32 → Byte}
    (e1 : ∀ d (hd : d < 32), F (X + d) = h1 ⟨d, hd⟩)
    (e2 : ∀ d (hd : d < 23), F (X + 32 + d) = h2 ⟨d, by omega⟩) : Holds F X (two h1 h2) := by
  have hg : ∀ d, (fun d => if hd : d < 32 then (h1 ⟨d, hd⟩).toNat
      else if hd2 : d - 32 < 32 then (h2 ⟨d - 32, hd2⟩).toNat else 0) d < 256 := by
    intro d; simp only; split
    · exact (h1 _).isLt
    · split
      · exact (h2 _).isLt
      · decide
  intro i hi
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_ofNat, show 54 - i = 55 - 1 - i by omega, two, Drbg.beN_digit _ hg 55 i hi]
  by_cases h32 : i < 32
  · simp only [h32, ↓reduceDIte]; rw [e1 i h32]
  · simp only [h32, ↓reduceDIte, show i - 32 < 32 by omega]
    rw [show X + i = X + 32 + (i - 32) by omega, e2 (i - 32) (by omega)]

/-- The seed material as the first hash reads it: Hash_df's prefix with counter
`k` at 0x23fb (the word 00 00 01 b8 after it), then the `S` bytes from 0x2400. -/
theorem df_input (F : Nat → Byte) (S k : Nat) :
    (List.range (S + 5)).map (fun d => setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 k) (0x23fb + d))
      = pre k ++ seedOf F S := by
  rw [show S + 5 = 5 + S by omega, List.range_add, List.map_append, List.map_map]
  congr 1
  simp only [seedOf]; apply List.map_congr_left; intro d _
  simp only [Function.comp, setB, setW, SEED, show ¬ 0x23fb + (5 + d) = 0x23fb by omega,
    show ¬ (0x23fc ≤ 0x23fb + (5 + d) ∧ 0x23fb + (5 + d) < 0x23fc + 4) by omega, ↓reduceIte]
  congr 1; omega

theorem word_setW_out (F : Nat → Byte) {c x n : Nat} (h : c + 4 ≤ x ∨ x + 4 ≤ c) : word (setW F c n) x = word F x := by
  simp only [word, setW, show ¬ (c ≤ x ∧ x < c + 4) by omega, show ¬ (c ≤ x + 1 ∧ x + 1 < c + 4) by omega,
    show ¬ (c ≤ x + 2 ∧ x + 2 < c + 4) by omega, show ¬ (c ≤ x + 3 ∧ x + 3 < c + 4) by omega, ↓reduceIte]

/-- `sb rs2, imm(s0)`, the byte known: memory `setB F c v`. -/
theorem sb_view (hp : Placed env base) {k : Nat} (hk : k < 61) {s : Machine} (hcode : CodeAt s.mem base kernel)
    (hpc : s.pc = base + BitVec.ofNat 32 (4 * k)) {rs2 : Reg} {imm : BitVec 12} {c : Nat} {v : Byte}
    (hi : kernel.getD k .ecall = .st .sb S0 rs2 imm) (hs0 : s.reg S0 = base)
    (himm : imm.signExtend 32 = BitVec.ofNat 32 c) (hc : c < 0x10000) (hv : BitVec.ofNat 8 (s.reg rs2).toNat = v)
    {F : Nat → Byte} (hmem : View s.mem base F) :
    ∃ s', run env 1 s = .running s' ∧ s'.pc = base + BitVec.ofNat 32 (4 * (k + 1))
      ∧ View s'.mem base (setB F c v) ∧ ∀ r, s'.reg r = s.reg r := by
  obtain ⟨s', e, p', m', r'⟩ := sbStep hp k (by rw [kernel_length]; omega) hcode hpc hi c
    (by rw [hs0, himm]) hc hlen
  exact ⟨s', e, p', by rw [m', hv]; exact view_writeByte hp.fit hmem hc _, r'⟩

/-- The region with `4i` zeros from 0x500. -/
def zeros (F : Nat → Byte) (i : Nat) : Nat → Byte := fun o => if 0x500 ≤ o ∧ o < 0x500 + 4 * i then 0 else F o

structure ZInv (base : Word) (F : Nat → Byte) (i : Nat) (keep : Reg → Word) (s : Machine) : Prop where
  pc : s.pc = base + BitVec.ofNat 32 (4 * (if i < 46 then 46 else 50))
  mem : View s.mem base (zeros F i)
  a0 : s.reg A0 = base + BitVec.ofNat 32 (0x500 + 4 * i)
  t2 : s.reg T2 = BitVec.ofNat 32 (46 - i)
  kept : ∀ r, r ≠ A0 → r ≠ T2 → s.reg r = keep r

theorem zero_iter (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 61 → F o = F0 o) {keep : Reg → Word} {i : Nat} (hi : i < 46)
    {s : Machine} (h : ZInv base F i keep s) :
    ∃ s', run env 4 s = .running s' ∧ ZInv base F (i + 1) keep s' := by
  have hpc : s.pc = base + BitVec.ofNat 32 (4 * 46) := by rw [h.pc]; simp [hi]
  have hcode : CodeAt s.mem base kernel := seed_code hp hc0 hv0 h.mem (fun o ho => by
    simp only [zeros, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * i) by omega, ↓reduceIte]; exact hFc o ho)
  obtain ⟨s1, e1, p1, m1, r1⟩ := storeStep hp 46 (by rw [kernel_length]; decide) hcode hpc
    (rs1 := A0) (rs2 := 0) (imm := 0) rfl (0x500 + 4 * i)
    (by rw [h.a0, show (0 : BitVec 12).signExtend 32 = 0#32 from rfl, BitVec.add_zero]) (by omega) (by omega) hlen
  have mv1 : View s1.mem base (zeros F (i + 1)) := by
    rw [m1, reg_zero, show (0 : Word).toNat = 0 from rfl]
    refine (view_writeLE hp.fit h.mem (by omega) 0).congr (fun o _ => ?_)
    simp only [setW, zeros, Nat.zero_div]
    by_cases h1 : 0x500 + 4 * i ≤ o ∧ o < 0x500 + 4 * i + 4
    · simp only [h1, and_self, ↓reduceIte, show 0x500 ≤ o ∧ o < 0x500 + 4 * (i + 1) by omega]; rfl
    · simp only [h1, ↓reduceIte]
      by_cases h2 : 0x500 ≤ o ∧ o < 0x500 + 4 * i
      · simp only [h2, and_self, ↓reduceIte, show 0x500 ≤ o ∧ o < 0x500 + 4 * (i + 1) by omega]
      · simp only [h2, ↓reduceIte, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * (i + 1)) by omega]
  have hc1 : CodeAt s1.mem base kernel := seed_code hp hc0 hv0 mv1 (fun o ho => by
    simp only [zeros, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * (i + 1)) by omega, ↓reduceIte]; exact hFc o ho)
  have e2 := run_line hp [.opi .addi A0 A0 4, .opi .addi T2 T2 0xfff] (by decide) 47 s1
    (by decide) (by rw [kernel_length]; decide) hc1 p1 hlen
  generalize hs2 : s1.line [.opi .addi A0 A0 4, .opi .addi T2 T2 0xfff] = s2 at e2
  have g0 : s2.reg A0 = base + BitVec.ofNat 32 (0x500 + 4 * (i + 1)) := by
    have : s2.reg A0 = s1.reg A0 + (4 : BitVec 12).signExtend 32 := by
      rw [← hs2]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T2]
    rw [this, r1, h.a0, show (4 : BitVec 12).signExtend 32 = BitVec.ofNat 32 4 by decide,
      off_add hp.fit _ _ (by omega)]; rfl
  have g2 : s2.reg T2 = BitVec.ofNat 32 (46 - (i + 1)) := by
    have : s2.reg T2 = s1.reg T2 + (0xfff : BitVec 12).signExtend 32 := by
      rw [← hs2]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T2]
    rw [this, r1, h.t2, count_down _ (by omega) (by omega), Nat.sub_sub]
  have k2 : ∀ r, r ≠ A0 → r ≠ T2 → s2.reg r = s1.reg r := fun r a b => by
    rw [← hs2]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => b e.symm
  have p2 : s2.pc = base + BitVec.ofNat 32 (4 * (47 + 2)) := by rw [← hs2]; exact line_pc_at _ p1 (by decide)
  have hc2 : CodeAt s2.mem base kernel := by rw [← hs2, line_mem]; exact hc1
  obtain ⟨s3, e3, p3, m3, r3⟩ := brStep hp 49 (by rw [kernel_length]; decide) hc2 p2
    (op := .bne) (rs1 := T2) (rs2 := 0) (off := BitVec.ofInt 12 (2 * (46 - 49 : Int))) rfl (k' := 46) (by decide) hlen
  have tk : taken .bne (s2.reg T2) (s2.reg 0) = decide (i + 1 < 46) := by
    rw [g2, show s2.reg 0 = 0 from reg_zero _]
    by_cases hlt : i + 1 < 46
    · have : BitVec.ofNat 32 (46 - (i + 1)) ≠ 0 := by
        intro e; have := congrArg BitVec.toNat e
        rw [BitVec.toNat_ofNat, Nat.mod_eq_of_lt (by omega)] at this; simp at this; omega
      simp only [taken, hlt, decide_true]; exact bne_iff_ne.mpr this
    · rw [show 46 - (i + 1) = 0 by omega]; simp only [taken, hlt, decide_false]; decide
  have e2' : run env 2 s1 = .running s2 := e2
  refine ⟨s3, ?_, ⟨?_, ?_, ?_, ?_, ?_⟩⟩
  · rw [show 4 = 1 + (2 + 1) by rfl, run_add_running e1, run_add_running e2', e3]
  · rw [p3, tk]; by_cases hlt : i + 1 < 46 <;> simp [hlt]
  · rw [m3, ← hs2, line_mem]; exact mv1
  · rw [r3, g0]
  · rw [r3, g2]
  · intro r a b
    rw [r3, k2 r a b, r1, h.kept r a b]

theorem zero_loop (hp : Placed env base) {M0 : Word → Byte} {F0 F : Nat → Byte} (hc0 : CodeAt M0 base kernel)
    (hv0 : View M0 base F0) (hFc : ∀ o, o < 4 * 61 → F o = F0 o) {keep : Reg → Word} {s : Machine}
    (h : ZInv base F 0 keep s) : ∀ i, i ≤ 46 → ∃ s', run env (4 * i) s = .running s' ∧ ZInv base F i keep s' := by
  intro i hi
  induction i with
  | zero => exact ⟨s, rfl, h⟩
  | succ i ih =>
    obtain ⟨s', e, hs'⟩ := ih (by omega)
    obtain ⟨s'', e', hs''⟩ := zero_iter hp hc0 hv0 hFc (by omega) hs'
    exact ⟨s'', by rw [show 4 * (i + 1) = 4 * i + 4 by omega, run_add_running e, e'], hs''⟩

/-- C's Hash_df input as the kernel reads it: the counter at 0x43a, then
00 00 01 b8 and the 0x00 it wrote, then V's 55 bytes. -/
theorem c_input (G : Nat → Byte) {v : Nat} (k : Nat) (h3b : G 0x43b = 0) (h3c : G 0x43c = 0) (h3d : G 0x43d = 1)
    (h3e : G 0x43e = 0xb8) (h3f : G 0x43f = 0) (hv : Holds G 0x440 v) :
    (List.range 61).map (fun d => setB G 0x43a (BitVec.ofNat 8 k) (0x43a + d)) = pre k ++ 0 :: digs v := by
  rw [show 61 = 6 + 55 by rfl, List.range_add, List.map_append, List.map_map,
    show pre k ++ 0 :: digs v = (pre k ++ [0]) ++ digs v by simp [pre]]
  congr 1
  · simp [List.range_succ, setB, pre, h3b, h3c, h3d, h3e, h3f]
  · simp only [digs]; apply List.map_congr_left; intro d hd
    have := List.mem_range.mp hd
    simp only [Function.comp, setB, show ¬ 0x43a + (6 + d) = 0x43a by omega, ↓reduceIte]
    rw [show 0x43a + (6 + d) = 0x440 + d by omega]; exact hv d this

/-- What Instantiate leaves, as vk26-alice-4's Generate asks for it
(`Drbg.generate_run`'s hypotheses), and nothing else changed. -/
structure Laid (H : List Byte → Fin 32 → Byte) (F : Nat → Byte) (S m iv : Nat) (G : Nat → Byte) : Prop where
  v : Holds G Drbg.VV (dfV H (seedOf F S))
  c : Holds G Drbg.CC (dfC H (dfV H (seedOf F S)))
  pre3 : G Drbg.PRE = 3
  hb : ∀ i, i < 23 → G (Drbg.HB + i) = 0
  cb : ∀ i, i < 51 → G (Drbg.CB + i) = 0
  one : Holds G Drbg.ONE 1
  m : word G Drbg.PAR = m
  iv : word G (Drbg.PAR + 4) = iv
  cnt : word G (Drbg.PAR + 8) = 1
  rest : ∀ o, ¬ (0x23fb ≤ o ∧ o < 0x2400) → ¬ (0x43a ≤ o ∧ o < 0x4c0) → ¬ (0x500 ≤ o ∧ o < 0x5b8)
    → ¬ (0x400 ≤ o ∧ o < 0x40c) → G o = F o

theorem inst_run (hp : Placed env base) {s : Machine} (hpc : s.pc = base) {F : Nat → Byte}
    (hv0 : View s.mem base F) (hc0 : CodeAt s.mem base kernel) {S m iv : Nat}
    (hS : word F (PI + 8) = S) (hS2 : S ≤ 0x80) (hm : word F PI = m) (hiv : word F (PI + 4) = iv) :
    ∃ s' G, run env 241 s = .halted 0 s' ∧ View s'.mem base G ∧ Laid env.hash F S m iv G := by
  obtain ⟨s1, e1, p1, m1, r1⟩ := regStep (prog := kernel) hp 0 (by decide) hc0 (by rw [hpc]; simp)
    (i := .auipc S0 0) rfl (rd := S0) (v := s.pc + (0#20 ++ 0#12)) rfl hlen
  have b1 : s1.reg S0 = base := by
    rw [reg_wrote r1 (by decide), hpc, show (0#20 ++ 0#12 : BitVec 32) = 0#32 by decide, BitVec.add_zero]
  obtain ⟨s2, e2, p2, m2, r2⟩ := regStep (prog := kernel) hp 1 (by decide) (by rw [m1]; exact hc0) p1
    (i := .lui T0 2) rfl (rd := T0) (v := 2#20 ++ 0#12) rfl hlen
  have hc2 : CodeAt s2.mem base kernel := by rw [m2, m1]; exact hc0
  have e3 := run_line hp [.op .add S1 S0 T0] rfl 2 s2 (by decide) (by rw [kernel_length]; decide) hc2 p2 hlen
  generalize hs3 : s2.line [.op .add S1 S0 T0] = s3 at e3
  have b3 : s3.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    have : s3.reg S1 = s2.reg S0 + s2.reg T0 := by
      rw [← hs3]; simp [Machine.line, Machine.alu, reg_setReg, aluR, S1, S0, T0]
    rw [this, reg_kept r2 (by decide), b1, reg_wrote r2 (by decide)]; rfl
  have k3 : ∀ r, r ≠ S1 → s3.reg r = s2.reg r := fun r a => by
    rw [← hs3]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have p3 : s3.pc = base + BitVec.ofNat 32 (4 * (2 + 1)) := by rw [← hs3]; exact line_pc_at _ p2 (by decide)
  have hc3 : CodeAt s3.mem base kernel := by rw [← hs3, line_mem]; exact hc2
  obtain ⟨s4, e4, p4, m4, r4⟩ := regStep (prog := kernel) hp 3 (by decide) hc3 p3
    (i := .lui T1 0xb8010) rfl (rd := T1) (v := 0xb8010#20 ++ 0#12) rfl hlen
  have b4 : s4.reg S1 = base + BitVec.ofNat 32 0x2000 := by rw [reg_kept r4 (by decide), b3]
  have hc4 : CodeAt s4.mem base kernel := by rw [m4]; exact hc3
  obtain ⟨s5, e5, p5, m5, r5⟩ := storeStep hp 4 (by decide) hc4 p4 (rs1 := S1) (rs2 := T1) (imm := 0x3fc) rfl 0x23fc
    (by rw [b4, show (0x3fc : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x3fc by decide,
      off_add hp.fit _ _ (by decide)]) (by decide) (by decide) hlen
  have mv5 : View s5.mem base (setW F 0x23fc 0xb8010000) := by
    rw [m5, reg_wrote r4 (by decide), show (0xb8010#20 ++ 0#12 : BitVec 32).toNat = 0xb8010000 by decide, m4,
      ← hs3, line_mem, m2, m1]
    exact view_writeLE hp.fit hv0 (by decide) _
  have hc5 : CodeAt s5.mem base kernel := seed_code hp hc0 hv0 mv5 (fun o ho => by
    simp only [setW, show ¬ (0x23fc ≤ o ∧ o < 0x23fc + 4) by omega, ↓reduceIte])
  have k5 : ∀ r, r ≠ T1 → r ≠ T0 → r ≠ S1 → r ≠ S0 → s5.reg r = s.reg r := fun r a b c d => by
    rw [r5, reg_kept r4 a, k3 r c, reg_kept r2 b, reg_kept r1 d]
  have b5 : s5.reg S0 = base := by rw [r5, reg_kept r4 (by decide), k3 S0 (by decide), reg_kept r2 (by decide), b1]
  obtain ⟨s6, e6, p6, m6, r6⟩ := loadStep hp 5 (by decide) hc5 p5 (rd := S2) (rs1 := S1) (imm := 0x488) rfl 0x2488
    (by rw [r5, b4, show (0x488 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x488 by decide,
      off_add hp.fit _ _ (by decide)]) (by decide) (by decide) hlen
  have b6 : s6.reg S2 = BitVec.ofNat 32 S := by
    rw [reg_wrote r6 (by decide), readLE_view hp.fit mv5 (by decide), word_setW_out F (by decide)]
    rw [← hS]; rfl
  have hc6 : CodeAt s6.mem base kernel := by rw [m6]; exact hc5
  have e7 := run_line hp [.opi .addi S2 S2 5] rfl 6 s6 (by decide) (by rw [kernel_length]; decide) hc6 p6 hlen
  generalize hs7 : s6.line [.opi .addi S2 S2 5] = s7 at e7
  have b7 : s7.reg S2 = BitVec.ofNat 32 (S + 5) := by
    have : s7.reg S2 = s6.reg S2 + (5 : BitVec 12).signExtend 32 := by
      rw [← hs7]; simp [Machine.line, Machine.alu, reg_setReg, aluI, S2]
    rw [this, b6]; apply BitVec.eq_of_toNat_eq; simp [BitVec.toNat_add]
  have k7 : ∀ r, r ≠ S2 → s7.reg r = s6.reg r := fun r a => by
    rw [← hs7]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have s70 : s7.reg S0 = base := by rw [k7 S0 (by decide), reg_kept r6 (by decide), b5]
  have s71 : s7.reg S1 = base + BitVec.ofNat 32 0x2000 := by rw [k7 S1 (by decide), reg_kept r6 (by decide), r5, b4]
  have p7 : s7.pc = base + BitVec.ofNat 32 (4 * 7) := by rw [← hs7]; exact line_pc_at _ p6 (by decide)
  have mv7 : View s7.mem base (setW F 0x23fc 0xb8010000) := by rw [← hs7, line_mem, m6]; exact mv5
  have hFw : ∀ o, o < 4 * 61 → setW F 0x23fc 0xb8010000 o = F o := fun o ho => by
    simp only [setW, show ¬ (0x23fc ≤ o ∧ o < 0x23fc + 4) by omega, ↓reduceIte]
  have hoffV : ∀ t : Machine, t.reg S1 = base + BitVec.ofNat 32 0x2000 →
      t.reg S1 + (0x3fb : BitVec 12).signExtend 32 = base + BitVec.ofNat 32 0x23fb := fun t h => by
    rw [h, show (0x3fb : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x3fb by decide, off_add hp.fit _ _ (by decide)]
  -- V: Hash_df's two hashes of the seed material, to 0x440 and 0x460
  obtain ⟨s8, e8, p8, mv8, k8⟩ := df_run hp hc0 hv0 hFw (p := 7) (k := 1) (rs := S1) (len := S2) (off := 0x3fb) (lenImm := 0)
    (dst := 0x440) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (c := 0x23fb) (by decide)
    (n := S + 5) (by omega) (by omega) (dd := 0x440) (by decide) p7 mv7 s70 (hoffV s7 s71)
    (by rw [b7]; simp) (by decide)
  rw [df_input F S 1] at mv8
  generalize hh1 : env.hash (pre 1 ++ seedOf F S) = h1 at mv8
  have k80 : s8.reg S0 = base := by
    rw [k8 S0 (by decide) (by decide) (by decide) (by decide) (by decide), s70]
  have k81 : s8.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    rw [k8 S1 (by decide) (by decide) (by decide) (by decide) (by decide), s71]
  have k82 : s8.reg S2 = BitVec.ofNat 32 (S + 5) := by
    rw [k8 S2 (by decide) (by decide) (by decide) (by decide) (by decide), b7]
  obtain ⟨s9, e9, p9, mv9, k9⟩ := df_run hp hc0 hv0 (fun o ho => by
      simp only [setH, setB, setW, show ¬ (0x440 ≤ o ∧ o < 0x440 + 32) by omega, show ¬ o = 0x23fb by omega,
        show ¬ (0x23fc ≤ o ∧ o < 0x23fc + 4) by omega, ↓reduceIte, ↓reduceDIte])
    (p := 14) (k := 2) (rs := S1) (len := S2) (off := 0x3fb) (lenImm := 0) (dst := 0x460) (by decide)
    (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (c := 0x23fb) (by decide)
    (n := S + 5) (by omega) (by omega) (dd := 0x460) (by decide) p8 mv8 k80 (hoffV s8 k81)
    (by rw [k82]; simp) (by decide)
  have hin2 : (List.range (S + 5)).map (fun d => setB (setH (setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 1))
      0x440 h1) 0x23fb (BitVec.ofNat 8 2) (0x23fb + d)) = pre 2 ++ seedOf F S := by
    rw [← df_input F S 2]
    apply List.map_congr_left; intro d hd
    have := List.mem_range.mp hd
    simp only [setB, setH]
    by_cases h0 : 0x23fb + d = 0x23fb
    · simp only [h0, ↓reduceIte]
    · simp only [h0, ↓reduceIte, show ¬ (0x440 ≤ 0x23fb + d ∧ 0x23fb + d < 0x440 + 32) by omega, ↓reduceDIte]
  rw [hin2] at mv9
  generalize hh2 : env.hash (pre 2 ++ seedOf F S) = h2 at mv9
  -- what the two hashes for V left
  have hG9a : ∀ d (hd : d < 32), setH (setB (setH (setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 1)) 0x440 h1)
      0x23fb (BitVec.ofNat 8 2)) 0x460 h2 (0x440 + d) = h1 ⟨d, hd⟩ := fun d hd => by
    simp only [setH, setB, show ¬ (0x460 ≤ 0x440 + d ∧ 0x440 + d < 0x460 + 32) by omega,
      show ¬ 0x440 + d = 0x23fb by omega, show 0x440 ≤ 0x440 + d ∧ 0x440 + d < 0x440 + 32 by omega, and_self,
      ↓reduceIte, ↓reduceDIte, Nat.add_sub_cancel_left]
  have hG9b : ∀ d (hd : d < 32), setH (setB (setH (setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 1)) 0x440 h1)
      0x23fb (BitVec.ofNat 8 2)) 0x460 h2 (0x460 + d) = h2 ⟨d, hd⟩ := fun d hd => by
    simp only [setH, show 0x460 ≤ 0x460 + d ∧ 0x460 + d < 0x460 + 32 by omega, and_self, ↓reduceDIte,
      Nat.add_sub_cancel_left]
  have hG9o : ∀ o, ¬ (0x23fb ≤ o ∧ o < 0x2400) → ¬ (0x440 ≤ o ∧ o < 0x480) →
      setH (setB (setH (setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 1)) 0x440 h1)
        0x23fb (BitVec.ofNat 8 2)) 0x460 h2 o = F o := fun o h1' h2' => by
    simp only [setH, setB, setW, show ¬ (0x460 ≤ o ∧ o < 0x460 + 32) by omega, show ¬ o = 0x23fb by omega,
      show ¬ (0x440 ≤ o ∧ o < 0x440 + 32) by omega, show ¬ (0x23fc ≤ o ∧ o < 0x23fc + 4) by omega,
      ↓reduceIte, ↓reduceDIte]
  generalize hG9 : setH (setB (setH (setB (setW F 0x23fc 0xb8010000) 0x23fb (BitVec.ofNat 8 1)) 0x440 h1)
      0x23fb (BitVec.ofNat 8 2)) 0x460 h2 = G9 at mv9 hG9a hG9b hG9o
  have hVv : Holds G9 0x440 (dfV env.hash (seedOf F S)) := by
    rw [dfV, hh1, hh2]
    exact holds_two (fun d hd => hG9a d hd) (fun d hd => by rw [show 0x440 + 32 + d = 0x460 + d by omega]; exact hG9b d (by omega))
  generalize hv : dfV env.hash (seedOf F S) = v at hVv
  have hc9 : CodeAt s9.mem base kernel := seed_code hp hc0 hv0 mv9 (fun o ho => hG9o o (by omega) (by omega))
  have k90 : s9.reg S0 = base := by rw [k9 S0 (by decide) (by decide) (by decide) (by decide) (by decide), k80]
  have k91 : s9.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    rw [k9 S1 (by decide) (by decide) (by decide) (by decide) (by decide), k81]
  -- C's prefix: 00 00 01 b8 00 at 0x43b
  obtain ⟨s10, e10, p10, mv10, r10⟩ := sb_view hp (k := 21) (by decide) hc9 p9 (rs2 := 0) (imm := 0x43b) (c := 0x43b)
    (v := 0) rfl k90 (by decide) (by decide) (by simp) mv9
  have hc10 := seed_code hp hc0 hv0 mv10 (fun o ho => by
    simp only [setB, show ¬ o = 0x43b by omega, ↓reduceIte]; exact hG9o o (by omega) (by omega))
  obtain ⟨s11, e11, p11, mv11, r11⟩ := sb_view hp (k := 22) (by decide) hc10 p10 (rs2 := 0) (imm := 0x43c) (c := 0x43c)
    (v := 0) rfl (by rw [r10, k90]) (by decide) (by decide) (by simp) mv10
  have hc11 := seed_code hp hc0 hv0 mv11 (fun o ho => by
    simp only [setB, show ¬ o = 0x43c by omega, show ¬ o = 0x43b by omega, ↓reduceIte]
    exact hG9o o (by omega) (by omega))
  have e12 := run_line hp [.opi .addi T1 0 1] rfl 23 s11 (by decide) (by rw [kernel_length]; decide) hc11 p11 hlen
  generalize hs12 : s11.line [.opi .addi T1 0 1] = s12 at e12
  have t12 : s12.reg T1 = 1 := by rw [← hs12]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]
  have k12 : ∀ r, r ≠ T1 → s12.reg r = s11.reg r := fun r a => by
    rw [← hs12]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have p12 : s12.pc = base + BitVec.ofNat 32 (4 * 24) := by rw [← hs12]; exact line_pc_at _ p11 (by decide)
  have hc12 : CodeAt s12.mem base kernel := by rw [← hs12, line_mem]; exact hc11
  have mv12 : View s12.mem base (setB (setB G9 0x43b 0) 0x43c 0) := by rw [← hs12, line_mem]; exact mv11
  obtain ⟨s13, e13, p13, mv13, r13⟩ := sb_view hp (k := 24) (by decide) hc12 p12 (rs2 := T1) (imm := 0x43d)
    (c := 0x43d) (v := 1) rfl (by rw [k12 S0 (by decide), r11, r10, k90]) (by decide) (by decide)
    (by rw [t12]; rfl) mv12
  have hc13 := seed_code hp hc0 hv0 mv13 (fun o ho => by
    simp only [setB, show ¬ o = 0x43d by omega, show ¬ o = 0x43c by omega, show ¬ o = 0x43b by omega, ↓reduceIte]
    exact hG9o o (by omega) (by omega))
  have e14 := run_line hp [.opi .addi T1 0 0xb8] rfl 25 s13 (by decide) (by rw [kernel_length]; decide) hc13 p13 hlen
  generalize hs14 : s13.line [.opi .addi T1 0 0xb8] = s14 at e14
  have t14 : s14.reg T1 = 0xb8 := by rw [← hs14]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]
  have k14 : ∀ r, r ≠ T1 → s14.reg r = s13.reg r := fun r a => by
    rw [← hs14]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have p14 : s14.pc = base + BitVec.ofNat 32 (4 * 26) := by rw [← hs14]; exact line_pc_at _ p13 (by decide)
  have hc14 : CodeAt s14.mem base kernel := by rw [← hs14, line_mem]; exact hc13
  have mv14 : View s14.mem base (setB (setB (setB G9 0x43b 0) 0x43c 0) 0x43d 1) := by
    rw [← hs14, line_mem]; exact mv13
  have s140 : s14.reg S0 = base := by rw [k14 S0 (by decide), r13, k12 S0 (by decide), r11, r10, k90]
  obtain ⟨s15, e15, p15, mv15, r15⟩ := sb_view hp (k := 26) (by decide) hc14 p14 (rs2 := T1) (imm := 0x43e)
    (c := 0x43e) (v := 0xb8) rfl s140 (by decide) (by decide) (by rw [t14]; rfl) mv14
  have hc15 := seed_code hp hc0 hv0 mv15 (fun o ho => by
    simp only [setB, show ¬ o = 0x43e by omega, show ¬ o = 0x43d by omega, show ¬ o = 0x43c by omega,
      show ¬ o = 0x43b by omega, ↓reduceIte]
    exact hG9o o (by omega) (by omega))
  obtain ⟨s16, e16, p16, mv16, r16⟩ := sb_view hp (k := 27) (by decide) hc15 p15 (rs2 := 0) (imm := 0x43f)
    (c := 0x43f) (v := 0) rfl (by rw [r15, s140]) (by decide) (by decide) (by simp) mv15
  generalize hGpe : setB (setB (setB (setB (setB G9 0x43b 0) 0x43c 0) 0x43d 1) 0x43e 0xb8) 0x43f 0 = Gp at mv16
  have hGp : ∀ o, ¬ (0x43b ≤ o ∧ o < 0x440) → Gp o = G9 o := fun o h => by
    rw [← hGpe]; simp only [setB, show ¬ o = 0x43f by omega, show ¬ o = 0x43e by omega, show ¬ o = 0x43d by omega,
      show ¬ o = 0x43c by omega, show ¬ o = 0x43b by omega, ↓reduceIte]
  have hpV : Holds Gp 0x440 v := fun i hi => by rw [hGp _ (by omega)]; exact hVv i hi
  have hcin : ∀ k, (List.range 61).map (fun d => setB Gp 0x43a (BitVec.ofNat 8 k) (0x43a + d))
      = pre k ++ 0 :: digs v := fun k => c_input Gp k (by rw [← hGpe]; rfl) (by rw [← hGpe]; rfl) (by rw [← hGpe]; rfl)
      (by rw [← hGpe]; rfl) (by rw [← hGpe]; rfl) hpV
  have s160 : s16.reg S0 = base := by rw [r16, r15, s140]
  have s161 : s16.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    rw [r16, r15, k14 S1 (by decide), r13, k12 S1 (by decide), r11, r10, k91]
  have hGpc : ∀ o, o < 4 * 61 → Gp o = F o := fun o ho => by
    rw [hGp o (by omega)]; exact hG9o o (by omega) (by omega)
  -- C: Hash_df's two hashes of 0x00 ‖ V, to 0x480 and 0x4a0
  obtain ⟨s17, e17, p17, mv17, k17⟩ := df_run hp hc0 hv0 hGpc (p := 28) (k := 1) (rs := S0) (len := 0)
    (off := 0x43a) (lenImm := 61) (dst := 0x480) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (c := 0x43a) (by decide) (n := 61) (by decide)
    (by decide) (dd := 0x480) (by decide) p16 mv16 s160 (by rw [s160]; rfl) (by simp) (by decide)
  rw [hcin 1] at mv17
  generalize hc1 : env.hash (pre 1 ++ 0 :: digs v) = c1 at mv17
  obtain ⟨s18, e18, p18, mv18, k18⟩ := df_run hp hc0 hv0 (fun o ho => by
      simp only [setH, setB, show ¬ (0x480 ≤ o ∧ o < 0x480 + 32) by omega, show ¬ o = 0x43a by omega, ↓reduceIte,
        ↓reduceDIte]; exact hGpc o ho)
    (p := 35) (k := 2) (rs := S0) (len := 0)
    (off := 0x43a) (lenImm := 61) (dst := 0x4a0) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (c := 0x43a) (by decide) (n := 61) (by decide)
    (by decide) (dd := 0x4a0) (by decide) p17 mv17
    (by rw [k17 S0 (by decide) (by decide) (by decide) (by decide) (by decide), s160])
    (by rw [k17 S0 (by decide) (by decide) (by decide) (by decide) (by decide), s160]; rfl) (by simp) (by decide)
  have hin4 : (List.range 61).map (fun d => setB (setH (setB Gp 0x43a (BitVec.ofNat 8 1)) 0x480 c1) 0x43a
      (BitVec.ofNat 8 2) (0x43a + d)) = pre 2 ++ 0 :: digs v := by
    rw [← hcin 2]; apply List.map_congr_left; intro d hd
    have := List.mem_range.mp hd
    simp only [setB, setH]
    by_cases h0 : 0x43a + d = 0x43a
    · simp only [h0, ↓reduceIte]
    · simp only [h0, ↓reduceIte, show ¬ (0x480 ≤ 0x43a + d ∧ 0x43a + d < 0x480 + 32) by omega, ↓reduceDIte]
  rw [hin4] at mv18
  generalize hc2 : env.hash (pre 2 ++ 0 :: digs v) = c2 at mv18
  have hG18a : ∀ d (hd : d < 32), setH (setB (setH (setB Gp 0x43a (BitVec.ofNat 8 1)) 0x480 c1) 0x43a
      (BitVec.ofNat 8 2)) 0x4a0 c2 (0x480 + d) = c1 ⟨d, hd⟩ := fun d hd => by
    simp only [setH, setB, show ¬ (0x4a0 ≤ 0x480 + d ∧ 0x480 + d < 0x4a0 + 32) by omega,
      show ¬ 0x480 + d = 0x43a by omega, show 0x480 ≤ 0x480 + d ∧ 0x480 + d < 0x480 + 32 by omega, and_self,
      ↓reduceIte, ↓reduceDIte, Nat.add_sub_cancel_left]
  have hG18b : ∀ d (hd : d < 32), setH (setB (setH (setB Gp 0x43a (BitVec.ofNat 8 1)) 0x480 c1) 0x43a
      (BitVec.ofNat 8 2)) 0x4a0 c2 (0x4a0 + d) = c2 ⟨d, hd⟩ := fun d hd => by
    simp only [setH, show 0x4a0 ≤ 0x4a0 + d ∧ 0x4a0 + d < 0x4a0 + 32 by omega, and_self, ↓reduceDIte,
      Nat.add_sub_cancel_left]
  have hG18o : ∀ o, ¬ o = 0x43a → ¬ (0x480 ≤ o ∧ o < 0x4c0) → setH (setB (setH (setB Gp 0x43a (BitVec.ofNat 8 1))
      0x480 c1) 0x43a (BitVec.ofNat 8 2)) 0x4a0 c2 o = Gp o := fun o h1' h2' => by
    simp only [setH, setB, show ¬ (0x4a0 ≤ o ∧ o < 0x4a0 + 32) by omega, h1',
      show ¬ (0x480 ≤ o ∧ o < 0x480 + 32) by omega, ↓reduceIte, ↓reduceDIte]
  generalize hG18 : setH (setB (setH (setB Gp 0x43a (BitVec.ofNat 8 1)) 0x480 c1) 0x43a (BitVec.ofNat 8 2)) 0x4a0 c2
    = G18 at mv18 hG18a hG18b hG18o
  have hCc : Holds G18 0x480 (dfC env.hash v) := by
    rw [dfC, hc1, hc2]
    exact holds_two (fun d hd => hG18a d hd) (fun d hd => by rw [show 0x480 + 32 + d = 0x4a0 + d by omega]; exact hG18b d (by omega))
  have hG18F : ∀ o, ¬ (0x23fb ≤ o ∧ o < 0x2400) → ¬ (0x43a ≤ o ∧ o < 0x4c0) → G18 o = F o := fun o h1' h2' => by
    rw [hG18o o (by omega) (by omega), hGp o (by omega)]; exact hG9o o h1' (by omega)
  have hc18 : CodeAt s18.mem base kernel := seed_code hp hc0 hv0 mv18 (fun o ho => hG18F o (by omega) (by omega))
  have s180 : s18.reg S0 = base := by
    rw [k18 S0 (by decide) (by decide) (by decide) (by decide) (by decide),
      k17 S0 (by decide) (by decide) (by decide) (by decide) (by decide), s160]
  have s181 : s18.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    rw [k18 S1 (by decide) (by decide) (by decide) (by decide) (by decide),
      k17 S1 (by decide) (by decide) (by decide) (by decide) (by decide), s161]
  -- 0x03 before V, for Generate's H
  have e19 := run_line hp [.opi .addi T1 0 3] rfl 42 s18 (by decide) (by rw [kernel_length]; decide) hc18 p18 hlen
  generalize hs19 : s18.line [.opi .addi T1 0 3] = s19 at e19
  have k19 : ∀ r, r ≠ T1 → s19.reg r = s18.reg r := fun r a => by
    rw [← hs19]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  obtain ⟨s20, e20, p20, mv20, r20⟩ := sb_view hp (k := 43) (s := s19) (by decide) (by rw [← hs19, line_mem]; exact hc18)
    (by rw [← hs19]; exact line_pc_at _ p18 (by decide)) (rs2 := T1) (imm := 0x43f) (c := 0x43f) (v := 3) rfl
    (by rw [k19 S0 (by decide), s180]) (by decide) (by decide)
    (by rw [← hs19]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]) (by rw [← hs19, line_mem]; exact mv18)
  have hc20 := seed_code hp hc0 hv0 mv20 (fun o ho => by
    simp only [setB, show ¬ o = 0x43f by omega, ↓reduceIte]; exact hG18F o (by omega) (by omega))
  -- 46 words of zeros from 0x500
  have e21 := run_line hp [.opi .addi A0 S0 0x500, .opi .addi T2 0 46] (by decide) 44 s20 (by decide)
    (by rw [kernel_length]; decide) hc20 p20 hlen
  generalize hs21 : s20.line [.opi .addi A0 S0 0x500, .opi .addi T2 0 46] = s21 at e21
  have s200 : s20.reg S0 = base := by rw [r20, k19 S0 (by decide), s180]
  have hZ0 : ZInv base (setB G18 0x43f 3) 0 s21.reg s21 := by
    refine ⟨by rw [← hs21]; exact line_pc_at _ p20 (by decide), ?_, ?_, ?_, fun _ _ _ => rfl⟩
    · rw [← hs21, line_mem]
      exact mv20.congr (fun o _ => by simp only [zeros, Nat.mul_zero, Nat.add_zero]; split <;> first | omega | rfl)
    · have : s21.reg A0 = s20.reg S0 + (0x500 : BitVec 12).signExtend 32 := by
        rw [← hs21]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T2, S0]
      rw [this, s200]; rfl
    · rw [← hs21]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T2]
  have hG20c : ∀ o, o < 4 * 61 → setB G18 0x43f 3 o = F o := fun o ho => by
    simp only [setB, show ¬ o = 0x43f by omega, ↓reduceIte]; exact hG18F o (by omega) (by omega)
  obtain ⟨s22, e22, h22⟩ := zero_loop hp hc0 hv0 hG20c hZ0 46 (Nat.le_refl _)
  have p22 : s22.pc = base + BitVec.ofNat 32 (4 * 50) := by rw [h22.pc]; simp
  have hGz : ∀ o, o < 4 * 61 → zeros (setB G18 0x43f 3) 46 o = F o := fun o ho => by
    simp only [zeros, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * 46) by omega, ↓reduceIte]; exact hG20c o ho
  have hc22 := seed_code hp hc0 hv0 h22.mem hGz
  have k22 : ∀ r, r ≠ A0 → r ≠ T2 → s22.reg r = s20.reg r := fun r a b => by
    rw [h22.kept r a b, ← hs21]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl | rfl <;> simp [rdOf] <;> first | exact fun e => a e.symm | exact fun e => b e.symm
  -- the number 1 at 0x580
  have e23 := run_line hp [.opi .addi T1 0 1] rfl 50 s22 (by decide) (by rw [kernel_length]; decide) hc22 p22 hlen
  generalize hs23 : s22.line [.opi .addi T1 0 1] = s23 at e23
  have k23 : ∀ r, r ≠ T1 → s23.reg r = s22.reg r := fun r a => by
    rw [← hs23]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  obtain ⟨s24, e24, p24, mv24, r24⟩ := sb_view hp (k := 51) (s := s23) (by decide) (by rw [← hs23, line_mem]; exact hc22)
    (by rw [← hs23]; exact line_pc_at _ p22 (by decide)) (rs2 := T1) (imm := 0x5b6) (c := 0x5b6) (v := 1) rfl
    (by rw [k23 S0 (by decide), k22 S0 (by decide) (by decide), s200]) (by decide) (by decide)
    (by rw [← hs23]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]) (by rw [← hs23, line_mem]; exact h22.mem)
  generalize hG24e : setB (zeros (setB G18 0x43f 3) 46) 0x5b6 1 = G24 at mv24
  have hG24F : ∀ o, ¬ (0x23fb ≤ o ∧ o < 0x2400) → ¬ (0x43a ≤ o ∧ o < 0x4c0) → ¬ (0x500 ≤ o ∧ o < 0x5b8) →
      G24 o = F o := fun o a b c' => by
    rw [← hG24e]; simp only [setB, zeros, show ¬ o = 0x5b6 by omega, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * 46) by omega,
      show ¬ o = 0x43f by omega, ↓reduceIte]; exact hG18F o a b
  have hc24 := seed_code hp hc0 hv0 mv24 (fun o ho => hG24F o (by omega) (by omega) (by omega))
  have s240 : s24.reg S0 = base := by rw [r24, k23 S0 (by decide), k22 S0 (by decide) (by decide), s200]
  have s241 : s24.reg S1 = base + BitVec.ofNat 32 0x2000 := by
    rw [r24, k23 S1 (by decide), k22 S1 (by decide) (by decide), r20, k19 S1 (by decide), s181]
  have hw24 : ∀ x, 0x2480 ≤ x → x + 4 ≤ 0x248c → word G24 x = word F x := fun x a b => by
    simp only [word]; rw [hG24F x (by omega) (by omega) (by omega), hG24F (x + 1) (by omega) (by omega) (by omega),
      hG24F (x + 2) (by omega) (by omega) (by omega), hG24F (x + 3) (by omega) (by omega) (by omega)]
  have hm32 : m < 2 ^ 32 := hm ▸ Drbg.word_lt _ _
  have hiv32 : iv < 2 ^ 32 := hiv ▸ Drbg.word_lt _ _
  -- m, the interval and the counter 1, to 0x400
  obtain ⟨s25, e25, p25, m25, r25⟩ := loadStep hp 52 (by decide) hc24 p24 (rd := T1) (rs1 := S1) (imm := 0x480) rfl
    0x2480 (by rw [s241, show (0x480 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x480 by decide,
      off_add hp.fit _ _ (by decide)]) (by decide) (by decide) hlen
  have t25 : s25.reg T1 = BitVec.ofNat 32 m := by
    rw [reg_wrote r25 (by decide), readLE_view hp.fit mv24 (by decide), hw24 0x2480 (by decide) (by decide)]
    rw [← hm]; rfl
  obtain ⟨s26, e26, p26, m26, r26⟩ := storeStep hp 53 (by decide) (by rw [m25]; exact hc24) p25 (rs1 := S0) (rs2 := T1)
    (imm := 0x400) rfl 0x400 (by rw [reg_kept r25 (by decide), s240]; rfl) (by decide) (by decide) hlen
  have mv26 : View s26.mem base (setW G24 0x400 m) := by
    rw [m26, t25, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hm32, m25]; exact view_writeLE hp.fit mv24 (by decide) _
  have hc26 := seed_code hp hc0 hv0 mv26 (fun o ho => by
    simp only [setW, show ¬ (0x400 ≤ o ∧ o < 0x400 + 4) by omega, ↓reduceIte]
    exact hG24F o (by omega) (by omega) (by omega))
  obtain ⟨s27, e27, p27, m27, r27⟩ := loadStep hp 54 (by decide) hc26 p26 (rd := T1) (rs1 := S1) (imm := 0x484) rfl
    0x2484 (by rw [r26, reg_kept r25 (by decide), s241,
      show (0x484 : BitVec 12).signExtend 32 = BitVec.ofNat 32 0x484 by decide, off_add hp.fit _ _ (by decide)])
    (by decide) (by decide) hlen
  have t27 : s27.reg T1 = BitVec.ofNat 32 iv := by
    rw [reg_wrote r27 (by decide), readLE_view hp.fit mv26 (by decide), word_setW_out _ (by decide),
      hw24 0x2484 (by decide) (by decide)]
    rw [← hiv]; rfl
  obtain ⟨s28, e28, p28, m28, r28⟩ := storeStep hp 55 (by decide) (by rw [m27]; exact hc26) p27 (rs1 := S0) (rs2 := T1)
    (imm := 0x404) rfl 0x404 (by rw [reg_kept r27 (by decide), r26, reg_kept r25 (by decide), s240]; rfl)
    (by decide) (by decide) hlen
  have mv28 : View s28.mem base (setW (setW G24 0x400 m) 0x404 iv) := by
    rw [m28, t27, BitVec.toNat_ofNat, Nat.mod_eq_of_lt hiv32, m27]; exact view_writeLE hp.fit mv26 (by decide) _
  have hc28 := seed_code hp hc0 hv0 mv28 (fun o ho => by
    simp only [setW, show ¬ (0x404 ≤ o ∧ o < 0x404 + 4) by omega, show ¬ (0x400 ≤ o ∧ o < 0x400 + 4) by omega,
      ↓reduceIte]
    exact hG24F o (by omega) (by omega) (by omega))
  have e29 := run_line hp [.opi .addi T1 0 1] rfl 56 s28 (by decide) (by rw [kernel_length]; decide) hc28 p28 hlen
  generalize hs29 : s28.line [.opi .addi T1 0 1] = s29 at e29
  have k29 : ∀ r, r ≠ T1 → s29.reg r = s28.reg r := fun r a => by
    rw [← hs29]; refine line_keeps _ _ r (fun i hi => ?_)
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hi
    rcases hi with rfl; simp [rdOf]; exact fun e => a e.symm
  have t29 : s29.reg T1 = 1 := by rw [← hs29]; simp [Machine.line, Machine.alu, reg_setReg, aluI, T1]
  obtain ⟨s30, e30, p30, m30, r30⟩ := storeStep hp 57 (s := s29) (by decide) (by rw [← hs29, line_mem]; exact hc28)
    (by rw [← hs29]; exact line_pc_at _ p28 (by decide)) (rs1 := S0) (rs2 := T1) (imm := 0x408) rfl 0x408
    (by rw [k29 S0 (by decide), r28, reg_kept r27 (by decide), r26, reg_kept r25 (by decide), s240]; rfl)
    (by decide) (by decide) hlen
  have mv30 : View s30.mem base (setW (setW (setW G24 0x400 m) 0x404 iv) 0x408 1) := by
    rw [m30, t29, ← hs29, line_mem]; exact view_writeLE hp.fit mv28 (by decide) _
  have hc30 := seed_code hp hc0 hv0 mv30 (fun o ho => by
    simp only [setW, show ¬ (0x408 ≤ o ∧ o < 0x408 + 4) by omega, show ¬ (0x404 ≤ o ∧ o < 0x404 + 4) by omega,
      show ¬ (0x400 ≤ o ∧ o < 0x400 + 4) by omega, ↓reduceIte]
    exact hG24F o (by omega) (by omega) (by omega))
  -- HALT 0
  have e31 := run_line hp [.opi .addi A0 0 0, .opi .addi T0 0 1] (by decide) 58 s30 (by decide)
    (by rw [kernel_length]; decide) hc30 p30 hlen
  generalize hs31 : s30.line [.opi .addi A0 0 0, .opi .addi T0 0 1] = s31 at e31
  have g0 : s31.reg A0 = 0 := by rw [← hs31]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have g5 : s31.reg T0 = 1 := by rw [← hs31]; simp [Machine.line, Machine.alu, reg_setReg, aluI, A0, T0]
  have e32 := haltStep hp 60 (by rw [kernel_length]; decide) (by rw [← hs31, line_mem]; exact hc30)
    (by rw [← hs31]; exact line_pc_at _ p30 (by decide)) rfl g5 hlen 0
  rw [g0] at e32
  refine ⟨s31, setW (setW (setW G24 0x400 m) 0x404 iv) 0x408 1, ?_, by rw [← hs31, line_mem]; exact mv30, ?_⟩
  · have e1' : run env 1 s = .running s1 := e1
    have e3' : run env 1 s2 = .running s3 := e3
    have e7' : run env 1 s6 = .running s7 := e7
    have e12' : run env 1 s11 = .running s12 := e12
    have e14' : run env 1 s13 = .running s14 := e14
    have e19' : run env 1 s18 = .running s19 := e19
    have e21' : run env 2 s20 = .running s21 := e21
    have e23' : run env 1 s22 = .running s23 := e23
    have e29' : run env 1 s28 = .running s29 := e29
    have e31' : run env 2 s30 = .running s31 := e31
    rw [show 241 = 1 + (1 + (1 + (1 + (1 + (1 + (1 + (7 + (7 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (7 + (7 + (1 + (1
      + (2 + (4 * 46 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (1 + (2 + (0 + 1))))))))))))))))))))))))))))))) by rfl,
      run_add_running e1', run_add_running e2, run_add_running e3', run_add_running e4, run_add_running e5,
      run_add_running e6, run_add_running e7', run_add_running e8, run_add_running e9, run_add_running e10,
      run_add_running e11, run_add_running e12', run_add_running e13, run_add_running e14', run_add_running e15,
      run_add_running e16, run_add_running e17, run_add_running e18, run_add_running e19', run_add_running e20,
      run_add_running e21', run_add_running e22, run_add_running e23', run_add_running e24, run_add_running e25,
      run_add_running e26, run_add_running e27, run_add_running e28, run_add_running e29', run_add_running e30,
      run_add_running e31', e32]
  have hz : ∀ o, ¬ (0x400 ≤ o ∧ o < 0x40c) →
      setW (setW (setW G24 0x400 m) 0x404 iv) 0x408 1 o = G24 o := fun o h => by
    simp only [setW, show ¬ (0x408 ≤ o ∧ o < 0x408 + 4) by omega, show ¬ (0x404 ≤ o ∧ o < 0x404 + 4) by omega,
      show ¬ (0x400 ≤ o ∧ o < 0x400 + 4) by omega, ↓reduceIte]
  have h24 : ∀ o, ¬ o = 0x5b6 → ¬ (0x500 ≤ o ∧ o < 0x5b8) → ¬ o = 0x43f → G24 o = G18 o := fun o a b c' => by
    rw [← hG24e]; simp only [setB, zeros, a, show ¬ (0x500 ≤ o ∧ o < 0x500 + 4 * 46) by omega, c', ↓reduceIte]
  have h24z : ∀ o, 0x500 ≤ o → o < 0x5b8 → ¬ o = 0x5b6 → G24 o = 0 := fun o a b c' => by
    rw [← hG24e]; simp only [setB, zeros, c', show 0x500 ≤ o ∧ o < 0x500 + 4 * 46 by omega, and_self, ↓reduceIte]
  refine ⟨?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩
  · rw [hv]; intro i hi
    simp only [Drbg.VV]
    rw [hz _ (by omega), h24 _ (by omega) (by omega) (by omega), hG18o _ (by omega) (by omega)]; exact hpV i hi
  · rw [hv]; intro i hi
    simp only [Drbg.CC]
    rw [hz _ (by omega), h24 _ (by omega) (by omega) (by omega)]; exact hCc i hi
  · simp only [Drbg.PRE]; rw [hz _ (by omega), ← hG24e]
    simp only [setB, zeros, show ¬ (0x43f : Nat) = 0x5b6 by decide, show ¬ (0x500 ≤ 0x43f ∧ 0x43f < 0x500 + 4 * 46) by decide,
      ↓reduceIte]
  · intro i hi; simp only [Drbg.HB]; rw [hz _ (by omega), h24z _ (by omega) (by omega) (by omega)]
  · intro i hi; simp only [Drbg.CB]; rw [hz _ (by omega), h24z _ (by omega) (by omega) (by omega)]
  · intro i hi; simp only [Drbg.ONE]; rw [hz _ (by omega)]
    by_cases h54 : i = 54
    · subst h54; rw [← hG24e]; simp [setB]
    · rw [h24z _ (by omega) (by omega) (by omega), Nat.div_eq_of_lt (Nat.one_lt_pow (by omega) (by decide))]; rfl
  · simp only [Drbg.PAR]
    rw [word_setW_out _ (by decide), word_setW_out _ (by decide), Drbg.word_setW _ _ hm32]
  · simp only [Drbg.PAR]
    rw [word_setW_out _ (by decide), Drbg.word_setW _ _ hiv32]
  · simp only [Drbg.PAR]; exact Drbg.word_setW _ _ (by decide)
  · intro o a b c' d
    rw [hz o d, h24 o (by omega) c' (by omega)]; exact hG18F o a b

/-- **Instantiate from boot**: an image that begins with this kernel's 244
bytes, with the seed material's length `S` (at most 0x80), `m` and the
interval at 0x2480. 241 instructions later it halts with 0, the region laid
out as vk26-alice-4's Generate asks, V and C SP 800-90A's Instantiate of the
seed material (`Laid`). -/
theorem inst_boot (hp : Placed env base) (img : ByteArray) (hsize : 244 ≤ img.size)
    (himg : ∀ d (h : d < 244), img.get d (by omega) = bytes.getD d 0) {S m iv : Nat}
    (hS : word (Drbg.imgF img) (PI + 8) = S) (hS2 : S ≤ 0x80) (hm : word (Drbg.imgF img) PI = m)
    (hiv : word (Drbg.imgF img) (PI + 4) = iv) :
    ∃ s' G, run env 241 (boot env.region img) = .halted 0 s' ∧ View s'.mem base G
      ∧ Laid env.hash (Drbg.imgF img) S m iv G := by
  have hpc : (boot env.region img).pc = base := by simp [boot, hp.region]
  have hmem : (boot env.region img).mem = memOfImage base img := by simp [boot, hp.region]
  have hc : CodeAt (memOfImage base img) base kernel :=
    Rv32.code_of_image hp.fit (by rw [kernel_length]; decide) (toBytes_words kernel) img
      (by rw [kernel_length]; omega) (fun d h => himg d (by rw [kernel_length] at h; exact h))
  exact inst_run hp hpc (by rw [hmem]; exact Drbg.view_image img) (by rw [hmem]; exact hc) hS hS2 hm hiv

/-! ## The chain: vk26-alice-2's kernel, this one, vk26-alice-4's -/

/-- The shell's one step between kernels: the next kernel's bytes at the
region's start, every other byte as the last kernel left it. -/
def loadCode (m : Word → Byte) (base : Word) (bs : List UInt8) : Word → Byte := fun a =>
  if h : (a - base).toNat < bs.length then BitVec.ofNat 8 (bs[(a - base).toNat]'h).toNat else m a

/-- And the machine the next kernel starts on: at `base`, any registers. -/
def restart (s : Machine) (base : Word) (bs : List UInt8) : Machine := { s with pc := base, mem := loadCode s.mem base bs }

theorem toBytes_length (prog : List Instr) : (toBytes prog).length = 4 * prog.length := by
  induction prog with
  | nil => rfl
  | cons i prog ih => simp [toBytes, List.flatMap_cons] at ih ⊢; omega

theorem code_loaded (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr} (hl : 4 * prog.length < 0x10000)
    (m : Word → Byte) : CodeAt (loadCode m base (toBytes prog)) base prog := by
  have hc := Rv32.code_of_image hfit (by omega) (toBytes_words prog) ⟨(toBytes prog).toArray⟩
    (by simp [ByteArray.size, toBytes_length]) (fun d h => by
      simp [ByteArray.get, List.getD_eq_getElem?_getD, toBytes_length, h])
  refine Ct.code_keep hfit hl (fun o ho => ?_) hc
  simp only [loadCode, memOfImage, Ct.off_of base o (by omega), toBytes_length, ho, ↓reduceDIte]
  simp [ByteArray.size, ByteArray.get, toBytes_length, ho]

/-- Past the kernel's bytes, the region is what it was. -/
theorem loaded_past (m : Word → Byte) (bs : List UInt8) {o : Nat} (ho : bs.length ≤ o) (h2 : o < 2 ^ 32) :
    loadCode m base bs (base + BitVec.ofNat 32 o) = m (base + BitVec.ofNat 32 o) := by
  simp only [loadCode, Ct.off_of base o h2, show ¬ o < bs.length by omega, ↓reduceDIte]

/-- The seed material the chain gives Instantiate: vk26-alice-2's digest of
its tested window (its output, 32 bytes at 0x2400), then the 16 bytes of the
nonce the shell put at 0x2420. -/
def seedMat (H : List Byte → Fin 32 → Byte) (m0 : Word → Byte) (base : Word) : List Byte :=
  (List.range 32).map (fun d => if h : d < 32 then H (Alice.Window.windowBytes m0 base Trust.SMP 1) ⟨d, h⟩ else 0)
  ++ (List.range 16).map (fun d => m0 (base + BitVec.ofNat 32 (0x2420 + d)))

theorem code_zero_iff (H : List Byte → Fin 32 → Byte) (m0 : Word → Byte) :
    Trust.code H m0 base = 0 ↔ Trust.Trusted H m0 base ∧ Alice.Window.WinOk m0 base Trust.SMP 0
      ∧ Alice.Window.WinOk m0 base Trust.SMP 1 := by
  unfold Trust.code
  by_cases h1 : Trust.Trusted H m0 base <;> by_cases h2 : Alice.Window.WinOk m0 base Trust.SMP 0 <;>
    by_cases h3 : Alice.Window.WinOk m0 base Trust.SMP 1 <;> simp [h1, h2, h3]

/-- **The chain.** An image holding vk26-alice-2's kernel and its inputs (the
KAT and 2048 samples), a nonce at 0x2420, and at 0x2480 the seed material's
length 48, `m` and the interval. vk26-alice-2's kernel halts with its code,
and that code is 0 exactly when the hash passed its KAT and both windows
their tests. Only then does the shell go on: this kernel, then vk26-alice-4's,
each after putting its bytes at the region's start (`restart`). Both halt
with 0, after exactly 241 and `COST m` instructions, and block `j` at 0x600 is
Hash(V + j) for V = Hash_df(digest ‖ nonce): **the bits are SP 800-90A's
Generate after its Instantiate, from the seed the tests passed**, for any
hash function. -/
theorem chain (hp : Placed env base) (img : ByteArray) (hsize : 0x248c ≤ img.size)
    (himg : ∀ d (h : d < 448), img.get d (by omega) = Trust.bytes.getD d 0)
    {m iv : Nat} (hS : word (Drbg.imgF img) (PI + 8) = 48) (hm : word (Drbg.imgF img) PI = m)
    (hiv : word (Drbg.imgF img) (PI + 4) = iv) (hm1 : 1 ≤ m) (hm2 : Drbg.OUT + 32 * m < 0x10000)
    (hiv1 : 1 ≤ iv) (hiv2 : iv < 2 ^ 32 - 1) :
    ∃ s1, run env (Trust.cost env.hash (memOfImage base img) base) (boot env.region img)
        = .halted (Trust.code env.hash (memOfImage base img) base) s1 ∧
      (Trust.code env.hash (memOfImage base img) base = 0 ↔ Trust.Trusted env.hash (memOfImage base img) base
        ∧ Alice.Window.WinOk (memOfImage base img) base Trust.SMP 0
        ∧ Alice.Window.WinOk (memOfImage base img) base Trust.SMP 1) ∧
      (Trust.code env.hash (memOfImage base img) base = 0 →
        ∃ s2, run env 241 (restart s1 base bytes) = .halted 0 s2 ∧
        ∃ s3, run env (Drbg.COST m) (restart s2 base Drbg.bytes) = .halted 0 s3 ∧
        ∀ j d, j < m → ∀ (hd : d < 32), s3.mem (base + BitVec.ofNat 32 (Drbg.OUT + 32 * j + d))
          = env.hash (digs (dfV env.hash (seedMat env.hash (memOfImage base img) base) + j)) ⟨d, hd⟩) := by
  obtain ⟨-, s1, e1, ms1⟩ := Trust.from_boot hp img (by omega) himg
  generalize hm0 : memOfImage base img = m0 at e1 ms1 ⊢
  refine ⟨s1, e1, code_zero_iff env.hash m0, fun h0 => ?_⟩
  have hT := (code_zero_iff env.hash m0).mp h0
  have ms1' : s1.mem = writeBytes (Trust.katted env.hash m0 base) (base + BitVec.ofNat 32 Trust.OUT)
      (env.hash (Alice.Window.windowBytes m0 base Trust.SMP 1)) := by
    simp only [ms1, Trust.after, hT, and_self, ↓reduceIte]
  -- after vk26-alice-2's kernel: the digest at 0x2400, and the image from 0x2420 on
  have s1out : ∀ d (hd : d < 32), s1.mem (base + BitVec.ofNat 32 (0x2400 + d))
      = env.hash (Alice.Window.windowBytes m0 base Trust.SMP 1) ⟨d, hd⟩ := fun d hd => by
    rw [ms1']; exact Trust.writeBytes_in hp.fit _ _ hd (by decide)
  have s1keep : ∀ o, 0x2420 ≤ o → o < 0x10000 → s1.mem (base + BitVec.ofNat 32 o) = Drbg.imgF img o := by
    intro o h1 h2
    rw [ms1', writeBytes_apply, Drbg.dist_view hp.fit h2 (by decide)]
    simp only [Trust.OUT, show 0x2400 ≤ o by omega, ↓reduceIte, show ¬ o - 0x2400 < 32 by omega, ↓reduceDIte]
    rw [Trust.katted, writeBytes_apply, Drbg.dist_view hp.fit h2 (by decide)]
    simp only [Trust.KGOT, show 0x360 ≤ o by omega, ↓reduceIte, show ¬ o - 0x360 < 32 by omega, ↓reduceDIte]
    rw [← hm0]; exact Drbg.view_image img o h2
  -- this kernel, on what that one left
  generalize hF : (fun o => loadCode s1.mem base bytes (base + BitVec.ofNat 32 o)) = F
  have hFpast : ∀ o, 244 ≤ o → o < 0x10000 → F o = s1.mem (base + BitVec.ofNat 32 o) := fun o h1 h2 => by
    rw [← hF]; exact loaded_past _ _ (by rw [bytes, toBytes_length, kernel_length]; omega) (by omega)
  have hFw : ∀ x, 0x2420 ≤ x → x + 4 ≤ 0x10000 → word F x = word (Drbg.imgF img) x := fun x a b => by
    simp only [word]; rw [hFpast x (by omega) (by omega), hFpast (x + 1) (by omega) (by omega),
      hFpast (x + 2) (by omega) (by omega), hFpast (x + 3) (by omega) (by omega), s1keep x (by omega) (by omega),
      s1keep (x + 1) (by omega) (by omega), s1keep (x + 2) (by omega) (by omega), s1keep (x + 3) (by omega) (by omega)]
  have hseed : seedOf F 48 = seedMat env.hash m0 base := by
    rw [seedOf, seedMat, show 48 = 32 + 16 by rfl, List.range_add, List.map_append, List.map_map]
    congr 1
    · apply List.map_congr_left; intro d hd
      have := List.mem_range.mp hd
      simp only [SEED, this, ↓reduceDIte]
      rw [hFpast _ (by omega) (by omega)]; exact s1out d this
    · apply List.map_congr_left; intro d hd
      have := List.mem_range.mp hd
      simp only [Function.comp, SEED]
      rw [hFpast _ (by omega) (by omega), show 0x2400 + (32 + d) = 0x2420 + d by omega,
        s1keep _ (by omega) (by omega), ← hm0]
      exact (Drbg.view_image img _ (by omega)).symm
  obtain ⟨s2, G, e2, mv2, hL⟩ := inst_run (env := env) hp (s := restart s1 base bytes) rfl (F := F) (S := 48) (m := m) (iv := iv)
    (by rw [← hF]; intro o _; rfl) (code_loaded hp.fit hlen _)
    (by rw [hFw _ (by decide) (by decide)]; exact hS) (by decide)
    (by rw [hFw _ (by decide) (by decide)]; exact hm) (by rw [hFw _ (by decide) (by decide)]; exact hiv)
  refine ⟨s2, e2, ?_⟩
  -- vk26-alice-4's Generate, on what this one left
  generalize hF' : (fun o => loadCode s2.mem base Drbg.bytes (base + BitVec.ofNat 32 o)) = F'
  have hFG : ∀ o, 280 ≤ o → o < 0x10000 → F' o = G o := fun o h1 h2 => by
    rw [← hF', ← mv2 o h2]
    exact loaded_past _ _ (by rw [Drbg.bytes, toBytes_length, Drbg.kernel_length]; omega) (by omega)
  have hol : ∀ X N, 280 ≤ X → X + 55 ≤ 0x10000 → Holds G X N → Holds F' X N := fun X N a b h i hi => by
    rw [hFG _ (by omega) (by omega)]; exact h i hi
  have hwd : ∀ x, 280 ≤ x → x + 4 ≤ 0x10000 → word F' x = word G x := fun x a b => by
    simp only [word]; rw [hFG x (by omega) (by omega), hFG (x + 1) (by omega) (by omega),
      hFG (x + 2) (by omega) (by omega), hFG (x + 3) (by omega) (by omega)]
  obtain ⟨s3, e3, mv3⟩ := Drbg.generate_run (env := env) hp (s := restart s2 base Drbg.bytes) rfl (F0 := F') (m := m) (cnt := 1)
    (by rw [← hF']; intro o _; rfl) (code_loaded hp.fit Drbg.hlen _)
    (hol _ _ (by decide) (by decide) hL.v) (hol _ _ (by decide) (by decide) hL.c)
    (hol _ _ (by decide) (by decide) hL.one) (by rw [hFG _ (by decide) (by decide)]; exact hL.pre3)
    (fun i hi => by rw [hFG _ (by simp only [Drbg.HB]; omega) (by simp only [Drbg.HB]; omega)]; exact hL.hb i hi)
    (fun i hi => by rw [hFG _ (by simp only [Drbg.CB]; omega) (by simp only [Drbg.CB]; omega)]; exact hL.cb i hi)
    (by rw [hwd _ (by decide) (by decide)]; exact hL.m) (by rw [hwd _ (by decide) (by decide)]; exact hL.cnt) hm1 hm2
    (by rw [hwd _ (by decide) (by decide), hL.iv]; omega) (by rw [hwd _ (by decide) (by decide), hL.iv]; omega)
  refine ⟨s3, e3, fun j d hj hd => ?_⟩
  rw [mv3 _ (by simp only [Drbg.OUT] at hm2 ⊢; omega), ← hseed]
  exact Drbg.after_out F' _ _ _ hj hd

end Seed

#print axioms Seed.inst_run
#print axioms Seed.inst_boot
#print axioms Seed.chain

/-- `main OUT [TRUST DRBG]`: kernel.bin, and the two kernels it runs between,
as alice's package has them. -/
def main (args : List String) : IO Unit := do
  match args with
  | [out] => IO.FS.writeBinFile out Seed.image
  | [out, trust, drbg] =>
    IO.FS.writeBinFile out Seed.image
    IO.FS.writeBinFile trust Trust.image
    IO.FS.writeBinFile drbg Drbg.image
  | _ => pure ()
  for (i, k) in Seed.kernel.zipIdx do
    IO.println s!"  {Rv32.hex8 (4 * k) |>.drop 4}  {Rv32.hex8 (Rv32.encode i).toNat}  {i.toAsm}"
