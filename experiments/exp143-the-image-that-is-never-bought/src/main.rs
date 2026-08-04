#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::block::{
    item_generic_2bs, item_image_type_exe, Architecture, Block, Security, IMAGE_TYPE_TBYB,
    ITEM_1BS_VERSION,
};
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

// SLOT ("A"/"B"), VERSION_MAJOR, VERSION_MINOR, TBYB, BUY — set by build.rs
// from the EXP143_* environment variables. Same source, four declarations.
include!(concat!(env!("OUT_DIR"), "/exp143_config.rs"));

/// The one bit that makes an image provisional, in the position the IMAGE_TYPE
/// item puts its value: `item_generic_1bs` shifts the 16-bit value up by 16.
const TBYB_BIT: u32 = if TBYB { (IMAGE_TYPE_TBYB as u32) << 16 } else { 0 };

/// This image's own IMAGE_DEF, at the start of its partition.
///
/// Three items' worth of words: the image type — with the **TBYB** bit set in
/// the B build, which is the whole experiment — and a VERSION the ROM compares
/// across the A/B pair. embassy-rp's default IMAGE_DEF is off (`imagedef-none`)
/// so this is the block the ROM reads.
///
/// `explicit_buy` **rewrites this block in flash** to clear the TBYB bit. That
/// is why the image type word is read back below through a volatile read rather
/// than trusted as a compile-time constant: after a buy, the bytes on the chip
/// and the bytes in the source no longer agree, and the chip is the truth.
#[link_section = ".start_block"]
#[used]
static IMAGE_DEF: Block<3> = Block::new([
    item_image_type_exe(Security::Secure, Architecture::Arm) | TBYB_BIT,
    item_generic_2bs(0, 2, ITEM_1BS_VERSION),
    ((VERSION_MAJOR as u32) << 16) | VERSION_MINOR as u32,
]);

bind_interrupts!(struct Irqs {
    USBCTRL_IRQ => InterruptHandler<USB>;
});

const PACKET: usize = 64;

/// How long to wait before saying anything the reader must not miss. The log
/// queue holds lines written before the host opens the port, but only sixteen
/// of them (exp134 measured what that costs).
const SETTLE: Duration = Duration::from_secs(3);

/// How long slot A stays up before it asks the ROM to try slot B. It is also
/// the window in which `yi26 bootsel` can land, so it is generous on purpose:
/// a board that tried a new image every second would be a board you could not
/// reflash.
const TRY_AFTER: Duration = Duration::from_secs(15);

/// How long a provisional image talks before it decides. Measured on hardware:
/// the ROM arms the trial clock at 16.775 s of its 16.777 s maximum, so there
/// is room for USB to enumerate (about a second) and for a reader to see this
/// happen — nothing here has to race the watchdog or feed it.
const TRIAL_TALK: Duration = Duration::from_secs(6);

/// After a buy: how long before the image resets itself, once, to show that a
/// plain reset now boots the slot that was provisional a minute ago. Nothing
/// else in this repository can reset a board without a hand or a reflash.
const PROVE_AFTER: Duration = Duration::from_secs(10);

const IDLE_REPORT: Duration = Duration::from_secs(5);

const BLINK_ON: Duration = Duration::from_millis(50);
const BLINK_OFF: Duration = Duration::from_millis(950);

/// `reboot` flags, §5.5.8.5. `FLASH_UPDATE` is the only path that launches a
/// provisional image: on a normal boot an unbought TBYB image is not the
/// current image, and the ROM boots the other slot instead.
const REBOOT_NORMAL: u32 = 0x0;
const REBOOT_FLASH_UPDATE: u32 = 0x4;
const REBOOT_NO_RETURN: u32 = 0x100;

/// Where `partimg ab` puts image B: sector 17, as an XIP address and as a raw
/// flash offset. `reboot(FLASH_UPDATE)` takes an `update_base`, and which of
/// the two it wants is the thing this experiment finds out — so A tries the
/// XIP address first and the storage offset second, and prints what came back.
const B_BASE_XIP: u32 = 0x1001_1000;
const B_BASE_STORAGE: u32 = 0x0001_1000;

/// `PT_INFO`, from `get_partition_table_info` (§5.5.11.2).
const PT_INFO: u32 = 0x0001;

/// Set when the host sends anything at all — the brake. Slot A checks it
/// before starting a trial, so `yi26 send hold` parks a board that would
/// otherwise spend its life handing itself to an image that never buys.
static HOLD: AtomicBool = AtomicBool::new(false);

/// Scratch space for `explicit_buy`: it rewrites a flash sector to clear the
/// TBYB bit, and the sector it is rewriting is the one this code was booted
/// from, so the ROM needs somewhere in RAM to hold it. 4 KiB, 4 KiB-aligned,
/// as §5.5.12.3 requires.
#[repr(C, align(4096))]
struct Scratch([u8; 4096]);
static mut BUY_SCRATCH: Scratch = Scratch([0; 4096]);

/// The watchdog block, by hand (§12.9). `embassy-rp` keeps its PAC private and
/// its own `Watchdog` driver only starts and feeds one — this experiment needs
/// to *read* a watchdog somebody else armed, without disturbing it, so the four
/// registers are named here and touched with volatile accesses.
mod watchdog_regs {
    pub const BASE: usize = 0x400d_8000;
    /// CTRL: TIME in bits 23:0 (microseconds), ENABLE at bit 30.
    pub const CTRL: usize = BASE;
    /// LOAD: write to reload the countdown. Max 0xffffff — about 16 seconds.
    pub const LOAD: usize = BASE + 0x04;
    /// REASON: bit 0 TIMER — the last reset was a watchdog timeout.
    pub const REASON: usize = BASE + 0x08;

    pub const CTRL_TIME_MASK: u32 = 0x00ff_ffff;
    pub const CTRL_ENABLE: u32 = 1 << 30;
    pub const REASON_TIMER: u32 = 1 << 0;

    pub fn read(addr: usize) -> u32 {
        unsafe { core::ptr::read_volatile(addr as *const u32) }
    }
    pub fn write(addr: usize, value: u32) {
        unsafe { core::ptr::write_volatile(addr as *mut u32, value) }
    }
}

/// The watchdog exactly as the boot ROM left it, read before anything else
/// runs. If the ROM arms a trial clock for a provisional image, this is where
/// it shows: `enable` set, and `time` counting down.
#[derive(Clone, Copy)]
struct Watchdog {
    enabled: bool,
    /// CTRL.TIME — what is left of the countdown, in microseconds.
    time_us: u32,
    /// LOAD — what the countdown is reloaded to.
    load_us: u32,
    /// REASON.TIMER — was the reset that started this boot a watchdog timeout?
    last_reset_was_timeout: bool,
}

impl Watchdog {
    /// Read it, do not touch it. Called first thing in `main`, before
    /// `embassy_rp::init`, so nothing of ours can be blamed for the numbers.
    fn capture() -> Self {
        use watchdog_regs as wr;
        let ctrl = wr::read(wr::CTRL);
        Self {
            enabled: ctrl & wr::CTRL_ENABLE != 0,
            time_us: ctrl & wr::CTRL_TIME_MASK,
            load_us: wr::read(wr::LOAD) & wr::CTRL_TIME_MASK,
            last_reset_was_timeout: wr::read(wr::REASON) & wr::REASON_TIMER != 0,
        }
    }

    /// Stop it. Only ever called after a buy has been confirmed in flash — a
    /// bought image that let the trial clock run out would be reset for winning.
    fn disable() {
        use watchdog_regs as wr;
        wr::write(wr::CTRL, wr::read(wr::CTRL) & !wr::CTRL_ENABLE);
    }
}

/// This image's IMAGE_TYPE word **as it is in flash right now**.
///
/// `Block` is `#[repr(C)]`: the start marker, then the items. So the first item
/// — the image type — is one word in. Volatile, because the point is to see a
/// change the compiler has no way to know about.
fn image_type_in_flash() -> u32 {
    let p = core::ptr::addr_of!(IMAGE_DEF) as *const u32;
    unsafe { core::ptr::read_volatile(p.add(1)) }
}

fn is_provisional(image_type_word: u32) -> bool {
    (image_type_word >> 16) as u16 & IMAGE_TYPE_TBYB != 0
}

#[embassy_executor::task]
async fn usb_task(mut device: UsbDevice<'static, Driver<'static, USB>>) -> ! {
    device.run().await
}

#[embassy_executor::task]
async fn log_task(sender: Sender<'static, usb_reboot::UsbDriver>) -> ! {
    usb_log::run(sender).await
}

/// The 1200-baud watcher, so the next flash needs no button — and the brake:
/// any byte from the host sets HOLD.
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
            // Only a packet with bytes in it. A zero-length read arrives on its
            // own at enumeration, and the first version of this counted it —
            // the board held itself before the host had said anything at all.
            Either::Second(Ok(n)) if n > 0 => {
                HOLD.store(true, Ordering::Relaxed);
                log!("held: {} bytes arrived from the host. No trial will be started.", n);
            }
            Either::Second(_) => {}
        }
    }
}

/// Print the state the ROM handed this boot: how it got here, and whether a
/// trial clock is running.
fn report_boot(wd: Watchdog, image_type: u32) {
    // Two lines, not one: usb_log cuts at 96 bytes and marks the cut with `...`,
    // and a truncated hex word is not evidence of anything.
    log!("I am slot {}, version {}.{}.", SLOT, VERSION_MAJOR, VERSION_MINOR);
    log!(
        "IMAGE_TYPE in flash = {:#010x} — TBYB {}",
        image_type,
        if is_provisional(image_type) { "set (provisional)" } else { "clear (permanent)" }
    );
    log!(
        "watchdog as the ROM left it: enable={}, time={} us, load={} us",
        wd.enabled,
        wd.time_us,
        wd.load_us
    );
    // REASON.TIMER, said plainly and not over-read. Measured on hardware: it is
    // set after an ordinary `pflash` too, because the ROM's own reboot path goes
    // through the watchdog. So this bit says "a watchdog reset started this
    // boot", and never "a trial ran out" — the two are not distinguishable here.
    log!(
        "WATCHDOG.REASON.TIMER = {} (a watchdog reset started this boot; the ROM's",
        wd.last_reset_was_timeout as u8
    );
    log!("  own reboot uses the watchdog too, so this alone proves nothing about a trial)");
}

/// Slot A: the image that is already bought. It says where it stands, then
/// hands the board to the provisional image on purpose.
#[embassy_executor::task]
async fn permanent_task(wd: Watchdog) -> ! {
    Timer::after(SETTLE).await;
    report_boot(wd, image_type_in_flash());

    let mut buf = [0u32; 16];
    let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), PT_INFO) };
    log!("get_partition_table_info(PT_INFO) -> {}", n);
    let b = unsafe { rom_data::get_b_partition(0) };
    log!("get_b_partition(0) -> {} (1 = there is a B side to try)", b);

    if !TBYB {
        log!(
            "trying the other slot in {} s — send anything (yi26 send hold) to stop it",
            TRY_AFTER.as_secs() - SETTLE.as_secs()
        );
        Timer::after(TRY_AFTER - SETTLE).await;

        if HOLD.load(Ordering::Relaxed) {
            log!("held. Not starting a trial; the board stays on slot {}.", SLOT);
        } else {
            // A flash update boot is the only way in: on a normal boot the ROM
            // will not run an unbought TBYB image. If this call works, nothing
            // below it ever runs.
            log!("reboot(FLASH_UPDATE, update_base={:#010x}) — see you on the other side", B_BASE_XIP);
            let rc = rom_data::reboot(
                REBOOT_FLASH_UPDATE | REBOOT_NO_RETURN,
                50,
                B_BASE_XIP,
                0,
            );
            log!("it came back: rc={} — the XIP address is not what update_base means", rc);

            log!("reboot(FLASH_UPDATE, update_base={:#010x}) — trying the storage offset", B_BASE_STORAGE);
            let rc = rom_data::reboot(
                REBOOT_FLASH_UPDATE | REBOOT_NO_RETURN,
                50,
                B_BASE_STORAGE,
                0,
            );
            log!("it came back too: rc={}. No trial was started.", rc);
        }
    }

    loop {
        Timer::after(IDLE_REPORT).await;
        let w = image_type_in_flash();
        log!(
            "idle: slot {} v{}.{} — IMAGE_TYPE {:#010x}, TBYB {}",
            SLOT,
            VERSION_MAJOR,
            VERSION_MINOR,
            w,
            if is_provisional(w) { "set" } else { "clear" }
        );
    }
}

/// Slot B: the provisional image. It is here on trial, and the whole question
/// is whether it calls `explicit_buy` before the ROM's clock runs out.
#[embassy_executor::task]
async fn provisional_task(wd: Watchdog) -> ! {
    Timer::after(SETTLE).await;
    let before = image_type_in_flash();
    report_boot(wd, before);

    if !is_provisional(before) {
        log!("nothing to buy: the TBYB bit is already clear, so this image was");
        log!("bought in an earlier boot and the ROM started it the ordinary way.");
        log!("A bought image is just an image.");
    } else {
        log!("this is a trial boot, and the clock above is the trial. Deciding in {} s.", TRIAL_TALK.as_secs());
        Timer::after(TRIAL_TALK).await;

        // A second sample. One reading of CTRL.TIME is a number; two readings
        // that differ are a clock, and a clock is what makes this a trial.
        let now = Watchdog::capture();
        log!(
            "watchdog now: enable={}, time={} us ({} us gone since boot)",
            now.enabled,
            now.time_us,
            wd.time_us.saturating_sub(now.time_us)
        );

        if BUY {
            log!("calling explicit_buy — it rewrites the sector I am running from");
            // Interrupts off: the ROM erases and reprograms flash under XIP, and
            // an interrupt handler fetched from that flash while it is erased is
            // the classic way to lose the board. The cost of getting this wrong
            // is a crash, which is a trial that ends without a buy — the safe
            // side of this experiment.
            let rc = cortex_m::interrupt::free(|_| unsafe {
                rom_data::explicit_buy(core::ptr::addr_of_mut!(BUY_SCRATCH) as *mut u8, 4096)
            });
            unsafe { rom_data::flash_flush_cache() };
            let after = image_type_in_flash();
            log!("explicit_buy -> {}", rc);
            log!(
                "IMAGE_TYPE in flash is now {:#010x} — TBYB {}",
                after,
                if is_provisional(after) { "STILL SET (not bought)" } else { "CLEARED (bought)" }
            );
            let post = Watchdog::capture();
            log!("watchdog after the buy: enable={}, time={} us", post.enabled, post.time_us);
            if !is_provisional(after) {
                // Bought. If the ROM left its trial clock running, stop it, or
                // this image gets reset for winning.
                if post.enabled && post.time_us > 0 {
                    Watchdog::disable();
                    log!("trial clock was still running after the buy — stopped it");
                }
                log!("bought. This slot is now the one a plain reset boots — and here is");
                log!("the proof, in {} s: a plain reset, and see who comes back.", PROVE_AFTER.as_secs());
                Timer::after(PROVE_AFTER).await;
                // Exactly once: the next boot finds TBYB clear and takes the
                // "nothing to buy" branch, so it does not reset again.
                rom_data::reboot(REBOOT_NORMAL | REBOOT_NO_RETURN, 50, 0, 0);
            }
        } else {
            log!("not buying. Nothing is wrong with me — I simply never call it.");
            log!("From here the ROM takes the board back to the other slot.");
            if !now.enabled || now.time_us == 0 {
                // No trial clock is running, so nothing will end this boot.
                // End it honestly: a plain reset, with the buy never made.
                log!("no trial clock is running, so: reboot(NORMAL), unbought.");
                Timer::after(Duration::from_secs(2)).await;
                rom_data::reboot(REBOOT_NORMAL | REBOOT_NO_RETURN, 50, 0, 0);
            }
        }
    }

    // The repeating line carries the state, read from flash each time. The lines
    // said at boot are gone within a minute — usb_log's queue is sixteen deep —
    // so a reader who arrives late, or a check.sh that runs against a board that
    // has been up for an hour, has to be able to learn this from a line that
    // keeps coming. And it is read from flash, not from the build flag, for the
    // same reason as the product string.
    loop {
        Timer::after(IDLE_REPORT).await;
        let w = image_type_in_flash();
        log!(
            "idle: slot {} v{}.{} — IMAGE_TYPE {:#010x}, TBYB {}",
            SLOT,
            VERSION_MAJOR,
            VERSION_MINOR,
            w,
            if is_provisional(w) { "set (unbought)" } else { "clear (bought)" }
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
    // First, before anything of ours can disturb it: what did the ROM leave in
    // the watchdog?
    let wd = Watchdog::capture();

    let p = embassy_rp::init(Default::default());
    let led = Output::new(p.PIN_25, Level::Low);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    // The slot is in the product string, so which image is running is visible
    // from `yi26 port` alone — the log needs an open port, and a trial image
    // may not be there long enough to wait for one.
    //
    // "provisional" comes from the **flash**, not from the build flag: after a
    // buy the same binary is no longer provisional, and a descriptor that still
    // said so would be the one place in this experiment that lied.
    config.product = Some(match (SLOT, is_provisional(image_type_in_flash())) {
        ("A", _) => "exp143 slot A",
        ("B", true) => "exp143 slot B provisional",
        _ => "exp143 slot B bought",
    });
    config.serial_number = Some("143");
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
    if TBYB {
        spawner.spawn(provisional_task(wd).unwrap());
    } else {
        spawner.spawn(permanent_task(wd).unwrap());
    }
    spawner.spawn(blink_task(led).unwrap());

    log!(
        "exp143 up. slot {} v{}.{}, {}.",
        SLOT,
        VERSION_MAJOR,
        VERSION_MINOR,
        // From flash again, for the same reason as the product string above.
        if is_provisional(image_type_in_flash()) { "provisional (TBYB)" } else { "permanent" }
    );
}
