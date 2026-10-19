// Paperhawk sheet feeder: two 28BYJ-48 steppers on ULN2003 boards, driven by an ESP32.
//
// Serial commands (115200 baud, one per line):
//   FEED            feed one sheet; answers "DONE" when the sheet lies in the box
//   JOG <m> <mm>    turn motor m (drive or exit) by <mm> of roller surface, negative = back
//   SPEED <rpm>     motor speed, 1 to 15 rpm (default 9.75)
//   OFF             switch all coils off
//   STATUS          print settings
//
// The drive motor turns pick and feed roller through printed gears (pinion 20 teeth, feed gear
// 30, the pick arm's idler and the pick gear 30): both rollers turn 1.5 times slower than the
// motor and with 1.5 times its force. The exit motor turns the upper exit roller directly, so it
// runs faster than the sheet comes and pulls it once it has it. Per sheet both motors start
// together; each stops after its own travel, measured in steps (nothing senses the paper; the
// camera checks every result). The travels come from the simulation in hardware/feeder: the
// drive stops once the exit rollers have the sheet, long before its tail leaves the pick roller,
// so it never pushes the next sheet, and the exit roller runs on until the sheet lies in the box.
// Pick and feed roller sit behind freewheels, so neither the stopped nor the slower drive brakes
// the sheet the exit roller pulls.

#include <Arduino.h>

struct Stepper {
  const char* name;
  uint8_t pins[4];
  float steps_per_mm;    // of roller surface
  int8_t direction;      // +1 or -1: flip if the roller turns the wrong way (check with JOG)
  int32_t remaining;     // steps still to go
  int8_t sense;          // direction of the current move
  uint8_t phase;         // 0..3 in the full-step sequence
};

// Full steps (two coils on): the strongest mode of the 28BYJ-48.
const uint8_t SEQUENCE[4][4] = {{1, 1, 0, 0}, {0, 1, 1, 0}, {0, 0, 1, 1}, {1, 0, 0, 1}};
const float STEPS_PER_REV = 2048.0;          // 32 steps x 64:1; some units are 2038, check with JOG
const float ROLLER_DIAMETER = 24.0;          // mm, O-rings included
const float REDUCTION = 30.0 / 20.0;         // feed and pick gear over the drive motor's pinion
const float EXIT_STEPS_PER_MM = STEPS_PER_REV / (PI * ROLLER_DIAMETER);
const float DRIVE_STEPS_PER_MM = EXIT_STEPS_PER_MM * REDUCTION;

// Travel per sheet, mm of feed and exit roller surface (FeedSettings in simulation.jl).
const float FEED_TRAVEL = 160.0;
const float EXIT_TRAVEL = 500.0;

// GPIOs that are free and not strapping pins on a 30-pin ESP32 DevKit.
// The pinion turns the gears against the motor's sense, so the drive motor runs the other way
// than a motor straight on a roller would.
Stepper motors[2] = {
  {"drive", {32, 33, 25, 26}, DRIVE_STEPS_PER_MM, +1, 0, 1, 0},
  {"exit", {18, 19, 21, 22}, EXIT_STEPS_PER_MM, -1, 0, 1, 0},
};

// 9.75 rpm is 333 full steps per second (3 ms each): the speed at which a 28BYJ-48 on a ULN2003
// at 5 V was measured to hold 38 mN.m (jangeox.be, 2013): 3.1 N at the exit roller, 4.65 N at
// pick and feed roller through the gears. The simulation needs at most 1.9 and 2.6 N there with
// a motor 30 % weaker. Faster, the torque falls off quickly: unloaded, half stepping stopped at
// about 12 rpm. Both motors step at this rate: 12.25 mm/s at the exit roller, 8.2 at the others.
float rpm = 9.75;
uint32_t interval_us = 0;

void set_speed(float r) {
  rpm = constrain(r, 1.0, 15.0);
  interval_us = (uint32_t)(60.0e6 / (rpm * STEPS_PER_REV));
}

void coils(Stepper& m, bool on) {
  for (int i = 0; i < 4; i++) digitalWrite(m.pins[i], on ? SEQUENCE[m.phase][i] : 0);
}

void start(Stepper& m, float mm) {
  int32_t steps = lroundf(mm * m.steps_per_mm);
  m.sense = (steps >= 0 ? 1 : -1) * m.direction;
  m.remaining = labs(steps);
  coils(m, true);
}

// Steps every motor that still has steps to go, all at the same rate, until all are done.
void run_all() {
  uint32_t next = micros();
  bool busy = true;
  while (busy) {
    while ((int32_t)(micros() - next) < 0) {}
    next += interval_us;
    busy = false;
    for (auto& m : motors) {
      if (m.remaining <= 0) continue;
      m.phase = (m.phase + 4 + m.sense) % 4;
      coils(m, true);
      if (--m.remaining == 0) coils(m, false);   // off as soon as done: freewheels take over
      busy = true;
    }
  }
}

Stepper* find(const String& name) {
  for (auto& m : motors) if (name.equalsIgnoreCase(m.name)) return &m;
  return nullptr;
}

void setup() {
  Serial.begin(115200);
  for (auto& m : motors) {
    for (int i = 0; i < 4; i++) pinMode(m.pins[i], OUTPUT);
    coils(m, false);
  }
  set_speed(rpm);
  Serial.println("READY");
}

void loop() {
  if (!Serial.available()) return;
  String line = Serial.readStringUntil('\n');
  line.trim();
  int space = line.indexOf(' ');
  String cmd = space < 0 ? line : line.substring(0, space);
  String args = space < 0 ? "" : line.substring(space + 1);
  if (cmd.equalsIgnoreCase("FEED")) {
    start(motors[0], FEED_TRAVEL);
    start(motors[1], EXIT_TRAVEL);
    run_all();
    Serial.println("DONE");
  } else if (cmd.equalsIgnoreCase("JOG")) {
    int s2 = args.indexOf(' ');
    Stepper* m = s2 < 0 ? nullptr : find(args.substring(0, s2));
    if (!m) { Serial.println("ERR usage: JOG drive|exit <mm>"); return; }
    start(*m, args.substring(s2 + 1).toFloat());
    run_all();
    Serial.println("DONE");
  } else if (cmd.equalsIgnoreCase("SPEED")) {
    set_speed(args.toFloat());
    Serial.printf("SPEED %.1f\n", rpm);
  } else if (cmd.equalsIgnoreCase("OFF")) {
    for (auto& m : motors) coils(m, false);
    Serial.println("OFF");
  } else if (cmd.equalsIgnoreCase("STATUS")) {
    Serial.printf("rpm %.1f, steps/mm drive %.2f exit %.2f, travels drive %.0f exit %.0f mm\n",
                  rpm, DRIVE_STEPS_PER_MM, EXIT_STEPS_PER_MM, FEED_TRAVEL, EXIT_TRAVEL);
  } else if (cmd.length() > 0) {
    Serial.println("ERR unknown command");
  }
}
