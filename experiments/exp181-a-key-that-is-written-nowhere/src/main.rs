// SPDX-License-Identifier: Apache-2.0
//! exp181 — a key that is written nowhere.
//!
//! The [identity road](../README.md#the-identity-road) asks where a board's own
//! secret comes from, and had three answers, all of them "not from here": OTP
//! stores but does not hide ([exp154](../exp154-somewhere-to-put-a-key/)), a
//! TRNG key dies at reset ([exp159](../exp159-a-key-that-was-never-in-flash/)),
//! and a compiled-in key is readable and identical on every board
//! ([exp166](../exp166-whose-firmware-will-it-accept/), and
//! [exp175](../exp175-the-secret-is-the-file/) forged an assertion with one).
//!
//! [exp179](../exp179-what-survives-a-reset/) opened the fourth: **the RP2350
//! does not clear SRAM on power-on.** Bank 8 comes up at about 51% one-bits,
//! every time, and this experiment asks whether the pattern is *the same* 51%
//! often enough to carry a key.
//!
//! # What is stored, and what is not
//!
//! ```text
//!   in flash:  helper data, a key hash, and the enrolment's uniformity
//!   in SRAM:   whatever the cells settle to when power arrives
//!   the key:   neither. It exists for as long as it is being used, and
//!              is reconstructed from the two above.
//! ```
//!
//! The helper is `H = K ⊕ w`, a code-offset fuzzy commitment with a repetition
//! code: each of 256 key bits is spread across **31 SRAM cells**, and
//! reconstruction is a majority vote. Anybody who dumps this flash gets `H`,
//! which is the key XORed with a pattern that only exists inside a powered
//! chip. **That is the property [exp175](../exp175-the-secret-is-the-file/) said
//! was missing**: the image cannot carry this secret, because the secret is not
//! in the image.
//!
//! # What it is not
//!
//! - **Not unique to this chip, as far as this experiment knows.** Uniqueness
//!   needs a second board, and this repository's other one lives with a phone.
//!   What is shown here is that the key is not in the image — a different
//!   sentence, and a reader will merge the two unless they are kept apart.
//! - **Not hidden while it is in use.**
//!   [exp163](../exp163-how-long-is-a-secret-in-the-open/) measured how long a
//!   key sits readable in SRAM, and every word of it applies here. A PUF changes
//!   where a key comes from, not whether it can be read while it is being used.
//! - **Not a key anybody should trust.** Every key this repository produces is a
//!   test key.
//!
//! # Two traps, both handed over by earlier experiments
//!
//! **Enrolling on a cleared window.** exp179 measured that the flashing path
//! zeroes SRAM: on the boot straight after `yi26 flash`, bank 8 reads 0.00%.
//! Enrolling then would produce `H = K ⊕ 0 = K` — a key stored in flash in plain
//! sight, which is exp175's failure reinvented. So enrolment **refuses** unless
//! the window's uniformity is between 40% and 60%.
//!
//! **Counting a warm reset as evidence.** exp179 also measured that a reset
//! which keeps the power clears nothing, so reconstruction after one is exact by
//! construction and proves nothing at all. `breadcrumb` says how this boot
//! began, and a reconstruction on anything but a genuinely fresh boot is
//! reported as what it is.

#![no_std]
#![no_main]

use breadcrumb::Cause;
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::flash::{Blocking, Flash};
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, Trng};
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use sha2::{Digest, Sha256};
use static_cell::StaticCell;
use usb_log::log;

use panic_halt as _;

const PRODUCT: &str = "exp181 a key that is written nowhere";

/// SRAM bank 8: 4 KB the linker knows nothing about, so nothing this firmware
/// places can land in it. exp159 put a key here for the same reason, and exp179
/// measured that it comes up at about 51% one-bits after power.
const WINDOW: usize = 0x2008_0000;
const WINDOW_BYTES: usize = 4096;
const WINDOW_BITS: usize = WINDOW_BYTES * 8;

const KEY_BITS: usize = 256;
/// Cells per key bit. Odd, because reconstruction is a majority vote, and 31
/// because it is the largest that fits 256 key bits into a quarter of the window
/// — leaving the rest for a later experiment to use differently.
const REPEAT: usize = 31;
const USED_BITS: usize = KEY_BITS * REPEAT;
const HELPER_BYTES: usize = USED_BITS / 8;

const _: () = assert!(USED_BITS <= WINDOW_BITS);
const _: () = assert!(REPEAT % 2 == 1, "an even repetition has no majority");

/// The band a genuine power-on reading falls in. exp179 measured 0.00% after a
/// flash and 51.0% after the cable came out and back in; this is the gap between
/// those two, and it is what stops an enrolment from happening on a cleared
/// window.
const UNIFORMITY_MIN: u32 = 400;
const UNIFORMITY_MAX: u32 = 600;

/// Three megabytes in — far past anything this repository flashes, and a whole
/// sector to itself.
const HELPER_OFFSET: u32 = 0x30_0000;
const FLASH_SIZE: usize = 4 * 1024 * 1024;
const XIP_BASE: usize = 0x1000_0000;
const SECTOR: usize = 4096;
const RECORD_MAGIC: u32 = 0x8181_5241;

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
    TRNG_IRQ => embassy_rp::trng::InterruptHandler<TRNG>;
});

/// What enrolment left behind. Everything here is safe to read off a dead chip;
/// none of it is the key.
#[repr(C)]
#[derive(Clone, Copy)]
struct Record {
    magic: u32,
    key_bits: u32,
    repeat: u32,
    uniformity_per_mille: u32,
    key_hash: [u8; 32],
    helper: [u8; HELPER_BYTES],
}

fn bit(buf: &[u8], i: usize) -> u8 {
    (buf[i / 8] >> (i % 8)) & 1
}

fn set_bit(buf: &mut [u8], i: usize, v: u8) {
    if v != 0 {
        buf[i / 8] |= 1 << (i % 8);
    } else {
        buf[i / 8] &= !(1 << (i % 8));
    }
}

/// One-bits per thousand, over the whole window.
fn uniformity(window: &[u8; WINDOW_BYTES]) -> u32 {
    let ones: u32 = window.iter().map(|b| b.count_ones()).sum();
    (ones as u64 * 1000 / WINDOW_BITS as u64) as u32
}

/// Reads the record out of flash through XIP, which needs no peripheral and no
/// erase-safe path — this is a read of memory-mapped flash like any other.
fn read_record() -> Option<Record> {
    let at = (XIP_BASE + HELPER_OFFSET as usize) as *const Record;
    // Safety: a fixed address inside this board's flash, read-only, and the
    // magic is checked before anything else is believed.
    let r = unsafe { core::ptr::read_volatile(at) };
    if r.magic == RECORD_MAGIC && r.key_bits == KEY_BITS as u32 && r.repeat == REPEAT as u32 {
        Some(r)
    } else {
        None
    }
}

/// `H = K ⊕ w`, spread across `REPEAT` cells per key bit.
fn build_helper(key: &[u8; KEY_BITS / 8], window: &[u8; WINDOW_BYTES]) -> [u8; HELPER_BYTES] {
    let mut helper = [0u8; HELPER_BYTES];
    for i in 0..USED_BITS {
        let k = bit(key, i / REPEAT);
        set_bit(&mut helper, i, k ^ bit(window, i));
    }
    helper
}

/// The majority vote, and the error count that falls out of it.
///
/// Every position where the vote disagrees with its own majority is a cell that
/// changed since enrolment. **That count is only the true error count if every
/// key bit reconstructed correctly**, which the key hash decides — so it is
/// reported beside the hash comparison and never on its own.
fn reconstruct(
    helper: &[u8; HELPER_BYTES],
    window: &[u8; WINDOW_BYTES],
) -> ([u8; KEY_BITS / 8], u32) {
    let mut key = [0u8; KEY_BITS / 8];
    let mut minority = 0u32;
    for j in 0..KEY_BITS {
        let mut ones = 0usize;
        for r in 0..REPEAT {
            let i = j * REPEAT + r;
            ones += (bit(helper, i) ^ bit(window, i)) as usize;
        }
        let majority = if ones * 2 > REPEAT { 1 } else { 0 };
        set_bit(&mut key, j, majority);
        minority += if majority == 1 { (REPEAT - ones) as u32 } else { ones as u32 };
    }
    (key, minority)
}

fn hash(key: &[u8; KEY_BITS / 8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(key);
    h.finalize().into()
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

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        led.toggle();
        Timer::after(Duration::from_millis(500)).await;
    }
}

fn cause_name(c: Cause) -> &'static str {
    match c {
        Cause::Fresh => "a power-on or a flash — nothing before it",
        Cause::Completed => "a reset that kept the power",
        Cause::Hang => "a hang",
        Cause::Fault => "a fault",
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // First, before anything can take a fault or touch a peripheral, and before
    // the window could be disturbed. Reading bank 8 needs no clocks.
    let note = breadcrumb::read();
    let mut window = [0u8; WINDOW_BYTES];
    for i in 0..WINDOW_BYTES {
        // Safety: bank 8, which nothing the linker placed can occupy.
        window[i] = unsafe { core::ptr::read_volatile((WINDOW as *const u8).add(i)) };
    }
    let uni = uniformity(&window);

    let p = embassy_rp::init(Default::default());
    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("181");
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

    Timer::after(Duration::from_millis(2500)).await;

    let fresh = note.cause == Cause::Fresh;
    let mut errors: u32 = 0;
    let mut matched = false;
    let mut enrolled_uni: u32 = 0;

    // One assignment, from one match, so there is no moment where `state` says
    // something nobody meant.
    let state: &str = match read_record() {
        None => {
            if !(UNIFORMITY_MIN..=UNIFORMITY_MAX).contains(&uni) {
                "REFUSED to enrol: the window is not a power-on reading"
            } else {
                let mut trng_config = TrngConfig::default();
                // exp109's number. The driver's default of 25 samples the ring
                // oscillator faster than it decorrelates, and exp174 lost
                // twenty seconds a credential to finding that out.
                trng_config.sample_count = 1000;
                let mut trng = Trng::new(p.TRNG, Irqs, trng_config);
                let mut key = [0u8; KEY_BITS / 8];
                trng.blocking_fill_bytes(&mut key);

                let helper = build_helper(&key, &window);
                let record = Record {
                    magic: RECORD_MAGIC,
                    key_bits: KEY_BITS as u32,
                    repeat: REPEAT as u32,
                    uniformity_per_mille: uni,
                    key_hash: hash(&key),
                    helper,
                };
                let mut page = [0xffu8; SECTOR];
                // Safety: Record is repr(C) and plain data; this is the same
                // bytes the reader will map back over.
                let bytes: &[u8] = unsafe {
                    core::slice::from_raw_parts(
                        &record as *const Record as *const u8,
                        core::mem::size_of::<Record>(),
                    )
                };
                page[..bytes.len()].copy_from_slice(bytes);

                let mut flash = Flash::<_, Blocking, FLASH_SIZE>::new_blocking(p.FLASH);
                let ok = flash.blocking_erase(HELPER_OFFSET, HELPER_OFFSET + SECTOR as u32).is_ok()
                    && flash.blocking_write(HELPER_OFFSET, &page).is_ok();
                // The key goes out of scope here and is never printed.
                enrolled_uni = uni;
                if ok { "ENROLLED" } else { "enrolment failed to write flash" }
            }
        }
        Some(r) => {
            enrolled_uni = r.uniformity_per_mille;
            let (key, minority) = reconstruct(&r.helper, &window);
            errors = minority;
            matched = hash(&key) == r.key_hash;
            if matched { "the key came back" } else { "the key did NOT come back" }
        }
    };

    // exp180's lesson: a fact printed once is a fact most readers never see.
    loop {
        log!("{}", PRODUCT);
        log!("  boot #{}, {}", note.boot, cause_name(note.cause));
        log!(
            "  bank 8 now: {}.{}% one-bits{}",
            uni / 10, uni % 10,
            if uni == 0 { " — cleared, so this board was just flashed (exp179)" } else { "" }
        );
        log!("  {}", state);
        if enrolled_uni > 0 {
            log!("    enrolled at {}.{}% one-bits", enrolled_uni / 10, enrolled_uni % 10);
        }
        if !state.starts_with("ENROLLED") && !state.starts_with("REFUSED") {
            let per_mille = (errors as u64 * 1000) / USED_BITS as u64;
            log!(
                "    {} of {} cells changed since enrolment — {}.{}% of them",
                errors, USED_BITS, per_mille / 10, per_mille % 10
            );
            log!(
                "    {} — and the count above is exact only because of that",
                if matched { "every one of the 256 key bits reconstructed" } else { "at least one key bit did not" }
            );
            if !fresh {
                log!("    NOT EVIDENCE: this boot kept its power, so the window was never re-rolled (exp179)");
            }
        }
        log!("  the key itself is not printed, and is not stored anywhere");
        Timer::after(Duration::from_secs(15)).await;
    }
}
