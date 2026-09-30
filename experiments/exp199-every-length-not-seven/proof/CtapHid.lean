/-
SPDX-License-Identifier: Apache-2.0

exp199: crates/ctap-hid's `fragment` and `Transaction::feed`, for every length.

Each definition below transcribes a function of crates/ctap-hid/src/lib.rs;
the lines it comes from are in cited.txt beside this file, and check.sh re-reads
them. mutants.txt holds wrong versions of it that must not check.

The crate's test `fragment_and_feed_are_inverses` asks seven lengths. The
theorem `fragment_then_feed` answers all 1025, and says what else it needs: a
channel that is neither broadcast nor reserved, a command that is not INIT and
fits in seven bits, and a device with no other message half-assembled.

Four simplifications, stated because a proof is exactly as strong as what it
is about:
- Bytes are `Nat`, where the Rust has `u8`. Nothing here depends on a data
  byte's value; the header bytes are written with the same `|`, `>>`, `&` and
  `% 256` (`as u8`) the Rust uses.
- The Rust's `buf` and `have` are one list here: the bytes written so far.
  `message()` is `buf[..want]` in both.
- `fragment`'s loop runs on `data.length` of fuel, which is always more than it
  needs: every turn consumes at least one byte.
- Every packet arrives at the same instant. Expiry is in the transcription, and
  exp196's model is where timing is the subject.
-/

namespace CtapHid

abbrev Bytes := List Nat

def PACKET : Nat := 64
def INIT_HEADER : Nat := 7
def CONT_HEADER : Nat := 5
def INIT_PAYLOAD : Nat := 57
def CONT_PAYLOAD : Nat := 59
def BROADCAST : Bytes := [0xff, 0xff, 0xff, 0xff]
def RESERVED : Bytes := [0, 0, 0, 0]
def TRANSACTION_TIMEOUT_MS : Nat := 750
def MAX_MESSAGE : Nat := 1024
def CTAPHID_INIT : Nat := 0x06
def ERR_INVALID_LEN : Nat := 0x03
def ERR_INVALID_SEQ : Nat := 0x04
def ERR_MSG_TIMEOUT : Nat := 0x05
def ERR_CHANNEL_BUSY : Nat := 0x06
def ERR_INVALID_CHANNEL : Nat := 0x0B

/-! ## `fragment` -/

/-- `[0u8; PACKET]` with a `copy_from_slice` into it: the bytes, then zeros. -/
def pad (k : Nat) (xs : Bytes) : Bytes := xs ++ List.replicate (k - xs.length) 0

/-- `fragment`'s first packet: CID, `0x80 | cmd`, BCNT high and low, 57 bytes. -/
def initPacket (cid : Bytes) (cmd : Nat) (data : Bytes) : Bytes :=
  cid ++ [0x80 ||| cmd, (data.length >>> 8) % 256, data.length % 256]
    ++ pad INIT_PAYLOAD (data.take INIT_PAYLOAD)

/-- Every packet after it: CID, SEQ, 59 bytes. -/
def contPacket (cid : Bytes) (seq : Nat) (chunk : Bytes) : Bytes :=
  cid ++ [seq] ++ pad CONT_PAYLOAD chunk

/-- `fragment`'s `while sent < data.len()` loop. -/
def conts (cid : Bytes) (seq : Nat) : Nat → Bytes → List Bytes
  | 0, _ => []
  | _, [] => []
  | fuel + 1, rest@(_ :: _) =>
    contPacket cid seq (rest.take CONT_PAYLOAD)
      :: conts cid ((seq + 1) % 256) fuel (rest.drop CONT_PAYLOAD)

/-- `fragment`. -/
def fragment (cid : Bytes) (cmd : Nat) (data : Bytes) : List Bytes :=
  initPacket cid cmd data :: conts cid 0 data.length (data.drop INIT_PAYLOAD)

/-! ## `Transaction::feed` -/

inductive Action
  | ignore
  | more
  | error (cid : Bytes) (code : Nat)
  | complete
  | init (cid nonce : Bytes)
  deriving DecidableEq

structure Tx where
  cid : Bytes
  cmd : Nat
  want : Nat
  buf : Bytes
  seq : Nat
  started : Nat
  active : Bool
  expired : Option Bytes
  deriving DecidableEq

def Tx.clear (t : Tx) : Tx := { t with active := false, buf := [], want := 0, seq := 0 }

def Tx.message (t : Tx) : Bytes × Nat × Bytes := (t.cid, t.cmd, t.buf.take t.want)

/-- `Transaction::expire`. `-` on `Nat` is Rust's `saturating_sub`. -/
def expire (t : Tx) (now : Nat) : Option Bytes × Tx :=
  if t.active ∧ TRANSACTION_TIMEOUT_MS ≤ now - t.started then (some t.cid, t.clear) else (none, t)

/-- The end of `feed`: whole, or not yet. -/
def finish (t : Tx) : Action × Tx :=
  if t.want ≤ t.buf.length then (.complete, { t with active := false }) else (.more, t)

/-- `feed`'s `if is_init` branch. -/
def judgeInit (t : Tx) (pkt : Bytes) (now : Nat) : Action × Tx :=
  let cid := pkt.take 4
  let cmd := pkt.getD 4 0 &&& 0x7f
  let want := (pkt.getD 5 0 <<< 8) ||| pkt.getD 6 0
  if cid = BROADCAST ∧ cmd ≠ CTAPHID_INIT then (.error cid ERR_INVALID_CHANNEL, t)
  else if cid = RESERVED then (.error cid ERR_INVALID_CHANNEL, t)
  else if cmd = CTAPHID_INIT then
    if want ≠ 8 then (.error cid ERR_INVALID_LEN, t)
    else
      let t := if t.active ∧ t.cid = cid then t.clear else t
      (.init cid ((pkt.drop INIT_HEADER).take 8), t)
  else if t.active ∧ t.cid ≠ cid then (.error cid ERR_CHANNEL_BUSY, t)
  else if MAX_MESSAGE < want then (.error cid ERR_INVALID_LEN, t)
  else
    finish { t with cid := cid, cmd := cmd, want := want, seq := 0, started := now,
                    active := true, buf := (pkt.drop INIT_HEADER).take (min want INIT_PAYLOAD) }

/-- `feed`'s `else` branch: a continuation packet. -/
def judgeCont (t : Tx) (pkt : Bytes) : Action × Tx :=
  let cid := pkt.take 4
  if !t.active then (.ignore, t)
  else if cid ≠ t.cid then (.ignore, t)
  else if pkt.getD 4 0 ≠ t.seq then (.error t.cid ERR_INVALID_SEQ, t.clear)
  else
    finish { t with seq := (t.seq + 1) % 256,
                    buf := t.buf ++ (pkt.drop CONT_HEADER).take (min (t.want - t.buf.length) CONT_PAYLOAD) }

def judge (t : Tx) (pkt : Bytes) (now : Nat) : Action × Tx :=
  if pkt.getD 4 0 &&& 0x80 ≠ 0 then judgeInit t pkt now else judgeCont t pkt

/-- `Transaction::feed`: too short, then time, then the packet. -/
def feed (t : Tx) (pkt : Bytes) (now : Nat) : Action × Tx :=
  if pkt.length < PACKET then (.ignore, t)
  else match expire t now with
    | (some stale, t') =>
      if pkt.take 4 = stale then (.error stale ERR_MSG_TIMEOUT, t')
      else judge { t' with expired := some stale } pkt now
    | (none, t') => judge t' pkt now

/-- A caller's loop: every packet, in order, at one instant. -/
def feedAll (t : Tx) (now : Nat) : List Bytes → List Action × Tx
  | [] => ([], t)
  | p :: ps =>
    let r := feed t p now
    let rs := feedAll r.2 now ps
    (r.1 :: rs.1, rs.2)

/-! ## Bytes -/

theorem pad_length (k : Nat) (xs : Bytes) (h : xs.length ≤ k) : (pad k xs).length = k := by
  simp [pad]; omega

theorem want_decodes (n : Nat) (h : n < 65536) :
    (((n >>> 8) % 256) <<< 8) ||| (n % 256) = n := by
  rw [← Nat.shiftLeft_add_eq_or_of_lt (Nat.mod_lt _ (by decide))]
  simp [Nat.shiftLeft_eq, Nat.shiftRight_eq_div_pow]
  omega

theorem cmd_decodes : ∀ c, c < 128 → (0x80 ||| c) &&& 0x80 ≠ 0 ∧ (0x80 ||| c) &&& 0x7f = c := by
  decide

theorem seq_is_not_init : ∀ s, s < 128 → s &&& 0x80 = 0 := by decide


theorem take_pad (k : Nat) (xs : Bytes) (m : Nat) (h : m = xs.length) : (pad k xs).take m = xs := by
  subst h; simp [pad]

theorem initPacket_length (cid : Bytes) (cmd : Nat) (data : Bytes) (hc : cid.length = 4) :
    (initPacket cid cmd data).length = PACKET := by
  simp [initPacket, pad, hc, PACKET, INIT_PAYLOAD]; omega

theorem contPacket_length (cid : Bytes) (s : Nat) (chunk : Bytes) (hc : cid.length = 4)
    (h : chunk.length ≤ CONT_PAYLOAD) : (contPacket cid s chunk).length = PACKET := by
  simp [contPacket, pad, hc, PACKET, CONT_PAYLOAD] at h ⊢; omega

/-- What the first packet does to an idle transaction. -/
theorem feed_initPacket (t : Tx) (cid : Bytes) (cmd now : Nat) (data : Bytes)
    (hcid : cid.length = 4) (hr : cid ≠ RESERVED) (hb : cid ≠ BROADCAST) (hcmd : cmd < 128)
    (hi : cmd ≠ CTAPHID_INIT) (hlen : data.length ≤ MAX_MESSAGE) (hidle : t.active = false) :
    feed t (initPacket cid cmd data) now =
      finish { t with cid := cid, cmd := cmd, want := data.length, seq := 0, started := now,
                      active := true, buf := data.take INIT_PAYLOAD } := by
  have hl := initPacket_length cid cmd data hcid
  have ⟨hbit, hc⟩ := cmd_decodes cmd hcmd
  have hw := want_decodes data.length (by simp [MAX_MESSAGE] at hlen; omega)
  have hmax : ¬ MAX_MESSAGE < data.length := by omega
  have hbuf : (pad INIT_PAYLOAD (data.take INIT_PAYLOAD)).take (min data.length INIT_PAYLOAD)
      = data.take INIT_PAYLOAD := take_pad _ _ _ (by simp [Nat.min_comm])
  rcases cid with _ | ⟨a, _ | ⟨b, _ | ⟨c, _ | ⟨d, _ | ⟨e, l⟩⟩⟩⟩⟩ <;> simp at hcid
  simp only [feed, hl, PACKET, Nat.lt_irrefl, ite_false, expire, hidle, Bool.false_eq_true,
    false_and, judge]
  simp [initPacket, judgeInit, hbit, hc, hw, hmax, hbuf, hr, hb, hi, hidle, INIT_HEADER]

/-- What a continuation packet does to the transaction it continues. -/
theorem feed_contPacket (t : Tx) (cid rest : Bytes) (now : Nat)
    (hcid : cid.length = 4) (hact : t.active = true) (htc : t.cid = cid) (hs : t.seq < 128)
    (htime : now - t.started < TRANSACTION_TIMEOUT_MS)
    (hwant : t.buf.length + rest.length = t.want) :
    feed t (contPacket cid t.seq (rest.take CONT_PAYLOAD)) now =
      finish { t with seq := (t.seq + 1) % 256, buf := t.buf ++ rest.take CONT_PAYLOAD } := by
  have hl := contPacket_length cid t.seq (rest.take CONT_PAYLOAD) hcid (by simp [Nat.min_le_left])
  have hnot := seq_is_not_init t.seq hs
  have hbuf : (pad CONT_PAYLOAD (rest.take CONT_PAYLOAD)).take (min (t.want - t.buf.length) CONT_PAYLOAD)
      = rest.take CONT_PAYLOAD := take_pad _ _ _ (by simp; omega)
  have hnexp : ¬ (TRANSACTION_TIMEOUT_MS ≤ now - t.started) := by omega
  rcases cid with _ | ⟨a, _ | ⟨b, _ | ⟨c, _ | ⟨d, _ | ⟨e, l⟩⟩⟩⟩⟩ <;> simp at hcid
  simp only [feed, hl, PACKET, Nat.lt_irrefl, ite_false, expire, hact, hnexp, and_false, judge]
  simp [contPacket, judgeCont, hnot, hact, htc, hbuf, CONT_HEADER]


theorem conts_nil (cid : Bytes) (s fuel : Nat) : conts cid s fuel [] = [] := by
  cases fuel <;> rfl

theorem replicate_more (n : Nat) (h : 0 < n) :
    Action.more :: (List.replicate (n - 1) Action.more ++ [Action.complete])
      = List.replicate n Action.more ++ [Action.complete] := by
  obtain ⟨m, rfl⟩ : ∃ m, n = m + 1 := ⟨n - 1, by omega⟩
  simp [List.replicate_succ]

theorem conts_ne_nil (cid : Bytes) (s fuel : Nat) (rest : Bytes) (h : rest ≠ []) (hf : 0 < fuel) :
    0 < (conts cid s fuel rest).length := by
  obtain ⟨x, xs, rfl⟩ := List.exists_cons_of_ne_nil h
  obtain ⟨f, rfl⟩ : ∃ f, fuel = f + 1 := ⟨fuel - 1, by omega⟩
  simp [conts]

/-- Every continuation packet `fragment` cuts, fed in order: `More` until the
last, `Complete` on it, and the rest of the message in the buffer. -/
theorem feedAll_conts (fuel : Nat) (t : Tx) (cid rest : Bytes) (now : Nat)
    (hcid : cid.length = 4) (hact : t.active = true) (htc : t.cid = cid)
    (hs : t.seq * CONT_PAYLOAD + rest.length ≤ 128 * CONT_PAYLOAD)
    (htime : now - t.started < TRANSACTION_TIMEOUT_MS)
    (hwant : t.buf.length + rest.length = t.want)
    (hfuel : rest.length ≤ fuel) (hne : rest ≠ []) :
    (feedAll t now (conts cid t.seq fuel rest)).1
        = List.replicate ((conts cid t.seq fuel rest).length - 1) .more ++ [.complete] ∧
      (feedAll t now (conts cid t.seq fuel rest)).2.cid = t.cid ∧
      (feedAll t now (conts cid t.seq fuel rest)).2.cmd = t.cmd ∧
      (feedAll t now (conts cid t.seq fuel rest)).2.want = t.want ∧
      (feedAll t now (conts cid t.seq fuel rest)).2.buf = t.buf ++ rest := by
  induction fuel generalizing t rest with
  | zero =>
    exfalso; apply hne; exact List.eq_nil_of_length_eq_zero (by omega)
  | succ fuel ih =>
    obtain ⟨x, xs, rfl⟩ := List.exists_cons_of_ne_nil hne
    have hs' : t.seq < 128 := by simp [CONT_PAYLOAD] at hs; omega
    have step := feed_contPacket t cid (x :: xs) now hcid hact htc hs' htime hwant
    simp only [conts, feedAll, step]
    by_cases hshort : (x :: xs).length ≤ CONT_PAYLOAD
    · have hdrop : (x :: xs).drop CONT_PAYLOAD = [] := List.drop_eq_nil_of_le hshort
      have htake : (x :: xs).take CONT_PAYLOAD = x :: xs := List.take_of_length_le hshort
      have hfin : t.want ≤ t.buf.length + (xs.length + 1) := by simp at hwant; omega
      simp [htake, hdrop, finish, hfin, conts_nil, feedAll]
    · have hlong : ¬ t.want ≤ (t.buf ++ (x :: xs).take CONT_PAYLOAD).length := by
        simp [CONT_PAYLOAD] at hwant hshort ⊢; omega
      simp only [finish, hlong, ite_false]
      generalize ht1 : ({ t with seq := (t.seq + 1) % 256, buf := t.buf ++ (x :: xs).take CONT_PAYLOAD } : Tx) = t1
      have hseq : t1.seq = (t.seq + 1) % 256 := by rw [← ht1]
      have hne' : (x :: xs).drop CONT_PAYLOAD ≠ [] := by
        intro h; have := congrArg List.length h; simp [CONT_PAYLOAD] at this hshort; omega
      have := ih t1 ((x :: xs).drop CONT_PAYLOAD) (by rw [← ht1]; exact hact) (by rw [← ht1]; exact htc)
        (by rw [← ht1]; simp [CONT_PAYLOAD] at hs hshort ⊢; omega) (by rw [← ht1]; exact htime)
        (by rw [← ht1]; simp [CONT_PAYLOAD] at hwant hshort ⊢; omega)
        (by simp [CONT_PAYLOAD] at hfuel ⊢; omega) hne'
      obtain ⟨h1, h2, h3, h4, h5⟩ := this
      have hpos := conts_ne_nil cid t1.seq fuel _ hne' (by simp [CONT_PAYLOAD] at hfuel hshort; omega)
      rw [← hseq]
      refine ⟨?_, ?_, ?_, ?_, ?_⟩
      · rw [h1]; simp only [List.length_cons, Nat.add_sub_cancel]
        exact replicate_more _ hpos
      · rw [h2, ← ht1]
      · rw [h3, ← ht1]
      · rw [h4, ← ht1]
      · rw [h5, ← ht1]; simp


/-- **`fragment` and `feed` are inverses, for every message length up to
`MAX_MESSAGE`.** Cut a message with `fragment`, hand the packets to an idle
transaction in order, and every packet but the last answers `More`, the last
answers `Complete`, and `message()` is the channel, the command and the bytes
that went in. -/
theorem fragment_then_feed (t : Tx) (cid : Bytes) (cmd now : Nat) (data : Bytes)
    (hcid : cid.length = 4) (hr : cid ≠ RESERVED) (hb : cid ≠ BROADCAST)
    (hcmd : cmd < 128) (hi : cmd ≠ CTAPHID_INIT) (hlen : data.length ≤ MAX_MESSAGE)
    (hidle : t.active = false) :
    (feedAll t now (fragment cid cmd data)).1
        = List.replicate ((fragment cid cmd data).length - 1) .more ++ [.complete] ∧
      (feedAll t now (fragment cid cmd data)).2.message = (cid, cmd, data) := by
  have step := feed_initPacket t cid cmd now data hcid hr hb hcmd hi hlen hidle
  simp only [fragment, feedAll, step]
  by_cases hshort : data.length ≤ INIT_PAYLOAD
  · have hdrop : data.drop INIT_PAYLOAD = [] := List.drop_eq_nil_of_le hshort
    have htake : data.take INIT_PAYLOAD = data := List.take_of_length_le hshort
    simp [htake, hdrop, finish, conts_nil, feedAll, Tx.message]
  · have hlong : ¬ data.length ≤ (data.take INIT_PAYLOAD).length := by
      simp [INIT_PAYLOAD] at hshort ⊢; omega
    simp only [finish, hlong, ite_false]
    have hne : data.drop INIT_PAYLOAD ≠ [] := by
      intro h; have := congrArg List.length h; simp [INIT_PAYLOAD] at this hshort; omega
    have := feedAll_conts data.length
      { t with cid := cid, cmd := cmd, want := data.length, seq := 0, started := now,
               active := true, buf := data.take INIT_PAYLOAD }
      cid (data.drop INIT_PAYLOAD) now hcid rfl rfl
      (by simp [CONT_PAYLOAD, MAX_MESSAGE, INIT_PAYLOAD] at hlen ⊢; omega) (by simp [TRANSACTION_TIMEOUT_MS])
      (by simp [INIT_PAYLOAD] at hshort ⊢; omega) (by simp) hne
    obtain ⟨h1, h2, h3, h4, h5⟩ := this
    have hpos := conts_ne_nil cid 0 data.length _ hne (by simp [INIT_PAYLOAD] at hshort; omega)
    refine ⟨?_, ?_⟩
    · rw [h1]; simp only [List.length_cons, Nat.add_sub_cancel]
      exact replicate_more _ hpos
    · simp only [Tx.message, h2, h3, h4, h5, List.take_append_drop, List.take_length]


/-! ## Each hypothesis is needed -/

def idle : Tx := { cid := RESERVED, cmd := 0, want := 0, buf := [], seq := 0, started := 0,
                   active := false, expired := none }

def A : Bytes := [0x0a, 0x0b, 0x0c, 0x0d]
def B : Bytes := [0x0e, 0x0f, 0x10, 0x11]

/-- Without `cmd ≠ CTAPHID_INIT`: an INIT is answered, never assembled. -/
theorem init_is_not_a_message :
    (feedAll idle 0 (fragment A CTAPHID_INIT (List.replicate 8 7))).1
      = [.init A (List.replicate 8 7)] := by decide

/-- Without `cid ≠ BROADCAST`. -/
theorem broadcast_is_refused :
    (feedAll idle 0 (fragment BROADCAST 0x01 [1, 2, 3])).1 = [.error BROADCAST ERR_INVALID_CHANNEL] := by
  decide

/-- Without `cid ≠ RESERVED`. -/
theorem reserved_is_refused :
    (feedAll idle 0 (fragment RESERVED 0x01 [1, 2, 3])).1 = [.error RESERVED ERR_INVALID_CHANNEL] := by
  decide

/-- Without `cmd < 128`: the top bit is the init flag, so it is not the command's. -/
theorem a_command_loses_its_top_bit :
    (feedAll idle 0 (fragment A 0x90 [1, 2, 3])).2.message = (A, 0x10, [1, 2, 3]) := by decide

/-- Without `data.length ≤ MAX_MESSAGE`: past it, the first packet is refused
with `ERR_INVALID_LEN` — refused, not truncated. -/
theorem past_the_limit_is_refused (t : Tx) (cid : Bytes) (cmd now : Nat) (data : Bytes)
    (hcid : cid.length = 4) (hr : cid ≠ RESERVED) (hb : cid ≠ BROADCAST)
    (hcmd : cmd < 128) (hi : cmd ≠ CTAPHID_INIT) (hidle : t.active = false)
    (hlen : MAX_MESSAGE < data.length) (hbcnt : data.length < 65536) :
    (feedAll t now (fragment cid cmd data)).1.head? = some (.error cid ERR_INVALID_LEN) := by
  have hl := initPacket_length cid cmd data hcid
  have ⟨hbit, hc⟩ := cmd_decodes cmd hcmd
  have hw := want_decodes data.length hbcnt
  rcases cid with _ | ⟨a, _ | ⟨b, _ | ⟨c, _ | ⟨d, _ | ⟨e, l⟩⟩⟩⟩⟩ <;> simp at hcid
  simp only [fragment, feedAll, feed, hl, PACKET, Nat.lt_irrefl, ite_false, expire, hidle,
    Bool.false_eq_true, false_and, judge]
  simp [initPacket, judgeInit, hbit, hc, hw, hlen, hr, hb, hi, hidle]

/-- Without `t.active = false`: another channel's half-sent message is in the way. -/
theorem a_busy_device_refuses :
    (feedAll { idle with active := true, cid := B, want := 100 } 0 (fragment A 0x01 [1, 2, 3])).1
      = [.error A ERR_CHANNEL_BUSY] := by decide


/-! ## Where `fragment` itself stops being right -/

theorem conts_length (cid : Bytes) (fuel s : Nat) (rest : Bytes) (h : rest.length ≤ fuel) :
    (conts cid s fuel rest).length = (rest.length + CONT_PAYLOAD - 1) / CONT_PAYLOAD := by
  induction fuel generalizing s rest with
  | zero => simp at h; simp [h, conts, CONT_PAYLOAD]
  | succ fuel ih =>
    cases rest with
    | nil => simp [conts, CONT_PAYLOAD]
    | cons x xs =>
      simp only [conts, List.length_cons]
      rw [ih _ _ (by simp [CONT_PAYLOAD] at h ⊢; omega)]
      simp [CONT_PAYLOAD]; omega

/-- The `k`th continuation packet carries sequence number `s + k`, mod 256. -/
theorem conts_seq (cid : Bytes) (hcid : cid.length = 4) (fuel s : Nat) (hs : s < 256)
    (rest : Bytes) (k : Nat) (hk : k < (conts cid s fuel rest).length) :
    ((conts cid s fuel rest)[k]).getD 4 0 = (s + k) % 256 := by
  induction fuel generalizing s rest k with
  | zero => simp [conts] at hk
  | succ fuel ih =>
    cases rest with
    | nil => simp [conts] at hk
    | cons x xs =>
      cases k with
      | zero =>
        rcases cid with _ | ⟨a, _ | ⟨b, _ | ⟨c, _ | ⟨d, _ | ⟨e, l⟩⟩⟩⟩⟩ <;> simp at hcid
        simp [conts, contPacket, Nat.mod_eq_of_lt hs]
      | succ k =>
        simp only [conts, List.getElem_cons_succ]
        rw [ih _ (Nat.mod_lt _ (by decide)) _ k (by simp [conts] at hk; omega)]
        omega

/-- **Up to 7609 bytes — CTAP-HID's own maximum — no continuation packet
`fragment` cuts has the top bit of its fifth byte set**, so `feed` can never
mistake one for the start of a message. -/
theorem fragment_to_7609_never_sets_the_init_bit (cid : Bytes) (hcid : cid.length = 4)
    (cmd : Nat) (data : Bytes) (hlen : data.length ≤ 7609) :
    ∀ p ∈ (fragment cid cmd data).tail, p.getD 4 0 &&& 0x80 = 0 := by
  intro p hp
  simp only [fragment, List.tail_cons] at hp
  obtain ⟨k, hk, rfl⟩ := List.mem_iff_getElem.mp hp
  have hl := conts_length cid data.length 0 (data.drop INIT_PAYLOAD) (by simp)
  rw [conts_seq cid hcid _ 0 (by decide) _ k hk]
  apply seq_is_not_init
  rw [hl] at hk; simp [CONT_PAYLOAD, INIT_PAYLOAD] at hk; omega

/-- **Past it, one does.** The 129th continuation packet carries sequence
number 128, and its fifth byte is `0x80`: to `feed`, the start of a new message.
`fragment` does not refuse a message this long; it cuts it wrong. -/
theorem past_7609_a_continuation_is_read_as_an_init (cid : Bytes) (hcid : cid.length = 4)
    (cmd : Nat) (data : Bytes) (hlen : 7609 < data.length) :
    ∃ p ∈ (fragment cid cmd data).tail, p.getD 4 0 &&& 0x80 ≠ 0 := by
  have hl := conts_length cid data.length 0 (data.drop INIT_PAYLOAD) (by simp)
  have hk : 128 < (conts cid 0 data.length (data.drop INIT_PAYLOAD)).length := by
    rw [hl]; simp [CONT_PAYLOAD, INIT_PAYLOAD]; omega
  refine ⟨(conts cid 0 data.length (data.drop INIT_PAYLOAD))[128], ?_, ?_⟩
  · simp only [fragment, List.tail_cons]; exact List.getElem_mem hk
  · rw [conts_seq cid hcid _ 0 (by decide) _ 128 hk]; decide


/-- How many packets: one, and one more for every 59 bytes past the first 57. -/
theorem fragment_length (cid : Bytes) (cmd : Nat) (data : Bytes) :
    (fragment cid cmd data).length = 1 + (data.length - INIT_PAYLOAD + CONT_PAYLOAD - 1) / CONT_PAYLOAD := by
  simp only [fragment, List.length_cons]
  rw [conts_length cid data.length 0 _ (by simp)]
  simp; omega

/-- crates/ctap-hid's `a_1024_byte_message_takes_eighteen_packets`, for every
1024-byte message rather than one. -/
theorem a_1024_byte_message_takes_eighteen_packets (cid : Bytes) (cmd : Nat) (data : Bytes)
    (h : data.length = MAX_MESSAGE) : (fragment cid cmd data).length = 18 := by
  rw [fragment_length, h]; decide

/-! ## What each proof rests on

Printed when this file is checked. A proof that skipped a step would list
`sorryAx` here; these list only the axioms of Lean itself. -/

#print axioms fragment_then_feed
#print axioms a_1024_byte_message_takes_eighteen_packets
#print axioms init_is_not_a_message
#print axioms broadcast_is_refused
#print axioms reserved_is_refused
#print axioms a_command_loses_its_top_bit
#print axioms past_the_limit_is_refused
#print axioms a_busy_device_refuses
#print axioms fragment_to_7609_never_sets_the_init_bit
#print axioms past_7609_a_continuation_is_read_as_an_init

end CtapHid
