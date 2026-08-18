//! exp154 — does this chip have anywhere to keep a secret?
//!
//! The signing road needs somewhere to put a private key that code on the
//! other side of a security boundary cannot read. Before building any boundary,
//! this asks the part what it already has — the same move
//! [exp138](../exp138-what-the-rom-already-knows/) made for A/B updates, where
//! asking turned out to reframe everything after it.
//!
//! It reads. It writes nothing. OTP is one-time programmable, so a firmware
//! that gets a write wrong does not fail — it ruins the board permanently, for
//! every future experiment. Nothing here calls a write function at all.
//!
//! # What it prints, and why each part is here
//!
//! 1. **Every row, classified.** All 4096 rows, collapsed into runs of
//!    like-answers, so the shape of the OTP fits on a screen instead of
//!    scrolling past. Three answers are possible per row and all three matter:
//!    *programmed* (something is there), *blank* (nothing yet), and **refused**
//!    — the hardware declining to hand it over, which is the one this road came
//!    looking for.
//! 2. **The identity rows.** exp113 builds a chip identity out of rows 0–3 and
//!    prints it. The same rows are printed here so the two experiments can be
//!    laid side by side on one board.
//! 3. **The rows a signing experiment elsewhere called a device key.** Prior
//!    work outside this repository reads what it calls the ECDSA private key
//!    from rows `0xE80`–`0xE8F`, and falls back to a compiled-in test key when
//!    they read as zero. Whether those rows exist, and what is in them, is a
//!    question with an answer rather than an assumption — so it gets read.
//!
//! # The arithmetic that made this worth checking
//!
//! That prior work addresses OTP by hand, as
//! `read_volatile(0x4013_0000 + (0xE80 + i) * 8)`, on the stated belief that a
//! row is two bytes of payload spaced eight bytes apart. The HAL disagrees:
//! `OTP_DATA_BASE` is a 32-bit alias where **one read returns two neighbouring
//! rows**, so row `r` sits at byte offset `r * 2`, and only the first 8 KiB —
//! 4096 rows — is populated.
//!
//! Take the two at their word and they do not describe the same place.
//! `(0xE80) * 8` is byte 29,696, which is nowhere in an 8 KiB window. Read as a
//! row number, `0xE80` is 3,712 and lands comfortably inside it. This firmware
//! reads it the second way, which is the way the HAL means, and prints what is
//! there.
//!
//! It deliberately does **not** read the first way. An access outside the
//! populated window is exactly the kind of thing that ends in a HardFault, and
//! a HardFault here takes USB with it — leaving a board that says nothing at
//! all, which is the least useful result this experiment could produce.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::otp;
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

/// Rows in the RP2350's OTP, post error-correction. The HAL says 64 pages of
/// 64 rows; this repeats the number rather than importing it so a change in
/// either place shows up as a disagreement in the log instead of silently
/// following along.
const TOTAL_ROWS: usize = 4096;

/// The rows the prior work named as a device key, read as row numbers.
const CLAIMED_KEY_FIRST: usize = 0xE80;
const CLAIMED_KEY_ROWS: usize = 16;

/// What one row had to say when it was asked.
///
/// `Refused` is not an error in the sense of something having gone wrong. It
/// is the hardware answering "not to you", which is the answer this experiment
/// is looking for — a place the CPU is already declining to read.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Answer {
    Programmed,
    Blank,
    Refused,
}

impl Answer {
    fn name(self) -> &'static str {
        match self {
            Answer::Programmed => "programmed",
            Answer::Blank => "blank",
            Answer::Refused => "REFUSED",
        }
    }
}

/// Ask one row, without interpreting what comes back.
///
/// The raw alias is used rather than the ECC one because it is the one that
/// distinguishes "refused" from "zero": the HAL reports `InvalidPermissions`
/// when a raw read comes back as all-ones, which is the bus saying no. An ECC
/// read of a locked row would arrive as a value like any other.
fn ask(row: usize) -> Answer {
    match otp::read_raw_word(row) {
        Err(_) => Answer::Refused,
        Ok(0) => Answer::Blank,
        Ok(_) => Answer::Programmed,
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

/// Sweep every row and report the answers as runs.
///
/// Printing 4096 lines would be printing, not reporting: a reader wants the
/// shape, and the shape is which stretches of the OTP say the same thing. So
/// consecutive rows with the same answer collapse into one line naming the
/// range and how many rows it covers.
#[embassy_executor::task]
async fn survey_task() -> ! {
    // Let enumeration finish before doing anything that takes a while. exp113
    // paid for this lesson: the first moments after boot are the one window
    // where a busy executor is unrecoverable, because a board that never
    // enumerates can only be reached through BOOTSEL.
    Timer::after(Duration::from_secs(3)).await;

    log!("sweeping {} OTP rows. Nothing here writes.", TOTAL_ROWS);

    let mut programmed = 0usize;
    let mut blank = 0usize;
    let mut refused = 0usize;
    let mut runs = 0usize;

    let mut run_start = 0usize;
    let mut run_answer = ask(0);

    for row in 0..TOTAL_ROWS {
        let answer = if row == 0 { run_answer } else { ask(row) };

        match answer {
            Answer::Programmed => programmed += 1,
            Answer::Blank => blank += 1,
            Answer::Refused => refused += 1,
        }

        // Hand the CPU back periodically. exp110 measured what a loop that
        // never yields does to every other task, and the heartbeat below is
        // this experiment's evidence that this one does.
        if row % 256 == 0 {
            Timer::after(Duration::from_ticks(1)).await;
        }

        if answer != run_answer {
            log!(
                "rows {:04x}-{:04x} ({:4}): {}",
                run_start,
                row - 1,
                row - run_start,
                run_answer.name()
            );
            runs += 1;
            run_start = row;
            run_answer = answer;
        }
    }

    log!(
        "rows {:04x}-{:04x} ({:4}): {}",
        run_start,
        TOTAL_ROWS - 1,
        TOTAL_ROWS - run_start,
        run_answer.name()
    );
    runs += 1;

    log!(
        "totals: {} programmed, {} blank, {} refused, in {} runs",
        programmed,
        blank,
        refused,
        runs
    );

    // The question this road actually came to ask. A count of zero is a real
    // answer and the one worth stating out loud, because it says the boundary
    // this road needs is not something OTP is going to provide on its own.
    if refused == 0 {
        log!("no row refused a read. Nothing here is hidden from this core by OTP alone.");
    } else {
        log!("{} rows refused. Something is already locked before this firmware ran.", refused);
    }

    // -- the identity rows, for continuity with exp113 -----------------------
    log!("identity rows, the ones exp113 folds into its public value:");
    for row in 0..4usize {
        match otp::read_ecc_word(row) {
            Ok(w) => log!("  row {:04x} = {:04x}", row, w),
            Err(_) => log!("  row {:04x} = REFUSED", row),
        }
    }

    // -- the rows the prior work called a key --------------------------------
    log!(
        "rows {:04x}-{:04x}, which prior work outside this repository reads as an ECDSA private key:",
        CLAIMED_KEY_FIRST,
        CLAIMED_KEY_FIRST + CLAIMED_KEY_ROWS - 1
    );
    let mut all_blank = true;
    for i in 0..CLAIMED_KEY_ROWS {
        let row = CLAIMED_KEY_FIRST + i;
        match otp::read_ecc_word(row) {
            Ok(w) => {
                if w != 0 {
                    all_blank = false;
                }
                log!("  row {:04x} = {:04x}", row, w);
            }
            Err(_) => {
                all_blank = false;
                log!("  row {:04x} = REFUSED", row);
            }
        }
    }
    if all_blank {
        log!("all sixteen read zero: on this part there is no key there to find.");
    }

    log!("survey done. The README records what this printed; nothing is concluded here.");

    loop {
        Timer::after(Duration::from_secs(60)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp154 somewhere to put a key");
    config.serial_number = Some("154");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), 64);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(reboot_task(control, receiver).unwrap());
    spawner.spawn(log_task(sender).unwrap());

    log!("exp154 up. Asking the chip what it already has, and writing nothing.");
    spawner.spawn(survey_task().unwrap());

    // The heartbeat is the evidence that the sweep yielded rather than hogging
    // the executor — the same role it plays in exp113.
    let mut beat: u32 = 0;
    loop {
        beat += 1;
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        log!("heartbeat #{}", beat);
        Timer::after(Duration::from_millis(950)).await;
    }
}
