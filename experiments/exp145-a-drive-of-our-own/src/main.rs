//! exp145 — a drive of our own, and the write the ROM's drive would not take.
//!
//! [exp144](../../exp144-one-file-either-half/) found the shape of the problem:
//! the ROM knows exactly which half of an A/B pair a dropped file belongs in and
//! will say so to anyone who asks — and its own BOOTSEL drive refuses the file
//! outright once a partition table exists. So the last item on the update road
//! is the control the road was always going to end at: serve the volume
//! ourselves, and do the thing the ROM declined to do.
//!
//! What this firmware is: an ordinary application, running from one half of an
//! A/B pair, that also presents a small FAT12 volume. Drop a `.uf2` on it and it
//! writes the image into the **other** half and reboots; the ROM then boots
//! whichever half has the higher version, which is exp142's result doing the
//! rest of the work.
//!
//! # Three sectors of filesystem, and nothing else kept
//!
//! The volume declares [`DISK_BLOCKS`] blocks but stores
//! [`fat12::METADATA_SECTORS`] of them — the boot sector, the FAT and the root
//! directory. Every other sector the host writes is looked at, and dropped:
//! if it is a UF2 block its 256-byte payload is copied into the staging buffer
//! at the address the block names, and the sector itself is not stored anywhere.
//! A device that only wants to *receive* a file does not need a disk. It needs
//! enough of a filesystem for the host to agree to write into it.
//!
//! # Knowing when the file is complete without being told
//!
//! Nothing tells a mass-storage device that a file was closed —
//! [exp137](../../exp137-the-volume-that-changes/) is the record of how little a
//! host will tell you. UF2 does not need it to: every block carries `blockNo`
//! and `numBlocks`, so the last missing block announces itself. That is the
//! whole completion protocol, and it is in the file format rather than in the
//! transport.

#![no_std]
#![no_main]

use core::sync::atomic::{AtomicU32, Ordering};

use embassy_executor::Spawner;
use embassy_futures::select::{select, Either};
use embassy_rp::bind_interrupts;
use embassy_rp::block::{item_generic_2bs, item_image_type_exe, Architecture, Block, Security, ITEM_1BS_VERSION};
use embassy_rp::flash::{Blocking, Flash};
use embassy_rp::gpio::{Level, Output};
use embassy_rp::peripherals::{FLASH, USB};
use embassy_rp::rom_data;
use embassy_rp::usb::{Driver, Endpoint, In, InterruptHandler, Out};
use embassy_time::{Duration, Timer};
use embassy_usb::class::cdc_acm::{CdcAcmClass, ControlChanged, Receiver, Sender, State};
use embassy_usb::driver::{Endpoint as _, EndpointIn, EndpointOut};
use embassy_usb::{Builder, Config as UsbConfig, UsbDevice};
use panic_halt as _;
use rp2350_linker as _;
use static_cell::StaticCell;
use usb_log::log;

include!(concat!(env!("OUT_DIR"), "/exp145_config.rs"));

/// exp142's versioned IMAGE_DEF. The version is the whole handover: this
/// firmware writes a newer one into the other half and reboots, and the ROM
/// does the choosing.
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
const IDLE_REPORT: Duration = Duration::from_secs(5);

const CLASS_MSC: u8 = 0x08;
const SUBCLASS_SCSI: u8 = 0x06;
const PROTOCOL_BOT: u8 = 0x50;

const CBW_SIGNATURE: u32 = 0x4342_5355;
const CSW_SIGNATURE: u32 = 0x5342_5355;
const CBW_LEN: usize = 31;
const CSW_LEN: usize = 13;
const CBW_FLAG_IN: u8 = 0x80;

const CSW_GOOD: u8 = 0x00;
const CSW_FAILED: u8 = 0x01;

const BLOCK: usize = 512;

/// The volume's declared size: 128 KiB, which holds a `.uf2` of this
/// repository's firmwares (~46 KiB) with room for the host to be clumsy.
///
/// Declared, not stored. One 512-byte FAT12 table addresses about 341 clusters,
/// so this is also near the largest volume `crates/fat12` can honestly describe.
const DISK_BLOCKS: u32 = 256;

/// Where the staged image is assembled: one A/B slot's worth, 64 KiB.
const STAGE_BYTES: usize = 64 * 1024;

/// Flash, as `embassy-rp`'s driver wants it declared. A Pico 2 has 4 MiB.
const FLASH_SIZE: usize = 4 * 1024 * 1024;

const XIP_BASE: u32 = 0x1000_0000;
const SECTOR_BYTES: u32 = 4096;
const FAMILY_RP2350_ARM_S: u32 = 0xe48b_ff59;

const UF2_MAGIC0: u32 = 0x0a32_4655;
const UF2_MAGIC1: u32 = 0x9e5d_5157;
const UF2_MAGIC_END: u32 = 0x0ab1_6f30;
const UF2_FLAG_FAMILY: u32 = 0x0000_2000;

/// `get_partition_table_info` flags, as exp144 measured them.
const PT_LOCATION_AND_FLAGS: u32 = 0x0010;
const PT_SINGLE_PARTITION: u32 = 0x8000;

const SENSE_ILLEGAL_REQUEST: u32 = 0x05;
const ASC_INVALID_COMMAND: u32 = 0x20;
const ASC_LBA_OUT_OF_RANGE: u32 = 0x21;

static SENSE_KEY: AtomicU32 = AtomicU32::new(0);
static SENSE_ASC: AtomicU32 = AtomicU32::new(0);
static COMMANDS: AtomicU32 = AtomicU32::new(0);
static SECTORS_SEEN: AtomicU32 = AtomicU32::new(0);
static BLOCKS_TAKEN: AtomicU32 = AtomicU32::new(0);

/// Scratch for the ROM calls that parse the partition table.
#[repr(C, align(4096))]
struct Workarea([u8; 4096]);
static mut WORKAREA: Workarea = Workarea([0; 4096]);
fn workarea() -> *mut u8 {
    core::ptr::addr_of_mut!(WORKAREA) as *mut u8
}

fn le_u32(b: &[u8]) -> u32 {
    u32::from_le_bytes([b[0], b[1], b[2], b[3]])
}
fn be_u32(b: &[u8]) -> u32 {
    u32::from_be_bytes([b[0], b[1], b[2], b[3]])
}
fn be_u16(b: &[u8]) -> u16 {
    u16::from_be_bytes([b[0], b[1]])
}
fn first_sector(location: u32) -> u32 {
    location & 0x1fff
}
fn last_sector(location: u32) -> u32 {
    (location >> 13) & 0x1fff
}

/// One UF2 block, reduced to what a receiver needs.
struct Uf2Block {
    target: u32,
    payload: (usize, usize),
    block_no: u32,
    num_blocks: u32,
}

/// Is this 512-byte sector a UF2 block for this chip?
///
/// Three magic words, not one. The end marker is what makes a half-written or
/// mis-sized sector recognisable as not-a-block, and the family check is what
/// keeps somebody else's firmware out of this board's flash.
fn parse_uf2(sector: &[u8]) -> Option<Uf2Block> {
    if sector.len() < BLOCK {
        return None;
    }
    if le_u32(&sector[0..4]) != UF2_MAGIC0
        || le_u32(&sector[4..8]) != UF2_MAGIC1
        || le_u32(&sector[508..512]) != UF2_MAGIC_END
    {
        return None;
    }
    let flags = le_u32(&sector[8..12]);
    if flags & UF2_FLAG_FAMILY == 0 || le_u32(&sector[28..32]) != FAMILY_RP2350_ARM_S {
        return None;
    }
    let len = le_u32(&sector[16..20]) as usize;
    if len == 0 || len > 476 {
        return None;
    }
    Some(Uf2Block {
        target: le_u32(&sector[12..16]),
        payload: (32, 32 + len),
        block_no: le_u32(&sector[20..24]),
        num_blocks: le_u32(&sector[24..28]),
    })
}

/// The image being assembled out of the blocks as they arrive.
struct Staging {
    bytes: &'static mut [u8; STAGE_BYTES],
    /// One bit per `blockNo`, so a host that writes a sector twice — and they
    /// do — does not count it twice.
    seen: [u32; 32],
    taken: u32,
    expect: u32,
    /// The highest offset any block reached, which decides how much flash to
    /// erase. Erasing a whole slot for a 23 KiB image is slower and no safer.
    end: usize,
    /// Set once every block has arrived. The transfer is finished; nothing on
    /// the wire said so.
    complete: bool,
}

impl Staging {
    fn reset(&mut self) {
        self.seen = [0; 32];
        self.taken = 0;
        self.expect = 0;
        self.end = 0;
        self.complete = false;
    }

    fn accept(&mut self, sector: &[u8]) -> bool {
        let Some(b) = parse_uf2(sector) else { return false };
        if b.target < XIP_BASE {
            return false;
        }
        let at = (b.target - XIP_BASE) as usize;
        let len = b.payload.1 - b.payload.0;
        if at + len > STAGE_BYTES {
            return false;
        }
        // A repeat of a block already taken is not an error and not news.
        let word = (b.block_no / 32) as usize;
        let bit = 1u32 << (b.block_no % 32);
        if word >= self.seen.len() {
            return false;
        }
        self.bytes[at..at + len].copy_from_slice(&sector[b.payload.0..b.payload.1]);
        self.end = self.end.max(at + len);
        if self.seen[word] & bit == 0 {
            self.seen[word] |= bit;
            self.taken += 1;
            self.expect = b.num_blocks;
            BLOCKS_TAKEN.store(self.taken, Ordering::Relaxed);
        }
        if self.expect > 0 && self.taken >= self.expect {
            self.complete = true;
        }
        true
    }
}

/// Where the ROM says a dropped file belongs, and what is running now.
struct Route {
    target_location: u32,
    running: i32,
    running_location: u32,
}

fn ask_the_rom() -> Route {
    let mut target = [0u32; 2];
    let rc =
        unsafe { rom_data::get_uf2_target_partition(workarea(), 4096, FAMILY_RP2350_ARM_S, target.as_mut_ptr()) };
    let running = unsafe { rom_data::pick_ab_parition(workarea(), 4096, 0) };

    let mut running_location = 0;
    if running >= 0 {
        let mut buf = [0u32; 8];
        let flags = PT_SINGLE_PARTITION | PT_LOCATION_AND_FLAGS | ((running as u32) << 24);
        let n = unsafe { rom_data::get_partition_table_info(buf.as_mut_ptr(), buf.len(), flags) };
        if n >= 3 {
            running_location = buf[1];
        }
    }

    Route {
        target_location: if rc >= 0 { target[0] } else { 0 },
        running,
        running_location,
    }
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
async fn console_task(
    control: ControlChanged<'static>,
    mut receiver: Receiver<'static, usb_reboot::UsbDriver>,
) -> ! {
    let mut buf = [0u8; PACKET];
    loop {
        match select(control.control_changed(), receiver.read_packet(&mut buf)).await {
            Either::First(()) => {
                usb_reboot::reboot_if_requested(receiver.line_coding().data_rate()).await;
            }
            Either::Second(_) => {}
        }
    }
}

fn set_sense(key: u32, asc: u32) {
    SENSE_KEY.store(key, Ordering::Relaxed);
    SENSE_ASC.store(asc, Ordering::Relaxed);
}

fn inquiry(out: &mut [u8]) -> usize {
    out[..36].fill(0);
    out[1] = 0x80; // removable
    out[2] = 0x02;
    out[3] = 0x02;
    out[4] = 31;
    out[8..16].copy_from_slice(b"yi26    ");
    out[16..32].copy_from_slice(b"exp145 updater  ");
    out[32..36].copy_from_slice(b"0001");
    36
}

fn request_sense(out: &mut [u8]) -> usize {
    out[..18].fill(0);
    out[0] = 0x70;
    out[2] = SENSE_KEY.load(Ordering::Relaxed) as u8;
    out[7] = 10;
    out[12] = SENSE_ASC.load(Ordering::Relaxed) as u8;
    18
}

fn read_capacity(out: &mut [u8]) -> usize {
    out[0..4].copy_from_slice(&(DISK_BLOCKS - 1).to_be_bytes());
    out[4..8].copy_from_slice(&(BLOCK as u32).to_be_bytes());
    8
}

fn mode_sense6(out: &mut [u8]) -> usize {
    out[..4].fill(0);
    out[0] = 3;
    4
}

/// Write the staged image into the half that is not running, and hand over.
///
/// Everything dangerous in this experiment is in this function, so it checks
/// before it erases: the ROM has to have named a target, the target must not be
/// the partition this code is executing from, and the image must fit inside it.
/// Any of those failing is a log line and no flash write at all.
fn install(flash: &mut Flash<'static, FLASH, Blocking, FLASH_SIZE>, stage: &Staging) -> bool {
    let route = ask_the_rom();
    if route.target_location == 0 {
        log!("install refused: the ROM named no target partition for this family");
        return false;
    }
    if route.target_location == route.running_location {
        log!("install refused: the target IS the running half (partition {})", route.running);
        return false;
    }

    let first = first_sector(route.target_location);
    let last = last_sector(route.target_location);
    let slot_bytes = (last + 1 - first) * SECTOR_BYTES;
    let span = (stage.end as u32).div_ceil(SECTOR_BYTES) * SECTOR_BYTES;
    if span > slot_bytes {
        log!("install refused: {} bytes into a {} byte slot", span, slot_bytes);
        return false;
    }

    // Flash offsets, not XIP addresses — `embassy-rp`'s driver says so in its
    // own doc comment, and getting it wrong here writes 0x10000000 bytes into
    // the wrong place.
    let offset = first * SECTOR_BYTES;
    log!("installing {} bytes into partition sectors {}..{}", stage.end, first, last);
    log!("  erase {:#x}..{:#x}, then program", offset, offset + span);

    if let Err(_e) = flash.blocking_erase(offset, offset + span) {
        log!("  erase failed");
        return false;
    }
    if let Err(_e) = flash.blocking_write(offset, &stage.bytes[..span as usize]) {
        log!("  program failed — that half is now erased, and the running one is not");
        return false;
    }
    log!("  written. Rebooting; the ROM boots whichever half has the higher version.");
    true
}

/// Serves the volume, watches what is written into it, and installs.
#[embassy_executor::task]
async fn storage_task(
    mut read_ep: Endpoint<'static, USB, Out>,
    mut write_ep: Endpoint<'static, USB, In>,
    meta: &'static mut [u8; fat12::METADATA_BYTES],
    mut stage: Staging,
    mut flash: Flash<'static, FLASH, Blocking, FLASH_SIZE>,
) -> ! {
    let mut buf = [0u8; PACKET];
    let mut reply = [0u8; 64];
    let mut sector = [0u8; BLOCK];

    loop {
        read_ep.wait_enabled().await;

        loop {
            let n = match read_ep.read(&mut buf).await {
                Ok(n) => n,
                Err(_) => break,
            };
            if n != CBW_LEN || le_u32(&buf[0..4]) != CBW_SIGNATURE {
                continue;
            }

            let tag = le_u32(&buf[4..8]);
            let want = le_u32(&buf[8..12]);
            let _to_host = buf[12] & CBW_FLAG_IN != 0;
            let cb = [
                buf[15], buf[16], buf[17], buf[18], buf[19], buf[20], buf[21], buf[22], buf[23],
                buf[24],
            ];
            let op = cb[0];
            COMMANDS.fetch_add(1, Ordering::Relaxed);

            let mut status = CSW_GOOD;
            let mut sent: u32 = 0;

            match op {
                0x00 | 0x1b | 0x1e | 0x35 => set_sense(0, 0),

                0x12 => {
                    let len = inquiry(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                }

                0x03 => {
                    let len = request_sense(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                }

                0x25 => {
                    let len = read_capacity(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                }

                0x1a => {
                    let len = mode_sense6(&mut reply).min(want as usize);
                    let _ = write_ep.write(&reply[..len]).await;
                    sent = len as u32;
                    set_sense(0, 0);
                }

                // READ(10): the three stored sectors, and zeros for the rest.
                // A volume nobody reads back still has to answer, because the
                // host reads the filesystem before it will write into it.
                0x28 => {
                    let lba = be_u32(&cb[2..6]);
                    let count = be_u16(&cb[7..9]) as u32;
                    if lba.saturating_add(count) > DISK_BLOCKS {
                        set_sense(SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE);
                        status = CSW_FAILED;
                    } else {
                        for i in 0..count {
                            let at = (lba + i) as usize * BLOCK;
                            if at + BLOCK <= meta.len() {
                                sector.copy_from_slice(&meta[at..at + BLOCK]);
                            } else {
                                sector.fill(0);
                            }
                            for chunk in sector.chunks(PACKET) {
                                if write_ep.write(chunk).await.is_err() {
                                    break;
                                }
                            }
                        }
                        sent = count * BLOCK as u32;
                        set_sense(0, 0);
                    }
                }

                // WRITE(10): the filesystem's own sectors are kept; everything
                // else is read for UF2 blocks and discarded.
                0x2a => {
                    let lba = be_u32(&cb[2..6]);
                    let count = be_u16(&cb[7..9]) as u32;
                    if lba.saturating_add(count) > DISK_BLOCKS {
                        set_sense(SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE);
                        status = CSW_FAILED;
                    } else {
                        for i in 0..count {
                            let mut at = 0;
                            while at < BLOCK {
                                match read_ep.read(&mut buf).await {
                                    Ok(got) => {
                                        let take = got.min(BLOCK - at);
                                        sector[at..at + take].copy_from_slice(&buf[..take]);
                                        at += take.max(1);
                                    }
                                    Err(_) => break,
                                }
                            }
                            SECTORS_SEEN.fetch_add(1, Ordering::Relaxed);
                            let dest = (lba + i) as usize * BLOCK;
                            if dest + BLOCK <= meta.len() {
                                meta[dest..dest + BLOCK].copy_from_slice(&sector);
                            } else {
                                stage.accept(&sector);
                            }
                        }
                        sent = count * BLOCK as u32;
                        set_sense(0, 0);
                    }
                }

                _ => {
                    set_sense(SENSE_ILLEGAL_REQUEST, ASC_INVALID_COMMAND);
                    status = CSW_FAILED;
                }
            }

            let mut csw = [0u8; CSW_LEN];
            csw[0..4].copy_from_slice(&CSW_SIGNATURE.to_le_bytes());
            csw[4..8].copy_from_slice(&tag.to_le_bytes());
            csw[8..12].copy_from_slice(&want.saturating_sub(sent).to_le_bytes());
            csw[12] = status;
            if write_ep.write(&csw).await.is_err() {
                break;
            }

            // Between commands, never inside one: the flash write disables
            // interrupts, so USB stops answering while it runs. Finishing the
            // command first means the host is never left waiting mid-transfer.
            if stage.complete {
                log!("all {} UF2 blocks arrived, {} bytes of image", stage.expect, stage.end);
                let ok = install(&mut flash, &stage);
                stage.reset();
                if ok {
                    Timer::after(Duration::from_millis(1500)).await;
                    rom_data::reboot(0x0 | 0x100, 50, 0, 0); // NORMAL | NO_RETURN
                }
            }
        }
    }
}

#[embassy_executor::task]
async fn idle_task() -> ! {
    Timer::after(Duration::from_secs(3)).await;
    let route = ask_the_rom();
    log!("I am version {}.{}, running partition {}.", VERSION_MAJOR, VERSION_MINOR, route.running);
    if route.target_location != 0 {
        log!(
            "a dropped .uf2 goes to sectors {}..{} — the other half",
            first_sector(route.target_location),
            last_sector(route.target_location)
        );
    } else {
        log!("the ROM names no target partition — is there a table?");
    }
    log!("drop a .uf2 on the DROP-A-UF2 volume and this firmware will install it.");

    // The repeating line carries the whole standing answer — which half is
    // running and which half a drop would go to — because the lines above are
    // said once and usb_log's queue is sixteen deep.
    loop {
        Timer::after(IDLE_REPORT).await;
        log!(
            "idle: v{}.{}, partition {}, drop -> sectors {}..{}, {} blocks taken",
            VERSION_MAJOR,
            VERSION_MINOR,
            route.running,
            first_sector(route.target_location),
            last_sector(route.target_location),
            BLOCKS_TAKEN.load(Ordering::Relaxed)
        );
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);
    let flash = Flash::<_, Blocking, FLASH_SIZE>::new_blocking(p.FLASH);
    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some(concat!("exp145 v", env!("EXP145_VERSION")));
    config.serial_number = Some("145");
    config.device_class = 0xef;
    config.device_sub_class = 0x02;
    config.device_protocol = 0x01;
    config.composite_with_iads = true;

    static CONFIG_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static BOS_DESCRIPTOR: StaticCell<[u8; 256]> = StaticCell::new();
    static CONTROL_BUF: StaticCell<[u8; 64]> = StaticCell::new();
    static ACM_STATE: StaticCell<State> = StaticCell::new();
    static META: StaticCell<[u8; fat12::METADATA_BYTES]> = StaticCell::new();
    static STAGE: StaticCell<[u8; STAGE_BYTES]> = StaticCell::new();

    let mut builder = Builder::new(
        driver,
        config,
        CONFIG_DESCRIPTOR.init([0; 256]),
        BOS_DESCRIPTOR.init([0; 256]),
        &mut [],
        CONTROL_BUF.init([0; 64]),
    );

    let class = CdcAcmClass::new(&mut builder, ACM_STATE.init(State::new()), PACKET as u16);

    let (read_ep, write_ep) = {
        let mut function = builder.function(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT);
        let mut interface = function.interface();
        let mut alt = interface.alt_setting(CLASS_MSC, SUBCLASS_SCSI, PROTOCOL_BOT, None);
        let out = alt.endpoint_bulk_out(None, PACKET as u16);
        let in_ = alt.endpoint_bulk_in(None, PACKET as u16);
        (out, in_)
    };

    let usb = builder.build();
    spawner.spawn(usb_task(usb).unwrap());

    let (sender, receiver, control) = class.split_with_control();
    spawner.spawn(log_task(sender).unwrap());
    spawner.spawn(console_task(control, receiver).unwrap());

    // Three sectors of filesystem, laid out by the same crate exp125 wrote and
    // exp126 and exp131 serve whole volumes from. The label is the instruction:
    // it is the only text a host shows before anything has been dropped.
    let meta = META.init([0u8; fat12::METADATA_BYTES]);
    fat12::format_metadata(meta, DISK_BLOCKS as u16, b"DROP-A-UF2 ");

    let stage = Staging {
        bytes: STAGE.init([0xffu8; STAGE_BYTES]),
        seen: [0; 32],
        taken: 0,
        expect: 0,
        end: 0,
        complete: false,
    };

    spawner.spawn(storage_task(read_ep, write_ep, meta, stage, flash).unwrap());
    spawner.spawn(idle_task().unwrap());

    log!(
        "exp145 up. v{}.{}, serving {} KiB of volume out of {} bytes of filesystem.",
        VERSION_MAJOR,
        VERSION_MINOR,
        DISK_BLOCKS as usize * BLOCK / 1024,
        fat12::METADATA_BYTES
    );

    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
