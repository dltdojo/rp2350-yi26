//! The half of `usb-log` that needs a board: the queue, the clock, and the one
//! task allowed to touch the USB sender. Everything that decides what a line
//! says is in `lib.rs`, where `cargo test` can reach it.

use core::fmt::{self, Write};
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use log_policy::{admit, Admission, Policy};

use embassy_rp::peripherals::USB;
use embassy_rp::usb::Driver;
use embassy_sync::blocking_mutex::raw::CriticalSectionRawMutex;
use embassy_sync::channel::Channel;
use embassy_time::{Instant, Timer};
use embassy_usb::class::cdc_acm::Sender;
use embedded_io_async::Write as _;

use crate::{claim, refund, Line, POLICY, QUEUE_DEPTH};
#[cfg(feature = "retain")]
use crate::LINE_CAPACITY;

/// The USB driver type these experiments use.
pub type UsbDriver = Driver<'static, USB>;

/// How often the writer checks whether a host has opened the port.
///
/// Only relevant while nobody is listening, so it costs nothing that matters.
const DTR_POLL_MS: u64 = 100;

/// The queue. `CriticalSectionRawMutex` because senders may live in different
/// tasks — and, in principle, on a different core or inside an interrupt.
static QUEUE: Channel<CriticalSectionRawMutex, Line, QUEUE_DEPTH> = Channel::new();

/// Whether a host currently has the port open, as last observed by [`run`].
///
/// Only [`Policy::SilentWhileIdle`] reads it, and it starts `true`
/// on purpose.
/// `log` is a synchronous function with no access to the USB sender, so it
/// cannot ask — it has to be told, and nobody can tell it until the writer has
/// looked at least once. Starting `false` would mean nothing is ever queued,
/// so the writer never wakes, so it never looks: a deadlock built out of two
/// correct halves.
///
/// The cost of starting `true` is exactly one line: the first thing logged
/// into a closed port is queued, the writer collects it, discovers DTR is low
/// and sets this flag, and from then on nothing is queued at all. That one
/// held line is the last thing said before the silence, which is a reasonable
/// thing for a reader to find waiting for them.
static READER_PRESENT: AtomicBool = AtomicBool::new(true);

/// Lines thrown away since the last time we managed to say so.
static DROPPED: AtomicU32 = AtomicU32::new(0);

/// How many recent lines are kept for a second reader, under `retain`.
///
/// Sixty-four at [`LINE_CAPACITY`] is 6 KiB of SRAM, which is nothing on an
/// RP2350 and is about a minute of a firmware that reports every five seconds
/// — enough that somebody who opens a page after plugging the board in sees
/// how it started, and not so much that a phone has to scroll through a day.
#[cfg(feature = "retain")]
pub const RETAIN_LINES: usize = 64;

/// The retained copy. A blocking mutex and not a channel: nothing awaits this,
/// nothing is woken by it, and a reader takes what is there at the moment it
/// asks.
#[cfg(feature = "retain")]
static RING: embassy_sync::blocking_mutex::Mutex<
    CriticalSectionRawMutex,
    core::cell::RefCell<log_ring::Ring<RETAIN_LINES, LINE_CAPACITY>>,
> = embassy_sync::blocking_mutex::Mutex::new(core::cell::RefCell::new(log_ring::Ring::new()));

/// Hand every retained line to `f`, oldest first, then the number that were
/// overwritten before anyone asked.
///
/// Runs inside a critical section, so `f` must be short and must not log.
#[cfg(feature = "retain")]
pub fn retained(mut f: impl FnMut(&[u8])) -> u32 {
    RING.lock(|r| {
        let r = r.borrow();
        r.for_each(&mut f);
        r.lost()
    })
}

/// Queues one line for the host. Never blocks, never waits, never fails.
///
/// Use the [`log!`] macro rather than calling this directly.
pub fn log(args: fmt::Arguments) {
    line(args, true)
}

/// Log a line to the serial stream **without keeping it in the retained ring**.
///
/// For things that are noise in a history and useful in a stream — above all,
/// a board's account of serving its own log. exp151 measured what happens
/// without this: reading the page over HTTP logs three lines per request, the
/// page refreshes itself every three seconds, and within a minute **58 of the
/// 64 retained lines were the reader's own footsteps**. The log had been
/// erased by the act of reading it.
///
/// The serial port still gets these lines, because somebody watching a serial
/// port wants to see requests arriving. The distinction is not importance, it
/// is *whose* log it belongs in.
///
/// With `retain` off this is exactly [`log`], because there is no ring to skip.
pub fn log_transient(args: fmt::Arguments) {
    line(args, false)
}

fn line(args: fmt::Arguments, retain: bool) {
    let _ = retain;
    // Ask before formatting anything. The decision needs two facts and no
    // string, and under `silent-while-idle` the cheapest line is the one that
    // was never built.
    let admission = admit(POLICY, QUEUE.is_full(), READER_PRESENT.load(Ordering::Relaxed));

    // Under `retain` the early return has to be deferred: the outgoing queue
    // and the ring are different consumers with different rules, and a line
    // the queue has no room for is one the ring should still keep. Without the
    // feature this is the same early return it always was, and the line is
    // never formatted at all.
    #[cfg(not(feature = "retain"))]
    match admission {
        Admission::Drop => {
            DROPPED.fetch_add(1, Ordering::Relaxed);
            return;
        }
        Admission::EvictOldest => {
            // Discard the head to make room. `admit` only returns this for a
            // full queue, so the receive cannot come up empty — but it is
            // checked rather than unwrapped, because "cannot" here depends on
            // another crate staying correct.
            if QUEUE.try_receive().is_ok() {
                DROPPED.fetch_add(1, Ordering::Relaxed);
            }
        }
        Admission::Enqueue => {}
    }

    #[cfg(feature = "retain")]
    if let Admission::EvictOldest = admission {
        if QUEUE.try_receive().is_ok() {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        }
    }

    // Claim the loss so it can be reported on *this* line, which — if it makes
    // it into the queue — is by definition the first one after the gap. That
    // is why the count is carried here rather than announced by the writer:
    // the writer only ever sees lines that survived, and would have to guess
    // where the missing ones went.
    //
    // The two policies count differently, and they have to.
    //
    // A **delta** is safe only in a queue that never discards what it already
    // accepted: the number is rendered into one line's text, and if that line
    // is thrown away the number goes with it. `keep-recent` throws accepted
    // lines away by design, so a delta would quietly undercount every gap it
    // evicted a marker for. It therefore reports a **running total**, which
    // survives eviction because every later line repeats it.
    let lost = claim(POLICY, &DROPPED);

    let now = Instant::now().as_millis();

    // Built without the loss marker first, because that marker belongs to the
    // **queue** and not to the ring.
    //
    // Measured on a phone: with nobody holding the serial port, the queue drops
    // a line per tick and every survivor carries `(+1 lines lost)`. Those
    // markers were being formatted into the text and then handed to *both*
    // consumers — so the HTTP page showed `(+1 lines lost)` on every line of a
    // log that had lost nothing at all. A reader shown a gap that is not there
    // is worse off than one shown no marker: they go looking for the missing
    // middle of something complete.
    //
    // The ring keeps its own count and [`retained`] returns it, so nothing is
    // hidden — it is reported by whoever actually lost something.
    //
    // Stamped here, in the caller's task, at the moment the event happened —
    // see the module docs for why this must not happen on the way out.
    let mut line = Line::new();
    let _ = write!(&mut line, "[{:>8} ms] ", now);
    let _ = line.write_fmt(args);

    // The ring gets it whatever the queue decides — unless the caller asked
    // for a line that passes through without being kept. This is the only
    // place in this function the second consumer is touched.
    #[cfg(feature = "retain")]
    if retain {
        RING.lock(|r| r.borrow_mut().push(&line.buf[..line.len]));
    }

    // Now the queue's copy, which does carry the queue's marker. `Arguments` is
    // `Copy`, so this costs a second formatting pass only in the rare case that
    // something was actually lost.
    let line = if lost > 0 {
        let mut marked = Line::new();
        let _ = write!(&mut marked, "[{:>8} ms] ", now);
        if matches!(POLICY, Policy::KeepRecent) {
            let _ = write!(&mut marked, "({} lines lost so far) ", lost);
        } else {
            let _ = write!(&mut marked, "(+{} lines lost) ", lost);
        }
        let _ = marked.write_fmt(args);
        marked
    } else {
        line
    };

    #[cfg(feature = "retain")]
    if let Admission::Drop = admission {
        DROPPED.fetch_add(1, Ordering::Relaxed);
        return;
    }

    // `try_send` is the whole design in one call: it either takes the line
    // immediately or refuses. It has no third option that involves waiting,
    // which is precisely why the caller cannot be parked here.
    //
    // Reaching the failure arm now means a race rather than a full queue:
    // `is_full` said there was room and another task filled it in between.
    if QUEUE.try_send(line).is_err() {
        refund(POLICY, &DROPPED, lost);
    }
}

/// Drains the queue to the host, forever. Spawn this in its own task.
///
/// This is the one place in the program allowed to touch the USB sender, and
/// the one place allowed to block. Give it the `Sender` half of your
/// `CdcAcmClass` and never keep a copy — single ownership is what makes
/// "callable from anywhere" safe.
pub async fn run(mut sender: Sender<'static, UsbDriver>) -> ! {
    loop {
        // Sleeps until a line arrives. No polling: an idle log costs nothing.
        let line = QUEUE.receive().await;

        // Wait for the host to configure the device at all.
        sender.wait_connection().await;

        // Then wait for a host that has actually *opened* the port.
        //
        // This is not politeness, it is a hardware-level requirement, and it
        // cost a wedged board to learn. Writing into the IN endpoint while
        // nothing is collecting leaves a packet armed indefinitely; on this
        // chip a firmware that keeps doing that eventually stops answering
        // control requests altogether. The serial port still streams, so the
        // board looks perfectly healthy — but SET_LINE_CODING never completes,
        // which means the 1200-baud reflash touch from exp105 hangs and the
        // only way back is the BOOTSEL button. Measured, not theorised: see
        // this experiment's README.
        //
        // DTR — the host asserts it on open and drops it on close — is the
        // signal for "somebody is there". There is no async way to await it
        // from a `Sender` (the `ControlChanged` half belongs to the reboot
        // watcher), so poll it. This task has nothing better to do.
        while !sender.dtr() {
            READER_PRESENT.store(false, Ordering::Relaxed);
            Timer::after_millis(DTR_POLL_MS).await;
        }
        READER_PRESENT.store(true, Ordering::Relaxed);

        emit(&mut sender, &line).await;
    }
}

/// Writes one line plus its terminator, ignoring errors.
///
/// Errors here mean the host went away mid-write. There is nobody to report
/// that to — the reporting channel is the thing that just broke — so the loop
/// simply goes back to waiting for a connection.
async fn emit(sender: &mut Sender<'static, UsbDriver>, line: &Line) {
    let _ = sender.write_all(&line.buf[..line.len]).await;

    // The terminator goes out as its own small write on purpose. A USB bulk
    // transfer ends when the host sees a packet shorter than the maximum, so
    // a line that happened to be exactly 64 bytes would otherwise sit in the
    // host's buffer waiting for a continuation that never comes. This short
    // trailing write always ends the transfer.
    let tail: &[u8] = if line.truncated { b"...\r\n" } else { b"\r\n" };
    let _ = sender.write_all(tail).await;
}
