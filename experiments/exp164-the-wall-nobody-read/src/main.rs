// SPDX-License-Identifier: Apache-2.0
//! **exp164 — the wall nobody read.**
//!
//! Six experiments on the [signing road](../README.md#the-signing-road) built a
//! security story on **ACCESSCTRL**, which is Raspberry Pi's own bus filter, and
//! not one of them ever looked at **the SAU**, which is the Cortex-M33's own
//! partitioning of the address space and the thing the Armv8-M architecture
//! actually means by "TrustZone".
//!
//! [exp156](../exp156-a-wall-you-can-measure/) said why, and the reason was
//! good: `embassy-rp` has no SAU support, `rp-pac` models ACCESSCTRL in full,
//! and `ACCESSCTRL.FORCE_CORE_NS` demotes a whole core with no hand-written
//! `SG` veneer. It also promised the veneer to a later experiment. This is not
//! that experiment. This is the one that should have come first.
//!
//! # The question, and why it is load-bearing rather than tidy
//!
//! exp156, exp159, exp160, exp162 and exp163 all depend on core 1 running
//! **Non-secure** — fetching its instructions from flash, running on a stack in
//! SRAM, reading half a megabyte of it. Security attribution on Armv8-M is not
//! ACCESSCTRL's business at all: it comes from the SAU and the IDAU, before the
//! request ever reaches the bus. So **something already attributes this chip's
//! flash and SRAM as Non-secure**, or none of those five experiments could have
//! run — and nobody has ever read what.
//!
//! That is the whole question. It is answered by reading, and by one
//! instruction most people never use.
//!
//! # What was measured before any of this was designed
//!
//! | fact | how | what it changed |
//! |---|---|---|
//! | `cortex-m` **already ships the SAU register block**, `src/peripheral/sau.rs`, `#[cfg(armv8m)]` — and its `build.rs` sets that cfg for `thumbv8m.main-none-eabihf` | read the crate | ← the SAU is reachable **on stable**, from a dependency already in every experiment's lockfile. exp156's "no SAU support" is true of the HAL and not of the architecture crate under it |
//! | `cortex-m` also ships `src/cmse.rs`: `TT`, `TTT`, `TTA`, `TTAT` | read the crate | ← **the instrument.** `TestTarget::check` asks the hardware about an address without accessing it, and reports `secure()`, `ns_readable()`, `idau_region()` and `sau_region()` separately — so the answer says *which unit decided* |
//! | nothing in `embassy-rp` mentions SAU, TrustZone or Non-secure | grepped the HAL | candidate 2 checks it on silicon rather than trusting the grep |
//! | `rp-pac` defines `SIO` at `0xd000_0000` **and `SIO_NS` at `0xd002_0000`** | read the PAC | the RP2350 has explicit Non-secure aliases, so the address map is part of the answer and the map below tests aliases as well as originals |
//! | only `extern "cmse-nonsecure-entry"` needs nightly | tried it | *configuring* the SAU does not. The nightly wall is the veneer, not the unit |
//!
//! # Read-only, and why that is not a survey
//!
//! Nothing here writes the SAU. Enabling it with the wrong regions would change
//! the attribution of the memory this firmware is running out of, and the
//! honest order is to find out what the bootrom left before planning anything
//! on top of it — [exp138](../exp138-what-the-rom-already-knows/)'s order, and
//! [exp154](../exp154-somewhere-to-put-a-key/)'s.
//!
//! A dump with no possible failure would still be worth nothing, so three of
//! the five candidates are things that can come out the other way:
//!
//! - candidate 2 compares the SAU **before and after `embassy_rp::init()`**, so
//!   "the HAL touches nothing" is a measurement and not a grep.
//! - candidate 4 shuts bank 8 to Non-secure and asks `TT` the same question
//!   again. If ACCESSCTRL and the SAU were one mechanism the answer would move.
//! - candidate 5 asks a demoted core what the SAU says, and requires it not to
//!   get the Secure answer.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use cortex_m::cmse::{AccessType, TestTarget};
use cortex_m_rt::{exception, ExceptionFrame};
use embassy_executor::Spawner;
use embassy_rp::bind_interrupts;
use embassy_rp::gpio::{Level, Output};
use embassy_rp::multicore::{spawn_core1, Stack};
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

/// The Security Attribution Unit, in the Secure System Control Space. Reached
/// by raw volatile reads rather than through `cortex_m::Peripherals::take()`,
/// for one reason: candidate 2 needs a snapshot from **before**
/// `embassy_rp::init()` runs, and an ownership token that early is a fight with
/// the HAL over nothing. Same style the whole repository uses for ACCESSCTRL.
const SAU: usize = 0xE000_EDD0;
const SAU_CTRL: usize = 0x00;
const SAU_TYPE: usize = 0x04;
const SAU_RNR: usize = 0x08;
const SAU_RBAR: usize = 0x0C;
const SAU_RLAR: usize = 0x10;
const SFSR: usize = 0x14;
const SFAR: usize = 0x18;
/// Not a number this firmware chose. `cortex-m` publishes the same address as
/// `SAU::PTR`, and candidate 1 compares the two before believing a single word
/// read through it — the difference between "the SAU says CTRL=1" and
/// "something at an address I typed says 1". It cannot be a `const` assert:
/// pointers cannot be cast to integers during const evaluation.
fn sau_base_agrees() -> bool {
    SAU == cortex_m::peripheral::SAU::PTR as usize
}

const NON_SECURE_BITS: u32 = 0b11;
const ACCESSCTRL_KEY: u32 = 0xACCE_0000;
const BANK8_REG: usize = 8;
const BANK8: usize = 0x2008_0000;
/// Bank 8 is 4 KB that survives a watchdog reset — exp159, exp160, exp162 and
/// exp163 all showed that, and this experiment has no key to keep in it. So
/// candidates 5 and 6 leave their readings here and the final report prints
/// both together, instead of asking a reader to scroll back through two boots
/// to compare the two orderings.
const SAUBOX: usize = 0x2008_0000;
const SAUBOX_MAGIC: u32 = 0x5341_5531;

const C_SAU_EXISTS: u8 = 1;
const C_INIT_TOUCHES_NOTHING: u8 = 2;
const C_THE_MAP: u8 = 3;
const C_TWO_WALLS: u8 = 4;
const C_DEMOTED_AFTER: u8 = 5;
const C_DEMOTED_BEFORE: u8 = 6;
const CANDIDATES: u8 = 6;

const STEP_BUDGET_US: u32 = 8_000_000;
const LAST_BOOT: u32 = 10;
const REFLASH_WINDOW_S: u64 = 5;

const CONTROL_BUF_LEN: usize = 64;
const PRODUCT: &str = "exp164 the wall nobody read";
const _: () = assert!(
    2 * PRODUCT.len() + 2 < CONTROL_BUF_LEN,
    "product string will overflow embassy-usb's control buffer and panic mid-enumeration"
);

/// Every address worth asking about, and the aliases that go with them. The
/// aliases are here because `rp-pac` has `SIO` at `0xd000_0000` and `SIO_NS` at
/// `0xd002_0000`, which says the RP2350 publishes Non-secure views of at least
/// some of its address space — and the shape of that is exactly what the IDAU
/// decides. Tested rather than assumed, including the ones that may not exist.
struct Spot {
    addr: u32,
    what: &'static str,
}
const MAP: [Spot; 18] = [
    // The bootrom, and the addresses either side of the one SAU region this
    // chip turns out to leave enabled. Added after the first run printed a
    // region at 0x46a0..0x7fff that the map had no address inside — a map that
    // covered everything except the one place where something happens.
    Spot { addr: 0x0000_0000, what: "bootrom, base" },
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
    Spot { addr: 0xE000_E000, what: "SCS" },
];

static STOPPED: AtomicBool = AtomicBool::new(false);

/// The SAU as it stood when `main` was entered, before the HAL ran. Filled by
/// [`snapshot`] and compared against a second reading in candidate 2.
static BEFORE: [AtomicU32; 4] = [
    AtomicU32::new(0),
    AtomicU32::new(0),
    AtomicU32::new(0),
    AtomicU32::new(0),
];

static CORE1_UP: AtomicBool = AtomicBool::new(false);
static CORE1_GO: AtomicBool = AtomicBool::new(false);
static CORE1_DONE: AtomicBool = AtomicBool::new(false);
static CORE1_FAULTED: AtomicBool = AtomicBool::new(false);
static CORE1_TYPE: AtomicU32 = AtomicU32::new(0);
static CORE1_CTRL: AtomicU32 = AtomicU32::new(0);
static CORE1_TT: AtomicU32 = AtomicU32::new(0);
static CORE1_BANK8: AtomicU32 = AtomicU32::new(0);
/// Set by core 1 **before** it makes the access that is supposed to fault, so
/// core 0 can tell "it never got that far" from "it got that far and died".
static CORE1_READ_DONE: AtomicBool = AtomicBool::new(false);

static mut CORE1_STACK: Stack<4096> = Stack::new();

/// Core 0 faulting is the case nothing else covers, so it goes to the harness.
/// Core 1 faulting is one of the two answers candidate 5 accepts, and it cannot
/// reach the watchdog anyway — `WATCHDOG` defaults to Secure-Privileged-only.
#[exception]
unsafe fn HardFault(_ef: &ExceptionFrame) -> ! {
    if embassy_rp::pac::SIO.cpuid().read() != 0 {
        CORE1_FAULTED.store(true, Ordering::Relaxed);
        loop {
            cortex_m::asm::wfe();
        }
    }
    breadcrumb::reboot()
}

fn box_read(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((SAUBOX + off) as *const u32) }
}

fn box_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((SAUBOX + off) as *mut u32, v) }
}

/// Four words per candidate, starting at word 1: flags, core 1's `SAU_TYPE`,
/// core 1's `TT` response, and core 0's `TT` response for the same address.
fn box_slot(n: u8) -> usize {
    4 + (n as usize - C_DEMOTED_AFTER as usize) * 16
}

fn sau_read(off: usize) -> u32 {
    unsafe { core::ptr::read_volatile((SAU + off) as *const u32) }
}

fn sau_write(off: usize, v: u32) {
    unsafe { core::ptr::write_volatile((SAU + off) as *mut u32, v) }
}

/// CTRL, TYPE, SFSR, SFAR. Deliberately not the region registers: reading a
/// region means writing `RNR` first, and this snapshot has to be side-effect
/// free to be worth comparing against a later one.
fn snapshot() -> [u32; 4] {
    [sau_read(SAU_CTRL), sau_read(SAU_TYPE), sau_read(SFSR), sau_read(SFAR)]
}

fn sregion() -> u32 {
    sau_read(SAU_TYPE) & 0xff
}

fn sau_enabled() -> bool {
    sau_read(SAU_CTRL) & 1 != 0
}

fn sau_allns() -> bool {
    sau_read(SAU_CTRL) & 0b10 != 0
}

fn bank_non_secure(bank: usize, allowed: bool) {
    let reg = embassy_rp::pac::ACCESSCTRL.sram(bank);
    let before = reg.read().0;
    let bits = if allowed { before | NON_SECURE_BITS } else { before & !NON_SECURE_BITS };
    reg.write_value(embassy_rp::pac::accessctrl::regs::Access(ACCESSCTRL_KEY | (bits & 0xFFFF)));
}

fn demote_core1() {
    let r = embassy_rp::pac::ACCESSCTRL.force_core_ns();
    let cur = r.read().0;
    r.write_value(embassy_rp::pac::accessctrl::regs::ForceCoreNs(
        ACCESSCTRL_KEY | ((cur | 0b10) & 0xFFFF),
    ));
}

/// One line of the map. `TT` does not access the address, so a spot that is not
/// backed by anything is a legitimate question and gets a legitimate answer.
async fn tt_line(s: &Spot) {
    let t = TestTarget::check(s.addr as *mut u32, AccessType::Current);
    let idau = match t.idau_region() {
        Some(n) => n as i32,
        None => -1,
    };
    let sau = match t.sau_region() {
        Some(n) => n as i32,
        None => -1,
    };
    log!(
        "  {:#010x} {:<22} S={} nsr={} nsrw={} idau={} sau={}",
        s.addr,
        s.what,
        if t.secure() { "yes" } else { "no " },
        if t.ns_readable() { "yes" } else { "no " },
        if t.ns_read_and_writable() { "yes" } else { "no " },
        idau,
        sau
    );
    Timer::after(Duration::from_millis(25)).await;
}

fn core1_main() -> ! {
    cortex_m::interrupt::disable();
    CORE1_UP.store(true, Ordering::Relaxed);
    while !CORE1_GO.load(Ordering::Relaxed) {
        cortex_m::asm::nop();
    }
    // The measurement, first, because the control below is designed to kill
    // this core. Three readings: the two Secure SAU registers, and the
    // architecture's own attribution of an address as *this core* sees it.
    CORE1_TYPE.store(sau_read(SAU_TYPE), Ordering::Relaxed);
    CORE1_CTRL.store(sau_read(SAU_CTRL), Ordering::Relaxed);
    CORE1_TT.store(
        TestTarget::check(0x2000_0000 as *mut u32, AccessType::Current).as_u32(),
        Ordering::Relaxed,
    );
    CORE1_READ_DONE.store(true, Ordering::Relaxed);

    // The control. Bank 8 is shut to Non-secure for this candidate, so a core
    // whose bus traffic really is marked Non-secure must be refused here.
    // Without it, everything above could be a core that was never demoted.
    let v = unsafe { core::ptr::read_volatile(BANK8 as *const u32) };
    CORE1_BANK8.store(v, Ordering::Relaxed);
    CORE1_DONE.store(true, Ordering::Relaxed);
    loop {
        cortex_m::asm::wfe();
    }
}

/// `demote_first` is the whole of candidate 6. Every experiment on this road so
/// far launches core 1 and demotes it afterwards, because exp162 found that
/// demoting first and then shutting the banks kills it in startup. Nobody has
/// ever demoted first with the banks left open — and if `FORCE_CORE_NS` is
/// sampled when the core comes out of reset, that is the only ordering that
/// could ever put it in Non-secure state.
async fn launch_core1(
    core1: embassy_rp::Peri<'static, embassy_rp::peripherals::CORE1>,
    demote_first: bool,
) -> bool {
    if demote_first {
        demote_core1();
    }
    #[allow(static_mut_refs)]
    let stack = unsafe { &mut CORE1_STACK };
    spawn_core1(core1, stack, core1_main);
    let mut waited = 0;
    while !CORE1_UP.load(Ordering::Relaxed) && waited < 200 {
        Timer::after(Duration::from_millis(10)).await;
        waited += 1;
    }
    if !CORE1_UP.load(Ordering::Relaxed) {
        log!("  core 1 never came up after 2 s.");
        return false;
    }
    if !demote_first {
        demote_core1();
    }
    CORE1_GO.store(true, Ordering::Relaxed);
    true
}

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

fn candidate_name(n: u8) -> &'static str {
    match n {
        C_SAU_EXISTS => "1 the SAU is implemented and Secure code can read it",
        C_INIT_TOUCHES_NOTHING => "2 embassy_rp::init() changes nothing in it",
        C_THE_MAP => "3 the map, address by address",
        C_TWO_WALLS => "4 shutting a bank moves nothing the SAU can see",
        C_DEMOTED_AFTER => "5 what a bus-demoted core sees of the Secure SAU",
        C_DEMOTED_BEFORE => "6 demoted before core 1 ever started",
        _ => "?",
    }
}

/// One pause per line, on every path, outside the match — exp160 lost the end
/// of its report to `usb-log`'s sixteen-deep queue and exp162 lost it a second
/// time by pacing inside a `match` whose arms are expressions.
/// Candidate 6 is the one candidate whose death is a result.
///
/// `spawn_core1` blocks on the SIO FIFO and panics after sixteen bad answers,
/// and `panic-halt` stops core 0, so "the launch did not complete" and "the
/// watchdog ended this boot" are the same event. That is reported as the
/// finding it is — and the other outcome is still reachable and still printed
/// differently, so this is not a candidate that cannot fail: if the launch ever
/// does complete, the matrix says so in its own words.
async fn report(note: &breadcrumb::Note) {
    for n in 1..=CANDIDATES {
        match (n, note.outcome(n)) {
            (_, breadcrumb::NOT_ATTEMPTED) => log!("  {} - not reached", candidate_name(n)),
            (C_DEMOTED_BEFORE, breadcrumb::DIED) => {
                log!("  {} - as expected: the launch never returned", candidate_name(n))
            }
            (C_DEMOTED_BEFORE, breadcrumb::SURVIVED_A) => {
                log!("  {} - the launch COMPLETED; read the log", candidate_name(n))
            }
            (_, breadcrumb::DIED) => log!("  {} - KILLED CORE 0", candidate_name(n)),
            (_, breadcrumb::SURVIVED_A) => log!("  {} - as expected", candidate_name(n)),
            _ => log!("  {} - NOT as expected", candidate_name(n)),
        }
        Timer::after(Duration::from_millis(25)).await;
    }
}

/// Every SAU region the unit says it has. Writing `RNR` is a side effect, which
/// is why it is not in [`snapshot`] and why this runs after candidate 2's
/// comparison rather than before it.
async fn regions() {
    let n = sregion();
    if n == 0 {
        log!("  SAU_TYPE.SREGION is 0: this core has no SAU regions to describe.");
        return;
    }
    for i in 0..n {
        sau_write(SAU_RNR, i);
        let rbar = sau_read(SAU_RBAR);
        let rlar = sau_read(SAU_RLAR);
        // Raw first, decoded second, on the same line. A decode is a claim
        // about a bit layout, and candidate 3 turned out to disagree with this
        // one — so the numbers the disagreement is about are printed as the
        // unit returned them.
        log!(
            "  r{} RBAR={:#010x} RLAR={:#010x} -> {:#08x}..{:#08x} en={} nsc={}",
            i,
            rbar,
            rlar,
            rbar & !0x1f,
            (rlar & !0x1f) | 0x1f,
            rlar & 1,
            (rlar >> 1) & 1
        );
        Timer::after(Duration::from_millis(25)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    // Before anything else runs. This is the whole of candidate 2.
    let before = snapshot();
    for (i, v) in before.iter().enumerate() {
        BEFORE[i].store(*v, Ordering::Relaxed);
    }

    let note = breadcrumb::read(164);

    let p = embassy_rp::init(Default::default());
    let after = snapshot();

    spawner.spawn(heartbeat(Output::new(p.PIN_25, Level::Low)).unwrap());

    let driver = Driver::new(p.USB, Irqs);
    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(PRODUCT);
    config.serial_number = Some("164");
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

    // Report before risk, always.
    Timer::after(Duration::from_secs(3)).await;
    log!("exp164 up, boot #{}. The matrix so far:", note.boot);
    report(&note).await;

    log!("SAU at entry:      CTRL={:#010x} TYPE={:#010x} SFSR={:#010x} SFAR={:#010x}",
         before[0], before[1], before[2], before[3]);
    log!("SAU after init:    CTRL={:#010x} TYPE={:#010x} SFSR={:#010x} SFAR={:#010x}",
         after[0], after[1], after[2], after[3]);
    log!("so: {} regions, enabled={}, allns={}", sregion(), sau_enabled(), sau_allns());

    let next = note.next_unattempted(CANDIDATES);
    let finishing = next.is_none() || note.boot >= LAST_BOOT;

    if !finishing {
        let n = next.unwrap();

        log!("reflash window: {} s, nothing armed. `yi26 bootsel` works now.", REFLASH_WINDOW_S);
        Timer::after(Duration::from_secs(REFLASH_WINDOW_S)).await;

        breadcrumb::arm(STEP_BUDGET_US);
        breadcrumb::step(n);
        log!("candidate {}", candidate_name(n));

        let ok = match n {
            // If this is 0 the part has no SAU regions at all and every line
            // below is about the IDAU alone — which would be the headline, not
            // a failure of the experiment.
            C_SAU_EXISTS => {
                let agrees = sau_base_agrees();
                log!("  reading {:#010x}; cortex-m publishes SAU::PTR = {:#010x} - {}",
                     SAU, cortex_m::peripheral::SAU::PTR as usize,
                     if agrees { "same" } else { "DIFFERENT" });
                log!("  SAU_TYPE = {:#010x}, SREGION = {}", sau_read(SAU_TYPE), sregion());
                regions().await;
                agrees && sregion() > 0
            }

            // The repository's own open question, asked on silicon. A grep says
            // the HAL never names the SAU; this says the HAL never moved it.
            C_INIT_TOUCHES_NOTHING => {
                let mut same = true;
                for i in 0..4 {
                    if BEFORE[i].load(Ordering::Relaxed) != after[i] {
                        log!("  word {} changed: {:#010x} -> {:#010x}",
                             i, BEFORE[i].load(Ordering::Relaxed), after[i]);
                        same = false;
                    }
                }
                log!("  four registers, before and after embassy_rp::init(): {}",
                     if same { "identical" } else { "MOVED" });
                same
            }

            // The artefact. Ungraded: this is the thing the experiment was
            // written to find out, and a check that demands a particular answer
            // to an open question is not a check.
            C_THE_MAP => {
                let mut answered = 0;
                for s in MAP.iter() {
                    tt_line(s).await;
                    if TestTarget::check(s.addr as *mut u32, AccessType::Current).as_u32() != 0 {
                        answered += 1;
                    }
                }
                log!("  {} of {} addresses asked with TT; none of them was accessed.",
                     answered, MAP.len());
                // The map itself is a measurement and is not graded - naming an
                // expected attribution would be asserting the answer. What IS
                // graded is that the instrument ran: a `TT` that did not execute
                // returns an all-zero response, and fourteen all-zero responses
                // would print a confident map of nothing.
                answered == MAP.len()
            }

            // ACCESSCTRL is not the SAU, and this is where that stops being an
            // assertion. Shut bank 8 to Non-secure — the exact write exp159 and
            // exp160 build their wall out of — and ask TT the same question.
            C_TWO_WALLS => {
                let a = TestTarget::check(BANK8 as *mut u32, AccessType::Current);
                log!("  bank 8, ACCESSCTRL open:  S={} nsr={} sau={:?}",
                     a.secure(), a.ns_readable(), a.sau_region());
                bank_non_secure(BANK8_REG, false);
                let b = TestTarget::check(BANK8 as *mut u32, AccessType::Current);
                log!("  bank 8, ACCESSCTRL SHUT:  S={} nsr={} sau={:?}",
                     b.secure(), b.ns_readable(), b.sau_region());
                bank_non_secure(BANK8_REG, true);
                let same = a.as_u32() == b.as_u32();
                log!("  the TT answer is {}. The two walls are {}.",
                     if same { "unchanged" } else { "DIFFERENT" },
                     if same { "separate mechanisms" } else { "not what this repo assumed" });
                same
            }

            // The two orderings, and the reading that turns out to matter.
            //
            // What is GRADED is the refusal: bank 8 is shut, so a core whose
            // bus traffic really carries Non-secure must fault on it. Without
            // that, every SAU value below could be a core that was never
            // demoted at all, and the experiment would be measuring its own
            // failure to demote.
            //
            // What is MEASURED, and deliberately not graded, is what that core
            // sees of the Secure SAU. exp162 taught this the hard way: an
            // expected answer written into a matrix is an answer the run cannot
            // contradict, and the first version of this candidate demanded that
            // core 1 be refused the SAU, got the opposite, and reported it as a
            // failure of the board rather than as the finding it is.
            C_DEMOTED_AFTER | C_DEMOTED_BEFORE => {
                let first = n == C_DEMOTED_BEFORE;
                bank_non_secure(BANK8_REG, false);
                log!("  bank 8 SHUT. FORCE_CORE_NS set {} core 1 starts.",
                     if first { "BEFORE" } else { "after" });
                if first {
                    // `spawn_core1` hands core 1 its entry point over the SIO
                    // FIFO and calls `fifo_read()` after every write, which
                    // blocks; sixteen bad answers and it panics, and
                    // `panic-halt` takes core 0 with it. So this line is the
                    // instrument: if it is the last thing in the log for this
                    // boot, the launch never came back, and the watchdog is
                    // what ended the candidate. exp134 is the record of how
                    // many ways silence reads, and this is the cheapest way to
                    // make one of them speak.
                    log!("  calling spawn_core1 now. If this is the last line, it did not return.");
                    Timer::after(Duration::from_millis(400)).await;
                }

                let mine = sau_read(SAU_TYPE);
                let my_tt = TestTarget::check(0x2000_0000 as *mut u32, AccessType::Current);
                let up = launch_core1(p.CORE1, first).await;
                Timer::after(Duration::from_secs(1)).await;

                let read_done = CORE1_READ_DONE.load(Ordering::Relaxed);
                let faulted = CORE1_FAULTED.load(Ordering::Relaxed);
                let done = CORE1_DONE.load(Ordering::Relaxed);
                let theirs = CORE1_TYPE.load(Ordering::Relaxed);
                let their_tt = CORE1_TT.load(Ordering::Relaxed);

                log!("  core 1: up={} read_done={} faulted={} finished={}",
                     up, read_done, faulted, done);
                log!("  SAU_TYPE  core 0 {:#010x}   core 1 {:#010x}", mine, theirs);
                log!("  SAU_CTRL  core 0 {:#010x}   core 1 {:#010x}",
                     sau_read(SAU_CTRL), CORE1_CTRL.load(Ordering::Relaxed));
                log!("  TT of 0x20000000  core 0 {:#010x}   core 1 {:#010x}",
                     my_tt.as_u32(), their_tt);
                if read_done && theirs == mine && their_tt == my_tt.as_u32() {
                    log!("  core 1 got the Secure answer to every question. It is not");
                    log!("  in Non-secure state; only its bus traffic is marked.");
                } else if read_done {
                    log!("  core 1 got a DIFFERENT answer: it really is Non-secure.");
                } else {
                    log!("  core 1 never reached the reading.");
                }

                let slot = box_slot(n);
                box_write(0, SAUBOX_MAGIC);
                box_write(slot, (read_done as u32) | ((faulted as u32) << 1) | ((up as u32) << 2));
                box_write(slot + 4, theirs);
                box_write(slot + 8, their_tt);
                box_write(slot + 12, my_tt.as_u32());

                bank_non_secure(BANK8_REG, true);
                up && faulted && !done
            }

            _ => false,
        };

        breadcrumb::mark(n, if ok { breadcrumb::SURVIVED_A } else { breadcrumb::SURVIVED_B });
        log!("candidate {} -> {}", n, if ok { "as expected" } else { "NOT as expected" });
        breadcrumb::finished();

        Timer::after(Duration::from_millis(300)).await;
        breadcrumb::reboot()
    }

    breadcrumb::disarm();
    STOPPED.store(true, Ordering::Relaxed);

    loop {
        log!("exp164 done after {} boots. Nothing armed; still reflashable.", note.boot);
        report(&note).await;

        log!("SAU: CTRL={:#010x} TYPE={:#010x} SFSR={:#010x} SFAR={:#010x}",
             sau_read(SAU_CTRL), sau_read(SAU_TYPE), sau_read(SFSR), sau_read(SFAR));
        Timer::after(Duration::from_millis(25)).await;
        regions().await;

        log!("the map, asked again with TT:");
        Timer::after(Duration::from_millis(25)).await;
        for s in MAP.iter() {
            tt_line(s).await;
        }

        // Counted, not asserted. The first version of this block said "every
        // region is disabled" in a string, and the board had one enabled the
        // whole time.
        let mut live = 0;
        for i in 0..sregion() {
            sau_write(SAU_RNR, i);
            if sau_read(SAU_RLAR) & 1 != 0 {
                live += 1;
            }
        }
        let ram = TestTarget::check(0x2000_0000 as *mut u32, AccessType::Current);
        log!("VERDICT: SAU enabled={}, allns={}, {} of {} regions enabled.",
             sau_enabled(), sau_allns(), live, sregion());
        Timer::after(Duration::from_millis(25)).await;
        log!("  main SRAM: Secure={} ns-readable={} SAU region {:?} IDAU {:?}",
             ram.secure(), ram.ns_readable(), ram.sau_region(), ram.idau_region());
        Timer::after(Duration::from_millis(25)).await;

        if box_read(0) == SAUBOX_MAGIC {
            for n in [C_DEMOTED_AFTER, C_DEMOTED_BEFORE] {
                let slot = box_slot(n);
                let f = box_read(slot);
                log!("  demoted {}: read={} fault={} TYPE={:#010x}",
                     if n == C_DEMOTED_BEFORE { "before" } else { "after " },
                     f & 1, (f >> 1) & 1, box_read(slot + 4));
                Timer::after(Duration::from_millis(25)).await;
                log!("            TT core1={:#010x} core0={:#010x}",
                     box_read(slot + 8), box_read(slot + 12));
                Timer::after(Duration::from_millis(25)).await;
            }
            // The sentence follows the readings; it is not printed over them.
            // The whole reason this experiment exists is that a previous
            // version asserted the opposite and was wrong.
            // Candidate 5 is the one that produces a reading; candidate 6's
            // record is absent when the launch it was testing did not come
            // back, and that absence is its own result rather than a gap in
            // this one.
            let slot = box_slot(C_DEMOTED_AFTER);
            let read = box_read(slot) & 1 != 0;
            let faulted = box_read(slot) & 2 != 0;
            let same = box_read(slot + 8) == box_read(slot + 12);
            if read && faulted && same {
                log!("  a core ACCESSCTRL refuses is a core the SAU still answers.");
                Timer::after(Duration::from_millis(25)).await;
                log!("  FORCE_CORE_NS marks the bus, not the core: Non-secure to");
                Timer::after(Duration::from_millis(25)).await;
                log!("  ACCESSCTRL, Secure to the architecture.");
            } else if read && faulted {
                log!("  the demoted core got a different answer: it really is Non-secure.");
            } else {
                log!("  candidate 5 did not produce both halves; no conclusion drawn.");
            }
            Timer::after(Duration::from_millis(25)).await;
            if box_read(box_slot(C_DEMOTED_BEFORE)) & 1 == 0 {
                log!("  and there is no other ordering: setting it before the launch");
                Timer::after(Duration::from_millis(25)).await;
                log!("  leaves spawn_core1 waiting on a FIFO that never answers.");
            }
        } else {
            log!("  no record in bank 8: candidates 5 and 6 did not both finish.");
        }
        Timer::after(Duration::from_secs(4)).await;
    }
}
