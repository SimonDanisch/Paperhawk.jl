# Printing the sheet feeder

Everything is set up for a Bambu Lab H2D with Bambu Studio: the parts lie the way they print
best, without supports, and the settings a part needs are already set. Back to the
[overview](README.md).

## 1. The fit test

Download and print [coupon_h2d.3mf](https://github.com/SimonDanisch/Paperhawk.jl/raw/main/hardware/feeder/parts/coupon_h2d.3mf):
the coupon in PLA (40 minutes) and one clip in PETG (7 minutes). It tries every kind of fit a
little tighter and looser than the design:

- three round holes (0.3, 0.4 and 0.5 mm play): the coupon's shaft must turn freely in the
  middle one;
- three D-shaped holes (0.15, 0.25 and 0.35 mm play): the shaft must slide into the middle one,
  and turning the shaft must turn the coupon;
- three slots for 2 mm strips (0.2, 0.3 and 0.4 mm play): the strip must slide into the middle one;
- three holes for the small pin printed with the shaft (3.0, 3.1 and 3.2 mm): it must press
  firmly into the middle one;
- three sockets for the motor shaft (0.05, 0.15 and 0.25 mm play): the motor's shaft must slide
  into the middle one;
- the clip: push it sideways, open side first, into the groove near the shaft's end. It must
  click on, turn in the groove and stay on when you push against it along the shaft.

If the middle fits bind, raise the X-Y hole compensation in Bambu Studio by 0.05 mm and print
the test again. If they are loose, leave it.

## 2. Paper and cork

This takes five minutes and a phone. Tape a sheet of your paper flat onto a book. Tape another
piece of it under the coupon, lay the coupon on the sheet and tilt the book slowly until the
coupon slides; read the angle with the phone's level app. Do the same with a 2 mm strip of
cork under the coupon instead.

| The coupon slides at | It must be |
|---|---|
| paper on paper | at most 31° |
| cork on paper | 35° to 45°, and at least 4° more than paper on paper |

Natural wine cork usually is; pressed cork crumbs or plastic "corks" may not be.

## 3. The feeder

Download [feeder_h2d.3mf](https://github.com/SimonDanisch/Paperhawk.jl/raw/main/hardware/feeder/parts/feeder_h2d.3mf),
open it in Bambu Studio and print all plates:

| Plates | Material | Time | Filament |
|---|---|---|---|
| 1–4 | PLA | 16.3 h | 654 g |
| 5 | PETG | 3.1 h | 65 g |

On the PETG plate, check that the first layer goes down evenly: the pad spring lies there flat
on its back and must come out as thick as designed.

[pad_spring_variants_h2d.3mf](https://github.com/SimonDanisch/Paperhawk.jl/raw/main/hardware/feeder/parts/pad_spring_variants_h2d.3mf)
(PETG, 50 minutes) has a softer and a stiffer pad spring. Print them only if the feeder asks
for them ([ELECTRONICS.md](ELECTRONICS.md#if-something-goes-wrong)).
