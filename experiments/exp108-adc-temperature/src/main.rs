//! exp108 — the chip takes its own temperature.
//!
//! Every number in the log so far was one the firmware worked out: a counter,
//! a timestamp, how late a wakeup was. This one comes from outside the
//! program — an analogue voltage, measured.
//!
//! The RP2350 has an on-chip temperature sensor wired to ADC channel 4. It is
//! not a thermometer that reports degrees; it is a diode whose forward voltage
//! falls as it warms, and turning that into a temperature is arithmetic you do
//! yourself, from the datasheet. That arithmetic is the experiment.
//!
//! The classic first ADC task on any microcontroller, and worth doing here
//! because the RP2350 gives you one without wiring anything up.

#![no_std]
#![no_main]

use embassy_executor::Spawner;
use embassy_rp::adc::{
    Adc, Async, Channel, Config as AdcConfig, InterruptHandler as AdcInterruptHandler,
};
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
    ADC_IRQ_FIFO => AdcInterruptHandler;
});

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

/// Turns a raw 12-bit conversion into degrees Celsius.
///
/// This is the whole experiment, and it is three lines because the datasheet
/// does the hard part. The sensor is a diode that reads **0.706 V at 27 °C**
/// and falls about **1.721 mV per degree** as it warms. The ADC reports where
/// that voltage sits across its 3.3 V range, in 4096 steps.
///
/// So: turn the count into volts, measure how far that is from the known
/// point, divide by the slope, and subtract — the sign flips because a
/// *higher* temperature means a *lower* voltage and therefore a *smaller*
/// count.
///
/// One caveat, because it changes what this number is for. Those two constants
/// are *typical* values for the part, not a calibration of the chip in front
/// of you, and the RP2350 datasheet says plainly that absolute accuracy
/// without per-chip calibration is poor. What you can trust is the *change*:
/// warm the chip and the number moves the right way by roughly the right
/// amount. Trusting the absolute value to a degree is the mistake this comment
/// exists to prevent.
fn raw_to_celsius(raw: u16) -> f32 {
    const STEP_VOLTS: f32 = 3.3 / 4096.0;
    let volts = raw as f32 * STEP_VOLTS;
    27.0 - (volts - 0.706) / 0.001_721
}

/// Reads the sensor once a second and reports both numbers.
///
/// Both, not just the temperature — the raw count is what the hardware
/// actually gave you, and the degrees are your arithmetic on top of it. When a
/// reading looks wrong, having both tells you which half is at fault. Printing
/// only the pretty one throws that away.
#[embassy_executor::task]
async fn temperature_task(mut adc: Adc<'static, Async>, mut channel: Channel<'static>) -> ! {
    loop {
        let raw = adc.read(&mut channel).await.unwrap_or(0);
        let c = raw_to_celsius(raw);

        // `log!` has no float formatter — `usb-log` writes into a fixed line
        // buffer with no allocator behind it. Splitting into whole and
        // hundredths keeps the line honest without dragging one in.
        let whole = c as i32;
        let hundredths = ((c - whole as f32) * 100.0) as i32;
        log!("temp: raw {} of 4095 -> {}.{:02} C", raw, whole, hundredths);

        Timer::after(Duration::from_secs(1)).await;
    }
}

#[embassy_executor::main]
async fn main(spawner: Spawner) {
    let p = embassy_rp::init(Default::default());
    let mut led = Output::new(p.PIN_25, Level::Low);

    let driver = Driver::new(p.USB, Irqs);

    let mut config = UsbConfig::new(0x1209, 0x0001);
    config.manufacturer = Some("rp2350-yi26");
    config.product = Some("exp108 adc temperature");
    config.serial_number = Some("108");
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

    log!("exp108 up. Reading ADC channel 4 — the sensor inside the chip.");

    // The ADC and its channel go to one task and nowhere else. Same ownership
    // argument exp107 made about the USB sender: nothing is shared, so there
    // is no lock to forget.
    let adc = Adc::new(p.ADC, Irqs, AdcConfig::default());
    let channel = Channel::new_temp_sensor(p.ADC_TEMP_SENSOR);
    spawner.spawn(temperature_task(adc, channel).unwrap());

    // Liveness for anyone looking at the board instead of the log.
    loop {
        led.set_high();
        Timer::after(Duration::from_millis(50)).await;
        led.set_low();
        Timer::after(Duration::from_millis(950)).await;
    }
}
