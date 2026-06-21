# Pi Zero Espresso HAT Design

Date: 2026-06-21

## Purpose

Design a low-voltage Raspberry Pi Zero 2 W HAT that replaces the current hand-wired espresso machine controller. The board integrates temperature sensing, switch sensing, heater control, future pump control, local status indication, and HAT identification while keeping all mains voltage off the PCB.

## Scope

This revision includes:

- Raspberry Pi Zero 2 W 40-pin HAT-style interface.
- MAX31865 RTD front end.
- 3-wire PT1000 support by default, with jumper/solder-bridge support for PT100.
- Brew switch sense input.
- Steam switch sense input.
- Buffered heater SSR output.
- Buffered future pump-control output.
- Single hardware output-enable switch that disables both actuator outputs.
- Power, output-enable, heater, pump, and fault LEDs.
- HAT EEPROM.
- Pluggable terminal block connectors.

This revision excludes:

- Mains routing.
- Pressure transducer input.
- Pump mains/relay power switching.
- Pi reset button, because reset would require a RUN-pad wire or pogo contact outside the 40-pin HAT interface.
- External power input.

## Safety Model

All machine-facing connections on the HAT are low-voltage only. Mains wiring remains outside the PCB and outside the Pi enclosure.

Actuator outputs must fail off:

- Heater SSR and pump outputs default low when the Pi GPIO is reset, floating, or not configured.
- A physical `OUTPUT_ENABLE` switch forces both actuator outputs off regardless of GPIO state.
- Status LEDs for heater and pump indicate the post-enable output state, not merely the raw GPIO command.
- Firmware should continue forcing `GPIO12` low early in Raspberry Pi boot config. Hardware default-off behavior does not depend on firmware.

The heater SSR is normally open on the mains side and turns the heater on only when its low-voltage input sees 3.3 V across `HEATER_OUT` and `GND`.

## GPIO Map

| Function | GPIO | Physical Pin | Notes |
| --- | ---: | ---: | --- |
| Heater SSR command | GPIO12 / PWM0 | 32 | Existing firmware pin; boot config forces low. |
| Brew switch sense | GPIO27 | 13 | Active-low, external pullup. |
| Steam switch sense | GPIO17 | 11 | Active-low, external pullup. |
| MAX31865 CE | GPIO8 / SPI0 CE0 | 24 | Existing MAX31865 SPI chip select. |
| MAX31865 MISO | GPIO9 / SPI0 MISO | 21 | SPI0. |
| MAX31865 MOSI | GPIO10 / SPI0 MOSI | 19 | SPI0. |
| MAX31865 SCLK | GPIO11 / SPI0 SCLK | 23 | SPI0. |
| Pump command | GPIO5 | 29 | New buffered output. |
| Fault LED | GPIO6 | 31 | New firmware-controlled status LED. |
| HAT EEPROM ID_SD | GPIO0 | 27 | Reserved for EEPROM only. |
| HAT EEPROM ID_SC | GPIO1 | 28 | Reserved for EEPROM only. |

GPIO0 and GPIO1 must not connect to anything except the HAT EEPROM circuit.

## MAX31865 RTD Section

The MAX31865 runs from 3.3 V and connects to SPI0.

Default configuration:

- 3-wire PT1000 probe.
- Precision PT1000 reference resistor path populated by default. Target values are 4.0 kOhm or 4.3 kOhm, selected during schematic capture to match the final MAX31865 configuration.
- RTD terminal supports the current 3-wire probe.

Configurable support:

- PT100 selectable by jumper or solder bridge with the matching reference resistor path. Target values are 400 Ohm or 430 Ohm, selected during schematic capture to match the final MAX31865 configuration.
- Connector has four positions so the board can support 2-wire, 3-wire, or 4-wire probes with appropriate stuffing/jumper configuration.

Layout requirements:

- Place MAX31865, reference resistor network, and RTD connector close together.
- Keep RTD traces away from heater/pump output routing.
- Add local decoupling at the MAX31865 supply pins.
- Clearly label `PT1000` and `PT100` selection on silkscreen.

## Switch Inputs

Brew and steam inputs use identical 3-pin connectors:

- `3V3`
- `SIG`
- `GND`

Current 2-wire mechanical switches use `SIG` and `GND`; the `3V3` pin remains unused.

Each `SIG` line has:

- External pullup to 3.3 V, nominally 10 kOhm.
- Small series resistor into the Pi GPIO.
- Optional capacitor footprint for debounce/noise filtering.

Logic behavior:

- Switch open: `SIG` is pulled high, firmware reads off.
- Switch closed: `SIG` is shorted to `GND`, firmware reads on.

This matches the current active-low firmware behavior.

## Actuator Outputs

Heater and pump outputs are buffered, non-inverting, and gated by `OUTPUT_ENABLE`.

Logic behavior:

- GPIO high and `OUTPUT_ENABLE` on: output high/on.
- GPIO low, reset, floating, or `OUTPUT_ENABLE` off: output low/off.

The preferred buffer/gate circuit is a small 3.3 V non-inverting tri-state buffer or equivalent logic gate. The `OUTPUT_ENABLE` switch controls the gate enable, and output pulldowns force the external outputs low when the gate is disabled. The exact part is selected during schematic capture.

Required behavior:

- Hardware pulldowns define off states.
- External connectors do not expose raw Pi GPIO pins.
- Heater and pump LEDs show the actual post-enable output state.
- Test points are provided for raw command and/or final output where useful.

### Heater SSR Output

Connector: 2-pin pluggable terminal block.

- `HEATER_OUT`
- `GND`

The SSR input is currently wired with one side to ground and one side driven high. `HEATER_OUT` provides the buffered 3.3 V command signal.

### Pump Control Output

Connector: 3-pin pluggable terminal block.

- `3V3`
- `PUMP_OUT`
- `GND`

`PUMP_OUT` is a buffered 3.3 V command signal for a future pump relay/module. The `3V3` pin is for low-current logic use only and must be labeled with an appropriate current limit once the buffer and connector ratings are selected.

## Indicators And Controls

LEDs:

- `PWR`: 3.3 V power present.
- `OUTPUT_ENABLE` or `ARMED`: actuator outputs enabled.
- `HEATER`: final heater output is high.
- `PUMP`: final pump output is high.
- `FAULT`: firmware-controlled fault/status indicator on GPIO6.

Control:

- One physical `OUTPUT_ENABLE` switch gates both heater and pump outputs.
- No reset button in this revision.

## Connectors

Use 3.5 mm pitch pluggable terminal blocks by default, placed along one service edge.

Required connector set:

| Connector | Pins | Signals |
| --- | ---: | --- |
| RTD | 4 | RTD wiring for 2/3/4-wire MAX31865 support. |
| BREW_SW | 3 | `3V3`, `SIG`, `GND`. |
| STEAM_SW | 3 | `3V3`, `SIG`, `GND`. |
| HEATER_SSR | 2 | `HEATER_OUT`, `GND`. |
| PUMP_CTRL | 3 | `3V3`, `PUMP_OUT`, `GND`. |

Silkscreen must clearly label every connector pin. For switch inputs, include a note if space allows: `2-wire switch: SIG-GND`.

## Mechanical And Layout

The board should align with the Raspberry Pi Zero 2 W 40-pin header and mounting holes. It may extend slightly beyond the Pi Zero outline to provide a service edge for terminal blocks and a future custom case.

Layout guidance:

- Put terminal blocks on one edge.
- Put MAX31865 and RTD circuitry near the RTD connector.
- Keep RTD routing away from actuator outputs.
- Put `OUTPUT_ENABLE`, actuator LEDs, and output circuitry near heater/pump connectors.
- Keep test points accessible when the HAT is installed.
- Use clear silkscreen labels for GPIO function, connector names, polarity, and output-enable state.

## HAT EEPROM

Include and populate the HAT EEPROM by default.

Requirements:

- Connect EEPROM only to ID EEPROM pins `ID_SD` and `ID_SC`.
- Do not use GPIO0/GPIO1 for any other function.
- Include write-protect arrangement according to the Raspberry Pi HAT/HAT+ guidance.
- EEPROM contents can be programmed later with board identity and GPIO metadata.

## Firmware Impact

Existing firmware-aligned behavior:

- Heater remains on GPIO12/PWM0.
- Brew switch remains GPIO27 active-low.
- Steam switch remains GPIO17 active-low.
- MAX31865 remains on SPI0 CE0.
- Boot config should keep `gpio=12=op,dl` or equivalent early-low behavior.

New firmware work needed later:

- Add pump output support on GPIO5.
- Add fault LED support on GPIO6.
- Optionally expose output-enable state to firmware in a future revision if a spare input is assigned. This revision does not require software visibility into `OUTPUT_ENABLE`.

## Open Implementation Choices

These choices are intentionally left for schematic capture, because they depend on KiCad library availability, assembler parts, and preferred vendors:

- Exact MAX31865 reference resistor values and jumper topology.
- Exact buffer/gate implementation.
- Exact pluggable terminal block series.
- Exact LED current values and footprints.
- Whether debounce capacitors are populated by default or left as DNP footprints.

## References

- Raspberry Pi HAT+ Specification: https://datasheets.raspberrypi.com/hat/hat-plus-specification.pdf
- Raspberry Pi Zero 2 W Product Brief: https://datasheets.raspberrypi.com/rpizero2/raspberry-pi-zero-2-w-product-brief.pdf
- MAX31865 Datasheet: https://www.analog.com/media/en/technical-documentation/data-sheets/max31865.pdf
