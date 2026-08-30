// SPDX-License-Identifier: Apache-2.0
//! **exp163 — how long is a secret in the open.**
//!
//! The fifth experiment on the [signing road](../README.md#the-signing-road),
//! and the remedy [exp160](../exp160-a-secret-too-big-to-hide/) asked for after
//! [exp162](../exp162-how-wide-can-a-wall-be/) took the other answer away.
//!
//! exp159 put a key somewhere Non-secure code cannot read. exp160 found a copy
//! of it in memory Non-secure code *can* read, left there by the act of using
//! it. exp162 then measured the wall and found it four bytes wide, so there is
//! no arrangement of `ACCESSCTRL.SRAM[n]` that covers 65,696 bytes of expanded
//! signing key. One answer remains — **use the key, then wipe** — and this is
//! the experiment that measures whether it works and what it costs.
//!
//! It does not measure that by sweeping its own memory afterwards and reporting
//! that it found nothing. exp160 swept, and a sweep run by the program that did
//! the signing tells you what that program's sweep can see. Here a **second
//! core, demoted to Non-secure, reads the whole 512 KB over and over while the
//! first core signs**, and the finding is the shape of what it saw: nothing,
//! then the key, then nothing again — and exactly where the second "nothing"
//! starts.
//!
//! # What was measured before any of this was designed
//!
//! | fact | how | what it changed |
//! |---|---|---|
//! | `ACCESSCTRL` has **ten** SRAM registers, `n < 10` | read the PAC | bank 9 exists and is gated separately from bank 8, so the watcher can live in one while the secret lives in the other |
//! | `ACCESSCTRL.TIMER0` **defaults to Secure access from any master** | read the PAC | ← **a Non-secure core on a stock RP2350 cannot read the clock.** The watcher counts its own passes instead of microseconds, and candidate 2 measures the refusal rather than quoting it |
//! | one ML-DSA-65 signature takes **74–97 ms** on this part | exp160, on hardware | the window is long enough to resolve at several passes, and short enough that a whole candidate fits a 15 s budget |
//! | exp160's byte-granular sweep of 471 KB took **~160 ms** | exp160's own log | ← too slow to watch a 97 ms signature. The watcher compares a **word** at 4-byte alignment, and candidate 4's own sweep is the byte-granular arbiter |
//! | the copy exp160 found sat at `0x20051cc0` | exp160, on hardware | word-aligned, so a word-aligned watcher can see it — an observation, not a guarantee, which is why the byte-granular sweep is still run |
//! | signing reached **369,456 bytes** below the caller's stack pointer | exp160, on hardware | ← the frame is not the region. Candidate 6 exists because of this number, and it does not quote exp160's 188,116-byte frame: `sign_once` reads `MSP` on entry, so the frame candidate 6 wipes is this build's, measured on the board |
//!
//! # Three things this had to get right, and one it deliberately gives away
//!
//! ## 1. The harness must not be the leak.
//!
//! The watcher looks for the 32-byte seed across the **whole** main SRAM, not
//! just the painted stack, so any copy the harness itself made would be found
//! and counted as a leak. So the seed is never materialised outside the region
//! that gets wiped: [`sign_once`] reads it out of bank 8 into its own frame and
//! nowhere else, the needle handed to the watcher is copied bank 8 → bank 9 a
//! word at a time through registers, and the buffer the TRNG fills on the first
//! boot is overwritten before it is left behind. SRAM survives a watchdog
//! reset, so a copy left on boot 1 would still be there on boot 5.
//!
//! Candidate 3 is what makes that claim checkable: the watcher runs for a
//! second and a half with nothing signing, and must see **nothing**.
//!
//! ## 2. The watcher must not live where it is looking.
//!
//! Core 1's stack and its mailbox are in **bank 9**, the second of the two 4 KB
//! banks — outside the 512 KB it scans, so it can never find its own copy of
//! the needle, and outside bank 8, so it never needs the access candidate 1
//! proves it does not have.
//!
//! ## 3. Phase boundaries must be exact.
//!
//! "Was it visible after the wipe?" cannot be answered by comparing pass
//! numbers across a race. Core 0 bumps an **epoch**; core 1 clears its counters
//! at the top of the next pass and acknowledges; core 0 waits for the
//! acknowledgement before going on. Sightings are therefore attributable to one
//! phase and not to a boundary.
//!
//! ## 4. The attacker is handed the answer, on purpose.
//!
//! Candidate 1 shows bank 8 refuses core 1. Candidates 3–6 then copy the seed
//! into bank 9 where core 1 can read it. That is not an accident and it is not
//! a hole: a watcher that had to *recognise* an ML-DSA key by its structure
//! would be measuring its own cleverness. This one is told exactly what to look
//! for, which makes it stronger than any real attacker — so when it goes quiet
//! after the wipe, the quiet means something.

#![no_std]
#![no_main]

use core::sync::atomic::{compiler_fence, AtomicBool, AtomicU32, Ordering};

use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::Trng;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Instant, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use hybrid_array::Array;
use ml_dsa::{MlDsa65, Seed, SigningKey};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// The main SRAM: eight banks, and exp162 measured that they are interleaved
/// four bytes at a time, so none of this can be walled off. It is all open to
/// Non-secure code, and that is the point.
const SRAM_LO: usize = 0x2000_0000;
const SRAM_HI: usize = 0x2008_0000;

/// Bank 8, 4 KB of its own. The seed lives here and is shut to Non-secure code
/// for every candidate that signs.
const BANK8: usize = 0x2008_0000;
const BANK8_REG: usize = 8;

/// Bank 9, the other 4 KB. Core 1's stack, its mailbox and this run's results.
/// Open to Non-secure code throughout — the watcher has to live somewhere, and
/// it must not be somewhere it is scanning.
const BANK9: usize = 0x2008_1000;

const CORE1_STACK_BYTES: usize = 3072;
const MAILBOX: usize = BANK9 + CORE1_STACK_BYTES;

const MB_MAGIC: usize = 0;
const MB_UP: usize = 4;
const MB_GO: usize = 8;
const MB_STOP: usize = 12;
const MB_DONE: usize = 16;
const MB_FAULTED: usize = 20;
const MB_JOB: usize = 24;
const MB_PASSES: usize = 28;
const MB_HITS: usize = 32;
const MB_FIRST_PASS: usize = 36;
const MB_LAST_PASS: usize = 40;
const MB_FIRST_ADDR: usize = 44;
const MB_LO: usize = 48;
const MB_HI: usize = 52;
const MB_READ: usize = 56;
const MB_EPOCH: usize = 60;
const MB_EPOCH_ACK: usize = 64;
/// Eight words. The seed as the watcher must see it in memory: little-endian
/// words, so a single load can be compared against one.
const MB_NEEDLE: usize = 96;

/// Per-candidate results, kept in bank 9 so the final report can print all
/// seven together instead of asking the reader to scroll back through seven
/// boots. Bank 8 survives a watchdog reset — exp159, exp160 and exp162 all
/// showed that — and bank 9 is assumed to behave the same way. Assumed, and
/// then checked: a candidate whose record reads back as zeros is printed as
/// "no record", not skipped.
const RESULTS: usize = MAILBOX + 128;
const R_STRIDE: usize = 80;
const R_FLAG: usize = 0;
const R_STALE: usize = 4;
const R_QUIET: usize = 8;
const R_HITS: usize = 12;
const R_POST: usize = 16;
const R_PASSES: usize = 20;
const R_FIRST_PASS: usize = 24;
const R_LAST_PASS: usize = 28;
const R_SIGN_START: usize = 32;
const R_SIGN_END: usize = 36;
const R_SIGN_US: usize = 40;
const R_WIPE_US: usize = 44;
const R_SWEEP: usize = 48;
const R_DEPTH: usize = 52;
const R_SWEEP_ADDR: usize = 56;
const R_EXPAND_US: usize = 60;
const R_FRAME: usize = 64;
const RESULT_MAGIC: u32 = 0x5245_5331;
/// Bank 9 is 4 KB and core 1's stack has the first 3 KB of it. Everything below
/// has to fit in what is left, and a layout that quietly ran off the end would
/// corrupt whatever the next bank holds.
const _: () = assert!(
    CORE1_STACK_BYTES + 128 + (CANDIDATES as usize) * R_STRIDE <= 4096,
    "the mailbox and result records do not fit in bank 9"
);

/// Deliberately not exp159's, exp160's or exp162's. Bank 8 survives a reflash,
/// so a board that ran exp160 an hour ago still has exp160's seed sitting
/// there, and this firmware must never mistake it for its own.
const KEY_MAGIC: u32 = 0x4B45_5934;
const RUN_MAGIC: u32 = 0x4B45_5935;

/// NSU (bit 0) and NSP (bit 1) — the two bits that are the wall. Field order
/// established from silicon by exp156.
const NON_SECURE_BITS: u32 = 0b11;
const ACCESSCTRL_KEY: u32 = 0xACCE_0000;

const SEED_LEN: usize = 32;
const PK_LEN: usize = 1952;
const SIG_LEN: usize = 3309;

const JOB_READ_BANK8: u32 = 1;
const JOB_READ_TIMER: u32 = 2;
const JOB_SCAN: u32 = 3;

const C_NS_READS_KEY: u8 = 1;
const C_NS_READS_CLOCK: u8 = 2;
const C_QUIET: u8 = 3;
const C_WATCHED: u8 = 4;
const C_WIPED: u8 = 5;
const C_FRAME_ONLY: u8 = 6;
const C_PRICE: u8 = 7;
const CANDIDATES: u8 = 7;

/// The message every candidate signs.
///
/// Fixed, published, and not from the TRNG — which is a change from exp159 and
/// exp160, where a fresh challenge was the whole point. Here the point is
/// different. ML-DSA signing is **rejection-sampled**, so the number of
/// attempts and therefore the time depends on the message: exp160 measured
/// **3.9x** between two board signatures of different messages. With a random
/// message per candidate, "candidate 4 took 178 ms and candidate 7 took 296 ms"
/// says nothing about what the watcher costs, because the two did different
/// amounts of work.
///
/// Fix the message and fix the seed, and FIPS-204 deterministic signing does
/// **byte-identical work** every time. Then candidate 7 minus candidate 4 is
/// the price of being watched, and the four signature fingerprints have to come
/// out equal — which is also how a reader can tell the signature was really
/// computed each time and not optimised away.
const MESSAGE: [u8; SEED_LEN] = *b"exp163: the same message, always";

/// What the paint is, and why it is not zero: zero is what a wiped region looks
/// like, and this experiment wipes with zero. Painting with zero would make
/// "nothing wrote here" and "the wipe wrote here" the same reading.
const PAINT: u32 = 0xC5C5_C5C5;

/// Keep the floor clear of everything the linker placed. `__ebss` is the top of
/// the statics; a kilobyte above it is the first address that is only ever
/// stack.
const PAINT_MARGIN: usize = 1024;

/// How far below the caller's stack pointer the painted, wiped and swept region
/// starts.
///
/// It has to clear two things, not one. [`paint`] and [`wipe`] are called from
/// that caller, so their own frames sit in this gap — that part is tens of
/// bytes. The other part is that **interrupts stay on while half a megabyte is
/// being written**: a USB or timer interrupt taken mid-wipe pushes an exception
/// frame at the current stack pointer and runs a handler below it, and if the
/// wipe's last writes reach that far it corrupts a live frame and returns to
/// nowhere. exp160 left 64 bytes here, which is smaller than an exception frame
/// alone. 4 KB is not a calculation, it is room.
const STACK_MARGIN: usize = 4096;

/// Generous on purpose: a candidate paints half a megabyte, signs, wipes half a
/// megabyte and then sweeps the whole 512 KB a byte at a time, all of it slowed
/// down by a second core hammering the same buses. A budget shorter than a step
/// that was going to succeed reports a death that never happened.
const STEP_BUDGET_US: u32 = 15_000_000;

const LAST_BOOT: u32 = 14;
const REFLASH_WINDOW_S: u64 = 5;

const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp163 secret in the open";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

extern "C" {
    static __ebss: u32;
}

static STOPPED: AtomicBool = AtomicBool::new(false);

/// The stack pointer as it stood on entry to [`sign_once`], after the prologue
/// had allocated the frame. Candidate 6 wipes down to here and no further, so
/// the question "is the frame enough?" is asked about **this build's** frame
/// and not about a number copied from another experiment's disassembly.
static FRAME_SP: AtomicU32 = AtomicU32::new(0);

static mut SIGNATURE: [u8; SIG_LEN] = [0; SIG_LEN];
static mut PUBLIC_KEY: [u8; PK_LEN] = [0; PK_LEN];

/// Core 0 faulting is the case nothing else covers, so it goes to the harness.
/// Core 1 faulting is what candidates 1 and 2 are trying to cause, and it
/// cannot reach the watchdog anyway — `WATCHDOG` defaults to
/// Secure-Privileged-only, so `breadcrumb::reboot` from here would fault inside
/// the fault handler.
#[exception]
unsafe fn HardFault(_ef: &ExceptionFrame) -> ! {
    if embassy_rp::pac::SIO.cpuid().read() != 0 {
        mb_write(MB_FAULTED, 1);
        loop {
            cortex_m::asm::wfe();
        }
    }
    breadcrumb::reboot()
}

// ---------------------------------------------------------------- bank 8 / 9

fn keystore_word(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((BANK8 + off) as *const u32) }
}

fn keystore_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((BANK8 + off) as *mut u32, v) }
}

fn mb_read(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((MAILBOX + off) as *const u32) }
}

fn mb_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((MAILBOX + off) as *mut u32, v) }
}

fn res_read(n: u8, off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((RESULTS + (n as usize - 1) * R_STRIDE + off) as *const u32) }
}

fn res_write(n: u8, off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((RESULTS + (n as usize - 1) * R_STRIDE + off) as *mut u32, v) }
}

/// Open or shut one SRAM bank to Non-secure code. Every `ACCESSCTRL` write
/// needs `0xACCE` in bits 31:16 — measured by exp156, re-derived by exp158 —
/// and `modify()` would drop it every time.
fn bank_non_secure(bank: usize, allowed: bool) {
    let reg = embassy_rp::pac::ACCESSCTRL.sram(bank);
    let before = reg.read().0;
    let bits = if allowed { before | NON_SECURE_BITS } else { before & !NON_SECURE_BITS };
    reg.write_value(embassy_rp::pac::accessctrl::regs::Access(ACCESSCTRL_KEY | (bits & 0xFFFF)));
}

fn demote_core1() {
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    let cur = r.read().0;
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        ACCESSCTRL_KEY | ((cur | 0b10) & 0xFFFF),
    ));
}

/// The seed, as eight little-endian words, copied bank 8 → bank 9 through
/// registers. There is deliberately no `[u8; 32]` anywhere in this function:
/// one would live on core 0's stack, inside the region the watcher scans, and
/// candidate 3 would find the harness instead of the signature.
fn publish_needle() {
    for i in 0..8 {
        mb_write(MB_NEEDLE + i * 4, keystore_word(4 + i * 4).swap_bytes());
    }
}

/// The first byte of the seed, for the cheap first test in [`sweep_seed`].
/// Bank 8 stores the seed big-endian, so byte 0 is the top of word 0.
fn seed_byte0() -> u8 {
    (keystore_word(4) >> 24) as u8
}

/// Does the 32-byte string at `a` equal the seed? Compared against bank 8 a
/// byte at a time, so the comparison never assembles a copy of the seed
/// anywhere the sweep could later find it.
fn seed_matches_at(a: usize) -> bool {
    for i in 0..8 {
        let w = keystore_word(4 + i * 4);
        for j in 0..4 {
            let want = (w >> (24 - 8 * j)) as u8;
            if unsafe { core::ptr::read_volatile((a + i * 4 + j) as *const u8) } != want {
                return false;
            }
        }
    }
    true
}

// ------------------------------------------------------------------- core 1

/// The watcher. Reads the whole main SRAM over and over looking for the needle
/// it was given, and counts. It never touches bank 8, it never calls anything
/// that allocates, and its stack is in bank 9.
///
/// It counts passes rather than microseconds because it cannot read a clock:
/// `ACCESSCTRL.TIMER0` defaults to Secure access from any master, which is what
/// candidate 2 measures.
fn scan() {
    let lo = mb_read(MB_LO) as usize;
    let hi = mb_read(MB_HI) as usize;
    let w0 = mb_read(MB_NEEDLE);

    let mut passes = 0u32;
    let mut hits = 0u32;
    let mut epoch = mb_read(MB_EPOCH);
    mb_write(MB_EPOCH_ACK, epoch);

    while mb_read(MB_STOP) == 0 {
        // Phase boundary. Core 0 bumps the epoch and waits for this
        // acknowledgement, so every sighting below belongs to one phase.
        let e = mb_read(MB_EPOCH);
        if e != epoch {
            epoch = e;
            hits = 0;
            mb_write(MB_HITS, 0);
            mb_write(MB_FIRST_PASS, 0);
            mb_write(MB_LAST_PASS, 0);
            mb_write(MB_FIRST_ADDR, 0);
            mb_write(MB_EPOCH_ACK, e);
        }

        let mut a = lo;
        while a + SEED_LEN <= hi {
            if unsafe { core::ptr::read_volatile(a as *const u32) } == w0 && needle_at(a) {
                hits += 1;
                mb_write(MB_HITS, hits);
                if mb_read(MB_FIRST_PASS) == 0 {
                    mb_write(MB_FIRST_PASS, passes + 1);
                    mb_write(MB_FIRST_ADDR, a as u32);
                }
                mb_write(MB_LAST_PASS, passes + 1);
            }
            a += 4;
        }

        passes += 1;
        mb_write(MB_PASSES, passes);
    }
}

/// The other seven words of the needle, from bank 9. Word-aligned: the watcher
/// trades the unaligned cases for the speed it needs to see a 97 ms signature
/// at all, and candidate 4's byte-granular sweep is what covers them.
fn needle_at(a: usize) -> bool {
    for i in 1..8 {
        let want = mb_read(MB_NEEDLE + i * 4);
        if unsafe { core::ptr::read_volatile((a + i * 4) as *const u32) } != want {
            return false;
        }
    }
    true
}

fn core1_main() -> ! {
    // PRIMASK does not mask HardFault, so this does not hide the refusals
    // candidates 1 and 2 are looking for. It keeps the scan loop from being
    // interrupted by anything that would land on a stack in bank 9.
    cortex_m::interrupt::disable();

    mb_write(MB_UP, 1);
    while mb_read(MB_GO) == 0 {
        cortex_m::asm::nop();
    }

    match mb_read(MB_JOB) {
        JOB_READ_BANK8 => {
            let v = unsafe { core::ptr::read_volatile(BANK8 as *const u32) };
            mb_write(MB_READ, v);
        }
        JOB_READ_TIMER => {
            let v = embassy_rp::pac::TIMER0.timerawl().read();
            mb_write(MB_READ, v);
        }
        JOB_SCAN => scan(),
        _ => {}
    }

    mb_write(MB_DONE, 1);
    loop {
        cortex_m::asm::wfe();
    }
}

/// Core 1's stack is in bank 9, forged rather than declared: a `static` would
/// be placed by the linker in the main SRAM, which is the region being scanned
/// and the region being wiped, and candidate 3 would then be measuring the
/// watcher.
async fn launch_core1(
    core1: embassy_rp::Peri<'static, embassy_rp::peripherals::CORE1>,
    job: u32,
) -> bool {
    mb_write(MB_JOB, job);
    let stack: &'static mut Stack<CORE1_STACK_BYTES> =
        unsafe { &mut *(BANK9 as *mut Stack<CORE1_STACK_BYTES>) };
    spawn_core1(core1, stack, core1_main);
    // Bounded, and it says so if it runs out. An unbounded wait here reads as a
    // dead candidate in the final matrix and tells nobody which half died.
    let mut waited = 0;
    while mb_read(MB_UP) == 0 && waited < 200 {
        Timer::after(Duration::from_millis(10)).await;
        waited += 1;
    }
    if mb_read(MB_UP) == 0 {
        log!("  core 1 never came up after 2 s.");
        return false;
    }
    // Open and Secure through startup, then demoted — exp162's ordering lesson.
    demote_core1();
    mb_write(MB_GO, 1);
    true
}

/// Bump the phase and wait for the watcher to acknowledge. Returns false if it
/// never did, which is reported rather than ignored.
async fn new_phase(epoch: &mut u32) -> bool {
    *epoch += 1;
    mb_write(MB_EPOCH, *epoch);
    let mut waited = 0;
    while mb_read(MB_EPOCH_ACK) != *epoch && waited < 400 {
        Timer::after(Duration::from_millis(5)).await;
        waited += 1;
    }
    mb_read(MB_EPOCH_ACK) == *epoch
}

// -------------------------------------------------------- paint, wipe, sweep

fn paint_floor() -> usize {
    let ebss = core::ptr::addr_of!(__ebss) as usize;
    (ebss + PAINT_MARGIN + 3) & !3
}

fn stack_here() -> usize {
    let probe = 0u32;
    core::ptr::addr_of!(probe) as usize
}

fn paint(lo: usize, hi: usize) {
    let mut a = lo;
    while a < hi {
        unsafe { core::ptr::write_volatile(a as *mut u32, PAINT) };
        a += 4;
    }
}

/// The remedy itself. Volatile so that no optimiser decides a region nobody
/// reads afterwards did not need writing — which is exactly the transformation
/// that makes hand-written wipes disappear in release builds.
fn wipe(lo: usize, hi: usize) -> u32 {
    let t0 = Instant::now();
    let mut a = lo;
    while a < hi {
        unsafe { core::ptr::write_volatile(a as *mut u32, 0) };
        a += 4;
    }
    compiler_fence(Ordering::SeqCst);
    t0.elapsed().as_micros() as u32
}

fn low_water(lo: usize, hi: usize) -> usize {
    let mut a = lo;
    while a < hi {
        if unsafe { core::ptr::read_volatile(a as *const u32) } != PAINT {
            return a;
        }
        a += 4;
    }
    hi
}

/// The arbiter: byte-granular, so it catches copies the word-aligned watcher
/// would step over. One byte load per position until the first byte matches,
/// which is what keeps a 512 KB sweep affordable.
fn sweep_seed(lo: usize, hi: usize) -> (u32, u32) {
    let b0 = seed_byte0();
    let mut hits = 0u32;
    let mut first = 0u32;
    let mut a = lo;
    while a + SEED_LEN <= hi {
        if unsafe { core::ptr::read_volatile(a as *const u8) } == b0 && seed_matches_at(a) {
            hits += 1;
            if first == 0 {
                first = a as u32;
            }
        }
        a += 1;
    }
    (hits, first)
}

// ------------------------------------------------------------- the signature

/// The seed, materialised in this frame and nowhere else. `#[inline(always)]`
/// is load-bearing: out of line, the 32 bytes would live in a frame this
/// experiment does not paint, wipe or account for.
#[inline(always)]
fn seed_from_bank8() -> Seed {
    let mut b = [0u8; SEED_LEN];
    for i in 0..8 {
        b[i * 4..i * 4 + 4].copy_from_slice(&keystore_word(4 + i * 4).to_be_bytes());
    }
    Array(b)
}

/// One signature, in one stack frame, with nothing held across an await.
///
/// `#[inline(never)]` keeps the 65,696-byte `SigningKey` out of the async
/// task's future — which is a static, and would have grown by that much — and
/// makes the frame a single measurable object, which is what candidate 6 wipes.
#[inline(never)]
fn sign_once(msg: &[u8], pk_out: &mut [u8; PK_LEN], sig_out: &mut [u8; SIG_LEN]) {
    // First statement in the body, so the prologue has already moved the stack
    // pointer down by the whole frame.
    FRAME_SP.store(cortex_m::register::msp::read(), Ordering::Relaxed);
    let s = seed_from_bank8();
    let sk = SigningKey::<MlDsa65>::from_seed(&s);
    pk_out.copy_from_slice(sk.expanded_key().verifying_key().encode().as_slice());
    let sig = sk.expanded_key().sign_deterministic(msg, b"").unwrap();
    sig_out.copy_from_slice(sig.encode().as_slice());
}

/// The half of the price nobody has ever timed: turning 32 bytes back into
/// 65,696. A design that keeps only the seed behind the wall pays this on every
/// single signature.
#[inline(never)]
fn expand_only() -> u32 {
    let s = seed_from_bank8();
    let t0 = Instant::now();
    let sk = SigningKey::<MlDsa65>::from_seed(&s);
    let us = t0.elapsed().as_micros() as u32;
    core::hint::black_box(&sk);
    us
}

// ----------------------------------------------------------------- the tasks

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        let (on, off) = if STOPPED.load(Ordering::Relaxed) { (100, 100) } else { (50, 950) };
        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        Timer::after(Duration::from_millis(off)).await;
    }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn reboot_task(
    control: ControlChanged<'static>,
    receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    usb_reboot::watch(control, receiver).await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// Thirty-two bytes of something public, in hex. It exists to be read by a
/// person and to be a use the optimiser cannot argue with.
async fn fingerprint(tag: &str, b: &[u8]) {
    const H: &[u8; 16] = b"0123456789abcdef";
    let mut out = [0u8; 64];
    for (i, &x) in b.iter().take(32).enumerate() {
        out[i * 2] = H[(x >> 4) as usize];
        out[i * 2 + 1] = H[(x & 0x0f) as usize];
    }
    log!("  {} {}", tag, core::str::from_utf8(&out).unwrap_or("??"));
    Timer::after(Duration::from_millis(25)).await;
}

fn candidate_name(n: u8) -> &'static str {
    match n {
        C_NS_READS_KEY => "1 Non-secure reads bank 8, DENIED",
        C_NS_READS_CLOCK => "2 Non-secure reads the clock, DENIED",
        C_QUIET => "3 the watcher runs, nothing signs",
        C_WATCHED => "4 the watcher watches one signature",
        C_WIPED => "5 the same, and the region is wiped",
        C_FRAME_ONLY => "6 only the signing frame is wiped",
        C_PRICE => "7 the price, with nobody watching",
        _ => "?",
    }
}

/// One pause per line, on every path, outside the match. exp160 lost the end of
/// its report to `usb-log`'s sixteen-deep queue, which drops the newest line
/// when it is full, and exp162 lost it a second time by pacing inside a `match`
/// whose arms are expressions and not statements.
async fn report(note: &breadcrumb::Note) {
    for n in 1..=CANDIDATES {
        match note.outcome(n) {
            breadcrumb::NOT_ATTEMPTED => log!("  {} - not reached", candidate_name(n)),
            breadcrumb::DIED => log!("  {} - KILLED CORE 0", candidate_name(n)),
            breadcrumb::SURVIVED_A => log!("  {} - as expected", candidate_name(n)),
            _ => log!("  {} - NOT as expected", candidate_name(n)),
        }
        Timer::after(Duration::from_millis(25)).await;
    }
}

/// The numbers, all seven candidates together, out of bank 9.
async fn numbers() {
    for n in 1..=CANDIDATES {
        if res_read(n, R_FLAG) != RESULT_MAGIC {
            log!("  {} - no record in bank 9", n);
            Timer::after(Duration::from_millis(25)).await;
            continue;
        }
        log!(
            "  {} stale={} quiet={} during={} after={} sweep={}",
            n,
            res_read(n, R_STALE),
            res_read(n, R_QUIET),
            res_read(n, R_HITS),
            res_read(n, R_POST),
            res_read(n, R_SWEEP)
        );
        Timer::after(Duration::from_millis(25)).await;
        log!(
            "      passes={} seen {}..{} of sign {}..{}",
            res_read(n, R_PASSES),
            res_read(n, R_FIRST_PASS),
            res_read(n, R_LAST_PASS),
            res_read(n, R_SIGN_START),
            res_read(n, R_SIGN_END)
        );
        Timer::after(Duration::from_millis(25)).await;
        log!(
            "      sign={} us wipe={} us expand={} us depth={} B",
            res_read(n, R_SIGN_US),
            res_read(n, R_WIPE_US),
            res_read(n, R_EXPAND_US),
            res_read(n, R_DEPTH)
        );
        Timer::after(Duration::from_millis(25)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let note = breadcrumb::read(163);

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("163");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; CONTROL_BUF_LEN]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; CONTROL_BUF_LEN]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    // Report before risk, always.
    Timer::after(Duration::from_secs(3)).await;
    log!("exp163 up, boot #{}. The matrix so far:", note.boot);
    report(&note).await;

    // The mailbox is in bank 9, which survives a reset the same way bank 8
    // does. Every boot is one candidate, so every boot starts it clean — except
    // the results area, which is the one thing that has to carry across.
    let fresh_run = mb_read(MB_MAGIC) != RUN_MAGIC;
    for off in (0..MB_NEEDLE + 32).step_by(4) {
        mb_write(off, 0);
    }
    mb_write(MB_MAGIC, RUN_MAGIC);
    if fresh_run {
        for n in 1..=CANDIDATES {
            res_write(n, R_FLAG, 0);
        }
        log!("bank 9 cleared: mailbox and seven empty result records.");
    }

    // Every bank open and both cores Secure at the top of every boot, so that a
    // refusal below is this firmware's doing and not something inherited.
    // exp162 measured that neither survives a watchdog reset; this does not
    // depend on that measurement, it repeats the write.
    let inherited_ns = embassy_rp::pac::ACCESSCTRL.force_core_ns().read().0;
    let inherited_b8 = embassy_rp::pac::ACCESSCTRL.sram(BANK8_REG).read().0;
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        ACCESSCTRL_KEY | ((inherited_ns & !0b10) & 0xFFFF),
    ));
    bank_non_secure(BANK8_REG, true);
    bank_non_secure(9, true);
    log!("inherited FORCE_CORE_NS={:#010x} SRAM8={:#010x}; both reset.", inherited_ns, inherited_b8);

    // The seed. Generated here or already in bank 8 from a previous boot.
    let mut trng = Trng::new(p.TRNG, Irqs, embassy_rp::trng::Config::default());
    if keystore_word(0) == KEY_MAGIC {
        log!("bank 8 still holds this run's seed: it survived the reboot.");
    } else {
        // Every 32-byte string is a valid ML-DSA seed, so unlike exp159 there is
        // nothing to retry here.
        let mut k = [0u8; SEED_LEN];
        trng.blocking_fill_bytes(&mut k);
        for i in 0..8 {
            let mut w = [0u8; 4];
            w.copy_from_slice(&k[i * 4..i * 4 + 4]);
            keystore_write(4 + i * 4, u32::from_be_bytes(w));
        }
        keystore_write(0, KEY_MAGIC);
        // The harness taking its own medicine, and not optionally: SRAM
        // survives a watchdog reset, so these 32 bytes would still be lying in
        // the main SRAM when candidate 3 swept it four boots later and reported
        // the harness as a leak.
        for b in k.iter_mut() {
            unsafe { core::ptr::write_volatile(b as *mut u8, 0) };
        }
        compiler_fence(Ordering::SeqCst);
        log!("new ML-DSA-65 seed from the TRNG, into bank 8; the buffer was wiped.");
    }

    let lo = paint_floor();
    let hi = (stack_here() - STACK_MARGIN) & !3;
    log!("region: {:#010x}..{:#010x}, {} bytes.", lo, hi, hi - lo);
    log!("message (fixed, public): \"{}\"", core::str::from_utf8(&MESSAGE).unwrap_or("??"));

    let next = note.next_unattempted(CANDIDATES);
    let finishing = next.is_none() || note.boot >= LAST_BOOT;

    if !finishing {
        let n = next.unwrap();

        log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
        Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

        breadcrumb::arm(STEP_BUDGET_US);
        breadcrumb::step(n);
        log!("candidate {}", candidate_name(n));
        res_write(n, R_FLAG, RESULT_MAGIC);

        let ok = match n {
            // The two refusals. Both are ACCESSCTRL saying no to a demoted core
            // 1, and neither can share a boot with the other: the first one
            // faults, and a faulted core does not go on to try the second.
            C_NS_READS_KEY | C_NS_READS_CLOCK => {
                let job = if n == C_NS_READS_KEY {
                    bank_non_secure(BANK8_REG, false);
                    log!("  bank 8 SHUT; TIMER0 left at its power-on default.");
                    JOB_READ_BANK8
                } else {
                    let t = embassy_rp::pac::ACCESSCTRL.timer0().read().0;
                    log!("  bank 8 open; ACCESSCTRL.TIMER0 reads {:#010x}, untouched.", t);
                    JOB_READ_TIMER
                };

                let up = launch_core1(p.CORE1, job).await;
                Timer::after(Duration::from_secs(1)).await;

                let faulted = mb_read(MB_FAULTED) == 1;
                let _ = up;
                let done = mb_read(MB_DONE) == 1;
                log!("  core 1: done={} faulted={} read={:#010x}", done, faulted, mb_read(MB_READ));
                faulted && !done
            }

            // Everything else runs the watcher. The three that sign differ from
            // one another by which wipe they call and by nothing else.
            _ => {
                bank_non_secure(BANK8_REG, false);
                log!("  bank 8 SHUT. wiping {:#010x}..{:#010x} for hygiene.", lo, hi);

                // Hygiene first, and it is not only hygiene: SRAM survives the
                // reboot, so this clears the previous candidate's signature out
                // of the region before this one starts, and the sweep that
                // follows says whether anything got out of the region.
                let hyg_us = wipe(lo, hi);
                log!("  wiped in {} us. sweeping all 512 KB.", hyg_us);
                let (stale, stale_at) = sweep_seed(SRAM_LO, SRAM_HI);
                res_write(n, R_STALE, stale);
                log!("  inherited copies still in SRAM: {} (first {:#010x})", stale, stale_at);

                if n == C_PRICE {
                    // No watcher at all, so these are the numbers a design
                    // would actually pay. Candidate 4's are the same numbers
                    // with a second core on the bus.
                    let expand_us = expand_only();
                    paint(lo, hi);

                    let t0 = Instant::now();
                    unsafe {
                        sign_once(
                            &MESSAGE,
                            &mut *core::ptr::addr_of_mut!(PUBLIC_KEY),
                            &mut *core::ptr::addr_of_mut!(SIGNATURE),
                        )
                    };
                    let sign_us = t0.elapsed().as_micros() as u32;
                    fingerprint("SGHD", unsafe { &*core::ptr::addr_of!(SIGNATURE) }).await;
                    fingerprint("PKHD", unsafe { &*core::ptr::addr_of!(PUBLIC_KEY) }).await;
                    let depth = hi - low_water(lo, hi);
                    let wipe_us = wipe(lo, hi);
                    let (sweep, sweep_at) = sweep_seed(SRAM_LO, SRAM_HI);

                    res_write(n, R_EXPAND_US, expand_us);
                    res_write(n, R_SIGN_US, sign_us);
                    res_write(n, R_WIPE_US, wipe_us);
                    res_write(n, R_DEPTH, depth as u32);
                    res_write(n, R_SWEEP, sweep);
                    res_write(n, R_SWEEP_ADDR, sweep_at);
                    log!("  expand {} us, sign {} us, wipe {} us.", expand_us, sign_us, wipe_us);
                    log!("  stack went {} bytes deep; copies left afterwards: {}", depth, sweep);

                    expand_us > 0 && sign_us > 0 && wipe_us > 0 && stale == 0
                } else {
                    paint(lo, hi);
                    publish_needle();
                    log!("  painted; needle published to bank 9. starting the watcher.");
                    mb_write(MB_LO, SRAM_LO as u32);
                    mb_write(MB_HI, SRAM_HI as u32);

                    let up = launch_core1(p.CORE1, JOB_SCAN).await;
                    let mut epoch = 0u32;

                    // Phase one: the watcher runs and nothing signs. Whatever
                    // it sees here it would have seen anyway, and the answer
                    // has to be nothing.
                    Timer::after(Duration::from_millis(600)).await;
                    let quiet = mb_read(MB_HITS);
                    res_write(n, R_QUIET, quiet);
                    log!("  watcher up: {} passes, {} sightings with nothing signing.", mb_read(MB_PASSES), quiet);

                    let acked = new_phase(&mut epoch).await;

                    let (during, first_pass, last_pass, first_addr, sign_us, depth) =
                        if n == C_QUIET {
                            // Phase two, for the control, is more of the same.
                            Timer::after(Duration::from_millis(1200)).await;
                            (mb_read(MB_HITS), mb_read(MB_FIRST_PASS), mb_read(MB_LAST_PASS),
                             mb_read(MB_FIRST_ADDR), 0u32, 0usize)
                        } else {
                            res_write(n, R_SIGN_START, mb_read(MB_PASSES));

                            let t0 = Instant::now();
                            unsafe {
                                sign_once(
                                    &MESSAGE,
                                    &mut *core::ptr::addr_of_mut!(PUBLIC_KEY),
                                    &mut *core::ptr::addr_of_mut!(SIGNATURE),
                                )
                            };
                            let us = t0.elapsed().as_micros() as u32;

                            // Read all five counters here, before anything else
                            // happens. The key is still lying in the dead frame
                            // through the two fingerprints below - 25 ms each -
                            // and through `low_water`, which walks half a
                            // megabyte. Sightings from that window are real, but
                            // they are not what a number called "while it was in
                            // use" is allowed to count. The first run of this
                            // firmware read them afterwards and reported 46
                            // sightings spanning passes 65..87 of a signature
                            // that ended at pass 82.
                            let end_pass = mb_read(MB_PASSES);
                            let hits = mb_read(MB_HITS);
                            let fp = mb_read(MB_FIRST_PASS);
                            let lp = mb_read(MB_LAST_PASS);
                            let fa = mb_read(MB_FIRST_ADDR);
                            res_write(n, R_SIGN_END, end_pass);

                            // Not decoration. `SIGNATURE` and `PUBLIC_KEY` are
                            // written and never read, and the first build of
                            // this firmware had `.bss` come out 517 bytes
                            // SMALLER than the two of them together: LLVM had
                            // removed both, and with them any reason to compute
                            // the signature at all. Printing a fingerprint is
                            // what keeps the work alive.
                            //
                            // They are also a check. Deterministic signing over
                            // a fixed message with a fixed seed means these two
                            // lines must come out identical in candidates 4, 5,
                            // 6 and 7, and `verify.py` checks that they did.
                            fingerprint("SGHD", unsafe { &*core::ptr::addr_of!(SIGNATURE) }).await;
                            fingerprint("PKHD", unsafe { &*core::ptr::addr_of!(PUBLIC_KEY) }).await;
                            (hits, fp, lp, fa, us, hi - low_water(lo, hi))
                        };

                    res_write(n, R_HITS, during);
                    res_write(n, R_FIRST_PASS, first_pass);
                    res_write(n, R_LAST_PASS, last_pass);
                    res_write(n, R_SIGN_US, sign_us);
                    res_write(n, R_DEPTH, depth as u32);
                    log!("  signed in {} us, {} bytes deep; watcher saw it {} times.", sign_us, depth, during);
                    if during > 0 {
                        log!("  first at {:#010x}, passes {}..{} of sign {}..{}.",
                             first_addr, first_pass, last_pass,
                             res_read(n, R_SIGN_START), res_read(n, R_SIGN_END));
                    }

                    // Phase three: the remedy, or the absence of it. The three
                    // candidates differ here and nowhere else.
                    let frame_sp = FRAME_SP.load(Ordering::Relaxed) as usize;
                    let frame = hi.saturating_sub(frame_sp);
                    let wipe_us = match n {
                        C_WIPED => wipe(lo, hi),
                        // Down to the stack pointer `sign_once` itself ran on,
                        // and not one word further.
                        C_FRAME_ONLY => {
                            log!("  sign_once's own frame measured {} bytes; wiping exactly that.", frame);
                            wipe(frame_sp & !3, hi)
                        }
                        _ => 0,
                    };
                    res_write(n, R_FRAME, frame as u32);
                    res_write(n, R_WIPE_US, wipe_us);

                    let acked2 = new_phase(&mut epoch).await;
                    Timer::after(Duration::from_millis(800)).await;
                    let post = mb_read(MB_HITS);
                    res_write(n, R_POST, post);
                    res_write(n, R_PASSES, mb_read(MB_PASSES));

                    mb_write(MB_STOP, 1);
                    let mut waited = 0;
                    while mb_read(MB_DONE) == 0 && waited < 100 {
                        Timer::after(Duration::from_millis(10)).await;
                        waited += 1;
                    }

                    let (sweep, sweep_at) = sweep_seed(SRAM_LO, SRAM_HI);
                    res_write(n, R_SWEEP, sweep);
                    res_write(n, R_SWEEP_ADDR, sweep_at);
                    log!("  wiped in {} us; afterwards the watcher saw it {} times.", wipe_us, post);
                    log!("  the byte-granular sweep of all 512 KB found {} (first {:#010x}).", sweep, sweep_at);

                    let sane = up && acked && acked2 && quiet == 0 && stale == 0
                        && mb_read(MB_FAULTED) == 0 && mb_read(MB_PASSES) > 0;

                    match n {
                        // The control. Nothing signed, so nothing may be seen.
                        C_QUIET => sane && during == 0 && post == 0 && sweep == 0,
                        // The window. No wipe, so the key is there during and
                        // still there after.
                        C_WATCHED => sane && during > 0 && post > 0 && sweep > 0,
                        // The remedy. Same as candidate 4 up to one call.
                        C_WIPED => sane && during > 0 && post == 0 && sweep == 0,
                        // exp160's open question. `sweep` is the answer and is
                        // deliberately not graded: grading it would mean
                        // asserting the result the experiment was written to
                        // find.
                        C_FRAME_ONLY => sane && during > 0,
                        _ => false,
                    }
                }
            }
        };

        breadcrumb::mark(n, if ok { breadcrumb::SURVIVED_A } else { breadcrumb::SURVIVED_B });
        log!("candidate {} -> {}", n, if ok { "as expected" } else { "NOT as expected" });
        breadcrumb::finished();

        Timer::after(Duration::from_millis(300)).await;
        breadcrumb::reboot()
    }

    breadcrumb::disarm();
    STOPPED.store(true, Ordering::Relaxed);

    loop {
        log!("exp163 done after {} boots. Nothing armed; still reflashable.", note.boot);
        report(&note).await;
        log!("the numbers, out of bank 9:");
        numbers().await;

        let seen = res_read(C_WATCHED, R_HITS);
        let wiped_post = res_read(C_WIPED, R_POST);
        let wiped_sweep = res_read(C_WIPED, R_SWEEP);
        let frame_sweep = res_read(C_FRAME_ONLY, R_SWEEP);
        Timer::after(Duration::from_millis(25)).await;

        if res_read(C_WATCHED, R_FLAG) == RESULT_MAGIC && res_read(C_WIPED, R_FLAG) == RESULT_MAGIC {
            log!("VERDICT: a Non-secure core saw the key {} times while it was in use,", seen);
            Timer::after(Duration::from_millis(25)).await;
            log!("  and {} times after the wipe; the 512 KB sweep then found {}.", wiped_post, wiped_sweep);
            Timer::after(Duration::from_millis(25)).await;
            log!("  wiping only the {}-byte frame leaves {} copies behind.",
                 res_read(C_FRAME_ONLY, R_FRAME), frame_sweep);
        } else {
            log!("VERDICT: incomplete - not every candidate left a record in bank 9.");
        }
        Timer::after(Duration::from_secs(4)).await;
    }
}
