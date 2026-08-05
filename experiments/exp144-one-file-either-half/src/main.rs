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

// VERSION_MAJOR / VERSION_MINOR, from build.rs. There is no slot letter here on
// purpose: this image does not know which half it is in, and the experiment is
// about who does.
include!(concat!(env!("OUT_DIR"), "/exp144_config.rs"));

/// The usual versioned IMAGE_DEF (exp142's recipe): the ROM compares this
/// VERSION across the A/B pair.
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
const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

/// `get_partition_table_info` flags (§5.5.11.2). `PT_INFO` is the summary
/// exp139 and exp142 used; `LOCATION_AND_FLAGS` asks for each partition's own
/// location word, which is what makes the ROM's answer below nameable as a
/// partition rather than as a pair of sector numbers.
const PT_INFO: u32 = 0x0001;
/// Measured, not guessed: `0x0002` is accepted and answers nothing, `0x0010` is
/// the one that returns location/flags pairs. See the README.
const PT_LOCATION_AND_FLAGS: u32 = 0x0010;
/// Ask about one partition only; its number goes in bits 24 and up.
const PT_SINGLE_PARTITION: u32 = 0x8000;

/// A partition's location word, as both the ROM and
/// [`crates/partition-table`](../../../crates/partition-table/) encode it:
/// first sector in bits 0..12, last sector in bits 13..25, the six permission
/// bits above that.
fn first_sector(location: u32) -> u32 {
    location & 0x1fff
}
fn last_sector(location: u32) -> u32 {
    (location >> 13) & 0x1fff
}

/// The UF2 family ID of every firmware in this repository — what
/// `elf2flash convert -b rp2350` stamps into each block, and what the
/// partitions in `partimg`'s table declare they accept.
const FAMILY_RP2350_ARM_S: u32 = 0xe48b_ff59;

/// Scratch for the two ROM calls that have to parse the partition table before
/// they can answer. 4 KiB, 4 KiB-aligned, same as `explicit_buy` wanted in
/// exp143 — these calls read rather than write, but the requirement is the
/// ROM's, not ours.
#[repr(C, align(4096))]
struct Workarea([u8; 4096]);
static mut WORKAREA: Workarea = Workarea([0; 4096]);

fn workarea() -> *mut u8 {
    core::ptr::addr_of_mut!(WORKAREA) as *mut u8
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

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

/// The two questions this experiment exists to ask, and one to place them.
#[embassy_executor::task]
async fn interrogate_task() -> ! {
    Timer::after(SETTLE).await;

    log!("I am version {}.{}. I do not know which half I am in.", VERSION_MAJOR, VERSION_MINOR);

    // ---- What does the table say? -----------------------------------------
    //
    // With LOCATION_AND_FLAGS the ROM returns each partition's own location
    // word after the summary, which is how the answer below gets a name.
    let mut buf = [0u32; 16];
    let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), PT_INFO) };
    let count = if n > 1 { buf[1] & 0xff } else { 0 };
    log!("get_partition_table_info(PT_INFO) -> {} words, {} partitions", n, count);

    // Each partition's own location word, asked for one at a time. These are
    // the words the answer below is matched against, so the ROM names the
    // partition rather than this firmware assuming partimg's layout.
    let mut located = [0u32; 4];
    for i in 0..count.min(located.len() as u32) {
        let flags = PT_SINGLE_PARTITION | PT_LOCATION_AND_FLAGS | (i << 24);
        let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), flags) };
        if n >= 3 {
            located[i as usize] = buf[1];
            log!(
                "  partition {}: sectors {}..{}, flags {:#010x}",
                i,
                first_sector(buf[1]),
                last_sector(buf[1]),
                buf[2]
            );
        } else {
            log!("  partition {}: no location returned (rc {})", i, n);
        }
    }

    // ---- Where would a dropped file go? -----------------------------------
    //
    // The prediction, made before anything is dropped. The ROM answers it from
    // the partition table alone: which partition accepts this UF2 family, and —
    // for an A/B pair whose halves accept the same family — which half is not
    // the one running.
    //
    // The out parameter is a `resident_partition_t`: **two** words, location
    // and flags, not a partition index. Reading it as one word (the first
    // version of this experiment did) gets a number like 0xfc020001 that looks
    // like nonsense and is in fact the location: sectors 1..16, all six
    // permissions.
    let mut target = [0u32; 2];
    let rc = unsafe {
        rom_data::get_uf2_target_partition(
            workarea(),
            4096,
            FAMILY_RP2350_ARM_S,
            target.as_mut_ptr(),
        )
    };
    log!("get_uf2_target_partition(rp2350-arm-s) -> rc {}", rc);
    let mut target_index: i32 = -1;
    if rc >= 0 {
        for (i, w) in located.iter().take(count as usize).enumerate() {
            if *w == target[0] {
                target_index = i as i32;
            }
        }
        log!(
            "  location {:#010x} = partition {}, sectors {}..{}",
            target[0],
            target_index,
            first_sector(target[0]),
            last_sector(target[0])
        );
    } else {
        log!("  negative: the ROM will not route this family into a partition");
    }

    // ---- Where is the newest image now? -----------------------------------
    //
    // The outcome, after one has been dropped. `pick_ab_parition` returns the
    // half of the pair with the better IMAGE_DEF — which, with the versions
    // this experiment uses, is the half the newest file landed in. This image
    // cannot see its own partition; it can ask which one the ROM prefers, and
    // since this image *is* the one running, the answer names its own half.
    let pick = unsafe { rom_data::pick_ab_parition(workarea(), 4096, 0) };
    log!("pick_ab_parition(0) -> {} (the half holding the better image)", pick);
    if pick == target_index {
        log!("  WARNING: the next drop would overwrite the half that is running");
    } else {
        log!("  running {}, next drop goes to {} — the other half", pick, target_index);
    }

    // The repeating line carries the whole answer, because the lines above are
    // said once and the log queue is sixteen deep: a reader who arrives late
    // still learns which half is running and where the next drop lands.
    loop {
        Timer::after(IDLE_REPORT).await;
        log!(
            "idle: v{}.{}, running partition {}, next drop -> partition {}",
            VERSION_MAJOR,
            VERSION_MINOR,
            pick,
            target_index
        );
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
    // The version, in the descriptor, from build.rs. After a drop, `yi26 port`
    // says which version came up without anything having to open the log — and
    // the version is the only thing that distinguishes the file that was just
    // dropped from the one that was already there.
    config.product = Some(concat!("exp144 v", env!("EXP144_VERSION")));
    config.serial_number = Some("144");
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

    log!("exp144 up. version {}.{}.", VERSION_MAJOR, VERSION_MINOR);
}
