//! exp147 — two firmwares, one phone, and a switch you can see from across the
//! room.
//!
//! The whole A/B arc, arranged so that a person with a phone and no toolchain
//! can run it and read the result with their eyes:
//!
//! - [exp139](../../exp139-a-table-of-one/) put a partition table on a board.
//! - [exp142](../../exp142-two-images-one-version/) let the ROM choose between
//!   two images by version.
//! - [exp143](../../exp143-the-image-that-is-never-bought/) found the other way
//!   in — a flash update boot runs the other half *once*, and gives it back.
//! - [exp146](../../exp146-a-page-that-writes-flash/) let a browser write flash.
//!
//! This firmware is the prop that makes all of that visible. It is exp142's
//! image with one thing added: **the blink rate is a build input**, so slot A
//! blinks fast and slot B blinks slow, and which one the ROM booted is a
//! question the LED answers with nothing installed on the host at all.
//!
//! The firmware itself proves nothing new. `ab.html` next to this file is the
//! experiment; this is what it moves around.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::block::{item_generic_2bs, item_image_type_exe, Architecture, Block, Security, ITEM_1BS_VERSION};
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::USB;
use embassy_rp::rom_data;
use embassy_rp::usb::{Driver, InterruptHandler};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

// SLOT, VERSION_MAJOR/MINOR, BLINK_MS, PACE — from build.rs.
include!(concat!(env!("OUT_DIR"), "/exp147_config.rs"));

/// exp142's versioned IMAGE_DEF, unchanged. The VERSION word is what the ROM
/// compares — and, in this experiment, the four bytes `ab.html` rewrites to
/// make the other half win.
#[link_section = ".start_block"]
#[used]
static IMAGE_DEF: Block<3> = Block::new([
    item_image_type_exe(Security::Secure, Architecture::Arm),
    item_generic_2bs(0, 2, ITEM_1BS_VERSION),
    ((VERSION_MAJOR as u32) << 16) | VERSION_MINOR as u32,
]);

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;
const SETTLE: Duration = Duration::from_secs(3);
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// Scratch for `pick_ab_parition`, which parses the partition table first.
#[repr(C, align(4096))]
struct Workarea([u8; 4096]);
static mut WORKAREA: Workarea = Workarea([0; 4096]);

/// This image's VERSION **as it is in flash right now**, which is not
/// necessarily the one it was built with.
///
/// `ab.html`'s switch rewrites exactly these four bytes, so after a switch the
/// number compiled into this firmware and the number the ROM compared are
/// different — and the ROM's is the one that decided anything. Reporting the
/// built-in constant would be the same mistake exp143 made with the TBYB bit:
/// trusting a build flag about a byte somebody else has since changed.
///
/// `Block` is `#[repr(C)]` — start marker, then the three item words — so the
/// version value is the fourth word. Volatile, because the point is to see a
/// change the compiler cannot know about.
fn version_in_flash() -> u32 {
    let p = core::ptr::addr_of!(IMAGE_DEF) as *const u32;
    unsafe { core::ptr::read_volatile(p.add(3)) }
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher. Load-bearing here: this is how a phone puts the board
/// back into BOOTSEL between switches, with `flash.html` and no button.
#[embassy_executor::task]
async fn control_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }
            Either::Second(_) => {}
        }
    }
}

/// The machine-readable half of the answer, for anyone who does open a log.
/// The LED is the point; this is the cross-check.
#[embassy_executor::task]
async fn say_task() -> ! {
    Timer::after(SETTLE).await;
    let v = version_in_flash();
    log!("I am slot {}, blinking {} — {} ms on, {} ms off.", SLOT, PACE, BLINK_MS, BLINK_MS);
    log!("  my VERSION in flash = v{}.{}", (v >> 16) & 0xffff, v & 0xffff);
    if v != ((VERSION_MAJOR as u32) << 16 | VERSION_MINOR as u32) {
        log!("  (built as v{}.{} — somebody rewrote those four bytes)", VERSION_MAJOR, VERSION_MINOR);
    }

    let pick = unsafe {
        rom_data::pick_ab_parition(core::ptr::addr_of_mut!(WORKAREA) as *mut u8, 4096, 0)
    };
    log!("pick_ab_parition(0) -> {} (the half the ROM prefers, which is me)", pick);

    loop {
        Timer::after(IDLE_REPORT).await;
        let v = version_in_flash();
        log!(
            "idle: slot {}, {} blink, v{}.{} in flash, partition {}",
            SLOT,
            PACE,
            (v >> 16) & 0xffff,
            v & 0xffff,
            pick
        );
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    // "exp147 slot A fast" / "exp147 slot B slow", built by build.rs. A phone
    // can read this with inspect.html and never open a log.
    config.product = Some(concat!("exp147 ", env!("EXP147_LABEL")));
    config.serial_number = Some("147");
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

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);
    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(control_task(control, receiver).unwrap());
    spawner.spawn(say_task().unwrap());

    // No version here on purpose: at this point the only version this code has
    // is the one it was built with, and after a switch that is not the number
    // that decided anything. The version is reported three seconds later, read
    // from flash.
    log!("exp147 up. slot {}, {} blink.", SLOT, PACE);

    // Deliberately in `main` and not in a task: if everything else in this
    // firmware were to stop, the LED is what a person is watching, and it
    // should be the last thing to go.
    let on = Duration::from_millis(BLINK_MS);
    loop {
        led.set_high();
        Timer::after(on).await;
        led.set_low();
        Timer::after(on).await;
    }
}
