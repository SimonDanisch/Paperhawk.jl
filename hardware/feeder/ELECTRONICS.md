# Wiring, programming and starting the feeder

Back to the [overview](README.md).

## Wiring

Wire the boards while they lie on the carrier, before the carrier goes into the frame
([assembly step 2](ASSEMBLY.md#2-electronics-onto-the-carrier)). The ESP32's pins point down:
the jumper wires go onto them from below.

Each ULN2003 driver board: IN1–IN4 to the ESP32 as in the table, its power pins (`−` and `+`,
marked 5-12V) to GND and 5 V. Leave the little jumper next to them on. The motors plug into
their boards.

| Motor | IN1 | IN2 | IN3 | IN4 |
|---|---|---|---|---|
| drive (left driver) | D32 | D33 | D25 | D26 |
| exit (right driver) | D18 | D19 | D21 | D22 |

The ESP32 has two GND pins, one for each driver, but only one 5 V pin (`VIN`). Split it: cut two
jumper wires in the middle, strip 10 mm off three of the cut ends, twist the three together,
fold the twist along one wire and wrap it tightly with tape (or solder it). Put the three free
ends on `VIN` and on both drivers' `+`.

## Programming the ESP32

1. Install the [Arduino IDE](https://www.arduino.cc/en/software).
2. In *File → Preferences → Additional boards manager URLs* enter
   `https://espressif.github.io/arduino-esp32/package_esp32_index.json`, then install
   *esp32 by Espressif Systems* in *Tools → Board → Boards Manager*.
3. Download [feeder.ino](https://github.com/SimonDanisch/Paperhawk.jl/raw/main/hardware/feeder/firmware/feeder/feeder.ino)
   and open it; the IDE offers to put it into a folder of its own, say yes.
4. Plug the ESP32 in with the USB cable, into a USB 3 port of the computer (USB 2 gives the
   motors barely enough power). Choose *Tools → Board → esp32 → ESP32 Dev Module* and the new
   port under *Tools → Port* (on Windows, if none appears, install the
   [CP210x driver](https://www.silabs.com/developer-tools/usb-to-uart-bridge-vcp-drivers)).
5. Click *Upload*.

## First start

Open *Tools → Serial Monitor* and set it to 115200 baud. Commands are typed into its input line:

1. `JOG drive 20` and `JOG exit 20`: both must move paper toward the box. If one turns the wrong
   way, change its `direction` in the program from `+1` to `-1` (or back) and upload again.
2. `JOG exit 75.4` must turn the exit roller exactly once around. If it stops a little short,
   set `STEPS_PER_REV` to `2038` and upload again.

## Feeding paper

Stand the feeder behind the box so that it reaches over the box's back wall. Lift the pick
roller by its shaft, slide the stack in face up until its top edge touches the ramp, and let
the roller down. Each `FEED` lays one sheet into the box and answers `DONE`. Empty the box after
every 40 sheets.

## If something goes wrong

- **Two sheets at once:** the cork grips your paper too little; check both as in
  [PRINTING.md](PRINTING.md#2-paper-and-cork). No spring fixes that.
- **The top sheet stops at the rollers while the motor runs:** print and fit the stiffer
  (1.0 N) pad spring.
- **The exit motor hums and the sheet stops on its way:** fit the softer (0.8 N) pad spring.
- **Nothing moves when a feed starts:** wipe the pick roller's O-rings with alcohol; dust takes
  their grip.
- **A motor hums and skips:** swap it for another one from the pack of five, or slow both down
  with `SPEED 7`. Never go above the default 9.75.
- **A folded letter stands up at the end instead of lying down:** run a thumb once along its
  fold the other way before loading.
