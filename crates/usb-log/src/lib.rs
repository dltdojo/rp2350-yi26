//! Print from anywhere, without the printing becoming the bug.
//!
//! A serial log carries far more than a blinking LED can: numbers, timings,
//! which of several tasks did what and when. exp104 gave this repository the
//! ability to print at all. This crate makes it something you can call from
//! *any* task, at any moment, without stopping to think about who owns the
//! USB endpoint or what happens if nobody is listening.
//!
//! ```ignore
//! usb_log::log!("button #{} down after {} ms", presses, uptime);
//! ```
//!
//! That call is an ordinary synchronous function. It does not `.await`, it
//! cannot block, and it takes the same bounded time whether the host is
//! reading avidly, has the port open and ignores it, or is not plugged in.
//!
//! # The problem this exists to solve
//!
//! exp104 measured what naive printing does: two consecutive counter values
//! arrived **21 seconds apart**, because `write_all` parks the task until
//! something drains the endpoint. exp106 worked around it by only printing
//! when DTR was asserted — which helps, and is still not enough: a terminal
//! that is open but not reading asserts DTR just fine, and then the write
//! parks anyway. A debug tool that changes the timing of the thing being
//! debugged is worse than no debug tool, because it lies.
//!
//! # How it is solved: move the blocking, do not remove it
//!
//! There is exactly one way to make a USB write not block, and it is not to
//! make USB faster. It is to put a **queue** between the code that has
//! something to say and the code that says it:
//!
//! ```text
//!   button task  ─┐
//!   timer task   ─┼─→ [ queue, 16 lines ] ─→ logger task ─→ USB ─→ host
//!   any task     ─┘        (never waits)      (waits here)
//! ```
//!
//! The logger task still blocks — that part is unavoidable. The point is
//! *where* it blocks: in a task whose only job is logging, where being stuck
//! harms nothing. Your button keeps being polled at 20 ms whatever the host
//! is doing.
//!
//! # It waits for a listener before it writes at all
//!
//! One extra rule, and it is not politeness — it was learned by wedging a
//! board. The writer will not put a line on the wire until the host asserts
//! DTR, which is what opening the port does.
//!
//! Without that check, a line written while nobody is collecting leaves a
//! packet armed in the USB IN endpoint indefinitely. Keep doing that and the
//! chip eventually stops answering **control** requests, while the serial
//! stream itself keeps flowing perfectly. The board looks healthy and is not:
//! `SET_LINE_CODING` never completes, so the 1200-baud reflash touch hangs and
//! the BOOTSEL button becomes the only way back in. Measured on hardware —
//! reproducible after about thirty seconds of writing into a closed port, and
//! not recoverable by attaching a reader afterwards.
//!
//! So the queue is not only a buffer against slow readers. It is where output
//! waits for an audience, and the drop counting below is what keeps that
//! honest.
//!
//! # What happens when the queue fills
//!
//! Waiting for room is disqualified: it is the original bug wearing a hat.
//! So the line is dropped, and this crate **counts what it dropped**. The
//! count is attached to the first line that survives after the gap, so the
//! loss is marked exactly where it happened:
//!
//! ```text
//! [    9012 ms] (+47 lines lost) heartbeat #10 (LED flashed)
//! ```
//!
//! For a long time the paragraph above said there were "only two choices",
//! wait or drop, and that was wrong in a way nobody noticed for thirty-three
//! experiments. Dropping hides a second question: **which** line? Refusing the
//! new arrival keeps the *oldest* entries; evicting the head keeps the
//! *newest*. Both are dropping, both cost the same RAM, and they hand a reader
//! two completely different logs — which matters most to somebody who opens a
//! browser page two minutes after the interesting thing happened.
//!
//! [`POLICY`] is that choice, made at build time, and [`log_policy`] holds the
//! decision itself so it can be tested without a board. The default is
//! unchanged and always will be: refuse the newest, keep the oldest, count
//! everything.
//!
//! Counting at the sending end rather than announcing it from the writer is
//! what makes that position right: the writer only ever sees lines that were
//! accepted, and would have to guess where the missing ones belonged.
//!
//! Silent loss would be the worst of all options: you would read an
//! incomplete log believing it complete. Losing data is survivable; not
//! knowing you lost it is not. That principle is the same one behind
//! `experiments/audit.sh` — a tool that asks to be trusted has already
//! failed.
//!
//! # The timestamp is taken by the caller, not by the writer
//!
//! [`log`] stamps the line the moment you call it, before it enters the
//! queue. If it were stamped on the way out, every timestamp would record
//! when USB got around to it — and the delays you are trying to debug would
//! be invisible, having been quietly absorbed into the measurement. A log
//! that hides the very effect you are hunting is a trap, and this ordering is
//! the difference.
//!
//! # Costs, stated plainly
//!
//! - **RAM:** [`QUEUE_DEPTH`] × [`LINE_CAPACITY`] bytes of static buffer
//!   (1536 with the defaults), plus one [`Line`] built on the caller's stack.
//! - **Time per call:** formatting, a copy of at most [`LINE_CAPACITY`]
//!   bytes, and a brief critical section inside the queue. Bounded and
//!   short — but not zero. Do not call this from an interrupt-critical path
//!   without measuring it, and do not put it inside a tight loop.
//! - **Lines are truncated** at [`LINE_CAPACITY`] bytes rather than being
//!   split or dropped. A cut line ends in `...` so you can see it happened.
//! - **Nothing is authenticated.** Everything logged is readable by any local
//!   process that can open the serial port. `experiments/audit.sh` reports
//!   this. Do not log secrets.

#![no_std]

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

/// The USB driver type these experiments use.
pub type UsbDriver = Driver<'static, USB>;

/// Longest line, in bytes, including the timestamp prefix. Longer lines are
/// truncated and marked with `...`.
pub const LINE_CAPACITY: usize = 96;

/// How many lines can be waiting to go out before new ones are dropped.
///
/// Bigger absorbs longer stalls and costs proportionally more RAM. 16 lines
/// is enough to ride out a host that pauses for a moment, and small enough
/// that a host which stops reading altogether shows you the drop message
/// quickly instead of pretending everything is fine.
pub const QUEUE_DEPTH: usize = 16;

#[cfg(all(feature = "keep-recent", feature = "silent-while-idle"))]
compile_error!(
    "keep-recent and silent-while-idle are alternatives, not additions: one \
     keeps the newest lines and the other keeps none. Choose one."
);

/// What this build does when the queue is full, or when nobody is reading.
///
/// Selected at compile time because the answer is a property of the firmware,
/// not of the moment — and because a runtime switch would mean shipping all
/// three and letting a mistake be a mistake in the field rather than in the
/// build. See [`log_policy`] for what each one means and why none of them is
/// universally right.
pub const POLICY: Policy = if cfg!(feature = "keep-recent") {
    Policy::KeepRecent
} else if cfg!(feature = "silent-while-idle") {
    Policy::SilentWhileIdle
} else {
    Policy::DropNewest
};

/// How often the writer checks whether a host has opened the port.
///
/// Only relevant while nobody is listening, so it costs nothing that matters.
const DTR_POLL_MS: u64 = 100;

/// One formatted line, waiting its turn.
///
/// A fixed-size array rather than a `String`: there is no allocator on this
/// chip, and a log line whose size depends on its content is a log line that
/// can run the queue out of memory at the worst possible moment.
pub struct Line {
    buf: [u8; LINE_CAPACITY],
    len: usize,
    truncated: bool,
}

impl Line {
    const fn new() -> Self {
        Self { buf: [0; LINE_CAPACITY], len: 0, truncated: false }
    }
}

impl Write for Line {
    /// Copies what fits and remembers if anything did not.
    ///
    /// Note it returns `Ok` even when it dropped bytes. That is deliberate: a
    /// logging path that can fail becomes a thing callers have to handle, and
    /// then they stop logging. Truncation is recorded in the output instead,
    /// where a human will see it.
    fn write_str(&mut self, s: &str) -> fmt::Result {
        let bytes = s.as_bytes();
        let room = LINE_CAPACITY - self.len;
        let n = if bytes.len() < room { bytes.len() } else { room };
        self.buf[self.len..self.len + n].copy_from_slice(&bytes[..n]);
        self.len += n;
        if n < bytes.len() {
            self.truncated = true;
        }
        Ok(())
    }
}

/// The queue. `CriticalSectionRawMutex` because senders may live in different
/// tasks — and, in principle, on a different core or inside an interrupt.
static QUEUE: Channel<CriticalSectionRawMutex, Line, QUEUE_DEPTH> = Channel::new();

/// Whether a host currently has the port open, as last observed by [`run`].
///
/// Only [`Policy::SilentWhileIdle`] reads it, and it starts `true` on purpose.
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

/// Queues one line for the host. Never blocks, never waits, never fails.
///
/// Use the [`log!`] macro rather than calling this directly.
pub fn log(args: fmt::Arguments) {
    // Ask before formatting anything. The decision needs two facts and no
    // string, and under `silent-while-idle` the cheapest line is the one that
    // was never built.
    let admission = admit(POLICY, QUEUE.is_full(), READER_PRESENT.load(Ordering::Relaxed));

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
    let lost = if matches!(POLICY, Policy::KeepRecent) {
        DROPPED.load(Ordering::Relaxed)
    } else {
        DROPPED.swap(0, Ordering::Relaxed)
    };

    let mut line = Line::new();

    // Stamped here, in the caller's task, at the moment the event happened —
    // see the module docs for why this must not happen on the way out.
    let _ = write!(&mut line, "[{:>8} ms] ", Instant::now().as_millis());
    if lost > 0 {
        if matches!(POLICY, Policy::KeepRecent) {
            let _ = write!(&mut line, "({} lines lost so far) ", lost);
        } else {
            let _ = write!(&mut line, "(+{} lines lost) ", lost);
        }
    }
    let _ = line.write_fmt(args);

    // `try_send` is the whole design in one call: it either takes the line
    // immediately or refuses. It has no third option that involves waiting,
    // which is precisely why the caller cannot be parked here.
    //
    // Reaching the failure arm now means a race rather than a full queue:
    // `is_full` said there was room and another task filled it in between.
    if QUEUE.try_send(line).is_err() {
        if matches!(POLICY, Policy::KeepRecent) {
            DROPPED.fetch_add(1, Ordering::Relaxed);
        } else {
            // This line is lost too, and it was carrying the running total —
            // put both back so the next survivor reports the full gap.
            DROPPED.fetch_add(lost + 1, Ordering::Relaxed);
        }
    }
}

/// Log a line, `println!`-style. Callable from any task.
///
/// ```ignore
/// usb_log::log!("worst wakeup lateness so far: {} us", worst);
/// ```
#[macro_export]
macro_rules! log {
    ($($arg:tt)*) => {
        $crate::log(::core::format_args!($($arg)*))
    };
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
