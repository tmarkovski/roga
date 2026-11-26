# 112. Let the house be turned off in Settings

Accepted on 2026-11-26. This adds a setting that turns off the house from [decision 21](0021-draw-the-houses-animations-from-joints.md) in the title row and the one that drops through the Fetch button in [decision 57](0057-the-house-drops-through-the-fetch-button.md), and brings back Settings' Motion section to hold it. It was asked for in [issue 123](https://github.com/tmarkovski/roga/issues/123).

## Context

The house moves whenever git does something Roga can show. It pushes or heaves in the title row while a push or a pull runs, waddles while an undo, an abort or a rebase's next step does, and drops through the Fetch button on a thread during every fetch. It's part of Roga's character, but some people want a quieter window.

Until now the only way to calm it was the Mac's Reduce Motion, which changes every app, and even then the house shows up in the title row, standing still in a pose. Settings' Motion section, which had the house's animations on a card and a slider for their speed, was left out in 3e8e34d, so there was nothing about the house in Settings at all.

## Decision

**Settings › Appearance has a Motion section again, with one switch, Animate the house,** and the line "The house that pushes, pulls and drops through Fetch while Git works." under it. It's stored as `animatesHouse`, is on unless it's turned off, and is one setting for every window. Search finds it by its name, its line, Motion, and words such as Animations and Reduce Motion. The section has no card of houses above the switch, so nothing moves on the page where people go to stop the motion. The speed slider stays out, as 3e8e34d left it.

**With the switch off, there's no house anywhere git runs:**

- **The title row shows words after the counts,** for pushing, pulling, undoing, aborting and continuing a rebase, the way it already did for committing and reverting. The counts stay put while git runs, and when it's done, the words and Undo show after them.
- **Nothing waits for the house.** A push that's done before the house would have played once shows what it did at once, since `timeToPlayHouse` is zero with no house.
- **The Fetch button stays still and pulses** while a fetch runs, as it already did for someone with Reduce Motion on. The pulse isn't the house, and the button still needs to say that a fetch is running.

**Turning it off takes effect at once,** even during a push or a fetch: the house goes, and the words or the pulse take over. **Turning it back on waits for the next action,** so the house doesn't zoom in partway through a push or jump into a drop that's halfway done. That holds for an action that started with the house off, and for one it was turned off during and then on again. The house plays for an action only when it was on as the action started and has stayed on since, and the Fetch button starts its drops only while it's on and stops them when it's turned off.

**Reduce Motion works as before.** With the switch on and Reduce Motion on, the house stands still in its pose. With the switch off, there's no house either way.

## Consequences

- Someone who turns the house off sees the counts stay during a push or a pull, and can click one while git runs, which does nothing until git is done, as during a commit.
- A quick push or pull with the house off says what it did sooner, since it doesn't wait for the house to play once.
- The house still plays on the first-run setup screens, which come before Settings, in Replay History, where it's part of the video someone asked for, in the app icon and the wordmark. Other motion, such as the agents' turning ring, follows Reduce Motion as before.
- Motion is shown whenever it has a setting to show, rather than only while the speed is offered, so the speed can come back beside the switch.

## Alternatives considered

- **House animations as the name.** It reads more like a heading than a setting, and the other switches in Settings say what they do.
- **Show the house while Git works as the name.** It's closer to what off does, since there's no house rather than a still one, but Animate the house is shorter and matches what people search for, and the line under it says which house.
- **The card of the house's animations above the switch,** as it was above the speed. It shows what the switch turns off, but it's a card of moving houses on the page where someone goes to stop them. Showing them still while the switch is off was considered too.
- **A still house with the switch off,** as with Reduce Motion. It still takes the counts' place in the title row and makes the action wait, which isn't the quieter window this is for.
- **Bringing the house back at once when the switch is turned on.** The house would zoom in during a push that had started without it, hiding the counts partway through, or appear for the last seconds of the words about a push that's done, and the Fetch button would jump into the middle of a drop.
- **A setting for each window.** The house is the same in every window, and the other appearance settings are app-wide.
