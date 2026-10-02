/-
SPDX-License-Identifier: Apache-2.0

# A kernel placed at `base`, in the 64 KiB region

What every kernel proof assumes about where it is — `Placed` — and the
arithmetic of addresses inside the region that follows from it, stated once:
`base + c` never wraps, so an address is a number and `omega` can reason
about it. exp203 wrote these first; exp204 needed them second.

And the two things the kernels from exp204 on do that exp203's did not: read
a byte (`lbu`), and call `HASH`.
-/
import Rv32.Proof

namespace Rv32

/-- What the theorems assume about where the kernel is: word-aligned, the
64 KiB region fitting below `2^32`, and the region being exactly that. -/
structure Placed (env : Env) (base : Word) : Prop where
  align : base.toNat % 4 = 0
  fit : base.toNat + 0x10000 ≤ 2^32
  region : env.region = ⟨base.toNat, base.toNat + 0x10000⟩

/-- `base + c`, as a number: nothing wraps inside the region. -/
theorem toNat_off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (c : Nat) (hc : c < 0x10000) :
    (base + BitVec.ofNat 32 c).toNat = base.toNat + c := by
  rw [BitVec.toNat_add, BitVec.toNat_ofNat, Nat.mod_eq_of_lt (show c < 2^32 by omega),
    Nat.mod_eq_of_lt (show base.toNat + c < 2^32 by omega)]

theorem off_add {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (c d : Nat)
    (h : c + d < 0x10000) :
    base + BitVec.ofNat 32 c + BitVec.ofNat 32 d = base + BitVec.ofNat 32 (c + d) := by
  apply BitVec.eq_of_toNat_eq
  rw [BitVec.toNat_add, toNat_off hfit c (by omega), toNat_off hfit (c + d) h, BitVec.toNat_ofNat,
    Nat.mod_eq_of_lt (show d < 2^32 by omega), Nat.mod_eq_of_lt (show base.toNat + c + d < 2^32 by omega)]
  omega

theorem ok_off {env : Env} {base : Word} (hp : Placed env base) (c n : Nat) (hc : c < 0x10000)
    (h : c + n ≤ 0x10000) :
    env.region.ok (base + BitVec.ofNat 32 c) n := by
  rw [hp.region]
  simp only [Region.ok]
  rw [toNat_off hp.fit c (by omega)]; omega

theorem align_off {base : Word} (hp : base.toNat % 4 = 0) (hfit : base.toNat + 0x10000 ≤ 2^32)
    (c : Nat) (hc : c < 0x10000) (h4 : c % 4 = 0) : (base + BitVec.ofNat 32 c).toNat % 4 = 0 := by
  rw [toNat_off hfit c hc]; omega

theorem toNat_sub_off {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) (x : Word) (c : Nat)
    (hc : c < 0x10000) :
    (x - (base + BitVec.ofNat 32 c)).toNat = (2^32 - (base.toNat + c) + x.toNat) % 2^32 := by
  rw [BitVec.toNat_sub, toNat_off hfit c hc]

/-! ## A byte -/

theorem readLE_one (m : Word → Byte) (a : Word) : readLE m a 1 = (m a).toNat := by
  simp [readLE]

theorem exec_lbu {env : Env} {s : Machine} {rd rs1 : Reg} {imm : BitVec 12}
    (hok : env.region.ok (s.reg rs1 + imm.signExtend 32) 1) :
    exec env s (.ld .lbu rd rs1 imm) =
      .running (s.setReg rd (BitVec.ofNat 32 (s.mem (s.reg rs1 + imm.signExtend 32)).toNat)).next := by
  have h1 : ¬ (s.reg rs1 + imm.signExtend 32).toNat % 1 ≠ 0 := by omega
  have h2 : ¬ ¬ env.region.ok (s.reg rs1 + imm.signExtend 32) 1 := by simpa using hok
  simp only [exec, LdOp.extend, LdOp.size, readLE_one]
  simp only [h1, h2, ↓reduceIte]

/-! ## HASH -/

/-- `ecall` with `t0 = 0`, its arguments in order: the 32 bytes of
`env.hash` of the input are written at `a2`, and the run goes on. -/
theorem exec_hash {env : Env} {s : Machine} (h0 : s.reg T0 = 0)
    (hlen : (s.reg A1).toNat % 64 = 0) (hsrc : (s.reg A0).toNat % 4 = 0)
    (hdst : (s.reg A2).toNat % 4 = 0) (hin : env.region.ok (s.reg A0) (s.reg A1).toNat)
    (hout : env.region.ok (s.reg A2) 32) :
    exec env s .ecall = .running ({ s with mem := writeBytes s.mem (s.reg A2) (env.hash (readBytes s.mem (s.reg A0) (s.reg A1).toNat)) } : Machine).next := by
  simp only [exec, syscall, h0, ↓reduceIte, hlen, hsrc, hdst, hin, hout, and_self]

/-- What a byte holds after HASH wrote its 32. -/
theorem writeBytes_apply (m : Word → Byte) (a : Word) (f : Fin 32 → Byte) (x : Word) :
    writeBytes m a f x = if h : (x - a).toNat < 32 then f ⟨(x - a).toNat, h⟩ else m x := rfl

/-- Stepping one byte along, then `d`, is stepping `d + 1`. -/
theorem add_one_ofNat (a : Word) (d : Nat) : a + 1 + BitVec.ofNat 32 d = a + BitVec.ofNat 32 (d + 1) := by
  rw [BitVec.ofNat_add, BitVec.add_assoc, BitVec.add_comm (1 : Word)]; rfl

/-- `n + k` bytes are `n` bytes, then `k` more. -/
theorem readBytes_append (m : Word → Byte) (a : Word) (n k : Nat) :
    readBytes m a (n + k) = readBytes m a n ++ readBytes m (a + BitVec.ofNat 32 n) k := by
  induction n generalizing a with
  | zero => simp [readBytes]
  | succ n ih =>
    rw [Nat.add_right_comm, readBytes, readBytes, ih, List.cons_append, add_one_ofNat]

/-- Two memories that agree on `n` bytes from `a` read the same bytes there. -/
theorem readBytes_congr {m m' : Word → Byte} {a : Word} {n : Nat}
    (h : ∀ d, d < n → m (a + BitVec.ofNat 32 d) = m' (a + BitVec.ofNat 32 d)) :
    readBytes m a n = readBytes m' a n := by
  induction n generalizing a with
  | zero => rfl
  | succ n ih =>
    simp only [readBytes]
    have h0 := h 0 (by omega)
    simp only [show a + BitVec.ofNat 32 0 = a by simp] at h0
    rw [h0, ih]
    intro d hd
    have := h (d + 1) (by omega)
    rwa [← add_one_ofNat] at this

/-- The same, for two places: `n` bytes from `a` in `m` and from `a'` in `m'`
are the same list when they agree byte by byte. -/
theorem readBytes_shift {m m' : Word → Byte} {a a' : Word} {n : Nat}
    (h : ∀ d, d < n → m (a + BitVec.ofNat 32 d) = m' (a' + BitVec.ofNat 32 d)) :
    readBytes m a n = readBytes m' a' n := by
  induction n generalizing a a' with
  | zero => rfl
  | succ n ih =>
    simp only [readBytes]
    have h0 := h 0 (by omega)
    simp only [show ∀ b : Word, b + BitVec.ofNat 32 0 = b from fun b => by simp] at h0
    rw [h0, ih]
    intro d hd
    have := h (d + 1) (by omega)
    rwa [← add_one_ofNat, ← add_one_ofNat] at this

/-- `n` bytes that are all `c`. -/
theorem readBytes_const {m : Word → Byte} {a : Word} {n : Nat} {c : Byte}
    (h : ∀ d, d < n → m (a + BitVec.ofNat 32 d) = c) : readBytes m a n = List.replicate n c := by
  induction n generalizing a with
  | zero => rfl
  | succ n ih =>
    simp only [readBytes, List.replicate_succ]
    have h0 := h 0 (by omega)
    simp only [show a + BitVec.ofNat 32 0 = a by simp] at h0
    rw [h0, ih]
    intro d hd
    have := h (d + 1) (by omega)
    rwa [← add_one_ofNat] at this

/-- Two places whose four bytes agree read the same word. -/
theorem readLE_four_eq {m m' : Word → Byte} {a a' : Word}
    (h : ∀ d : Nat, d < 4 → m (a + BitVec.ofNat 32 d) = m' (a' + BitVec.ofNat 32 d)) :
    readLE m a 4 = readLE m' a' 4 := by
  rw [readLE_four, readLE_four]
  have h0 := h 0 (by decide); have h1 := h 1 (by decide)
  have h2 := h 2 (by decide); have h3 := h 3 (by decide)
  simp only [show ∀ b : Word, b + BitVec.ofNat 32 0 = b from fun b => by simp] at h0
  rw [h0, show a + 1 = a + BitVec.ofNat 32 1 from rfl, h1, show a + 2 = a + BitVec.ofNat 32 2 from rfl,
    h2, show a + 3 = a + BitVec.ofNat 32 3 from rfl, h3]
  rfl

theorem readBytes_length (m : Word → Byte) (a : Word) (n : Nat) : (readBytes m a n).length = n := by
  induction n generalizing a with
  | zero => rfl
  | succ n ih => simp [readBytes, ih]

/-- Byte `d` of what was read is the byte at `a + d`. -/
theorem readBytes_getElem (m : Word → Byte) (a : Word) (n d : Nat) (hd : d < n) :
    (readBytes m a n)[d]'(by rw [readBytes_length]; exact hd) = m (a + BitVec.ofNat 32 d) := by
  induction n generalizing a d with
  | zero => omega
  | succ n ih =>
    cases d with
    | zero => simp [readBytes]
    | succ d =>
      simp only [readBytes, List.getElem_cons_succ]
      rw [ih _ _ (by omega), add_one_ofNat]

/-! ## The bytes are the kernel -/

/-- A program as bytes: each instruction's word, little-endian. What a kernel's
`kernel.bin` is. -/
def toBytes (prog : List Instr) : List UInt8 :=
  prog.flatMap fun i =>
    let n := (encode i).toNat
    [n % 256, n / 256 % 256, n / 65536 % 256, n / 16777216].map UInt8.ofNat

/-- **Any image that starts with `bytes`, loaded at `base`, holds `prog`** —
given that word `k` of `bytes`, put back together, is the encoding of
instruction `k`. A kernel discharges that by `decide`, once per word; this is
the bridge from the file `check.sh` holds byte-equal to the theorems. -/
theorem code_of_image {base : Word} (hfit : base.toNat + 0x10000 ≤ 2^32) {prog : List Instr}
    {bytes : List UInt8} (hlen : 4 * prog.length ≤ 0x10000)
    (hwords : ∀ k (h : k < prog.length),
      (bytes.getD (4 * k) 0).toNat + 256 * (bytes.getD (4 * k + 1) 0).toNat
        + 65536 * (bytes.getD (4 * k + 2) 0).toNat + 16777216 * (bytes.getD (4 * k + 3) 0).toNat
        = (encode prog[k]).toNat)
    (img : ByteArray) (hsize : 4 * prog.length ≤ img.size)
    (himg : ∀ d (h : d < 4 * prog.length), img.get d (by omega) = bytes.getD d 0) :
    CodeAt (memOfImage base img) base prog := by
  intro k hk
  rw [readLE_four, ← hwords k hk]
  have at_ : ∀ j (hj : j < 4), memOfImage base img (base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 j)
      = BitVec.ofNat 8 (bytes.getD (4 * k + j) 0).toNat := by
    intro j hj
    unfold memOfImage
    have hd : (base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 j - base).toNat = 4 * k + j := by
      rw [off_add hfit _ _ (by omega), BitVec.toNat_sub, toNat_off hfit _ (by omega)]
      omega
    simp only [hd, show 4 * k + j < img.size by omega, ↓reduceDIte]
    rw [himg _ (by omega)]
  have e0 := at_ 0 (by decide); have e1 := at_ 1 (by decide)
  have e2 := at_ 2 (by decide); have e3 := at_ 3 (by decide)
  simp only [show base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 0 = base + BitVec.ofNat 32 (4 * k)
    by simp, Nat.add_zero] at e0
  rw [e0, show base + BitVec.ofNat 32 (4 * k) + 1 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 1
    from rfl, e1, show base + BitVec.ofNat 32 (4 * k) + 2 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 2
    from rfl, e2, show base + BitVec.ofNat 32 (4 * k) + 3 = base + BitVec.ofNat 32 (4 * k) + BitVec.ofNat 32 3
    from rfl, e3]
  simp only [BitVec.toNat_ofNat]
  have := (bytes.getD (4 * k) 0).toNat_lt
  have := (bytes.getD (4 * k + 1) 0).toNat_lt
  have := (bytes.getD (4 * k + 2) 0).toNat_lt
  have := (bytes.getD (4 * k + 3) 0).toNat_lt
  omega

end Rv32
