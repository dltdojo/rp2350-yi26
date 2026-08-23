// SPDX-License-Identifier: Apache-2.0
//
// exp178 — the shape of the contract.
//
// This file is the measurement. It is the smallest thing the RP2350 can carry
// that OpenSK's `Env` trait will accept: every method in `adapter` exists
// because the compiler refused to build without it, and none exists because
// somebody thought it might be useful. Delete any one of them and `cargo build`
// says so, by name.
//
// **It is never flashed and it would do nothing if it were.** Half of what
// follows returns an error. That is not laziness: the question this experiment
// asks is what a CTAP 2.1 engine *demands before it will build*, and a demand
// is answered by a signature, not by a working implementation. What each real
// implementation would be is written beside the stub, and every one of them
// already exists somewhere in this repository — which is the finding.
//
// The other half of the experiment (`../driver/`) runs the same engine for
// real, on the host, where OpenSK's own `TestEnv` supplies all of this.

#![no_std]
#![no_main]

// `Env` returns `alloc::vec::Vec` and `alloc::boxed::Box`, so a heap is not a
// choice this experiment made. It is the first one on this road: exp168 to
// exp174 hand-rolled CTAP2 with no allocator at all, and `crates/cbor` refuses
// to allocate by construction.
extern crate alloc;

use cortex_m_rt::entry;
use embedded_alloc::LlffHeap;
// Linked for its `#[panic_handler]` and nothing else.
use panic_halt as _;

#[global_allocator]
static HEAP: LlffHeap = LlffHeap::empty();

// A number, not a measurement. Nothing here runs, so this only has to be big
// enough for the linker to accept a `static`; what a real build needs is
// something the next experiment on this road would have to find out. It sits
// outside the module on purpose, so that **both** arms of the build carry the
// heap and the difference between them is the engine alone.
const HEAP_BYTES: usize = 32 * 1024;
static mut HEAP_MEMORY: [u8; HEAP_BYTES] = [0; HEAP_BYTES];

// Everything below is the adapter, and it is a module so that the same crate
// can be built without it: `--no-default-features` produces a binary with the
// heap, the entry point and the panic handler and no engine at all. The
// difference between the two images is what OpenSK costs in flash on this chip,
// measured rather than estimated.
#[cfg(feature = "engine")]
mod adapter {
    use alloc::boxed::Box;
    use alloc::vec::Vec;
    use core::fmt;
    use core::hint;

    use opensk::api::clock::Clock;
    use opensk::api::connection::{HidConnection, RecvStatus, UsbEndpoint};
    use opensk::api::crypto::software_crypto::SoftwareCrypto;
    use opensk::api::customization::{CustomizationImpl, DEFAULT_CUSTOMIZATION};
    use opensk::api::key_store::Helper as KeyStoreHelper;
    use opensk::api::persist::{Persist, PersistIter};
    use opensk::api::rng::Rng;
    use opensk::api::rng::rand_core::{CryptoRng, Error as RngError, RngCore};
    use opensk::api::user_presence::{UserPresence, UserPresenceError, UserPresenceWaitResult};
    use opensk::ctap::status_code::{Ctap2StatusCode, CtapResult};
    use opensk::env::Env;
    use opensk::{Ctap, Transport};

    // -----------------------------------------------------------------------
    // Obligation 1 of 6 — Rng
    //
    // The real one: exp109's hardware TRNG, and exp174's finding that
    // `embassy-rp`'s default `sample_count` of 25 turns thirty-two bytes into
    // twenty-five seconds. Whatever fills this buffer inherits that.
    // -----------------------------------------------------------------------
    struct StubRng;

    impl RngCore for StubRng {
        fn next_u32(&mut self) -> u32 {
            hint::black_box(0)
        }
        fn next_u64(&mut self) -> u64 {
            hint::black_box(0)
        }
        fn fill_bytes(&mut self, dest: &mut [u8]) {
            dest.fill(hint::black_box(0))
        }
        fn try_fill_bytes(&mut self, dest: &mut [u8]) -> Result<(), RngError> {
            dest.fill(hint::black_box(0));
            Ok(())
        }
    }

    // The marker that says "this output is fit for key material". A stub
    // asserting it is exactly the lie this experiment must not tell anywhere it
    // could be mistaken for a build somebody runs — hence the first paragraph
    // of this file, and the fact that no image here is ever flashed.
    impl CryptoRng for StubRng {}
    impl Rng for StubRng {}

    // -----------------------------------------------------------------------
    // Obligation 2 of 6 — UserPresence
    //
    // The real one: exp171's BOOTSEL wait, and exp174's whole subject — a
    // device that stays silent while it waits is one a browser gives up on, so
    // a real `wait_with_timeout` is also where `CTAPHID_KEEPALIVE` goes out.
    // -----------------------------------------------------------------------
    struct StubUserPresence;

    impl UserPresence for StubUserPresence {
        fn check_init(&mut self) {}

        fn wait_with_timeout(
            &mut self,
            _packet: &mut [u8; 64],
            _timeout_ms: usize,
        ) -> UserPresenceWaitResult {
            // Declined, not confirmed. exp171's rule — the presence bit is the
            // device's own word and nothing in the protocol checks it — applies
            // to a stub with more force than to a real build, not less.
            hint::black_box(Ok((Err(UserPresenceError::Declined), RecvStatus::Timeout)))
        }

        fn check_complete(&mut self) {}
    }

    // -----------------------------------------------------------------------
    // Obligation 3 of 6 — Clock
    //
    // The real one: `embassy-time`, already running in every experiment from
    // exp168 on.
    // -----------------------------------------------------------------------
    #[derive(Default)]
    struct StubTimer;

    struct StubClock;

    impl Clock for StubClock {
        type Timer = StubTimer;

        fn make_timer(&mut self, _milliseconds: usize) -> Self::Timer {
            StubTimer
        }

        // "A default Timer should return `true` when checked", says the trait,
        // so a stub that always claims elapsed is the one consistent answer.
        fn is_elapsed(&mut self, _timer: &Self::Timer) -> bool {
            hint::black_box(true)
        }
    }

    // -----------------------------------------------------------------------
    // Obligation 4 of 6 — Write, for debugging
    //
    // The real one: `crates/usb-log` over the CDC interface, which is why this
    // road's device is a composite and not a bare security key.
    // -----------------------------------------------------------------------
    struct StubWrite;

    impl fmt::Write for StubWrite {
        fn write_str(&mut self, _s: &str) -> fmt::Result {
            hint::black_box(Ok(()))
        }
    }

    // -----------------------------------------------------------------------
    // The environment itself, and obligations 5 and 6 hanging off it.
    // -----------------------------------------------------------------------
    struct StubEnv {
        rng: StubRng,
        user_presence: StubUserPresence,
        clock: StubClock,
        customization: CustomizationImpl,
    }

    impl StubEnv {
        fn new() -> Self {
            StubEnv {
                rng: StubRng,
                user_presence: StubUserPresence,
                clock: StubClock,
                // Twenty-one policy decisions, and upstream will make all of
                // them for you. Accepting them is one line; each one is still a
                // decision this device announces to every relying party it
                // meets.
                customization: DEFAULT_CUSTOMIZATION,
            }
        }
    }

    // -----------------------------------------------------------------------
    // Obligation 5 of 6 — Persist: four methods, and a key-value store is all
    // it is.
    //
    // The real one: exp145 already writes flash from firmware into an A/B
    // partition, and exp157 already keeps a note across a reset. Fifty-four
    // CTAP-level operations — credentials, the PIN retry counter, the
    // large-blob array, the signature counter — are built on top of these four
    // by upstream.
    // -----------------------------------------------------------------------
    impl Persist for StubEnv {
        fn find(&self, _key: usize) -> CtapResult<Option<Vec<u8>>> {
            hint::black_box(Ok(None))
        }

        fn insert(&mut self, _key: usize, _value: &[u8]) -> CtapResult<()> {
            hint::black_box(Err(Ctap2StatusCode::CTAP2_ERR_VENDOR_HARDWARE_FAILURE))
        }

        fn remove(&mut self, _key: usize) -> CtapResult<()> {
            hint::black_box(Err(Ctap2StatusCode::CTAP2_ERR_VENDOR_HARDWARE_FAILURE))
        }

        fn iter(&self) -> CtapResult<PersistIter<'_>> {
            // `PersistIter` is a `Box<dyn Iterator>`. The heap again, in the
            // one place a `no_std` firmware would least expect to meet it.
            Ok(Box::new(core::iter::empty()))
        }
    }

    // -----------------------------------------------------------------------
    // Obligation 6 of 6 — HidConnection: two methods.
    //
    // The real one: exp168's CTAPHID over `embassy-usb`'s raw report
    // descriptor, including the 57-and-59-byte packet arithmetic exp128 is
    // about.
    // -----------------------------------------------------------------------
    impl HidConnection for StubEnv {
        fn send(&mut self, _buf: &[u8; 64], _endpoint: UsbEndpoint) -> CtapResult<()> {
            hint::black_box(Ok(()))
        }

        fn recv(&mut self, _buf: &mut [u8; 64], _timeout_ms: usize) -> CtapResult<RecvStatus> {
            hint::black_box(Ok(RecvStatus::Timeout))
        }
    }

    // One empty line, and the whole key store arrives: credential wrapping, the
    // per-credential HMAC secret, PIN hash encryption and decryption — six
    // methods upstream implements for anything that says this. It is the
    // largest single thing the contract gives away for free, and it is worth
    // knowing that it is given away rather than demanded.
    impl KeyStoreHelper for StubEnv {}

    impl Env for StubEnv {
        type Rng = StubRng;
        type UserPresence = StubUserPresence;
        type Persist = Self;
        type KeyStore = Self;
        type Write = StubWrite;
        type Customization = CustomizationImpl;
        type HidConnection = Self;
        type Clock = StubClock;
        type Crypto = SoftwareCrypto;

        fn rng(&mut self) -> &mut Self::Rng {
            &mut self.rng
        }

        fn user_presence(&mut self) -> &mut Self::UserPresence {
            &mut self.user_presence
        }

        fn persist(&mut self) -> &mut Self::Persist {
            self
        }

        fn key_store(&mut self) -> &mut Self::KeyStore {
            self
        }

        fn clock(&mut self) -> &mut Self::Clock {
            &mut self.clock
        }

        fn write(&mut self) -> Self::Write {
            StubWrite
        }

        fn customization(&self) -> &Self::Customization {
            &self.customization
        }

        fn hid_connection(&mut self) -> &mut Self::HidConnection {
            self
        }

        fn boots_after_soft_reset(&self) -> bool {
            hint::black_box(false)
        }
    }

    /// Constructs the engine and hands it one packet.
    ///
    /// A dependency that is never called is one the linker may delete, and a
    /// size measured from a deleted dependency would be a measurement of
    /// nothing. The first version of this file measured exactly that: with
    /// every stub returning a compile-time constant, LTO propagated them
    /// through the whole engine and 23,000 lines of CTAP came out as 1,852
    /// bytes. That is why every stub above answers through
    /// `core::hint::black_box` — a real implementation's answers are not
    /// knowable at compile time, and the stub has to be as unknowable as the
    /// thing it stands in for.
    pub fn exercise() -> usize {
        let mut ctap = Ctap::new(StubEnv::new());
        // Opaque, so that no command handler can be proved unreachable from
        // the bytes of the packet.
        let packet = hint::black_box([0u8; 64]);
        ctap.process_hid_packet(&packet, Transport::MainHid).count()
    }
}

#[entry]
fn main() -> ! {
    // Safety: called once, before anything allocates.
    unsafe {
        let start = &raw mut HEAP_MEMORY as *mut u8;
        HEAP.init(start as usize, HEAP_BYTES)
    }

    #[cfg(feature = "engine")]
    core::hint::black_box(adapter::exercise());

    loop {
        cortex_m::asm::wfi();
    }
}
