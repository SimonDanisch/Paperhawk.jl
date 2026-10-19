# How the sheet feeder works and how it was checked

Back to the [overview](README.md).

Everything here is generated from Julia code and checked by simulation before printing:
`design.jl` (paper path), `physics.jl` and `simulation.jl` (2D sheet simulation),
`envelope.jl` (the conditions it has to handle), `skew.jl` (sheet skew in MuJoCo),
`mechanics.jl` and `assembly.jl` (parts), `checks.jl` (collisions, motion, assembly,
strength), `print.jl` (Bambu Studio projects), `printsim.jl` and `printchecks.jl` (the parts
as printed, rebuilt from Bambu Studio's G-code), `render.jl` and `raytrace/guide.jl` (the
pictures), `firmware/feeder/feeder.ino` (ESP32).

## How it works

- **Stack.** The sheets lie face up in a tray that rises 10° toward the back, their top edges
  against a short ramp. At 10° friction holds the stack where it lies, so its weight stays on
  the tray and never reaches the separation.
- **Pick.** A pick roller hangs on an arm that swings about the feed roller's shaft. The arm's
  own weight (0.72 N) presses it onto the top sheet, at any stack height; it pushes that sheet
  over the ramp onto the separation pad.
- **Separation.** The pad is a curved cork face on a PETG leaf spring that presses it with
  0.9 N against the feed roller above. It leads the sheet in at a flat angle: a sheet pushed
  between two rollers stays nearly straight, so the nip has to open the way it comes. The feed
  roller takes the top sheet; the cork holds back anything dragged along under it. This works
  because rubber grips paper better than cork, and cork grips paper better than paper grips
  paper ([checked before printing](PRINTING.md#2-paper-and-cork)).
- **Path.** A short hump leads to the exit rollers, 30 mm in front of the box's back wall. The
  sheet drops into the box face up.
- **Drive.** Two 28BYJ-48 steppers. The drive motor, outside the left plate, turns the feed
  roller's gear with a 20-tooth pinion, and the feed gear turns the pick roller's gear through
  an idler on the arm: both rollers turn 1.5 times slower and stronger than the motor. Each of
  these gears turns freely on its shaft and carries a flexible pawl inside that pushes a
  ratchet on the shaft: a freewheel. The exit motor sits straight on the exit roller's shaft
  and runs 1.5 times faster, so once it has the sheet it pulls it out of the feed nip and the
  freewheels let pick and feed roller run along.
- **Control.** The firmware only counts steps. Per sheet it starts both motors, stops the
  drive after 160 mm (the exit rollers have the sheet, its tail is still under the pick roller,
  so the next sheet is never pushed) and the exit roller after 500 mm. One sheet takes about
  41 seconds. Paperhawk's camera checks every result.

**Why this layout.** An earlier version stood the stack nearly upright and picked the
rearmost sheet; there the stack's weight rested on the separation wedge, and with more than a
few sheets two went through at once. Flat, the weight stays on the tray. The pick arm is short
(30 mm from the feed roller's axis), so the sheet has no room to buckle between pick roller and
nip; with a 50 mm arm it did.

## What it feeds

Every case below was simulated through two full feeds (pick, separation, path, landing in the
box) and every sheet landed on its own and as flat as its own shape allows:

| Varied | Range |
|---|---|
| Sheets in the tray | 1 to 40 |
| Paper | 60, 80 and 120 g/m² |
| Paper on paper grip (static) | 0.35 to 0.6 |
| O-ring grip | new 1.3, worn 1.0 |
| Cork grip | 0.7 to 1.0 |
| Pad force | 0.8 to 1.0 N |
| Pick arm weight | 0.65 to 0.8 N |
| Motors | as measured, and 30 % weaker with 20 % lost in each gear mesh |
| Paper already in the box | 0 to 15 mm |
| Letters folded in three and opened | text outside: creases up to 70°; text inside: up to 50° |
| Sheets folded once across | crease up to 60° (text outside), 30° (text inside) |
| A crease 15 mm behind the top edge | 45° down, 35° up |
| Lightly crumpled (eight different sheets, creases up to ±25°, waves) | all |
| Cockled (3 mm waves) | all |
| Curled | down to 150 mm radius, either way |

The corners combine what pushes toward the same failure: grippy paper with slippery cork, a
weak pad and a heavy arm (two sheets at once); worn tires, grippy heavy paper and a light arm
(no sheet); a 30 % weaker motor with lossy gears against the strongest springs, grippiest cork,
heavy paper and a full box (a motor stalling).

**Limits.** No friction feeder separates paper that grips itself as hard as the pad grips it,
or picks paper that grips itself as hard as its tires do; the cork check makes sure yours is in
range. Sheets folded with the text inside and opened rise toward their ends; past the angles
above the last panel stands up against the lower exit roller instead of lying down: a letter
folded in three at 60°, a sheet folded once at 40°, and one of nine crumpled test sheets, whose
last 13 cm were bent up by 60° in all. Running a thumb once along such a fold the other way
before loading helps. The camera sees any sheet that did not land flat.

## The bought parts

**The motor.** The ANGEEK set is the common 28BYJ-48 (5 V, unipolar). Its data, from the
[listing's drawing](https://www.amazon.de/dp/B07VGV1XFT) and the
[28BYJ-48 datasheet](https://www.rajguruelectronics.com/Product/1467/28BYJ-48%20-%205V%20Stepper%20Motor.pdf):
gear 1:64 (2048 full steps per turn), 50 Ω per phase, torque above 34.3 mN·m at 120 Hz,
unloaded it starts up to 600 Hz and runs up to 1000 Hz. The datasheet says nothing about the
torque at higher speed, so the feeder runs where a 28BYJ-48 on its ULN2003 board was
[measured](http://www.jangeox.be/2013/10/stepper-motor-28byj-48_25.html): 333 full steps
per second (9.75 rpm), where it held 380 gf·cm (37.3 mN·m) before missing steps. Faster it
loses torque quickly; unloaded, half stepping stopped at about 12 rpm. The parts it fits into
follow both drawings, the worse value where they differ: shaft 5 mm, flattened to 3 mm only
over its outer 6 ± 0.2 mm, 10 ± 0.5 mm long; boss 9 mm, 1.8 mm high; lug holes 4 mm,
35 ± 0.2 mm apart; cable housing 17.1 mm from the body's axis; lead 230 ± 10 mm. At 9.75 rpm
the exit roller's surface moves 12.25 mm/s, pick and feed roller's 8.2 mm/s.

**The boards.** No seller publishes the boards' hole patterns, so the holders do not use them:
each board lies on four shelves under its corners and a printed frame holds it down by the
corners, where the boards have nothing but their mounting holes. The pockets take the ULN2003
boards at 35.5 × 31.4 mm (ANGEEK's listing) ± 0.3 mm and the ESP32 at 51.3 × 28.4 mm ± 0.6 /
0.3 mm, measured on MiMiU's straight top photo against the 2.54 mm pin pitch, with its
USB-C socket 2.1 mm past the board's end.

**Power.** Both motors draw up to 0.4 A together while they run: a USB 3 port (900 mA) carries
that, a USB 2 port (500 mA) is at its limit. The drivers get the USB's 5 V through the ESP32's
VIN pin, behind a diode, so the coils see about 10 % less current than in the torque
measurement; the simulation's 30 % weaker motor covers that.

## What the simulation and the checks covered

### The paper path, in the side view

The 2D simulation resolves every sheet as a chain of nodes with real paper stiffness, contacts
with sticking friction, roller rotation, the gears that tie pick and feed roller to one motor
(10 % of its work lost in each printed mesh, one mesh to the feed roller and three to the pick
roller; 20 % tried as well), the freewheels with their pawl drag, the arm the pick roller swings
on, and the steppers' force limit. Folds and creases are kinks the sheet relaxes to, with a
softer hinge where the fibers broke; waves and curl are curvature it relaxes to. The nip was
cross-checked against MuJoCo. In the cases of the table above the drive motor needed at most
2.55 N of the 3.26 N a 30 % weaker motor gives through the gears, the exit motor 1.93 N of
2.18 N. With the strongest pawl drag a swollen print gives (0.30 N per freewheel instead of
0.18 N), the corner where everything is at its worst at once needs 2.15 N of the exit motor's
2.18 N and still lands every sheet; with motors as measured that is 69 %.

Choices the simulation made: the nip opens 10° up from the tray and the pad's face is curved
wide (30 mm radius), because with a steeper nip the sheet ran head-on into the pad; the tray
and the ramp meet in a rounded corner; the pick arm is 30 mm long; pick and feed roller sit
behind freewheels (a pick roller without one braked the outgoing sheet by 0.65 N); the drive is
geared 1.5:1, because the weak motor could not push the stiffest case through the nip.

### The parts as printed

Bambu Studio slices the same project you print. Every extrusion in its G-code is a bead whose
width follows from the plastic it lays; the beads of each layer, united, are what the part is
made of, layer by layer, with stair steps on round faces that print lying. On top of that each
part shrinks while it cools (0.3 % PLA, 0.4 % PETG, tried from none to twice that) and every
face may swell by up to 0.1 mm, which is how printed holes come out small. At all nine
combinations:

- every shaft turns through a full circle in its bores and the pick shaft in the arms, the arms
  turn on the feed shaft, the cup gears on their shafts and the idler on its shaft;
- the hubs, ratchets and collars grip their D-shafts and the left arm the idler's shaft; the
  motor sockets grip the motor shafts' flats from 6 to 9 mm out and stay clear of their round
  part nearer the motor, for every shaft length the drawings allow;
- each motor's lug goes over its two printed pins with the holes 35 ± 0.2 mm apart, with
  0.035 to 0.23 mm to spare;
- the tray, both halves of the lower guide, the upper guide, the carrier and the tie bars slide
  into their pockets, the tray stand's pegs into the tray, and the pad pin presses into the pad
  bar;
- every peg and pin has plastic around it and every foot and spring block lies on plastic;
- every board, from the smallest to the largest its listing allows and pushed into any corner
  of its pocket, drops in (at least 0.095 mm to spare), rests on its four corner shelves (at
  least 1.5 mm² under each corner), is held down by the clamp frame's fingers (at least
  1.1 mm² over each corner) with 0.24 mm above the thickest board, and shelves and fingers stay
  inside the corners where the board carries nothing;
- both motor plugs pass through their slots, and each slot keeps at least 6 mm of plastic to
  the next hole or pocket;
- the gears, rolled against each other about the axes where the cooled plate and the cooled
  arm hold them (pinion and feed gear, feed gear and idler, idler and pick gear), never jam; the
  backlash stays between 0.22 and 0.72 mm;
- the pawls catch 0.76 to 0.97 mm deep into the ratchets' teeth, bend by at most 0.95 %, and
  drag with 0.12 to 0.30 N (the simulation covers both);
- the pad spring comes out 1.20 mm thick at every combination (its force exactly as designed),
  the idler springs 2.56 to 2.78 mm (0.96 to 1.22 of their force, within the simulated range);
- cut every millimeter across the feeder, the printed parts only overlap where they press
  together or a spring or pawl is preloaded.

These checks changed the design: the lower guide is two halves (whole, the bed beside the pad
would have started in mid-air), the pad spring's root block has a wedge under it so the spring
lies flat on the bed, the tray stand lies on its square back face, the pad pin is the same
3.2 mm pin in a 3.1 mm hole as the lug pins, the stand's pegs got 0.3 mm of play, and Bambu
Studio slices every plate without a warning.

### Skew

`skew.jl` follows the sheet in its own plane in MuJoCo: the paper path unrolled, the sheet a
plate free to move along and across it and to turn, every roller a rigid body of a few short
cylinders with its spring force, drive, freewheel and friction, the pick roller's weight on the
stack and the fences beside it. The asymmetries a print and its bought parts bring:

| Case | Skew | Sideways | Clearance to the plates |
|---|---|---|---|
| left exit roller 0.1 mm bigger | 0.61° | 0.6 mm | 3.8 mm |
| left exit roller 0.2 mm bigger, worn O-rings | 1.23° | 1.4 mm | 1.5 mm |
| idler springs 1.8 and 1.2 N | 0.03° | 0.0 mm | 5.9 mm |
| sheet 1.5 mm off center in the stack | 0.03° | 0.1 mm | 5.8 mm |
| all three together, also with grippy paper or worn O-rings | 1.32° | 1.3 mm | 1.3 mm |

Once the exit rollers pull the sheet faster than the feed roller gives it, they alone steer it,
so a difference in their size turns it a little. The sheet never touches the plates and lands
at most 1.3° turned (the camera straightens it), inside a box 220 mm wide.

### Construction

The CAD checks build every part in place with OpenCASCADE: no two parts overlap except the
intended press fits (O-rings in their grooves, pawl tips on the ratchets, lug pins, the pad pin,
the clamp frames' pegs); the pick arm with everything it carries swings freely from an empty
tray to a full one and 15 mm higher for loading; the lower exit roller can drop its full travel;
every shaft slides in through the standing frame, the tray in along its pockets. The arm's
parts weigh 86 g and press the pick roller on with 0.70 to 0.74 N, from a full to an empty
tray. Each board and the room it needs (the parts on it, the motor plug, the jumper wires and
their bends, the ESP32's USB-C plug and cable) is clear of every printed part, for the smallest
and largest board in every corner of its pocket. Each motor's lead, laid from its housing to
its slot and on to the farthest corner of its driver, misses every part, the circles the gear
teeth sweep and everything the arm swings through, and needs 201 mm (drive) and 214 mm (exit)
with 20 mm slack of the 220 mm the shortest lead has. Seen from the phone, the feeder hides
nothing of the sheet but two patches 16 mm wide at its back edge, behind the lower exit
rollers: up to 5.6 mm deep in an empty box, 12 mm with 15 mm of paper in it. Most sheets land
with their back edge 4 to 10 mm from the box's wall (0 to 25 mm in all cases), so those two
patches can cut a few millimeters off the edge's middle; the rest of the edge stays in view.

Beam theory checks the shafts, springs, pawls and gears against the simulated loads:

| Check | Value | Limit |
|---|---|---|
| Feed shaft sag under the pad | 0.19 mm | 0.3 mm |
| Pick shaft bending stress | 0.84 MPa | 7 MPa |
| Exit rollers out of parallel across their width | 0.15 mm | 0.3 mm O-ring squeeze |
| Pad spring stress at 2 N | 8.9 MPa | 10 MPa (PETG, no creep) |
| Idler spring stress | 6.7 MPa | 10 MPa |
| Pawl strain, as printed | 0.95 % | 3 % (PETG) |
| Pawl load with the motor blocked vs buckling | 6.2 N | 9.1 N |
| Gear tooth stress at full motor torque (pinion, idler) | 0.38, 0.71 MPa | 10 MPa |
| Gear contact ratios | 1.49 to 1.51 | at least 1.2 |
| Pick gear to feed shaft | 1.0 mm | 0.5 mm |
| Drive motor force needed (30 % weaker motor) | 2.55 N | 3.26 N |
| Exit motor force needed (30 % weaker motor) | 1.93 N | 2.18 N |

The firmware compiles against an Arduino stub with every warning on; the ESP32 toolchain was
not at hand for this version, so it was not compiled for the ESP32 itself yet.

### What is not simulated

- How the sheet bends across its width. The side view bends it along the path, the skew model
  turns it as a rigid plate. A fold along the sheet, or a dog-eared corner, is beyond both.
- The real friction of your cork, O-rings and paper (covered by the ranges above; the check
  before printing measures yours).
- Your printer's swell and shrinkage: the model covers a range, the coupon tells where in it
  your printer lies. Warping of long parts beyond even shrinkage.
- Your motors' torque: the design rests on one published measurement of one 28BYJ-48; the
  30 % weaker case covers some spread between units.
- Wear and creep of printed parts over months, and the USB power under load.

The tolerance coupon and the first sheets through the feeder are the remaining tests.

## The files and pictures

`parts/` is generated: `export_3mf` writes the Bambu Studio projects, `parts(...; dir = "parts")`
every printed part as STEP (`parts/step`) and binary STL (`parts/stl`). The pictures in
[ASSEMBLY.md](ASSEMBLY.md) and at the top of the README are raytraced with RayMakie at 512
samples per pixel: the parts in their materials on a plywood desk in a photo studio (Poly
Haven's `brown_photostudio_02` HDRI and `plywood` texture, both CC0, downloaded into
`~/.cache/paperhawk-feeder`). `raytrace/guide.jl` renders them in the environment of
`raytrace/`, which has RayMakie and the Makie it needs, apart from the app's.
