// SPDX-License-Identifier: Apache-2.0
//! # exp165 — who gets the last word
//!
//! [exp164] read the SAU and found it **enabled, with one of its eight regions
//! in use**: region 7, `0x46a0..0x7fff`, the upper bootrom, marked Non-secure
//! by something that ran before this firmware did. It also found that every one
//! of eighteen addresses — flash, every SRAM bank, the peripherals, the System
//! Control Space — comes back **Secure and not Non-secure-readable**, and it
//! left one question open on purpose:
//!
//! > `0x00005000` sits *inside* region 7, which is enabled and marks its range
//! > Non-secure, and `TT` reports that address **Secure**, attributed to **no
//! > SAU region at all**.
//!
//! exp164 could not settle that, because settling it needs the Armv8-M
//! Architecture Reference Manual and it had no copy. It printed `OPEN:` rather
//! than deriving a rule it could not check, which is the only honest thing to
//! do with a question — and it is not the only way to make progress on one.
//!
//! ## What this experiment is
//!
//! `cortex-m`'s own documentation for `sau_region()` lists **four** different
//! reasons the instruction returns no region number, and exp164's finding is
//! consistent with all of them:
//!
//! ```text
//! /// Returns None if:
//! ///   * SAU_CTRL.ENABLE is set to zero
//! ///   * the SREGION field does not match any enabled SAU regions
//! ///   * the address matches multiple enabled SAU regions
//! ///   * the address is exempt from the secure memory attribution
//! ///   * TT was executed from the Non-secure state
//! ```
//!
//! So "the IDAU overrules the SAU in the bootrom" is a *hypothesis*, not a
//! reading, and this repository has never read the IDAU at all.
//!
//! **This experiment writes the first SAU region this repository has ever
//! written, and uses it as an instrument.** Put a Non-secure region over memory
//! whose attribution nothing has any reason to override, and ask `TT` again:
//!
//! - if `TT` reports the range **Non-secure and names the region**, then the
//!   SAU's word is both honoured and reported — and region 7's silence is about
//!   *that address*, not about the reporting path. Something else decides
//!   there, and it is the first evidence of it this road has.
//! - if `TT` reports it Non-secure but still names **no region**, then the
//!   reporting path is what is silent, and region 7 is not special at all.
//! - if `TT` does not move, then something overrules the SAU even in ordinary
//!   SRAM, which would be the largest finding of the three.
//!
//! **All three are reachable and none is written down as the expected one.**
//! That is exp162's lesson — an expected outcome in a matrix is an answer the
//! run cannot contradict — and exp164 needed it twice.
//!
//! ## What it deliberately does not do
//!
//! It never executes anything, never enters Non-secure state, and never makes
//! an access that is meant to be refused. **It can therefore show the SAU
//! *saying* something and never show the SAU *refusing* anything**, and that
//! limit is stated here rather than discovered by a reader.
//!
//! exp156's sentence, turned around and pointed at this firmware: *a boundary
//! you did not build is not a boundary you measured.* An attribution nothing
//! tries to violate is an attribution that has been read, not tested. Getting a
//! refusal needs Non-secure code, which needs a Non-secure-Callable region, a
//! hand-written `SG` veneer, banked stack pointers and a second vector table —
//! a subsystem rather than an experiment, and not this one.
//!
//! ## Why there is no [`breadcrumb`] here, when exp164 had one
//!
//! Six of the seven experiments before this one run one candidate per boot,
//! because their candidates can kill a boot: a demoted core faults, a launch
//! blocks forever, a signature runs the stack 423 KB deep. **Nothing in this
//! firmware can die.** It performs no access through the regions it writes, it
//! executes nothing from them, and the ranges it is willing to write are
//! checked against a list of what this firmware is running out of — twice, once
//! at runtime by [`may_write`] and once by `check.sh` reading the source.
//!
//! So this runs in a single boot, which is also what makes it cheap to iterate
//! on: exp164 cost seven flashes, and [`docs/the-board-is-the-loop.md`] is the
//! arithmetic on why that is the number worth attacking.
//!
//! The candidate being attempted is logged **before** it runs, so a boot that
//! stops still names the thing that stopped it. exp134 is the record of how
//! many ways silence reads.
//!
//! [exp164]: ../../exp164-the-wall-nobody-read/
//! [`docs/the-board-is-the-loop.md`]: ../../../docs/the-board-is-the-loop.md
//! [`breadcrumb`]: ../../../crates/breadcrumb/

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, Ordering};

use cortex_m::cmse::{AccessType, TestTarget};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
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

/// The Security Attribution Unit, in the Secure System Control Space. Raw
/// volatile access rather than `cortex_m::Peripherals::take()`, for exp164's
/// reason: an ownership token is a fight with the HAL over nothing, and the
/// whole repository reaches ACCESSCTRL the same way. `cortex-m`'s
/// `SAU::set_region` would encode `RBAR`/`RLAR` exactly as [`region_write`]
/// does below, and candidate 2 checks that encoding by reading it back.
const SAU: usize = 0xE000_EDD0;
const SAU_CTRL: usize = 0x00;
const SAU_TYPE: usize = 0x04;
const SAU_RNR: usize = 0x08;
const SAU_RBAR: usize = 0x0C;
const SAU_RLAR: usize = 0x10;
const SFSR: usize = 0x14;
const SFAR: usize = 0x18;

/// Not a number this firmware chose; `cortex-m` publishes the same address.
/// Checked on the board before a single word read through it is believed.
fn sau_base_agrees() -> bool {
    SAU == cortex_m::peripheral::SAU::PTR as usize
}

/// Region 7 is the bootrom's and is left exactly as it was found. Region 1 is
/// this firmware's, and it is the only one ever written.
const OURS: u32 = 1;
const BOOTROM_REGION: u32 = 7;

/// Read, never written. Every other experiment on this road writes ACCESSCTRL
/// with the `0xACCE` key in bits 31:16; this one has no key constant at all,
/// and `check.sh` fails if one appears. Candidate 7 is about the bus filter
/// *not* moving, and a firmware that can write it is a worse witness to that.
const BANK9_REG: usize = 9;

const PRODUCT: &str = "exp165 who gets the last word";
const CONTROL_BUF_LEN: usize = 64;
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

/// What a region can be. The encoding is not obvious and is worth naming: the
/// architecture expresses **Secure** as a region descriptor that is *disabled*,
/// so "make this range Secure again" and "switch this region off" are the same
/// write. That is why candidate 5 can undo candidate 3 without a separate path.
#[derive(Copy, Clone, PartialEq, Eq)]
enum Attr {
    Secure,
    NonSecure,
    NonSecureCallable,
}

impl Attr {
    fn bits(self) -> u32 {
        match self {
            Attr::Secure => 0b00,
            Attr::NonSecure => 0b01,
            Attr::NonSecureCallable => 0b11,
        }
    }
}

/// A range this firmware is willing to put a region over, and why it is safe.
struct Probe {
    base: u32,
    limit: u32,
    what: &'static str,
}

/// **The four probes, and the whole safety argument.**
///
/// Marking a range Non-secure is harmless to Secure code that only *reads* it —
/// Secure state may access Non-secure memory, and the reverse is what is
/// forbidden. What is never harmless is marking memory a Secure core is
/// **fetching instructions from**: the architecture forbids that outright, the
/// core takes a SecureFault on the next fetch, and the board goes dark with no
/// log to say why.
///
/// So every range here is one that this firmware neither executes from nor
/// keeps anything in:
///
/// - **bank 9** is the primary probe. exp163 used it as scratch; nothing in
///   this firmware is in it, and unlike banks 0–7 it is not interleaved
///   ([exp162](../../exp162-how-wide-can-a-wall-be/)).
/// - **bank 8** is the same shape. exp164 kept a cross-boot mailbox here; this
///   firmware has no mailbox, because it has one boot.
/// - **the bootrom below region 7** is the interesting one, and it is
///   deliberately *not* region 7's own range: an address matching two enabled
///   regions returns no region number **by definition**, which would confound
///   the reading with the very thing being measured.
/// - **`SIO_NS`** is the Non-secure alias `rp-pac` publishes at `0xd002_0000`.
///   The HAL uses `SIO` at `0xd000_0000`; nothing here touches the alias.
///
/// Each probe is enabled, asked, and switched off again with no `await` in
/// between, so the window in which the map is altered is nanoseconds wide and
/// contains no logging, no USB and no timer work.
const PROBES: [Probe; 4] = [
    Probe { base: 0x2008_1000, limit: 0x2008_1fff, what: "SRAM bank 9" },
    Probe { base: 0x2008_0000, limit: 0x2008_0fff, what: "SRAM bank 8" },
    Probe { base: 0x0000_1000, limit: 0x0000_1fff, what: "bootrom below r7" },
    Probe { base: 0xd002_0000, limit: 0xd002_0fff, what: "SIO_NS alias" },
];

/// Everything this firmware is running out of. A region over any of it is
/// refused at runtime, and `check.sh` fails the build if [`PROBES`] overlaps
/// it — the same fact guarded twice, because the cost of being wrong is a dark
/// board and a walk to a bench.
const FORBIDDEN: [(u32, u32, &str); 4] = [
    (0x1000_0000, 0x1fff_ffff, "XIP flash: the code and the vector table"),
    (0x2000_0000, 0x2007_ffff, "main SRAM: the stack, .data and .bss"),
    (0x5010_0000, 0x5010_ffff, "USB DPRAM: the log's only way out"),
    (0xe000_0000, 0xe00f_ffff, "the System Control Space, including the SAU"),
];

/// The guard. Returns the name of the range that refused, or `None` if the
/// write may proceed. A `Secure` write is a *disable* and is always allowed:
/// refusing to switch a region off would be a guard that can strand the chip in
/// the state it exists to prevent.
fn may_write(base: u32, limit: u32, attr: Attr) -> Option<&'static str> {
    if attr == Attr::Secure {
        return None;
    }
    for (lo, hi, what) in FORBIDDEN.iter() {
        if base <= *hi && limit >= *lo {
            return Some(what);
        }
    }
    None
}

fn sau_read(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((SAU + off) as *const u32) }
}

fn sau_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((SAU + off) as *mut u32, v) }
}

fn sregion() -> u32 {
    sau_read(SAU_TYPE) & 0xff
}

/// CTRL, TYPE, SFSR, SFAR. `SFSR` is the one to watch: exp164 read it as zero,
/// meaning no SecureFault has ever been recorded on this part, and a non-zero
/// value here would mean this firmware caused one.
fn snapshot() -> [u32; 4] {
    [sau_read(SAU_CTRL), sau_read(SAU_TYPE), sau_read(SFSR), sau_read(SFAR)]
}

/// Configure a region, and **only** after the two barriers the architecture
/// requires does the new attribution apply to anything that follows.
///
/// Without `DSB`+`ISB` a `TT` issued immediately afterwards may be answered
/// from the old configuration, and this experiment would report "the SAU's word
/// was not honoured" when what actually happened is that it had not landed yet.
/// That failure would look exactly like the most interesting of the three
/// outcomes, which is the worst kind of bug an experiment can have.
fn region_write(n: u32, base: u32, limit: u32, attr: Attr) -> Result<(), &'static str> {
    if let Some(what) = may_write(base, limit, attr) {
        return Err(what);
    }
    if base & 0x1f != 0 {
        return Err("base is not 32-byte aligned");
    }
    if limit & 0x1f != 0x1f {
        return Err("limit does not end a 32-byte block");
    }
    sau_write(SAU_RNR, n);
    sau_write(SAU_RBAR, base & !0x1f);
    sau_write(SAU_RLAR, (limit & !0x1f) | attr.bits());
    cortex_m::asm::dsb();
    cortex_m::asm::isb();
    Ok(())
}

fn region_read(n: u32) -> (u32, u32) {
    sau_write(SAU_RNR, n);
    (sau_read(SAU_RBAR), sau_read(SAU_RLAR))
}

/// Switch this firmware's region off, whatever it was doing. Called on every
/// path out of every candidate, including the ones that fail.
fn region_off() {
    sau_write(SAU_RNR, OURS);
    sau_write(SAU_RLAR, 0);
    sau_write(SAU_RBAR, 0);
    cortex_m::asm::dsb();
    cortex_m::asm::isb();
}

/// A `TT` answer, kept as the raw response word as well as the decoded fields,
/// because a decode is a claim about a bit layout and exp164 found its own
/// decode disagreeing with the register it came from.
#[derive(Copy, Clone)]
struct Tt {
    raw: u32,
    secure: bool,
    nsr: bool,
    sau: i32,
    idau: i32,
}

fn tt(addr: u32) -> Tt {
    let t = TestTarget::check(addr as *mut u32, AccessType::Current);
    Tt {
        raw: t.as_u32(),
        secure: t.secure(),
        nsr: t.ns_readable(),
        sau: t.sau_region().map(|n| n as i32).unwrap_or(-1),
        idau: t.idau_region().map(|n| n as i32).unwrap_or(-1),
    }
}

fn yn(b: bool) -> &'static str {
    if b {
        "yes"
    } else {
        "no "
    }
}

async fn tt_line(prefix: &str, addr: u32, t: Tt) {
    log!(
        "  {:<22} {:#010x} S={} nsr={} sau={} idau={} raw={:#010x}",
        prefix,
        addr,
        yn(t.secure),
        yn(t.nsr),
        t.sau,
        t.idau,
        t.raw
    );
    Timer::after(Duration::from_millis(PACE_MS)).await;
}

static STOPPED: AtomicBool = AtomicBool::new(false);

#[embassy_executor::task]
async fn heartbeat(mut led: Output<'static>) -> ! {
    loop {
        let (on, off) = if STOPPED.load(Ordering::Relaxed) { (100, 100) } else { (50, 950) };
        led.set_high();
        Timer::after(Duration::from_millis(on)).await;
        led.set_low();
        Timer::after(Duration::from_millis(off)).await;
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

/// Milliseconds between log lines.
///
/// Not a taste decision. `usb-log` queues sixteen lines and drops the rest, and
/// the first run of this experiment lost twenty-three in one go: the drain
/// stopped for about 600 ms in the middle of candidate 1's map and the queue
/// filled behind it. Sixteen lines at this pace is nearly a second of outage
/// absorbed, which covers what was measured with room to spare.
const PACE_MS: u64 = 60;

/// Log a line and give `usb-log` time to drain it.
///
/// `usb-log` queues sixteen lines and drops the rest. exp160 lost the end of
/// its report that way and exp162 lost it a second time, and the first run of
/// **this** experiment lost forty-nine lines in the middle — including the
/// readings the whole thing was written to take. Every line therefore goes
/// through here, and nothing in this firmware calls `log!` directly.
macro_rules! say {
    ($($arg:tt)*) => {{
        log!($($arg)*);
        Timer::after(Duration::from_millis(PACE_MS)).await;
    }};
}

/// The same eighteen addresses exp164 asked about, so that candidate 1 is a
/// regression check across experiments rather than a fresh opinion. If this
/// part no longer answers the way exp164 recorded, every candidate after it is
/// measuring a chip that has moved and nobody would know.
struct Spot {
    addr: u32,
    what: &'static str,
}
const MAP: [Spot; 18] = [
    Spot { addr: 0x0000_0000, what: "bootrom, base" },
    Spot { addr: 0x0000_1000, what: "bootrom, probe range" },
    Spot { addr: 0x0000_4680, what: "bootrom, below r7" },
    Spot { addr: 0x0000_5000, what: "bootrom, inside r7" },
    Spot { addr: 0x0000_8000, what: "bootrom, above r7" },
    Spot { addr: 0x1000_0000, what: "XIP flash" },
    Spot { addr: 0x1100_0000, what: "XIP flash +0x01000000" },
    Spot { addr: 0x2000_0000, what: "SRAM bank 0" },
    Spot { addr: 0x2004_0000, what: "SRAM upper half" },
    Spot { addr: 0x2007_fffc, what: "SRAM top word" },
    Spot { addr: 0x2008_0000, what: "SRAM bank 8" },
    Spot { addr: 0x2008_1000, what: "SRAM bank 9" },
    Spot { addr: 0x3000_0000, what: "SRAM +0x10000000" },
    Spot { addr: 0x4006_0000, what: "ACCESSCTRL" },
    Spot { addr: 0x400b_0000, what: "TIMER0" },
    Spot { addr: 0x5010_0000, what: "USB DPRAM" },
    Spot { addr: 0xd000_0000, what: "SIO" },
    Spot { addr: 0xd002_0000, what: "SIO_NS" },
];

const BANK9: u32 = 0x2008_1000;
const BANK9_LIMIT: u32 = 0x2008_1fff;
/// Where bank 9 sits in [`MAP`], so that the baseline every later candidate is
/// compared against is the one taken in candidate 1, **before this firmware
/// wrote anything**. Asserted at compile time rather than counted by hand.
const BANK9_IDX: usize = 11;
const _: () = assert!(MAP[BANK9_IDX].addr == BANK9, "BANK9_IDX does not point at bank 9");
const CANDIDATES: usize = 8;

/// Seconds between repeats of the final report. The report itself takes about
/// two seconds to print at [`PACE_MS`], so any reader with a window longer than
/// this plus two seconds sees one complete copy.
const REPEAT_GAP_S: u64 = 15;

/// How a candidate came out. `Measured` is not a weaker `AsExpected`: it is the
/// verdict for a candidate written to find something out, where naming an
/// expected answer would be writing down the conclusion. exp164 shipped a
/// candidate that demanded a particular answer, got the opposite, and reported
/// a finding as a failure of the board.
#[derive(Copy, Clone, PartialEq, Eq)]
enum Outcome {
    NotReached,
    AsExpected,
    NotAsExpected,
    Measured,
}

impl Outcome {
    fn word(self) -> &'static str {
        match self {
            Outcome::NotReached => "not reached",
            Outcome::AsExpected => "as expected",
            Outcome::NotAsExpected => "NOT as expected",
            Outcome::Measured => "measured, ungraded",
        }
    }
}

fn candidate_name(n: usize) -> &'static str {
    match n {
        1 => "1 the board still answers as exp164 recorded",
        2 => "2 our region reads back as written, and leaves no trace",
        3 => "3 what TT says once our word is on the map",
        4 => "4 our region moved nothing else",
        5 => "5 switching it off puts the map back",
        6 => "6 the same range, marked Non-secure-Callable",
        7 => "7 our region moved nothing ACCESSCTRL can see",
        8 => "8 four ranges: where is our word honoured",
        _ => "?",
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let before = snapshot();
    let p = embassy_rp::init(Default::default());

    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("165");
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

    Timer::after(Duration::from_secs(3)).await;

    let mut outcome = [Outcome::NotReached; CANDIDATES];
    let mut base_raw = [0u32; MAP.len()];

    say!("exp165 who gets the last word");
    say!("  the first SAU region this repo writes, used to ask who overrules it");
    say!("  nothing here executes, accesses, or enters Non-secure state");

    // ---- candidate 1 -------------------------------------------------------
    say!("candidate {}", candidate_name(1));
    let agrees = sau_base_agrees();
    say!(
        "  SAU at {:#010x}; cortex-m says SAU::PTR={:#010x} - {}",
        SAU,
        cortex_m::peripheral::SAU::PTR as usize,
        if agrees { "same" } else { "DIFFERENT" }
    );
    say!(
        "  CTRL={:#010x} TYPE={:#010x} SFSR={:#010x} SFAR={:#010x}",
        before[0],
        before[1],
        before[2],
        before[3]
    );
    say!("  {} regions, enabled={}, allns={}", sregion(), before[0] & 1 != 0, before[0] & 2 != 0);
    let mut enabled_regions = 0;
    for i in 0..sregion() {
        let (rbar, rlar) = region_read(i);
        if rlar & 1 != 0 {
            enabled_regions += 1;
        }
        say!(
            "  r{} RBAR={:#010x} RLAR={:#010x} -> {:#08x}..{:#08x} en={} nsc={}",
            i,
            rbar,
            rlar,
            rbar & !0x1f,
            (rlar & !0x1f) | 0x1f,
            rlar & 1,
            (rlar >> 1) & 1
        );
    }
    let mut all_secure = true;
    for (i, s) in MAP.iter().enumerate() {
        let t = tt(s.addr);
        base_raw[i] = t.raw;
        if !t.secure || t.nsr || t.raw == 0 {
            all_secure = false;
        }
        tt_line(s.what, s.addr, t).await;
    }
    say!(
        "  all {} Secure and not NS-readable: {}; {} region(s) enabled",
        MAP.len(),
        if all_secure { "yes" } else { "NO" },
        enabled_regions
    );
    // Graded, and the only candidate here that asserts an attribution. This is
    // not an opinion about what the chip should say; it is exp164's recorded
    // reading, re-taken. A `TT` that did not execute answers zero, so an
    // all-zero response fails rather than passing as a confident map of nothing.
    outcome[0] = if agrees && sregion() > 0 && all_secure {
        Outcome::AsExpected
    } else {
        Outcome::NotAsExpected
    };
    say!("candidate 1 -> {}", outcome[0].word());

    // ---- candidate 2 -------------------------------------------------------
    say!("candidate {}", candidate_name(2));
    let wrote = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecure);
    let mut landed = false;
    match wrote {
        Err(why) => say!("  the guard refused the write: {}", why),
        Ok(()) => {
            let (rbar, rlar) = region_read(OURS);
            let base = rbar & !0x1f;
            let limit = (rlar & !0x1f) | 0x1f;
            say!(
                "  r{} RBAR={:#010x} RLAR={:#010x} -> {:#08x}..{:#08x} en={} nsc={}",
                OURS,
                rbar,
                rlar,
                base,
                limit,
                rlar & 1,
                (rlar >> 1) & 1
            );
            say!("  asked for {:#08x}..{:#08x} NonSecure", BANK9, BANK9_LIMIT);
            landed = base == BANK9 && limit == BANK9_LIMIT && rlar & 1 == 1 && (rlar >> 1) & 1 == 0;
        }
    }
    // **The check this experiment's first run paid for.** That run left the
    // region on at the end of this candidate, so every "baseline" measured
    // afterwards was taken through a map this firmware had already changed —
    // and the verdict came out backwards, reporting a wall that was working as
    // a wall that did nothing. Candidate 5's control is what caught it.
    //
    // A candidate that changes the map must hand the map back, and that is now
    // graded rather than assumed.
    region_off();
    let handed_back = tt(BANK9).raw == base_raw[BANK9_IDX];
    say!("  region switched off; map handed back: {}", if handed_back { "yes" } else { "NO" });
    outcome[1] = if landed && handed_back { Outcome::AsExpected } else { Outcome::NotAsExpected };
    say!("candidate 2 -> {}", outcome[1].word());

    // ---- candidate 3 -------------------------------------------------------
    // The heart of the experiment, and deliberately ungraded. The baseline is
    // candidate 1's, taken before this firmware had written anything at all.
    say!("candidate {}", candidate_name(3));
    let b9_before = tt(BANK9);
    let _ = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecure);
    let b9_ns = tt(BANK9);
    region_off();
    tt_line("bank 9, region off", BANK9, b9_before).await;
    tt_line("bank 9, ours NS", BANK9, b9_ns).await;
    let clean = b9_before.raw == base_raw[BANK9_IDX];
    if !clean {
        say!(
            "  WARNING: this baseline {:#010x} != candidate 1's {:#010x}",
            b9_before.raw,
            base_raw[BANK9_IDX]
        );
    }
    let heard = b9_ns.raw != base_raw[BANK9_IDX];
    say!("  the TT answer {} when our region went on", if heard { "MOVED" } else { "did not move" });
    outcome[2] = Outcome::Measured;
    say!("candidate 3 -> {}", outcome[2].word());

    // ---- candidate 4 -------------------------------------------------------
    say!("candidate {}", candidate_name(4));
    let _ = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecure);
    let mut leaked: [u32; MAP.len()] = [0; MAP.len()];
    for (i, s) in MAP.iter().enumerate() {
        let _ = s;
        leaked[i] = tt(MAP[i].addr).raw;
    }
    region_off();
    let mut moved = 0;
    for (i, s) in MAP.iter().enumerate() {
        if s.addr != BANK9 && leaked[i] != base_raw[i] {
            moved += 1;
            say!("  {} {:#010x} moved: {:#010x} -> {:#010x}", s.what, s.addr, base_raw[i], leaked[i]);
        }
    }
    say!("  {} of {} other addresses moved while ours was on", moved, MAP.len() - 1);
    // Graded. A base or limit wrong by one bit could cover the whole of SRAM,
    // and the reading at bank 9 would look exactly the same as a correct one.
    outcome[3] = if moved == 0 { Outcome::AsExpected } else { Outcome::NotAsExpected };
    say!("candidate 4 -> {}", outcome[3].word());

    // ---- candidate 5 -------------------------------------------------------
    // exp156's lesson, which cost that experiment a whole round: it reported a
    // wall it had not built, because the value it wrote was the value already
    // there. Open it before you shut it - and here, shut it again afterwards.
    say!("candidate {}", candidate_name(5));
    let _ = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecure);
    let on = tt(BANK9);
    region_off();
    let off_again = tt(BANK9);
    tt_line("bank 9, ours NS", BANK9, on).await;
    tt_line("bank 9, ours off", BANK9, off_again).await;
    let restored = off_again.raw == base_raw[BANK9_IDX];
    say!("  back to candidate 1's answer: {}", if restored { "yes" } else { "NO" });
    outcome[4] = if restored { Outcome::AsExpected } else { Outcome::NotAsExpected };
    say!("candidate 5 -> {}", outcome[4].word());

    // ---- candidate 6 -------------------------------------------------------
    // The cheapest possible look at what exp156's unkept promise would need. An
    // `SG` veneer has to live in a Non-secure-Callable region, and this chip has
    // none. Whether it *can* have one is a question one register write and a
    // `TT` can ask, with no veneer, no assembly and no nightly toolchain.
    say!("candidate {}", candidate_name(6));
    let _ = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecureCallable);
    let (_, nsc_rlar) = region_read(OURS);
    let b9_nsc = tt(BANK9);
    region_off();
    say!("  RLAR={:#010x} en={} nsc={}", nsc_rlar, nsc_rlar & 1, (nsc_rlar >> 1) & 1);
    tt_line("bank 9, ours NSC", BANK9, b9_nsc).await;
    say!(
        "  NSC vs NS: {} ({:#010x} vs {:#010x})",
        if b9_nsc.raw == b9_ns.raw { "same" } else { "different" },
        b9_nsc.raw,
        b9_ns.raw
    );
    outcome[5] = Outcome::Measured;
    say!("candidate 6 -> {}", outcome[5].word());

    // ---- candidate 7 -------------------------------------------------------
    // exp164's candidate 4 shut a bank in ACCESSCTRL and showed the SAU did not
    // move. This is the same question from the other side, and the pair is what
    // turns "two separate mechanisms" from an assertion into a measurement.
    say!("candidate {}", candidate_name(7));
    let ac_before = embassy_rp::pac::ACCESSCTRL.sram(BANK9_REG).read().0;
    let _ = region_write(OURS, BANK9, BANK9_LIMIT, Attr::NonSecure);
    let ac_during = embassy_rp::pac::ACCESSCTRL.sram(BANK9_REG).read().0;
    region_off();
    let ac_after = embassy_rp::pac::ACCESSCTRL.sram(BANK9_REG).read().0;
    say!(
        "  ACCESSCTRL.SRAM[9] pre={:#010x} ours-NS={:#010x} post={:#010x}",
        ac_before,
        ac_during,
        ac_after
    );
    let ac_still = ac_before == ac_during && ac_during == ac_after;
    say!("  the bus filter {} when the SAU map changed", if ac_still { "held still" } else { "MOVED" });
    outcome[6] = if ac_still { Outcome::AsExpected } else { Outcome::NotAsExpected };
    say!("candidate 7 -> {}", outcome[6].word());

    // ---- candidate 8 -------------------------------------------------------
    // Ungraded, and the reason is the whole experiment: this is the map of
    // where the SAU's word is final, and nobody here knows what it should say.
    say!("candidate {}", candidate_name(8));
    let mut honoured = 0;
    let mut named = 0;
    for pr in PROBES.iter() {
        let baseline = tt(pr.base);
        let wrote = region_write(OURS, pr.base, pr.limit, Attr::NonSecure);
        let with = tt(pr.base);
        region_off();
        let back = tt(pr.base);
        match wrote {
            Err(why) => say!("  {:<17} REFUSED: {}", pr.what, why),
            Ok(()) => {
                if with.raw != baseline.raw {
                    honoured += 1;
                }
                if with.sau == OURS as i32 {
                    named += 1;
                }
                say!(
                    "  {:<17} {:#010x} S {}->{} nsr {} sau={} {} back={}",
                    pr.what,
                    pr.base,
                    yn(baseline.secure),
                    yn(with.secure),
                    yn(with.nsr),
                    with.sau,
                    if with.raw != baseline.raw { "MOVED" } else { "unmoved" },
                    if back.raw == baseline.raw { "ok" } else { "NO" }
                );
            }
        }
    }
    say!("  {} of {} ranges moved; {} named our region", honoured, PROBES.len(), named);
    outcome[7] = Outcome::Measured;
    say!("candidate 8 -> {}", outcome[7].word());

    // ---- the verdict -------------------------------------------------------
    // Every sentence below is selected by a reading. exp164 printed three
    // conclusions as string literals and two of them were wrong; the ones that
    // survived were the ones that counted something.
    region_off();
    let (final_rbar, final_rlar) = region_read(OURS);
    let after = snapshot();
    STOPPED.store(true, Ordering::Relaxed);

    // **The report repeats, and that is not decoration.** This experiment runs
    // once and then has nothing left to do, so a reader who plugs in at second
    // twenty sees an idle board and no way to ask it anything - and so does
    // `check.sh`, whose first version hung waiting for a verdict that had
    // already scrolled past. exp134 is the record of how many ways silence
    // reads; this is one that was avoidable by printing again.
    //
    // Every line below is recomputed from the same stored readings each time
    // round, so a late reader gets the same report as an early one.
    loop {
        say!("exp165 done. Nothing armed; still reflashable.");
        for n in 1..=CANDIDATES {
            say!("  {} - {}", candidate_name(n), outcome[n - 1].word());
        }
        say!(
            "  our region r{} left RBAR={:#010x} RLAR={:#010x} en={}",
            OURS,
            final_rbar,
            final_rlar,
            final_rlar & 1
        );
        say!(
            "  SFSR before={:#010x} after={:#010x} - {}",
            before[2],
            after[2],
            if before[2] == after[2] { "no SecureFault recorded" } else { "A SECUREFAULT WAS RECORDED" }
        );
        say!("  region {} (the bootrom's) was never written here", BOOTROM_REGION);

        // The three readings the verdict below rests on, reprinted with it. A
        // repeated conclusion that leaves its evidence behind in a scrollback
        // nobody has is a conclusion a reader has to take on trust.
        tt_line("bank 9, region off", BANK9, b9_before).await;
        tt_line("bank 9, ours NS", BANK9, b9_ns).await;
        tt_line("bank 9, ours NSC", BANK9, b9_nsc).await;

        say!("VERDICT:");
        if !heard {
            say!("  our NS region changed nothing TT can see, in ordinary SRAM.");
            say!("  something other than the SAU decides attribution on this part.");
        } else if b9_ns.sau == OURS as i32 {
            say!("  the SAU's word is honoured AND reported: TT named region {}.", OURS);
            say!("  so exp164's region 7 reads sau=-1 for a reason belonging to");
            say!("  that address, not to the reporting path. Something else has");
            say!("  the last word in the bootrom, and this is the first sight of it.");
        } else {
            say!("  the SAU's word is honoured but TT named no region ({}).", b9_ns.sau);
            say!("  the reporting path is what is silent, so exp164's region 7 is");
            say!("  not special and the IDAU hypothesis has nothing holding it up.");
        }
        say!(
            "  bank 9: S {}->{}, ns-readable {}->{}",
            yn(b9_before.secure),
            yn(b9_ns.secure),
            yn(b9_before.nsr),
            yn(b9_ns.nsr)
        );
        say!(
            "  NSC is {} from NS in the TT response",
            if b9_nsc.raw == b9_ns.raw { "indistinguishable" } else { "distinguishable" }
        );
        say!("  {} of {} probed ranges honoured our word; {} named ours", honoured, PROBES.len(), named);
        say!("  NOT MEASURED: nothing was refused. This firmware never entered");
        say!("  Non-secure state, so every line above is what the SAU SAYS.");

        Timer::after(Duration::from_secs(REPEAT_GAP_S)).await;
    }
}
