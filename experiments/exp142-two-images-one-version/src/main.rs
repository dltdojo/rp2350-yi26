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

// SLOT ("A"/"B"), VERSION_MAJOR, VERSION_MINOR — the only difference between the
// two images, set by build.rs from EXP142_SLOT / EXP142_MAJOR / EXP142_MINOR.
include!(concat!(env!("OUT_DIR"), "/exp142_config.rs"));

/// This image's own IMAGE_DEF, at flash offset 0 of its partition.
///
/// It carries two items: the image type (a Secure Arm executable, matching what
/// `embassy-rp` would have injected), and a **VERSION** — the word the ROM
/// compares across the A/B pair to decide which partition to boot. embassy-rp's
/// default IMAGE_DEF is turned off by the `imagedef-none` feature so this is the
/// one the ROM reads. `Block` lays the words out for us; the block loop's link
/// is a self-loop (`0`), and the start/end markers are the ones the ROM scans
/// the first 4 KiB of a partition for.
///
/// The version word is `(major << 16) | minor`, the same encoding embassy-rp's
/// `with_version` uses for a partition table.
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

/// How long to wait before interrogating the ROM — for the reader, not the ROM.
/// The answers are said once, and a host that has not opened the port yet will
/// miss them. exp134 measured what that costs.
const SETTLE: Duration = Duration::from_secs(3);

/// How often the idle line repeats.
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// `PT_INFO`, from `get_partition_table_info` (§5.5.11.2) — whether there is a
/// table and how many partitions it has.
const PT_INFO: u32 = 0x0001;

const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher, so the next flash needs no button.
#[embassy_executor::task]
async fn control_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                let rate = receiver.line_coding().data_rate();
                usb_reboot::reboot_if_requested(rate).await;
            }
            Either::Second(_) => {}
        }
    }
}

/// Say which slot and version this image is, then ask the ROM about the table
/// and the A/B pairing — the same instrument exp139 used, now expecting a B.
#[embassy_executor::task]
async fn interrogate_task() -> ! {
    Timer::after(SETTLE).await;

    // ---- Who am I? --------------------------------------------------------
    //
    // Baked in at build time. The point of the experiment is that this line and
    // the ROM's choice agree: the slot that is *running* is the slot the ROM
    // picked, and it picked by the version below.
    log!("I am slot {}, version {}.{}.", SLOT, VERSION_MAJOR, VERSION_MINOR);
    log!(
        "  my IMAGE_DEF VERSION word = {:#010x}",
        ((VERSION_MAJOR as u32) << 16) | VERSION_MINOR as u32
    );

    let mut buf = [0u32; 16];

    // ---- Is there a table, and how many partitions? -----------------------
    let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), PT_INFO) };
    log!("get_partition_table_info(PT_INFO) -> {}", n);
    for (i, w) in buf.iter().take(n.max(0) as usize).enumerate() {
        log!("  word[{}] = {:#010x}", i, w);
    }

    // ---- Does partition 0 have a B side now? ------------------------------
    //
    // exp139 got -17 here: one partition, no B. With an A/B pair, the ROM
    // returns the index of the B partition. That number turning from negative
    // to a partition index is the table's A/B link being seen.
    let b = unsafe { rom_data::get_b_partition(0) };
    log!("get_b_partition(0) -> {}", b);
    if b < 0 {
        log!("  negative: partition 0 has no B side, or there is no table");
    } else {
        log!("  partition {} is the B side of partition 0 — this is an A/B pair", b);
    }

    log!("done. nothing was written; this firmware only reads.");

    loop {
        Timer::after(IDLE_REPORT).await;
        log!("idle: slot {} v{}.{} — see the README to decode", SLOT, VERSION_MAJOR, VERSION_MINOR);
    }
}

#[embassy_executor::task]
async fn blink_task(mut led: Output<'static>) -> ! {
    loop {
        led.set_high();
        Timer::after(BLINK_ON).await;
        led.set_low();
        Timer::after(BLINK_OFF).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let led = Output::new(p.PIN_25, Level::Low);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    // The product string carries the slot so `lsusb` alone tells you which image
    // booted, before the log is even read.
    config.product = Some(match SLOT {
        "A" => "exp142 slot A",
        "B" => "exp142 slot B",
        _ => "exp142",
    });
    config.serial_number = Some("142");
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
    spawner.spawn(interrogate_task().unwrap());
    spawner.spawn(blink_task(led).unwrap());

    log!("exp142 up. slot {}, version {}.{}, running from a partition.", SLOT, VERSION_MAJOR, VERSION_MINOR);
    log!("Asking the ROM about the A/B pair in {} seconds.", SETTLE.as_secs());
}
