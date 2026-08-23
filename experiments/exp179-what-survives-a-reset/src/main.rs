// SPDX-License-Identifier: Apache-2.0
//! exp179 — what survives a reset, and who cleared it.
//!
//! The [identity road](../README.md#the-identity-road) opens with a question the
//! rest of it waits on: **does anything in this chip's SRAM survive to be read
//! by user code?** If a region does, an SRAM PUF is at least possible here. If
//! the answer is no on every path, the road has a clean negative to point at
//! instead of folklore.
//!
//! # What was already measured, and what it could not separate
//!
//! Earlier work on this chip read a 4 KB window at `0x2007_C000` and found
//! **exactly zero one-bits out of 32,768** — `0.00%` uniformity — and concluded
//! the SRAM is cleared before user code runs. That measurement is not in doubt.
//! What it could not do is say **who** cleared it, and there are three
//! candidates:
//!
//! 1. the bootrom, before any of our code runs at all;
//! 2. `cortex-m-rt`'s startup, which zeroes `.bss` before `main`;
//! 3. this firmware's own stack — because `0x2007_C000` is the last 16 KB of the
//!    512 KB main SRAM, and the stack starts at the top of it and grows *down*
//!    through exactly that window.
//!
//! Three different causes, three different conclusions, and the same all-zero
//! reading. This experiment separates them by **where it puts the window it
//! owns**, not by when it reads: the probe lives in `.uninit`, the one section
//! `cortex-m-rt` is documented not to initialise, so candidate 2 is ruled out by
//! construction rather than by timing. It is read as the first thing `main`
//! does, before `embassy_rp::init`, and the survey says so in its own output.
//!
//! **`#[pre_init]` was the first design and it does not compile here.**
//! `embassy-rp` already defines `__pre_init`, and for a reason worth knowing:
//! SIO is not reset by `scb::sys_reset()`, so a boot that was interrupted while
//! holding spinlock 31 — the one the critical-section implementation uses —
//! comes back to a lock nobody will ever release. embassy resets SIO there
//! because `pre_init` is the only place guaranteed to run before user code could
//! have taken a critical section. So in an embassy firmware that position is
//! taken, and a second `__pre_init` is a duplicate symbol at link time. Worth
//! writing down: it is not obvious, and the error message names the symbol
//! rather than the reason.
//!
//! # Three windows, because they are cleared by different things
//!
//! | window | where | who could plausibly clear it |
//! | --- | --- | --- |
//! | `.uninit` | wherever the linker puts it, after `.bss` | the bootrom only — `cortex-m-rt` does not touch `.uninit`, and it is far below the stack |
//! | `0x2007_C000` | the last 16 KB of main SRAM | the bootrom, **or our own stack**. Read only, never written: writing 4 KB there would be writing over the stack this code is running on |
//! | `0x2008_0000` | SRAM bank 8, **outside** the 512 KB the linker knows about | the bootrom only. Nothing this firmware links can be placed here — [exp159](../exp159-a-key-that-was-never-in-flash/) put a key here for that reason |
//!
//! # What this does not prove, and says so first
//!
//! **None of the resets here removes power.** A watchdog reset, a
//! `reset_usb_boot()`, and the reboot that follows flashing all leave the SRAM
//! powered the whole time — [exp157](../exp157-a-note-for-the-next-boot/) had to
//! learn that flashing itself goes *through* the watchdog. So a marker that
//! survives one of these proves that **nothing cleared it**, and nothing more.
//! It is not a PUF measurement: a PUF is about what the cells settle to when
//! power returns, and this experiment never takes power away.
//!
//! That is deliberate. The cheap half decides whether the expensive half is
//! worth anybody's time: if these windows come back zeroed on a reset that never
//! cut power, they will certainly be zero on one that did, and the road stops
//! here. If they survive, a person unplugging a cable becomes worth asking for.

#![no_std]
#![no_main]

use core::mem::MaybeUninit;

use breadcrumb::Cause;
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use static_cell::StaticCell;
use usb_log::log;

use panic_halt as _;

const PRODUCT: &str = "exp179 what survives a reset";

/// 4 KB, the same window size the earlier measurement used, so the numbers are
/// comparable to it rather than merely similar.
const WINDOW: usize = 4096;
const WINDOW_BITS: u32 = (WINDOW * 8) as u32;

/// The earlier work's window: the last 16 KB of the 512 KB main SRAM.
const PRIOR: usize = 0x2007_C000;
/// SRAM bank 8, outside the `RAM` region in `memory.x` entirely.
const BANK8: usize = 0x2008_0000;

/// A pattern with a one-bit count nothing else here produces.
///
/// 24 one-bits in every four bytes is **75%** uniformity. Deliberately not
/// something like `0xA5`, whose 50% would be indistinguishable at a glance from
/// the healthy SRAM startup distribution this experiment is looking for. A
/// marker that can be mistaken for the result is not a marker.
const MARKER: [u8; 4] = [0xDE, 0xAD, 0xBE, 0xEF];

/// How many boots to take before stopping and just reporting.
const BOOTS: u32 = 3;

/// The window this firmware owns, in the section `cortex-m-rt` does not
/// initialise.
#[link_section = ".uninit.exp179_probe"]
static mut PROBE: MaybeUninit<[u8; WINDOW]> = MaybeUninit::uninit();

/// Main SRAM, and the two scratch banks after it.
const SRAM: usize = 0x2000_0000;
const SRAM_BLOCKS: usize = 512 * 1024 / WINDOW;
/// Bank 8 and bank 9 are 4 KB each, immediately after the 512 KB.
const BANK_BLOCKS: usize = 2;
const BLOCKS: usize = SRAM_BLOCKS + BANK_BLOCKS;

/// What the survey saw.
#[derive(Clone, Copy)]
struct Findings {
    probe_at: u32,
    ones: [u32; 3],
    head: [[u8; 16]; 3],
    /// One bit per 4 KB block, set when every byte in it is zero.
    zero_map: [u32; (BLOCKS + 31) / 32],
}

/// Reads the three windows, as the first thing this firmware does with memory.
///
/// What has already run when this is called, in order, because the reading only
/// means something with that list beside it:
///
/// 1. the **bootrom**;
/// 2. `cortex-m-rt`'s startup — `.data` copied, `.bss` zeroed, and `.uninit`
///    deliberately left alone;
/// 3. `embassy-rp`'s `pre_init`, which resets SIO and PROC1 and touches no SRAM;
/// 4. `breadcrumb::read`, which reads and clears watchdog registers.
///
/// What has **not** run is `embassy_rp::init`, the USB stack, or any task. The
/// stack has been used only by this call chain.
///
/// # Safety
///
/// Reads three fixed windows. `PROBE` is this firmware's own; `PRIOR` is inside
/// the stack's region and is read, never written; `BANK8` is outside everything
/// the linker placed.
unsafe fn survey() -> Findings {
    let probe = core::ptr::addr_of_mut!(PROBE) as *const u8;
    let windows: [*const u8; 3] = [probe, PRIOR as *const u8, BANK8 as *const u8];
    let mut out = Findings {
        probe_at: probe as u32,
        ones: [0; 3],
        head: [[0; 16]; 3],
        zero_map: [0; (BLOCKS + 31) / 32],
    };

    // The map. Three windows answer "is this one cleared"; the map answers
    // "where does the cleared part start and stop", which is the difference
    // between a point and a boundary. Read as u32s and OR'd, because all this
    // needs to know is whether anything in the block is non-zero.
    for b in 0..BLOCKS {
        let base = (SRAM + b * WINDOW) as *const u32;
        let mut acc: u32 = 0;
        for i in 0..(WINDOW / 4) {
            acc |= core::ptr::read_volatile(base.add(i));
        }
        if acc == 0 {
            out.zero_map[b / 32] |= 1 << (b % 32);
        }
    }
    for (w, base) in windows.iter().enumerate() {
        let mut ones: u32 = 0;
        for i in 0..WINDOW {
            ones += core::ptr::read_volatile(base.add(i)).count_ones();
        }
        out.ones[w] = ones;
        for j in 0..16 {
            out.head[w][j] = core::ptr::read_volatile(base.add(j));
        }
    }
    out
}

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

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

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        led.toggle();
        Timer::after(Duration::from_millis(500)).await;
    }
}

/// What a window's contents are, in the only four categories that mean anything
/// here.
fn verdict(ones: u32, head: &[u8; 16]) -> &'static str {
    if ones == 0 {
        return "ALL ZERO — something cleared it";
    }
    if ones == WINDOW_BITS {
        return "ALL ONES — erased flash's value, not SRAM's";
    }
    let mut is_marker = true;
    for (i, b) in head.iter().enumerate() {
        if *b != MARKER[i % 4] {
            is_marker = false;
            break;
        }
    }
    if is_marker {
        return "OUR MARKER — it survived, nothing cleared it";
    }
    "SOMETHING ELSE — neither zero nor ours"
}

const NAMES: [&str; 3] = [".uninit (ours)", "0x2007c000 (the earlier window)", "0x20080000 (bank 8)"];

fn cause_name(c: Cause) -> &'static str {
    match c {
        Cause::Fresh => "fresh — a flash or a power-on, with no note before it",
        Cause::Completed => "completed",
        Cause::Hang => "HANG",
        Cause::Fault => "FAULT",
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // First, before anything can take a fault or reset a peripheral.
    let note = breadcrumb::read();
    // Before embassy_rp::init, before USB, before any task. Safety: see survey.
    let found = unsafe { survey() };

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("179");
    config.max_power = 100;
    config.max_packet_size_0 = 64;

    static CONFIG_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESC: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 128]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESC.init([0; 256]),
        BOS_DESC.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 128]),
    );
    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());
    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    // Let the host attach before the interesting part goes past.
    Timer::after(Duration::from_millis(2500)).await;

    log!("{}", PRODUCT);
    log!("  read as the first thing main does, before embassy_rp::init.");
    log!("boot #{}, previous boot {}", note.boot, cause_name(note.cause));
    log!("  none of these resets removes power — see the README before reading a survival as a PUF");

    {
        log!("  .uninit probe sits at 0x{:08x}", found.probe_at);
        for w in 0..3 {
            let ones = found.ones[w];
            // Tenths of a percent, without floating point in a log line.
            let per_mille = (ones as u64 * 1000) / WINDOW_BITS as u64;
            log!(
                "  {}: {} of {} one-bits ({}.{}%)",
                NAMES[w],
                ones,
                WINDOW_BITS,
                per_mille / 10,
                per_mille % 10
            );
            let h = &found.head[w];
            log!(
                "    first 16: {:02x}{:02x}{:02x}{:02x} {:02x}{:02x}{:02x}{:02x} {:02x}{:02x}{:02x}{:02x} {:02x}{:02x}{:02x}{:02x}",
                h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7],
                h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]
            );
            log!("    {}", verdict(ones, h));
        }
    }

    // The zero map, as ranges rather than 130 lines — the log queue holds
    // sixteen and drops the rest, which exp168 paid for once already.
    {
        let zero = |b: usize| found.zero_map[b / 32] & (1 << (b % 32)) != 0;
        let total: usize = (0..BLOCKS).filter(|b| zero(*b)).count();
        log!("  zero map: {} of {} 4 KB blocks are entirely zero", total, BLOCKS);
        let mut b = 0usize;
        let mut printed = 0;
        while b < BLOCKS && printed < 4 {
            if zero(b) {
                let start = b;
                while b < BLOCKS && zero(b) {
                    b += 1;
                }
                log!(
                    "    0x{:08x}..0x{:08x}  {} block(s)",
                    SRAM + start * WINDOW,
                    SRAM + b * WINDOW,
                    b - start
                );
                printed += 1;
            } else {
                b += 1;
            }
        }
    }

    if note.boot < BOOTS {
        log!("writing the marker into .uninit and bank 8, then resetting through the watchdog");
        log!("  not into 0x2007c000: that window is the stack this code is standing on");
        // Safety: `.uninit` is ours, and bank 8 is outside everything the linker
        // placed. Neither is read by anything else in this firmware.
        unsafe {
            let probe = core::ptr::addr_of_mut!(PROBE) as *mut u8;
            for i in 0..WINDOW {
                core::ptr::write_volatile(probe.add(i), MARKER[i % 4]);
                core::ptr::write_volatile((BANK8 as *mut u8).add(i), MARKER[i % 4]);
            }
        }
        Timer::after(Duration::from_millis(500)).await;
        breadcrumb::reboot();
    }

    log!("boot #{} of {} — done. The three readings above are the result.", note.boot, BOOTS);
    loop {
        Timer::after(Duration::from_secs(5)).await;
        log!("idle: boot #{}, nothing further happens", note.boot);
    }
}
