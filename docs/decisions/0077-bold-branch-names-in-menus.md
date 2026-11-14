# 77. Bold branch names in menus, in place of the branch icon

Accepted on 2026-11-14. This replaces the branch icons of [decision 66](0066-sentence-case-branch-icons-and-the-value-on-a-row.md), whose sentence case and value on a row still hold.

## Context

Decision 66 put the branch icon in front of a branch's name in the menus Roga draws, as in `Merge ⎇feature into ⎇main…`, so that a row naming two branches showed which of its words were branches. The icon is small and gray, and the name after it is in the same font as the words around it, so the names still didn't stand out at a glance.

In issue #84 we tried other ways in real menus, in light and dark: the name in SF Mono; SF Mono on a soft gray fill, as GitHub shows inline code; SF Mono inside a thin outline; SF Mono on history's own badges; the menu's own words in SF Pro Rounded or New York beside names on a fill; and the name in bold.

## Decision

**A branch's name is bold in a menu's rows**, in the font of the words around it, as in "Merge **feature** into **main**…". `RefMenu.Title` still holds the words and the branch names apart, and is still written as `"Merge \(branch: name) into \(branch: head)…"`. Only how a name is drawn has changed. VoiceOver and typing to select read only the words, as before. `HEAD` on a detached commit isn't bold, because it isn't a branch.

**A heading is only the name, so it stays as it is**, in the heading's dim font, with no icon.

Bold reads as two branches at a glance, keeps the row one sentence in the system's font, and adds no shape or color. SF Mono on a fill was as easy to read, but it made the menu look like code, and SwiftUI's menus could only draw its fill as a square that hugs the letters.

**SwiftUI's menus can do this too.** Decision 66 said that only the rows Roga draws can put anything special in the middle of a row. That's true of an icon. But SwiftUI passes the font of a `Text` built from an `AttributedString` through to the menu item, and macOS draws it, including on a highlighted row. No row in SwiftUI's menus names a branch today: the title row's branch menu names its upstream only in its first line, which is the menu's heading.

## Consequences

- Dialogs still set a branch's name in SF Mono (`DialogText`), so the dialog that opens from "Merge **feature** into **main**…" shows the same names in a different font.
- A bold name is wider than the same name in the regular font, but narrower than the icon and its gap, so menus that name branches in their rows are a little narrower than they were.
- A name too long for its row is still cut short in its middle with the rest of the row.
