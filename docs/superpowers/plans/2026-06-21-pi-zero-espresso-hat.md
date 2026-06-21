# Pi Zero Espresso HAT Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a clean KiCad PCB project for a low-voltage Raspberry Pi Zero 2 W espresso controller HAT.

**Architecture:** Create a new KiCad project instead of repairing the existing experimental folders. The board is divided into clear schematic blocks: Pi/HAT EEPROM, MAX31865 RTD, switch inputs, buffered actuator outputs, indicators, connectors, and mechanical layout. Each task ends with a reviewable KiCad artifact and an ERC/DRC or manual verification checkpoint.

**Tech Stack:** KiCad 7 or newer, Raspberry Pi HAT+ mechanical/electrical guidance, MAX31865, Raspberry Pi Zero 2 W 40-pin header, Phoenix Contact MC 1,5 pluggable terminal blocks at 3.5 mm pitch or footprint-compatible equivalent, SN74LVC2G126 dual non-inverting tri-state buffer, Elixir/Nerves firmware pin map.

## Global Constraints

- All machine-facing connections on the HAT are low-voltage only.
- No mains voltage is routed on the PCB.
- The PCB receives power from the Raspberry Pi header only.
- The board aligns with Raspberry Pi Zero 2 W header and mounting holes.
- The board may extend beyond the Pi Zero outline for terminal blocks and case serviceability.
- GPIO0/GPIO1 are reserved exclusively for the HAT EEPROM.
- Heater SSR output uses GPIO12/PWM0 and must default off in hardware.
- Brew switch input uses GPIO27 and is active-low.
- Steam switch input uses GPIO17 and is active-low.
- MAX31865 uses SPI0 CE0/MISO/MOSI/SCLK on GPIO8/GPIO9/GPIO10/GPIO11.
- Pump output uses GPIO5 and must default off in hardware.
- Fault LED uses GPIO6.
- Heater and pump outputs are buffered, non-inverting, and gated by one physical `OUTPUT_ENABLE` switch.
- Status LEDs for heater and pump indicate the final post-enable output state.
- The HAT EEPROM is populated by default.
- Pressure transducer hardware is excluded from this revision.
- Pi reset button is excluded from this revision.

---

## File Structure

- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pro`
  - Clean KiCad project root for this PCB.
- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
  - Top-level schematic containing all design blocks.
- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`
  - PCB layout, board outline, footprints, routing, silkscreen, design rules.
- Create: `hardware/pi_zero_espresso_hat/symbols/pi_zero_espresso_hat.kicad_sym`
  - Project-local symbols only when the KiCad standard library lacks a needed part.
- Create: `hardware/pi_zero_espresso_hat/footprints/pi_zero_espresso_hat.pretty/`
  - Project-local footprints only when the KiCad standard library lacks a needed footprint.
- Create: `hardware/pi_zero_espresso_hat/fab/`
  - Gerbers, drill files, position files, BOM, and ERC/DRC reports generated after the board passes checks.
- Modify: `README.md`
  - Add a short pointer to the new hardware project and the design spec.

Do not delete or rewrite `expresso_hat/` or `ExpressoHat/` during this plan. They are old reference material and untracked user work.

---

### Task 1: Create Clean KiCad Project Skeleton

**Files:**
- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pro`
- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Create: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`
- Create: `hardware/pi_zero_espresso_hat/symbols/pi_zero_espresso_hat.kicad_sym`
- Create: `hardware/pi_zero_espresso_hat/footprints/pi_zero_espresso_hat.pretty/`

**Interfaces:**
- Consumes: design spec at `docs/superpowers/specs/2026-06-21-pi-zero-espresso-hat-design.md`
- Produces: KiCad project files used by all later tasks.

- [ ] **Step 1: Create the new hardware directory**

Run:

```bash
mkdir -p hardware/pi_zero_espresso_hat/symbols hardware/pi_zero_espresso_hat/footprints/pi_zero_espresso_hat.pretty hardware/pi_zero_espresso_hat/fab
```

Expected: directories exist under `hardware/pi_zero_espresso_hat/`.

- [ ] **Step 2: Create a new KiCad project**

Open KiCad and create a project named `pi_zero_espresso_hat` in `hardware/pi_zero_espresso_hat/`.

Expected files:

```text
hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pro
hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch
hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb
```

- [ ] **Step 3: Configure project-local libraries**

In KiCad project settings, add:

```text
Symbol library: hardware/pi_zero_espresso_hat/symbols/pi_zero_espresso_hat.kicad_sym
Footprint library: hardware/pi_zero_espresso_hat/footprints/pi_zero_espresso_hat.pretty
```

Expected: the project opens without missing library warnings.

- [ ] **Step 4: Add project metadata**

Set schematic and PCB title block:

```text
Title: Pi Zero Espresso HAT
Revision: A
Company: Expresso
Date: 2026-06-21
```

Expected: schematic and PCB title blocks show the same metadata.

- [ ] **Step 5: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Add clean espresso HAT KiCad project"
```

Expected: commit contains only the new KiCad project skeleton.

---

### Task 2: Add Pi Header, HAT EEPROM, Power Rails, And Mechanical Outline

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: empty KiCad project from Task 1.
- Produces: Pi-facing electrical/mechanical base used by all functional blocks.

- [ ] **Step 1: Add 40-pin Pi header symbol**

Add a 2x20 Raspberry Pi GPIO header symbol or a generic 2x20 odd/even connector with pin names matching the Pi header.

Required nets:

```text
3V3
5V
GND
GPIO0_ID_SD
GPIO1_ID_SC
GPIO5_PUMP_CMD
GPIO6_FAULT_LED
GPIO8_SPI0_CE0
GPIO9_SPI0_MISO
GPIO10_SPI0_MOSI
GPIO11_SPI0_SCLK
GPIO12_HEATER_PWM
GPIO17_STEAM_SW
GPIO27_BREW_SW
```

Expected: every used Pi pin has a clear net label.

- [ ] **Step 2: Add HAT EEPROM circuit**

Add a 24C32-compatible 3.3 V I2C EEPROM connected only to `GPIO0_ID_SD` and `GPIO1_ID_SC`.

Required connections:

```text
EEPROM VCC -> 3V3
EEPROM GND -> GND
EEPROM SDA -> GPIO0_ID_SD
EEPROM SCL -> GPIO1_ID_SC
EEPROM WP -> write-protect jumper or solder bridge
```

Add 3.9 kOhm pullups on the ID EEPROM bus according to the Raspberry Pi HAT/HAT+ specification.

Expected: GPIO0/GPIO1 do not connect to any non-EEPROM circuitry.

- [ ] **Step 3: Add power rail protection and decoupling**

Add schematic symbols and footprints for:

```text
3V3 decoupling bulk capacitor: 10 uF
3V3 local capacitor near EEPROM: 100 nF
3V3 local capacitor near future logic buffer area: 100 nF
PWR LED with current-limiting resistor from 3V3 to GND
```

Expected: power LED is connected to 3V3, and each IC area has a local 100 nF decoupling capacitor.

- [ ] **Step 4: Create PCB outline**

In `pi_zero_espresso_hat.kicad_pcb`, create an Edge.Cuts outline that:

```text
Aligns the 40-pin header with the Pi Zero 2 W header.
Aligns the Pi Zero mounting holes.
Extends on one side for the service-edge terminal blocks.
Leaves room for a custom enclosure cable exit.
```

Expected: the PCB outline is larger than the Pi Zero only on the service edge.

- [ ] **Step 5: Place fixed mechanical parts**

Place:

```text
40-pin female header footprint
Four Pi Zero mounting holes
HAT EEPROM near GPIO0/GPIO1 routing
Power LED in visible area
```

Expected: header and mounting holes match the Raspberry Pi Zero 2 W mechanical drawing.

- [ ] **Step 6: Run schematic ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/task-2-erc.rpt
```

Expected: no ERC errors. Warnings are acceptable only if documented in a note on the schematic.

- [ ] **Step 7: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Add Pi HAT base and EEPROM"
```

Expected: commit contains Pi header, HAT EEPROM, rails, outline, and fixed mechanical placement.

---

### Task 3: Add MAX31865 RTD Section

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: SPI0 nets and 3V3/GND from Task 2.
- Produces: RTD temperature measurement block used by firmware.

- [ ] **Step 1: Add MAX31865 schematic block**

Add MAX31865 with these nets:

```text
VDD -> 3V3
GND -> GND
SDI -> GPIO10_SPI0_MOSI
SDO -> GPIO9_SPI0_MISO
SCLK -> GPIO11_SPI0_SCLK
CS -> GPIO8_SPI0_CE0
RTD pins -> RTD connector and reference network
```

Expected: SPI net names match the GPIO map exactly.

- [ ] **Step 2: Add RTD connector**

Add a 4-pin 3.5 mm pluggable terminal block footprint and label pins for flexible RTD wiring.

Use schematic labels:

```text
RTD_FORCE+
RTD_SENSE+
RTD_SENSE-
RTD_FORCE-
```

Expected: current 3-wire PT1000 wiring can connect without bodge wires, and 2/4-wire options are possible by jumper/stuffing options.

- [ ] **Step 3: Add PT100/PT1000 reference selection**

Add selectable reference resistor paths:

```text
PT1000_REF: 4.30 kOhm 0.1% precision resistor footprint
PT100_REF: 430 Ohm 0.1% precision resistor footprint
Selection: solder bridge or 3-pin jumper labeled PT1000/PT100
Default silkscreen: PT1000
```

Expected: only one reference path can be selected at a time.

- [ ] **Step 4: Add local MAX31865 decoupling**

Place:

```text
100 nF capacitor at MAX31865 VDD
1 uF capacitor near MAX31865 VDD
```

Expected: capacitors are close to the MAX31865 power pins in PCB placement.

- [ ] **Step 5: Place RTD analog block**

On the PCB, place:

```text
RTD connector on service edge
MAX31865 close to RTD connector
Reference resistors close to MAX31865
PT100/PT1000 selection label visible near selector
```

Expected: RTD traces do not run near heater/pump output traces.

- [ ] **Step 6: Run schematic ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/task-3-erc.rpt
```

Expected: no ERC errors. Warnings are acceptable only if documented in a note on the schematic.

- [ ] **Step 7: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Add MAX31865 RTD front end"
```

Expected: commit contains the complete temperature-sensing schematic block and initial placement.

---

### Task 4: Add Brew And Steam Switch Inputs

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: `GPIO27_BREW_SW`, `GPIO17_STEAM_SW`, `3V3`, and `GND` from Task 2.
- Produces: active-low switch inputs matching current firmware.

- [ ] **Step 1: Add brew switch connector**

Add a 3-pin 3.5 mm pluggable terminal block:

```text
Pin 1: 3V3
Pin 2: BREW_SIG
Pin 3: GND
```

Connect:

```text
BREW_SIG -> 10 kOhm pullup to 3V3
BREW_SIG -> 220 Ohm series resistor -> GPIO27_BREW_SW
BREW_SIG -> optional debounce capacitor footprint to GND
```

Expected: a 2-wire switch connected between `BREW_SIG` and `GND` reads active-low.

- [ ] **Step 2: Add steam switch connector**

Add a 3-pin 3.5 mm pluggable terminal block:

```text
Pin 1: 3V3
Pin 2: STEAM_SIG
Pin 3: GND
```

Connect:

```text
STEAM_SIG -> 10 kOhm pullup to 3V3
STEAM_SIG -> 220 Ohm series resistor -> GPIO17_STEAM_SW
STEAM_SIG -> optional debounce capacitor footprint to GND
```

Expected: a 2-wire switch connected between `STEAM_SIG` and `GND` reads active-low.

- [ ] **Step 3: Add switch input silkscreen**

Add silkscreen labels:

```text
BREW_SW: 3V3 SIG GND
STEAM_SW: 3V3 SIG GND
2-wire switches use SIG-GND
```

Expected: switch wiring is clear without opening the schematic.

- [ ] **Step 4: Place switch connectors**

Place both switch connectors on the service edge near each other.

Expected: connector order is readable and leaves room for terminal plugs.

- [ ] **Step 5: Run schematic ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/task-4-erc.rpt
```

Expected: no ERC errors.

- [ ] **Step 6: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Add brew and steam switch inputs"
```

Expected: commit contains switch input connectors, pullups, protection resistors, optional debounce footprints, and placement.

---

### Task 5: Add Buffered Heater And Pump Outputs With Output Enable

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: `GPIO12_HEATER_PWM`, `GPIO5_PUMP_CMD`, `3V3`, and `GND`.
- Produces: default-off actuator outputs gated by `OUTPUT_ENABLE`.

- [ ] **Step 1: Select output gate topology**

Use this non-inverting 3.3 V topology:

```text
SN74LVC2G126 dual non-inverting tri-state buffer.
Both OE pins are driven by OUTPUT_ENABLE_LOGIC.
Each GPIO command input has a 100 kOhm pulldown to GND.
Each external output has a 10 kOhm pulldown to GND.
```

Required behavior:

```text
GPIO high + OUTPUT_ENABLE on -> external output high.
GPIO low -> external output low.
GPIO floating/reset -> external output low.
OUTPUT_ENABLE off -> external output low.
```

Expected: the buffer is non-inverting, disabled when `OUTPUT_ENABLE_LOGIC` is low, and has explicit hardware pulldowns on command inputs and external outputs.

- [ ] **Step 2: Add `OUTPUT_ENABLE` switch**

Add a physical switch that generates `OUTPUT_ENABLE_LOGIC`.

Connect:

```text
OUTPUT_ENABLE_LOGIC -> 10 kOhm pulldown to GND
OUTPUT_ENABLE switch ON -> 3V3
OUTPUT_ENABLE switch OFF -> pulldown holds disabled state
```

Expected: outputs are disabled by default when the switch is off or absent.

- [ ] **Step 3: Add heater output**

Connect:

```text
GPIO12_HEATER_PWM -> buffer/gate input
OUTPUT_ENABLE_LOGIC -> buffer/gate enable path
buffer/gate heater output -> HEATER_OUT
HEATER_OUT -> 10 kOhm pulldown to GND
HEATER_OUT -> heater LED current-limiting resistor -> LED -> GND
```

Add a 2-pin 3.5 mm pluggable terminal block:

```text
Pin 1: HEATER_OUT
Pin 2: GND
```

Expected: the heater SSR connector never exposes raw GPIO12.

- [ ] **Step 4: Add pump output**

Connect:

```text
GPIO5_PUMP_CMD -> buffer/gate input
OUTPUT_ENABLE_LOGIC -> buffer/gate enable path
buffer/gate pump output -> PUMP_OUT
PUMP_OUT -> 10 kOhm pulldown to GND
PUMP_OUT -> pump LED current-limiting resistor -> LED -> GND
```

Add a 3-pin 3.5 mm pluggable terminal block:

```text
Pin 1: 3V3
Pin 2: PUMP_OUT
Pin 3: GND
```

Expected: the pump connector provides low-current 3.3 V logic power plus a buffered output signal.

- [ ] **Step 5: Add armed LED**

Connect:

```text
OUTPUT_ENABLE_LOGIC -> current-limiting resistor -> ARMED LED -> GND
```

Expected: `ARMED` LED is on only when actuator outputs are enabled.

- [ ] **Step 6: Add test points**

Add test points:

```text
TP_HEATER_CMD: GPIO12_HEATER_PWM
TP_HEATER_OUT: HEATER_OUT
TP_PUMP_CMD: GPIO5_PUMP_CMD
TP_PUMP_OUT: PUMP_OUT
TP_OUTPUT_ENABLE: OUTPUT_ENABLE_LOGIC
```

Expected: raw command and final output can be measured independently.

- [ ] **Step 7: Place output block**

On PCB, place:

```text
OUTPUT_ENABLE switch near output connectors
HEATER_SSR connector on service edge
PUMP_CTRL connector on service edge
HEATER, PUMP, and ARMED LEDs visible near their circuits
```

Expected: actuator traces are grouped and do not cross the RTD analog area.

- [ ] **Step 8: Run schematic ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/task-5-erc.rpt
```

Expected: no ERC errors.

- [ ] **Step 9: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Add gated buffered actuator outputs"
```

Expected: commit contains output-enable switch, heater output, pump output, LEDs, test points, and placement.

---

### Task 6: Add Fault LED, Silkscreen, And README Pointer

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`
- Modify: `README.md`

**Interfaces:**
- Consumes: `GPIO6_FAULT_LED`, connector names, and board functions from prior tasks.
- Produces: local diagnostics and repo-level discoverability.

- [ ] **Step 1: Add fault LED**

Connect:

```text
GPIO6_FAULT_LED -> current-limiting resistor -> FAULT LED -> GND
```

Expected: GPIO6 high turns the fault LED on.

- [ ] **Step 2: Add connector pin silkscreen**

Add silkscreen labels exactly:

```text
RTD
BREW_SW 3V3 SIG GND
STEAM_SW 3V3 SIG GND
HEATER_SSR OUT GND
PUMP_CTRL 3V3 OUT GND
```

Expected: every service-edge connector can be wired from the board alone.

- [ ] **Step 3: Add safety and configuration silkscreen**

Add short silkscreen labels:

```text
NO MAINS
OUTPUT_ENABLE
PT1000 DEFAULT
PT100 SELECT
```

Expected: board states the most important safety/configuration facts.

- [ ] **Step 4: Update README**

Add this section to `README.md`:

```markdown
## Hardware

The espresso controller HAT design lives in `hardware/pi_zero_espresso_hat/`.
The current PCB design spec is `docs/superpowers/specs/2026-06-21-pi-zero-espresso-hat-design.md`.
The board is a low-voltage Raspberry Pi Zero 2 W HAT; mains wiring stays off-board.
```

Expected: repository root points future readers to the hardware project and design spec.

- [ ] **Step 5: Run schematic ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/task-6-erc.rpt
```

Expected: no ERC errors.

- [ ] **Step 6: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat README.md
git commit -m "Add HAT diagnostics and documentation pointer"
```

Expected: commit contains fault LED, silkscreen labels, and README pointer.

---

### Task 7: Complete PCB Routing And Design Rules

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: complete schematic and initial placements from Tasks 2-6.
- Produces: routed PCB that passes DRC.

- [ ] **Step 1: Set board design rules**

Configure KiCad board setup:

```text
Copper layers: 2
Board thickness: 1.6 mm
Minimum track width: 0.20 mm
Minimum clearance: 0.20 mm
Default signal track width: 0.25 mm
Power track width: 0.50 mm where practical
Ground: copper pour on both layers connected by stitching vias
```

Expected: design rules match common low-cost PCB assembly capabilities.

- [ ] **Step 2: Route critical nets first**

Route:

```text
MAX31865 SPI nets
RTD analog nets
3V3/GND for MAX31865 and reference section
```

Expected: RTD analog traces are short and kept away from output connectors.

- [ ] **Step 3: Route actuator outputs**

Route:

```text
GPIO12_HEATER_PWM to gate
HEATER_OUT to connector
GPIO5_PUMP_CMD to gate
PUMP_OUT to connector
OUTPUT_ENABLE_LOGIC
```

Expected: actuator traces stay grouped and do not pass through RTD area.

- [ ] **Step 4: Route switch inputs and LEDs**

Route:

```text
GPIO27_BREW_SW
GPIO17_STEAM_SW
GPIO6_FAULT_LED
PWR LED
ARMED LED
HEATER LED
PUMP LED
```

Expected: labels remain readable after routing.

- [ ] **Step 5: Add ground pours and stitching**

Add GND zones on top and bottom layers.

Expected:

```text
All GND pins connect to pours.
No isolated copper islands remain.
MAX31865 has a nearby low-impedance ground path.
```

- [ ] **Step 6: Run PCB DRC**

Run:

```bash
kicad-cli pcb drc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb --output hardware/pi_zero_espresso_hat/fab/task-7-drc.rpt
```

Expected: no DRC errors. Warnings are acceptable only if documented in PCB comments.

- [ ] **Step 7: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Route espresso HAT PCB"
```

Expected: commit contains fully routed board and passing DRC report.

---

### Task 8: Generate Fabrication Outputs And Final Review

**Files:**
- Modify: `hardware/pi_zero_espresso_hat/fab/`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch`
- Modify: `hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb`

**Interfaces:**
- Consumes: routed board from Task 7.
- Produces: reviewable fabrication package and final pre-order checklist.

- [ ] **Step 1: Run final ERC**

Run:

```bash
kicad-cli sch erc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_sch --output hardware/pi_zero_espresso_hat/fab/final-erc.rpt
```

Expected: no ERC errors.

- [ ] **Step 2: Run final DRC**

Run:

```bash
kicad-cli pcb drc hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb --output hardware/pi_zero_espresso_hat/fab/final-drc.rpt
```

Expected: no DRC errors.

- [ ] **Step 3: Generate Gerbers**

Run:

```bash
kicad-cli pcb export gerbers hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb --output hardware/pi_zero_espresso_hat/fab/gerbers
```

Expected: Gerber files exist in `hardware/pi_zero_espresso_hat/fab/gerbers/`.

- [ ] **Step 4: Generate drill files**

Run:

```bash
kicad-cli pcb export drill hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb --output hardware/pi_zero_espresso_hat/fab/gerbers
```

Expected: drill files exist beside the Gerbers.

- [ ] **Step 5: Generate BOM**

Use KiCad BOM export to write:

```text
hardware/pi_zero_espresso_hat/fab/pi_zero_espresso_hat-bom.csv
```

Expected: BOM includes MAX31865, EEPROM, buffer/gate parts, passives, connectors, LEDs, output-enable switch, and test points.

- [ ] **Step 6: Generate placement file**

Run:

```bash
kicad-cli pcb export pos hardware/pi_zero_espresso_hat/pi_zero_espresso_hat.kicad_pcb --output hardware/pi_zero_espresso_hat/fab/pi_zero_espresso_hat-pos.csv --format csv
```

Expected: position file includes assembled SMT parts.

- [ ] **Step 7: Perform manual final checklist**

Check and record results in `hardware/pi_zero_espresso_hat/fab/final-review.md`:

```markdown
# Pi Zero Espresso HAT Final Review

- [ ] GPIO0/GPIO1 only connect to HAT EEPROM.
- [ ] GPIO12 heater path defaults off with OUTPUT_ENABLE disabled.
- [ ] GPIO5 pump path defaults off with OUTPUT_ENABLE disabled.
- [ ] Heater and pump LEDs indicate post-enable output state.
- [ ] Brew and steam inputs are active-low with external pullups.
- [ ] Switch silkscreen says 2-wire switches use SIG-GND.
- [ ] MAX31865 default configuration is marked PT1000.
- [ ] RTD traces are routed away from actuator outputs.
- [ ] No mains labels or footprints exist on the PCB.
- [ ] All service-edge connector pin labels are visible in 3D/mechanical view.
- [ ] Pi Zero header and mounting holes align with the mechanical reference.
- [ ] Final ERC report has no errors.
- [ ] Final DRC report has no errors.
```

Expected: every checkbox is checked before ordering boards.

- [ ] **Step 8: Commit**

Run:

```bash
git add hardware/pi_zero_espresso_hat
git commit -m "Generate espresso HAT fabrication package"
```

Expected: commit contains final ERC/DRC reports, Gerbers, drill files, BOM, placement file, and final review checklist.
