//! exp112 — the fallback that every test passes.
//!
//! This firmware wants to use the hardware TRNG. It says so in `Cargo.toml`,
//! where `hardware-rng` is a default feature, and it says so in the code,
//! where a `cfg` picks the TRNG when that feature is on.
//!
//! Build it the other way and it uses a software generator instead. Not an
//! error, not a warning, not a panic — a different function, chosen at compile
//! time, doing what looks like the same job.
//!
//! The point of the experiment is everything that then **fails to notice**:
//!
//! - The bytes look random. They are printed here so you can check.
//! - exp111's two statistical tests pass. Both of them, comfortably.
//! - The firmware runs, enumerates, logs and behaves identically.
//!
//! One thing does notice, and it is not a test of the output: the build stamps
//! a marker into the binary saying which generator is actually compiled in,
//! and `experiments/audit.sh` reads it out of the `.uf2`. Source code says
//! what a build *would* do. The artifact says what it *is*.
//!
//! There is a second tell, and it costs nothing: **reboot the board**. A
//! software generator seeded from a constant produces the same first bytes
//! every time. Watch for it.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{TRNG, USB};
use embassy_rp::trng::{Config as TrngConfig, InterruptHandler as TrngInterruptHandler, Trng};
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
    TRNG_IRQ => TrngInterruptHandler<TRNG>;
});

/// What the binary says about itself.
///
/// The same trick `crates/usb-reboot` uses, and for the same reason: a
/// firmware built with a feature off differs from one built with it on only by
/// code that is no longer there, and `Cargo.toml` describes the *default*
/// build rather than the flags somebody actually used. So the answer travels
/// inside the artifact, where `strings` — and `audit.sh` — can find it.
///
/// `#[used]` and an explicit section stop the linker discarding it: nothing in
/// the program ever reads this string.
#[used]
#[unsafe(link_section = ".rodata.yi26_rng_marker")]
pub static RNG_MARKER: [u8; 21] = *if cfg!(feature = "hardware-rng") {
    b"yi26-cfg:rng=hardware"
} else {
    b"yi26-cfg:rng=software"
};

const TRNG_SAMPLE_COUNT: u32 = 1000;
const BITS_PER_ROUND: u32 = 64;
const BYTES_PER_ROUND: usize = (BITS_PER_ROUND / 8) as usize;

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

/// The stand-in: xorshift32, a well-known software generator.
///
/// Chosen deliberately over something obviously broken. xorshift32 is *good*
/// at looking random — it sails through both of exp111's tests and through
/// most of what a casual check would throw at it. A generator that failed
/// those tests would make this experiment easy and useless.
///
/// It is also completely deterministic. The seed below is a constant, so this
/// produces the identical sequence on every boot of every board, forever.
/// That is the property worth carrying away: predictable and random-looking
/// are not opposites.
struct SoftwareRng {
    state: u32,
}

// In the intended build these methods are never called, and the compiler says
// so. That warning is worth reading rather than silencing thoughtlessly: the
// fallback path is still *here*, in the source, one build flag away from being
// the one that runs. Deleting a fallback is a stronger fix than trusting the
// flag that selects it — but this experiment needs both paths to exist, which
// is exactly the situation being demonstrated.
#[allow(dead_code)]
impl SoftwareRng {
    const fn new() -> Self {
        // Any non-zero constant. The point is that it is a constant.
        Self { state: 0x2350_1209 }
    }

    fn next_u32(&mut self) -> u32 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.state = x;
        x
    }

    fn fill(&mut self, out: &mut [u8]) {
        for chunk in out.chunks_mut(4) {
            let v = self.next_u32().to_ne_bytes();
            chunk.copy_from_slice(&v[..chunk.len()]);
        }
    }
}

fn count_ones(bytes: &[u8]) -> u32 {
    bytes.iter().map(|b| b.count_ones()).sum()
}

fn count_transitions(bytes: &[u8], prev: &mut Option<bool>) -> u32 {
    let mut changes = 0;
    for byte in bytes {
        for i in 0..8 {
            let bit = (byte >> i) & 1 == 1;
            if let Some(p) = *prev {
                if p != bit {
                    changes += 1;
                }
            }
            *prev = Some(bit);
        }
    }
    changes
}

/// Produces bytes from whichever generator the build selected, and scores them
/// with exp111's tests so you can watch the tests fail to help.
#[embassy_executor::task]
async fn rng_task(mut trng: Trng<'static, TRNG>) -> ! {
    // Constructed in both builds, and that is the experiment rather than an
    // oversight. A fallback that is only compiled in when it is used is a
    // fallback somebody would notice; this one is present either way, and only
    // a `cfg` decides which generator the bytes come from. The `allow` says so
    // out loud instead of leaving a compiler warning to be ignored — a warning
    // nobody acts on is how a real one gets missed.
    #[cfg_attr(feature = "hardware-rng", allow(unused_mut, unused_variables))]
    let mut software = SoftwareRng::new();
    let mut ones: u32 = 0;
    let mut changes: u32 = 0;
    let mut prev: Option<bool> = None;
    let mut bits_total: u32 = 0;
    let mut round: u32 = 0;

    loop {
        round += 1;
        let mut bytes = [0u8; BYTES_PER_ROUND];

        // The whole difference between a firmware that is fine and one that is
        // catastrophically broken, and it is a `cfg`.
        #[cfg(feature = "hardware-rng")]
        trng.fill_bytes(&mut bytes).await;

        #[cfg(not(feature = "hardware-rng"))]
        {
            let _ = &mut trng;
            software.fill(&mut bytes);
        }

        if round <= 3 {
            log!(
                "bytes #{}: {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x} {:02x}",
                round,
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7]
            );
        }
        if round == 3 {
            log!("Reboot the board and compare those three lines. That is the tell.");
        }

        ones += count_ones(&bytes);
        changes += count_transitions(&bytes, &mut prev);
        bits_total += BITS_PER_ROUND;

        if round % 5 == 0 {
            let pct = |n: u32, d: u32| {
                let pm = n * 1000 / d;
                (pm / 10, pm % 10)
            };
            let (o1, o2) = pct(ones, bits_total);
            let (c1, c2) = pct(changes, bits_total);

            // The generator's name repeats on every scored line, not just in
            // the boot banner. Anyone who attaches a terminal after boot —
            // which is most people, most of the time — would otherwise be
            // reading numbers with no idea which build produced them, and
            // "PASS" means opposite things depending on the answer.
            let source = if cfg!(feature = "hardware-rng") {
                "hardware"
            } else {
                "software"
            };
            log!(
                "[{}] tests after {} bits: ones {}.{}%  changes {}.{}%  (fair coin 50.0%) -> PASS either way",
                source, bits_total, o1, o2, c1, c2
            );
        }

        Timer::after(Duration::from_millis(500)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp112 silent fallback");
    config.serial_number = Some("112");
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

    // The banner is honest, and it is also the least reliable thing here.
    // A log line proves what this build prints, not what it does — if the
    // `cfg` above and this line ever disagree, nothing catches it. The marker
    // in the binary is the one that cannot drift, because the linker puts it
    // there from the same `cfg!` the code uses.
    #[cfg(feature = "hardware-rng")]
    log!("exp112 up. Generator: HARDWARE TRNG (this is the intended build).");
    #[cfg(not(feature = "hardware-rng"))]
    log!("exp112 up. Generator: SOFTWARE xorshift32 (the feature is missing).");

    let mut trng_config = TrngConfig::default();
    trng_config.sample_count = TRNG_SAMPLE_COUNT;
    let trng = Trng::new(p.TRNG, Irqs, trng_config);
    spawner.spawn(rng_task(trng).unwrap());

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
