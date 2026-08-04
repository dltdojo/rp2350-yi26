#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
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

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;


/// A partition table, written by hand, one word at a time.
///
/// `embassy-rp` has a `PartitionTableBlock` builder and it cannot be used
/// here: its `contents` are private and there is no accessor, so a block it
/// builds cannot be placed at an address. That is not a complaint — the
/// builder is for firmware that writes a table at run time, and this table has
/// to exist before any of this firmware runs.
///
/// So it is written out, and the words are reproduced exactly as
/// `PartitionTableBlock::new().add_partition_item(...)` would produce them for
/// the one-partition case. exp125 hand-wrote a FAT12 for the same reason: a
/// structure is an arrangement of bytes that other software has agreed to
/// interpret, and you can write one with an array and some arithmetic.
///
/// ```text
///   0xffffded3   start marker
///   0x0100040a   one partition, four words of item, ITEM_2BS_PARTITION_TABLE
///   0xfc078000   unpartitioned space: all permissions, the families the ROM
///                itself defaulted to — exp138 read this exact value off a
///                board with no table at all
///   0xfc7fe001   partition 0: sectors 1..1023, all permissions
///   0xfc020000   partition 0: accepts the RP2350 ARM-S family
///   0x000004ff   ITEM_2BS_LAST, four words
///   0x00000000   the link to the next block: zero, so the loop is this block
///   0xab123579   end marker
/// ```
///
/// Sector 0 is deliberately *not* in the partition. It is where this table
/// lives, and a partition that contained its own table would be a partition
/// that could be erased by writing to it.
#[link_section = ".partition_table"]
#[used]
static PARTITION_TABLE: [u32; 8] = [
    0xffff_ded3,
    0x0100_040a,
    0xfc07_8000,
    0xfc7f_e001,
    0xfc02_0000,
    0x0000_04ff,
    0x0000_0000,
    0xab12_3579,
];

/// How long to wait before interrogating the ROM.
///
/// Not for the ROM's sake — it is ready before this firmware is. It is for the
/// reader's: the answers are said once, and a host that has not opened the
/// port yet will not see them. exp134 measured exactly what that costs.
const SETTLE: Duration = Duration::from_secs(3);

/// How often the idle line repeats.
const IDLE_REPORT: Duration = Duration::from_secs(5);

/// `PT_INFO`, from the datasheet's list of what `get_partition_table_info`
/// can be asked for (§5.5.11.2). Asking for the table's own summary rather
/// than for a particular partition, because whether there *is* a table is the
/// question this experiment exists to answer.
const PT_INFO: u32 = 0x0001;

/// `CHIP_INFO`, the first flag `get_sys_info` accepts (§5.5.11.1).
const SYS_INFO_CHIP_INFO: u32 = 0x0001;

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

/// The 1200-baud watcher, and nothing else.
///
/// This firmware has no commands. The watcher is here for the same reason it
/// is in every firmware from exp105 onwards: without it the next person to
/// change this board needs a hand on the BOOTSEL button, and two of the three
/// builds here are ones you will want to swap between repeatedly.
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
            // Nothing here reads commands. Bytes are collected and discarded
            // rather than ignored: an OUT endpoint that nobody drains leaves a
            // packet armed, which is the failure crates/usb-log's writer was
            // built to avoid on the other direction.
            Either::Second(_) => {}
        }
    }
}

/// One numbered line a second, forever.
///
/// Ask the ROM three questions, print exactly what it answered, and stop.
///
/// Every number below is printed **raw before it is interpreted**. A decoded
/// field that is wrong looks like a fact; the word it came from looks like
/// what it is. This experiment is the foundation the rest of the arc stands
/// on, so it is the one place where being able to check the decoding by hand
/// matters most.
#[embassy_executor::task]
async fn interrogate_task() -> ! {
    // Wait for a reader. Everything here is said once, and exp134 is the
    // experiment about what happens to lines said into a closed port.
    Timer::after(SETTLE).await;

    let mut buf = [0u32; 16];

    // ---- 1. Is there a partition table at all? ----------------------------
    //
    // PT_INFO, the first flag in the datasheet's list (§5.5.11.2). The ROM
    // returns the number of words it wrote, or a negative error.
    let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), PT_INFO) };
    log!("get_partition_table_info(PT_INFO) -> {}", n);

    if n <= 0 {
        log!("  no words returned: this board has no partition table");
    } else {
        for (i, w) in buf.iter().take(n as usize).enumerate() {
            log!("  word[{}] = {:#010x}", i, w);
        }
    }

    // ---- 2. What does the ROM say about itself? ---------------------------
    let n = unsafe { rom_data::get_sys_info(buf.as_mut_ptr(), buf.len(), SYS_INFO_CHIP_INFO) };
    log!("get_sys_info(CHIP_INFO) -> {}", n);
    for (i, w) in buf.iter().take(n.max(0) as usize).enumerate() {
        log!("  word[{}] = {:#010x}", i, w);
    }

    // ---- 3. Does partition 0 have a B side? -------------------------------
    //
    // The question the whole arc turns on. `get_b_partition` is the ROM
    // answering "which partition is the other half of this pair" — the thing
    // a chip without A/B support in its ROM cannot answer at all.
    let b = unsafe { rom_data::get_b_partition(0) };
    log!("get_b_partition(0) -> {}", b);
    if b < 0 {
        log!("  negative: partition 0 has no B side, or there is no table");
    } else {
        log!("  partition {} is the B side of partition 0", b);
    }

    log!("done. nothing was written; this firmware only reads.");

    loop {
        Timer::after(IDLE_REPORT).await;
        log!("idle: the answers above are all of them — see the README to decode");
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

    // Board-specific: the LED's GPIO. One line, clearly marked.
    let led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp139 a table of one");
    config.serial_number = Some("139");
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

    // Said once, and under two of the three policies you will never see it.
    // That is the experiment, stated by the firmware in the one line most
    // likely to be thrown away.
    log!(
        "exp139 up. Running from a partition, with a hand-written table at flash 0."
    );
    log!("Asking the ROM the same three questions in {} seconds.", SETTLE.as_secs());
}
