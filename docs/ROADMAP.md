# Roadmap

What's built, what isn't, and what the project still has to prove.

## Where it stands

Every part of the app is written: pool and snooker, one-cushion shots, spin, throw, 8-ball and snooker rules, and lining up from behind the cue ball. It all runs in the iOS Simulator on a generated demo table, and the package tests run on a Mac.

Nothing has been checked in the real world yet. No real table, no real iPhone. Every accuracy number in the README comes from generated scenes. So the first real-world step is still the accuracy test below.

## The main risk

The whole thing depends on one question: can a phone, held at the side of a table, work out where the balls are accurately enough for the lines to be worth trusting?

A pool pocket gives you very roughly 25 to 30 mm of room either side. A snooker pocket gives you much less. An error of a few millimetres at the ball grows over the length of the shot. That's why the project starts with a measuring test and not with features.

## Phases

### Phase 0: Prove it

Tap the four corners, detect the balls, and compare the measured positions with ruler measurements on a real table. Pass mark on a 9 ft pool table:

- Half of all balls within 5 mm of their true position
- 95% of balls within 10 mm
- At least 95% of balls found, in normal club lighting
- Lines stay on the table while you walk around it for a minute

`cuesight-bench compare` takes the two CSV files and prints the result.

### Phase 1: First small version

Pool on iPhone. Tap the corners, sweep to scan, fix any ball by hand, then see up to 3 direct shots with lines, a ghost ball, how hard to hit and how hard the shot is.

### Phase 2: Better advice

Shots off one cushion, where to strike the cue ball (centre, top, bottom), a simple throw correction, and basic 8-ball rules.

### Phase 3: Snooker

Full-size and 10 ft tables, ball colours, basic snooker rules, and a tighter accuracy test because the pockets are smaller. Snooker shots carry a "Rough guide" label until a real table says otherwise.

## Not done yet

These need a real iPhone, a real table or real players:

- Run ARKit world tracking on a phone (`LiveFrameSource` is written but has never run)
- The Phase 0 accuracy test on a real pool table, in normal and dim light
- Check that lines stay put during a one-minute walk around the table
- The same accuracy test on a snooker table
- Measure how much roll a ball keeps after a cushion (`ShotConfig.cushionSpinKept` is a guess)
- Play real shots and see how often the advice works, then tune the difficulty scores
- Battery and heat over a 30 minute session, and a check on the oldest supported iPhone
- Try the app with a real VoiceOver user
- Line up from behind the cue ball on a real table: check ARKit keeps tracking that low and close to the cloth, and that the line still looks right from close up

Known limits on generated tables:

- Maroon balls on red cloth are only found 92.7% of the time, because maroon is close to the cloth colour. They can be added by hand on the review screen.
- Very thin cuts on 10 ft snooker are the weakest advice.

## Later

- Android
- Planning across several shots, not just the next one
- Shots off two or more cushions, and combination shots
- Carom billiards
- Using the phone on a stand or tripod
- A top-down 2D view of the table

## If the accuracy test fails

Things to try, in order:

1. A small trained detector in place of classic image processing
2. Holding the phone higher, or scanning from both sides
3. Requiring a phone with LiDAR
4. A phone stand or tripod, looking down from higher up
5. Dropping exact lines and showing only general advice
