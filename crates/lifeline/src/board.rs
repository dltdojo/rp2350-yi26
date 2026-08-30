// SPDX-License-Identifier: Apache-2.0
//! The half that only a board can run.
//!
//! Everything here touches the watchdog, the ROM or a peripheral, so none of it
//! can be tested on a host — which is exactly why the rule that decides when to
//! give up lives in [`super::consecutive_deaths`] instead, where it can be.

use super::{Config, STEP_BOOTING};
use core::sync::atomic::{AtomicBool, Ordering};
pub use breadcrumb::Cause;

/// What the last boot did, and what this one is walking into.
#[derive(Clone, Copy, Debug)]
pub struct Boot {
    /// Which boot this is, counting from 1.
    pub count: u32,
    /// How the previous boot ended.
    pub cause: Cause,
    /// The step the previous boot was attempting when it died, `0` if it did not.
    pub step: u8,
    /// How many boots in a row have now died **before reaching [`alive`]**.
    pub deaths: u8,
}

impl Boot {
    /// Is this boot a retry after something died?
    pub fn recovering(&self) -> bool {
        self.deaths > 0
    }
}



/// **The first line of `main`**, before `embassy_rp::init` and before any
/// peripheral.
///
/// Reads the note the last boot left, decides whether this board should be
/// handed to the bootrom instead of trying again, and arms the watchdog.
///
/// Anything that resets a peripheral or takes a fault before this runs destroys
/// the only record of why the last boot ended — which is [`breadcrumb::read`]'s
/// rule, inherited whole.
pub fn begin(cfg: Config) -> Boot {
    let note = breadcrumb::read(cfg.tag);
    let deaths = breadcrumb::tally();

    #[cfg(feature = "escape")]
    if super::decide(deaths, cfg.escape_after) == super::Decision::HandOver {
        // **One shot.** The count is cleared on the way out, so the firmware
        // that gets flashed next — the fixed one — gets its own three tries.
        // Without this the tally stays at the threshold and every image after
        // it, working or not, is bounced into the bootloader before it runs:
        // a board permanently in BOOTSEL, which is a different way of needing
        // a person.
        breadcrumb::set_tally(0);
        // Not a fourth attempt at the thing that has already failed three
        // times. The board lands in the ROM bootloader, presents its drive, and
        // is reflashable by a host — which is the entire point of this crate.
        //
        // `0, 0` is the plain BOOTSEL behaviour: both interfaces, no fixed GPIO
        // activity mask.
        embassy_rp::rom_data::reset_to_usb_boot(0, 0);
    }

    // Presumed dead until it says otherwise. A boot that dies on the way up
    // cannot record anything on the way out, so the count goes in first.
    if let super::Decision::Try(next) = super::decide(deaths, cfg.escape_after) {
        breadcrumb::set_tally(next);
    }
    breadcrumb::step(STEP_BOOTING);
    breadcrumb::arm(cfg.boot_us);
    Boot { count: note.boot, cause: note.cause, step: note.step, deaths }
}

/// **This board can now be reached.** Call it once.
///
/// After this the watchdog switches to its short running timeout, and this boot
/// stops counting towards the escape however it ends. Put it at the earliest
/// moment a host could talk to the board — for a USB experiment, once the stack
/// is built and the tasks that serve it are spawned, not after the first log
/// line has been read by somebody.
pub fn alive(cfg: Config) {
    // Got up, so the run of failures ends here.
    breadcrumb::set_tally(0);
    breadcrumb::finished();
    breadcrumb::feed(cfg.run_us);
    ALIVE.store(true, Ordering::Relaxed);
}

static ALIVE: AtomicBool = AtomicBool::new(false);

/// Has [`alive`] been called on this boot?
pub fn is_alive() -> bool {
    ALIVE.load(Ordering::Relaxed)
}


/// Feed the watchdog. **Spawn this**, or nothing else here works.
///
/// Its silence is the mechanism: if the executor stops — a panic that spins, a
/// task that never yields, interrupts left off — this stops feeding and the
/// board resets. That is the case no fault handler catches, and it is the one
/// that cost three of one round's four trips to a bench.
#[embassy_executor::task]
pub async fn keepalive(cfg: Config) -> ! {
    loop {
        embassy_time::Timer::after(embassy_time::Duration::from_millis(
            (cfg.run_us / 3_000).max(50) as u64,
        ))
        .await;
        breadcrumb::feed(cfg.run_us);
    }
}

/// A panic that reboots rather than halting.
///
/// **It does not try to log.** That was tried on a bench and it does not work:
/// the log is a ring drained by a task, and by the time this runs that task is
/// never going to run again. What survives instead is the note — the next boot
/// reads `Cause::Fault` and the step, and says it out loud when there is a
/// working log to say it into.
///
/// `panic-halt` is what this replaces, and the difference is the whole crate: a
/// board that halts is indistinguishable from a bad cable, and a board that
/// reboots is one a host can still reach.
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    breadcrumb::reboot()
}

/// The same, for a fault the CPU raises rather than the code.
///
/// `cortex-m-rt`'s default handler is an infinite loop, which is the silent
/// death again by another name.
#[cortex_m_rt::exception]
unsafe fn HardFault(_ef: &cortex_m_rt::ExceptionFrame) -> ! {
    breadcrumb::reboot()
}

/// Blink what state this boot is in, for the person who has only the LED.
///
/// - **one short flash a second** — up, and nothing wanted
/// - **N quick flashes then a pause** — this is retry number N after a death,
///   and N reaching [`Config::escape_after`] is the last one before the board
///   hands itself to the bootloader
///
/// Optional. A firmware whose LED already says something — *press me*, *no
/// secret* — keeps its own and reads [`Boot::deaths`] instead.
#[embassy_executor::task]
pub async fn led(mut pin: embassy_rp::gpio::Output<'static>, boot: Boot) -> ! {
    use embassy_time::{Duration, Timer};
    loop {
        if boot.recovering() && !super::board::is_alive() {
            for _ in 0..boot.deaths {
                pin.set_high();
                Timer::after(Duration::from_millis(80)).await;
                pin.set_low();
                Timer::after(Duration::from_millis(120)).await;
            }
            Timer::after(Duration::from_millis(700)).await;
        } else {
            pin.set_high();
            Timer::after(Duration::from_millis(50)).await;
            pin.set_low();
            Timer::after(Duration::from_millis(950)).await;
        }
    }
}
