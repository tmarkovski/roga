# 21. Draw the house's animations from joints, in Swift

Accepted on 2026-11-03.

## Context

[Decision 19](0019-pull-and-push-from-the-branch-in-the-title-row.md) has the house from the mark waddle while git runs. That rocks the whole mark from side to side, so it says something's happening but not which way the commits are going. We wanted the house to push and to pull, which means moving its body and its legs separately, and the mark is one path.

We tried the motion first on a page in a browser, with the house pushing a box and pulling one on a rope. The box and the rope turned out to be only a way of thinking about it. The lean and the legs say enough, and without them the house stays about 20 points wide at 18 tall.

We considered these ways of building it:

- **Lottie**, which plays animations exported from After Effects. It suits a designer animating by hand. Here it would add a second third-party dependency beside Sparkle, and a tool for making the files, to play back what a few functions can work out.
- **A flipbook of frames drawn by hand.** This gives the most control at 18 points, but every change to a motion means redrawing frames, and a new animation can't reuse anything.
- **Keyframes in Core Animation**, which keep running when the main thread is busy. It's more code to get the same poses on screen, so it stays in reserve.

## Decision

**The body is the mark's own outline, and the legs are joints.** [`yaga-house-body.svg`](../design/branding/roga-house-body.svg) is the mark's house with its legs cut off. Each leg is a hip, a knee, a hock, an ankle and three toes, drawn as lines with round ends, so it can move without anything being redrawn by hand. A pose says where all of that is at one moment.

**An animation is a function from time to a pose.** Each one is a `HouseMotion`, and a new one only has to build poses from the same parts. A SwiftUI `Canvas` in a `TimelineView` draws them.

**There are four animations, and all of them stay for now.**

- **Push** leans forward with both legs behind the body. Each foot slides back along the floor and then steps forward, one after the other.
- **Tug of War** is the same walk with different numbers. It leans back with both legs in front of the body, heels dug in and toes up.
- **Heave** pulls the way sailors heave on a line. It leans forward and steps one foot back, then the other, and then swings the body back over them with both feet planted.
- **Waddle** rocks the whole house in the stride the mark is drawn in, as decision 19 describes.

**Each action gets the animation that says what it's doing.** Pushing and force pushing show Push, and pulling shows Heave. Fetching and undoing a pull show Waddle, because they have no direction to show. Nothing in the title row uses Tug of War.

**One setting changes the speed of all of them.** It multiplies their speed, from 0.25× to 3×. All four run above its slider in Settings, so the change shows while the slider moves, and changing it carries on from the same pose rather than jumping to another.

**The house plays at least once.** When git succeeds sooner than one cycle at the speed in Settings, the action stays in the title row until the cycle is over, and only then does **✓ Pushed 1** show. Git's work is already done by then, so a local push can look slower than it was: 1.25 seconds at normal speed. A refusal or a conflict doesn't wait, because its alert has more to say than the house.

**A window shows them up close.** Window > House Animations draws each one large on a moving floor, with its joints if you want them, and at 18, 22 and 28 points. It has its own pause, speed and frame slider. Its speed starts from the setting but doesn't change it, so slowing something down to look at it leaves the app alone.

**Someone who asks for less motion sees one still pose**, chosen so that it still shows which way the house is working.

## Consequences

- This changes what decision 19 describes, where the house waddles for every action.
- The window is for working on the animations, and it's in every build for now, which people using yaga don't need.
- The drawing happens on the main thread, so the house would stutter if that thread stalled. In a release build, one house at the size of the title row took about 6% of one core at 30 frames a second, on an M1 Max, and only while git runs. All four in Settings took about 20%, while that window is open. If either becomes a problem, the same poses can be handed to Core Animation.
- The legs depart from the mark a little. The rear one is a darker orange so that the two stay apart where they overlap, the toes are about 15% shorter so that the feet don't tangle, and below 28 points the legs are drawn thicker so that they don't disappear.
- `HousePose.mark` places the joints close to the mark's stride, but it isn't a trace. The waddle therefore differs slightly from rocking the mark itself.
- The body exists twice, in the SVG and in `HouseOutline.swift`, so a change to the mark's house means cutting it again in both.
- At 18 points the toes turn to mush. The lean and the stride are what still read at that size.
