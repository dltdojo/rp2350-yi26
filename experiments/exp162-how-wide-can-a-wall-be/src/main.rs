// SPDX-License-Identifier: Apache-2.0
//! exp162 — how wide can a wall be?
//!
//! [exp160](../exp160-a-secret-too-big-to-hide/) ended on a number and a
//! question. The number: an `SigningKey<MlDsa65>` is **65,696 bytes**, which is
//! 160 bytes larger than one 64 KB SRAM bank, and `ACCESSCTRL` gates SRAM one
//! bank at a time. The question it left: *do banks 0–7 map onto the address
//! range in a way that would let a secure region larger than one bank exist at
//! all?*
//!
//! Nothing this repository can read answers it. `rp-pac`'s doc string for
//! `ACCESSCTRL.SRAM[n]` names the register "SRAM0" and gives no address, and
//! [exp159](../exp159-a-key-that-was-never-in-flash/) got to sidestep the same
//! question — *"it stops mattering, because those banks are never touched"* —
//! by putting its key in bank 8. exp160 made it matter again.
//!
//! It is a real question and not a formality, because a contiguous map is not
//! the only arrangement a chip like this has shipped with. So this experiment
//! does not assume `bank n = 0x2000_0000 + n * 0x10000`. It asks the only thing
//! on this part that can answer: a Non-secure core, one address at a time.
//!
//! # The claim
//!
//! > **Every one of the eight 64 KB banks gates a known set of addresses, and
//! > this run says which — measured by a demoted core, one register different
//! > between each pair of readings, with the two controls that make a refusal
//! > mean something.**
//!
//! What that turns into for exp160 is one line, and this firmware prints it:
//! either two adjacent banks deny a *contiguous* 128 KB — in which case a
//! secure region larger than one bank does exist and exp160's second idea to
//! take away needs correcting — or they do not, in which case **this chip
//! cannot put an ML-DSA-65 signing key behind `ACCESSCTRL` in the form the
//! arithmetic needs**, and the signing road should record that before anything
//! is built on the assumption that it can.
//!
//! There is no cryptography here at all. That is deliberate: exp156 measured a
//! wall with no cryptography in it precisely so that a failure could only be
//! about the wall, and this is the same shape one layer along.
//!
//! # Why core 1 lives in bank 8
//!
//! The last candidate denies **all eight** banks to Non-secure code. A core 1
//! whose stack were in the main 512 KB would die on its own prologue, and the
//! run would report a refusal it had caused rather than measured.
//!
//! So core 1 gets [`BANK8`] — 4 KB at `0x2008_0000`, which exp159 established
//! is real, is not one of the eight, and is gated by its own register. Its
//! lower 3 KB is core 1's stack and the rest is the mailbox. Core 1's code is
//! in flash, which `XIP_MAIN` leaves fully open, and its very first act is
//! `cortex_m::interrupt::disable()`, so that no interrupt handler of somebody
//! else's touches the main SRAM on its behalf while the wall is up.
//!
//! **The last candidate is therefore its own control.** Core 1 can only report
//! that refusal at all if nothing it needs is in banks 0-7 — so a run that
//! answers it has proved the layout the whole run depends on.
//!
//! # The order of the three writes
//!
//! Core 1 is launched with everything open and **Secure**, and only then is the
//! wall raised, the core demoted, and the go-ahead written. That is not
//! tidiness either: `spawn_core1` and embassy's `core1_startup` write to
//! statics in the main SRAM — the FIFO handshake, `IS_CORE1_INIT`, the closure
//! being moved across — so a core launched into an already-shut main SRAM dies
//! on the launch rather than on the read.
//!
//! # The matrix
//!
//! One candidate per boot, fifteen boots, one flash — [exp158](../exp158-four-keys-and-one-flash/)'s
//! shape, so that an early failure costs the later readings a line each rather
//! than costing the trip.
//!
//! ```text
//!    1  nothing shut,   read 0x20000000    must be ALLOWED   (control)
//!    2  bank 0 shut,    read 0x20000000    must be DENIED    (control)
//!    3  bank 0 shut,    read 0x20010000    measured   <- the headline
//!    4  bank 0 shut,    read 0x20000004    measured   \
//!    5  bank 0 shut,    read 0x20000008    measured    | how wide a piece
//!    6  bank 0 shut,    read 0x20000010    measured    | one register owns
//!    7  bank 0 shut,    read 0x20000020    measured   /
//!    8  bank 1 shut,    read 0x20000004    measured   \
//!    9  bank 2 shut,    read 0x20000008    measured    | which register owns
//!   10  bank 3 shut,    read 0x2000000c    measured   /  the words next door
//!   11  bank 4 shut,    read 0x20000000    measured   \
//!   12  bank 0 shut,    read 0x20040000    measured    | is the upper half a
//!   13  bank 4 shut,    read 0x20040000    measured   /  different four?
//!   14  bank 2 shut,    read 0x20000040    measured   <- separates two maps
//!   15  all eight shut, read 0x2007fffc    must be DENIED    (control)
//! ```
//!
//! **Candidates 1 and 2 are exp156's lesson, and they are not decoration.** A
//! refusal on its own is one failed access; the same core reading the same
//! address a moment earlier under one different register bit is what makes the
//! refusal mean something. exp156 needed eight rounds to arrive at that, and
//! [nearly reported a wall the bootrom had left standing](../exp156-a-wall-you-can-measure/).
//!
//! **Candidate 3 is the headline** and it is one reading: if `0x2001_0000` is
//! refused while only bank 0 is shut, then bank 0 is not the first 64 KB, and
//! nothing about "each bank is a block" survives.
//!
//! # Twelve of the fifteen have no expected outcome, and that is the point
//!
//! Candidates 1, 2 and 15 are controls: this firmware knows what they must do
//! and says `as expected` or `NOT as expected`. The rest are **measurements**,
//! and declaring an expectation for them would be presuming the answer this
//! experiment was written to get. So the note records what *happened* — allowed
//! or denied, one bit, which is all a reading is — and the interpretation
//! happens at report time, on the board and again off it.
//!
//! [exp140](../exp140-a-checksum-that-passes/) is why that distinction is
//! written down rather than left to good sense: a run that can only report
//! success has not reported anything. This experiment took the point twice —
//! its first round carried a table of five precomputed patterns, met readings
//! that matched none of them, and printed so. A firmware that had graded those
//! candidates would have called a correct measurement a failure.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

/// SRAM bank 8: 4 KB of its own, immediately above the main 512 KB.
///
/// Not in `rp2350-linker`'s memory map — its `RAM` region is `0x2000_0000` for
/// 512K — so nothing the linker places can land here, and everything in this
/// bank is here on purpose. exp159 put a key here and measured that
/// `ACCESSCTRL.SRAM[8]` gates it.
const BANK8: usize = 0x2008_0000;

/// Core 1's stack, at the bottom of bank 8. Three kilobytes, because everything
/// core 1 does here is a volatile read and a volatile write, and the deepest it
/// ever gets is one exception frame on top of that.
const CORE1_STACK_BYTES: usize = 3072;

/// The mailbox, immediately above core 1's stack and still in bank 8.
///
/// exp159 put its mailbox in the **main** SRAM and said why: `SRAM` defaults to
/// fully open, so Non-secure writes there with nothing programmed. That reason
/// still holds and it is not available here, because candidate 9 shuts the main
/// SRAM. Bank 8 defaults open too, so the property is the same and only the
/// address changed.
const MAILBOX: usize = BANK8 + CORE1_STACK_BYTES;

const MB_MAGIC: usize = 0;
const MB_UP: usize = 4;
const MB_GO: usize = 8;
const MB_ADDR: usize = 12;
const MB_DONE: usize = 16;
const MB_FAULTED: usize = 20;
const MB_VALUE: usize = 24;

/// Marks the mailbox as this run's. Also answers, for nothing, whether bank 8
/// survives a watchdog reset — exp159 and exp160 both measured that it does,
/// and a third boot-crossing experiment may as well keep saying so.
const RUN_MAGIC: u32 = 0x4B45_5933;

/// NSU (bit 0) and NSP (bit 1) — the two bits that are the wall. exp156
/// established the field order from silicon: the PAC's names and positions are
/// right and its doc comments are shifted by one field.
const NON_SECURE_BITS: u32 = 0b11;

/// Every `ACCESSCTRL` write needs this in bits 31:16 or it raises a bus error.
/// Measured by exp156 across six rounds that were looking at exactly this, and
/// re-derived by exp158. `modify()` would drop it every time, so every write
/// here is a `write_value`.
const ACCESSCTRL_KEY: u32 = 0xACCE_0000;

const CANDIDATES: u8 = 15;

/// The whole of the main SRAM, which is what banks 0-7 divide between them.
const SRAM_BASE: u32 = 0x2000_0000;
const SRAM_BYTES: u32 = 512 * 1024;

/// What a candidate does: which of banks 0-7 to shut to Non-secure code, which
/// address core 1 then reads, and whether this firmware is entitled to an
/// opinion about the outcome.
struct Probe {
    /// Bit *n* set = shut `ACCESSCTRL.SRAM[n]` to Non-secure.
    shut: u8,
    addr: u32,
    expect: u8,
    what: &'static str,
}

const EXPECT_ALLOWED: u8 = 0;
const EXPECT_DENIED: u8 = 1;
/// No expectation. The run reports the reading and does not grade it.
const MEASURE: u8 = 2;

/// Fifteen readings, twelve of them measurements.
///
/// The first round of this experiment asked nine and **could not name the
/// answer**: it carried a table of five precomputed patterns, the board's
/// readings matched none of them, and it printed `NO ARRANGEMENT FITS` rather
/// than rounding to the nearest story. That was the instrument working. The
/// nine readings had already settled the headline — `0x2001_0000` is refused
/// when bank 0 alone is shut, so bank 0 is not the first 64 KB — but they could
/// not say what the map *is*.
///
/// So this set adds the probes that can. Candidates 8-10 ask which register
/// owns the words next to `0x2000_0000`, 11-13 ask whether the upper 256 KB
/// belongs to a different four registers, and 14 exists for one reason: without
/// it the two 32-byte-grain arrangements predict identical readings, and a
/// verdict that named one of them would be picking. Together the fifteen tell
/// all thirteen apart, which was checked by enumerating them rather than by
/// believing it.
const PROBES: [Probe; CANDIDATES as usize] = [
    Probe { shut: 0b0000_0000, addr: 0x2000_0000, expect: EXPECT_ALLOWED, what: "nothing shut, read 0x20000000" },
    Probe { shut: 0b0000_0001, addr: 0x2000_0000, expect: EXPECT_DENIED,  what: "bank 0 SHUT, read 0x20000000" },
    Probe { shut: 0b0000_0001, addr: 0x2001_0000, expect: MEASURE,        what: "bank 0 SHUT, read 0x20010000" },
    Probe { shut: 0b0000_0001, addr: 0x2000_0004, expect: MEASURE,        what: "bank 0 SHUT, read 0x20000004" },
    Probe { shut: 0b0000_0001, addr: 0x2000_0008, expect: MEASURE,        what: "bank 0 SHUT, read 0x20000008" },
    Probe { shut: 0b0000_0001, addr: 0x2000_0010, expect: MEASURE,        what: "bank 0 SHUT, read 0x20000010" },
    Probe { shut: 0b0000_0001, addr: 0x2000_0020, expect: MEASURE,        what: "bank 0 SHUT, read 0x20000020" },
    Probe { shut: 0b0000_0010, addr: 0x2000_0004, expect: MEASURE,        what: "bank 1 SHUT, read 0x20000004" },
    Probe { shut: 0b0000_0100, addr: 0x2000_0008, expect: MEASURE,        what: "bank 2 SHUT, read 0x20000008" },
    Probe { shut: 0b0000_1000, addr: 0x2000_000c, expect: MEASURE,        what: "bank 3 SHUT, read 0x2000000c" },
    Probe { shut: 0b0001_0000, addr: 0x2000_0000, expect: MEASURE,        what: "bank 4 SHUT, read 0x20000000" },
    Probe { shut: 0b0000_0001, addr: 0x2004_0000, expect: MEASURE,        what: "bank 0 SHUT, read 0x20040000" },
    Probe { shut: 0b0001_0000, addr: 0x2004_0000, expect: MEASURE,        what: "bank 4 SHUT, read 0x20040000" },
    Probe { shut: 0b0000_0100, addr: 0x2000_0040, expect: MEASURE,        what: "bank 2 SHUT, read 0x20000040" },
    Probe { shut: 0b1111_1111, addr: 0x2007_fffc, expect: EXPECT_DENIED,  what: "all eight SHUT, read 0x2007fffc" },
];

/// One candidate map for the eight banks.
///
/// The address range is cut into `8 / ways` equal contiguous chunks, and inside
/// each chunk consecutive `grain`-byte pieces go round `ways` banks in turn.
/// `ways = 1` is the arrangement everybody assumes: eight contiguous 64 KB
/// blocks, no interleaving at all.
struct Arrangement {
    name: &'static str,
    ways: u32,
    grain: u32,
    /// The largest run of consecutive addresses that a single register gates,
    /// which is the only number on this page exp160 needs.
    contiguous: u32,
}

const ARRANGEMENTS: [Arrangement; 13] = [
    Arrangement { name: "contiguous 64 KB banks", ways: 1, grain: 4, contiguous: 65536 },
    Arrangement { name: "8-way striped, 4-byte grain", ways: 8, grain: 4, contiguous: 4 },
    Arrangement { name: "8-way striped, 8-byte grain", ways: 8, grain: 8, contiguous: 8 },
    Arrangement { name: "8-way striped, 16-byte grain", ways: 8, grain: 16, contiguous: 16 },
    Arrangement { name: "8-way striped, 32-byte grain", ways: 8, grain: 32, contiguous: 32 },
    Arrangement { name: "two halves, 4-way, 4-byte grain", ways: 4, grain: 4, contiguous: 4 },
    Arrangement { name: "two halves, 4-way, 8-byte grain", ways: 4, grain: 8, contiguous: 8 },
    Arrangement { name: "two halves, 4-way, 16-byte grain", ways: 4, grain: 16, contiguous: 16 },
    Arrangement { name: "two halves, 4-way, 32-byte grain", ways: 4, grain: 32, contiguous: 32 },
    Arrangement { name: "four quarters, 2-way, 4-byte grain", ways: 2, grain: 4, contiguous: 4 },
    Arrangement { name: "four quarters, 2-way, 8-byte grain", ways: 2, grain: 8, contiguous: 8 },
    Arrangement { name: "four quarters, 2-way, 16-byte grain", ways: 2, grain: 16, contiguous: 16 },
    Arrangement { name: "four quarters, 2-way, 32-byte grain", ways: 2, grain: 32, contiguous: 32 },
];

/// Which bank an arrangement puts an address in.
///
/// This is arithmetic rather than a table on purpose. The first round of this
/// experiment carried five precomputed bit patterns, and when the board came
/// back with a sixth the firmware could say only that nothing fitted. A
/// prediction derived from the address can be wrong about the chip; a table can
/// also be wrong about the *question*.
fn bank_of(a: &Arrangement, addr: u32) -> u32 {
    let off = addr - SRAM_BASE;
    let chunk = SRAM_BYTES / (8 / a.ways);
    ((off / a.grain) % a.ways) + (off / chunk) * a.ways
}

/// Generous. One candidate is a core-1 launch and a one-second wait, so this is
/// far more than any of them needs — a budget shorter than a step that was
/// going to succeed reports a death that never happened.
const STEP_BUDGET_US: u32 = 8_000_000;

/// Fifteen candidates need fifteen boots. The ceiling is well above that so
/// that a run which loses a boot to something unexpected still finishes rather
/// than stopping one short and looking like a hang.
const LAST_BOOT: u32 = 20;
const REFLASH_WINDOW_S: u64 = 5;

const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp162 how wide a wall";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

static STOPPED: AtomicBool = AtomicBool::new(false);

/// Core 0 faulting is the case nothing else covers, so it goes to the harness.
///
/// Core 1 faulting is what most of these candidates are *trying* to cause, and
/// it cannot reach the watchdog anyway — `WATCHDOG` defaults to
/// Secure-Privileged-only, so `breadcrumb::reboot` from here would fault inside
/// the fault handler. It therefore leaves a flag and parks, and core 0 reports.
///
/// **Everything on core 1's path through here is in bank 8 or in flash.** The
/// flag is a volatile write to the mailbox and the frame is on core 1's own
/// stack; a handler that touched a static in the main SRAM would fault again
/// during candidate 9 and hand the log a lockup to explain instead of a
/// refusal.
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

fn mb_read(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((MAILBOX + off) as *const u32) }
}

fn mb_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((MAILBOX + off) as *mut u32, v) }
}

/// Open or shut one SRAM bank to Non-secure code.
fn bank_non_secure(bank: usize, allowed: bool) {
    let reg = embassy_rp::pac::ACCESSCTRL.sram(bank);
    let before = reg.read().0;
    let bits = if allowed { before | NON_SECURE_BITS } else { before & !NON_SECURE_BITS };
    reg.write_value(embassy_rp::pac::accessctrl::regs::Access(ACCESSCTRL_KEY | (bits & 0xFFFF)));
}

/// Open all eight, then shut the ones this candidate names.
///
/// **Opening first is not tidiness.** exp156 denied a peripheral that already
/// denied Non-secure at power-on, watched the refusal, and reported a wall it
/// had not built. Everything it printed was true and the conclusion was
/// somebody else's. Nothing here trusts a power-on default to be what it looks
/// like: every bank is put into a known state on every candidate, including the
/// candidate that shuts none of them.
fn apply_mask(shut: u8) {
    for bank in 0..8 {
        bank_non_secure(bank, shut & (1 << bank) == 0);
    }
}

fn force_core_ns_now() -> u32 {
    embassy_rp::pac::ACCESSCTRL.force_core_ns().read().0
}

fn set_core1_ns(ns: bool) {
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    let cur = r.read().0;
    let bits = if ns { cur | 0b10 } else { cur & !0b10 };
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        ACCESSCTRL_KEY | (bits & 0xFFFF),
    ));
}

/// Core 1's whole life: read one word from one address and say what happened.
///
/// Nothing in here touches the main SRAM. No `log!`, no atomics in `.bss`, no
/// embassy statics — a volatile spin on the mailbox in bank 8 and one volatile
/// read of the address under test.
fn core1_main() -> ! {
    // `spawn_core1` leaves the SIO FIFO interrupt enabled so that `pause` and
    // `resume` work, and its handler lives in embassy-rp and touches statics in
    // the main SRAM. Nothing here uses the FIFO after launch, and an interrupt
    // arriving mid-candidate would fault this core for a reason that is not the
    // wall — so the interrupts go off and stay off. PRIMASK does not mask
    // HardFault, which is the one exception this core is here to take.
    cortex_m::interrupt::disable();

    mb_write(MB_UP, 1);
    while mb_read(MB_GO) == 0 {
        cortex_m::asm::nop();
    }

    let a = mb_read(MB_ADDR) as usize;
    let v = unsafe { core::ptr::read_volatile(a as *const u32) };
    mb_write(MB_VALUE, v);
    mb_write(MB_DONE, 1);

    loop {
        cortex_m::asm::wfe();
    }
}

/// Bring core 1 up on bank 8's stack and leave it parked on the mailbox.
///
/// **The wall does not go up until this has returned.** `spawn_core1` and
/// embassy's own `core1_startup` write to statics in the main SRAM — the FIFO
/// handshake, `IS_CORE1_INIT`, the closure being moved across — so a core 1
/// launched into an already-shut main SRAM would die on the launch rather than
/// on the read, and the run would report a refusal it had caused. Launch first
/// with everything open and Secure, then raise the wall, then demote, then go.
///
/// The stack is a forged `&'static mut Stack<N>` at a fixed address rather than
/// a `static`, because a `static` is what the linker places and the linker only
/// knows about the main 512 KB. `Stack<N>` is `#[repr(C, align(32))]` around a
/// public `[u8; N]`, `BANK8` is 64 KB-aligned, and `spawn_core1` writes exactly
/// two words at the top of it — so this is a reinterpretation of 3 KB of SRAM
/// and nothing more. exp159 addresses bank 8 the same way, with `read_volatile`
/// at a constant.
async fn launch_core1(core1: embassy_rp::Peri<'static, embassy_rp::peripherals::CORE1>, addr: u32) {
    mb_write(MB_UP, 0);
    mb_write(MB_GO, 0);
    mb_write(MB_DONE, 0);
    mb_write(MB_FAULTED, 0);
    mb_write(MB_VALUE, 0);
    mb_write(MB_ADDR, addr);

    let stack: &'static mut Stack<CORE1_STACK_BYTES> =
        unsafe { &mut *(BANK8 as *mut Stack<CORE1_STACK_BYTES>) };
    spawn_core1(core1, stack, core1_main);

    while mb_read(MB_UP) == 0 {
        Timer::after(Duration::from_millis(10)).await;
    }
}

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        let ms = if STOPPED.load(Ordering::Relaxed) { 100 } else { 500 };
        led.toggle();
        Timer::after(Duration::from_millis(ms)).await;
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

fn outcome_word(o: u8) -> &'static str {
    match o {
        breadcrumb::SURVIVED_A => "allowed",
        breadcrumb::SURVIVED_B => "DENIED",
        _ => "-",
    }
}

/// One line per candidate: what it did, what came back, and — only for the
/// three that are controls — whether that is what it had to be.
async fn report(note: &breadcrumb::Note) {
    for n in 1..=CANDIDATES {
        let p = &PROBES[(n - 1) as usize];
        match note.outcome(n) {
            breadcrumb::NOT_ATTEMPTED => log!("  {} {} - not reached", n, p.what),
            breadcrumb::DIED => log!("  {} {} - KILLED CORE 0", n, p.what),
            o => {
                let reading = outcome_word(o);
                match p.expect {
                    MEASURE => log!("  {} {} - {} (measured)", n, p.what, reading),
                    e => {
                        let want = if e == EXPECT_ALLOWED {
                            breadcrumb::SURVIVED_A
                        } else {
                            breadcrumb::SURVIVED_B
                        };
                        log!("  {} {} - {} ({})", n, p.what, reading,
                             if o == want { "as expected" } else { "NOT as expected" });
                    }
                }
            }
        }
        // One pause per line, on every path through the match.
        //
        // `usb-log`'s queue is sixteen deep and drops the NEWEST line when it is
        // full, so an unpaced report is a report that silences whatever follows
        // it. This block is sixteen lines by itself and the verdict comes after
        // — exp160 lost its headline finding to this exact queue and wrote it
        // down, and the first paced draft of this function put the pause inside
        // the arms that end in a semicolon, which is none of the ones above.
        Timer::after(Duration::from_millis(25)).await;
    }
}

/// Turn fifteen readings into the one sentence exp160 asked for.
///
/// Every arrangement in [`ARRANGEMENTS`] is asked to predict all fifteen. The
/// answer is a name only when **exactly one** survives; two survivors means the
/// probes were not sharp enough and none means the map is outside the family
/// this experiment can express. Both of those are printed as themselves.
async fn verdict(note: &breadcrumb::Note) {
    let reached =
        |n: u8| note.outcome(n) == breadcrumb::SURVIVED_A || note.outcome(n) == breadcrumb::SURVIVED_B;
    let denied = |n: u8| note.outcome(n) == breadcrumb::SURVIVED_B;

    if !(1..=CANDIDATES).all(reached) {
        log!("VERDICT: incomplete - not every candidate has a reading yet.");
        Timer::after(Duration::from_millis(25)).await;
        return;
    }

    let mut fits = 0u32;
    let mut which = 0usize;
    for (i, a) in ARRANGEMENTS.iter().enumerate() {
        let mut ok = true;
        for n in 1..=CANDIDATES {
            let p = &PROBES[(n - 1) as usize];
            let predicted = (p.shut >> bank_of(a, p.addr)) & 1 == 1;
            if predicted != denied(n) {
                ok = false;
                break;
            }
        }
        if ok {
            fits += 1;
            which = i;
        }
    }

    if fits != 1 {
        log!("VERDICT: {} of {} arrangements predict these fifteen readings.", fits, ARRANGEMENTS.len());
        Timer::after(Duration::from_millis(25)).await;
        log!("  This experiment cannot name the map and will not guess. Read the lines");
        Timer::after(Duration::from_millis(25)).await;
        log!("  above: they are the measurement, and the summary is not.");
        Timer::after(Duration::from_millis(25)).await;
        return;
    }

    let a = &ARRANGEMENTS[which];
    log!("VERDICT: exactly one arrangement predicts all fifteen readings.");
    Timer::after(Duration::from_millis(25)).await;
    log!("  banks 0-7 are {}.", a.name);
    Timer::after(Duration::from_millis(25)).await;
    log!("  The longest run of addresses one register gates is {} bytes.", a.contiguous);
    Timer::after(Duration::from_millis(25)).await;

    if a.ways == 1 {
        log!("  So adjacent registers deny adjacent 64 KB blocks, and a Non-secure-denied");
        Timer::after(Duration::from_millis(25)).await;
        log!("  region LARGER than one bank does exist: two registers make a contiguous");
        Timer::after(Duration::from_millis(25)).await;
        log!("  128 KB. exp160's 65,696-byte signing key fits inside two banks, and");
        Timer::after(Duration::from_millis(25)).await;
        log!("  'cannot hide something bigger than one block' was the wrong limit.");
        Timer::after(Duration::from_millis(25)).await;
    } else {
        log!("  So one register does NOT gate one 64 KB block: it gates one {}-byte", a.grain);
        Timer::after(Duration::from_millis(25)).await;
        log!("  piece in every {}, scattered from one end of its half to the other.", a.ways);
        Timer::after(Duration::from_millis(25)).await;
        log!("  Shutting it takes {} bytes out of every {} across 256 KB, including out", a.grain, a.grain * a.ways);
        Timer::after(Duration::from_millis(25)).await;
        log!("  of the stack of whatever is running Non-secure.");
        Timer::after(Duration::from_millis(25)).await;
        log!("  THE ANSWER exp160 ASKED FOR IS NO, and it is worse than exp160 feared:");
        Timer::after(Duration::from_millis(25)).await;
        log!("  the limit is not 64 KB, it is {} bytes. Not one contiguous byte more than", a.contiguous);
        Timer::after(Duration::from_millis(25)).await;
        log!("  that can be denied to Non-secure code anywhere in the main 512 KB, so a");
        Timer::after(Duration::from_millis(25)).await;
        log!("  65,696-byte ML-DSA-65 signing key cannot go behind ACCESSCTRL at all.");
        Timer::after(Duration::from_millis(25)).await;
        log!("  What exp159's keystore stands on is bank 8, which is none of these eight:");
        Timer::after(Duration::from_millis(25)).await;
        log!("  core 1's stack and this mailbox are in it and they survived candidate 15,");
        Timer::after(Duration::from_millis(25)).await;
        log!("  with all eight shut. That is the only kind of place a secret can live.");
        Timer::after(Duration::from_millis(25)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let note = breadcrumb::read();

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("162");
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
    log!("exp162 up, boot #{}. The matrix so far:", note.boot);
    report(&note).await;

    // Two register states this boot inherited rather than chose, put back to a
    // known one — and the reading is worth a line because nothing here has
    // recorded whether ACCESSCTRL survives a watchdog reset. exp159 and exp160
    // both re-wrote these registers every boot without ever asking.
    let inherited = force_core_ns_now();
    log!("inherited FORCE_CORE_NS {:#010x} and SRAM[0] {:#010x}; both reset below.",
         inherited, embassy_rp::pac::ACCESSCTRL.sram(0).read().0);
    set_core1_ns(false);
    apply_mask(0);

    if mb_read(MB_MAGIC) == RUN_MAGIC {
        log!("bank 8 still holds this run's mailbox: it survived the reboot.");
    } else {
        mb_write(MB_MAGIC, RUN_MAGIC);
        log!("mailbox claimed at {:#010x}, in bank 8 and nowhere else.", MAILBOX);
    }

    let next = note.next_unattempted(CANDIDATES);
    let finishing = next.is_none() || note.boot >= LAST_BOOT;

    if !finishing {
        let n = next.unwrap();
        let probe = &PROBES[(n - 1) as usize];

        log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
        Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

        breadcrumb::arm(STEP_BUDGET_US);
        breadcrumb::step(n);
        log!("candidate {} {}", n, probe.what);

        launch_core1(p.CORE1, probe.addr).await;

        // Now, and only now: the wall, then the demotion, then the word that
        // lets core 1 read. Three writes in that order, and the last two are
        // what make the reading a reading.
        apply_mask(probe.shut);
        set_core1_ns(true);
        log!("  banks shut to Non-secure: {:#010b}, core 1 demoted.", probe.shut);
        mb_write(MB_GO, 1);
        Timer::after(Duration::from_secs(1)).await;

        let done = mb_read(MB_DONE) == 1;
        let faulted = mb_read(MB_FAULTED) == 1;
        let value = mb_read(MB_VALUE);
        log!("  core 1: done={} faulted={} read={:#010x}", done, faulted, value);

        // The reading, and only the reading. `done && !faulted` is allowed;
        // `faulted && !done` is denied. Anything else is neither, and the
        // outcome recorded for it is DIED so that the final report cannot
        // present a core that never answered as a refusal.
        let outcome = if done && !faulted {
            breadcrumb::SURVIVED_A
        } else if faulted && !done {
            breadcrumb::SURVIVED_B
        } else {
            log!("  core 1 answered neither way. This is not a refusal; it is a silence.");
            breadcrumb::DIED
        };

        breadcrumb::mark(n, outcome);

        match probe.expect {
            MEASURE => log!("candidate {} -> {} (measured)", n, outcome_word(outcome)),
            e => {
                let want = if e == EXPECT_ALLOWED { breadcrumb::SURVIVED_A } else { breadcrumb::SURVIVED_B };
                log!("candidate {} -> {} ({})", n, outcome_word(outcome),
                     if outcome == want { "as expected" } else { "NOT as expected" });
            }
        }
        breadcrumb::finished();

        Timer::after(Duration::from_millis(300)).await;
        breadcrumb::reboot()
    }

    // Nothing is armed and nothing is locked: `ACCESSCTRL.LOCK` is never
    // written by this firmware, so every configuration above is one power cycle
    // from ordinary. Put the banks back before settling, so that a board left
    // running this is not a board with a wall nobody remembers building.
    apply_mask(0);
    breadcrumb::disarm();
    STOPPED.store(true, Ordering::Relaxed);

    loop {
        log!("exp162 done after {} boots. Nothing armed; still reflashable.", note.boot);
        report(&note).await;
        verdict(&note).await;
        Timer::after(Duration::from_secs(5)).await;
    }
}
