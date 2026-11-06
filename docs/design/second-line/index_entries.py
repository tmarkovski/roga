"""The entries that add the Second line page to the canvas's index, as text
edits for the artifact's edit_version, written to the path given (edits.json
by default)."""

import json
import sys
P = "secondline"
boards = {
    "SL-Today.dc.html": dict(x=0, y=0, w=724, h=964, title="Today", page=P),
    "SL-A-Every.dc.html": dict(x=804, y=0, w=724, h=964, title="A · Two lines on every row", page=P),
    "SL-B-WhenNeeded.dc.html": dict(x=1608, y=0, w=724, h=964, title="B · A second line when there's something to say (the one I'd pick)", page=P),
    "SL-B2-MarkRight.dc.html": dict(x=2412, y=0, w=724, h=964, title="B2 · B with the mark at the right", page=P),
    "SL-States.dc.html": dict(x=0, y=1860, w=850, h=1210, title="What the second line says", page=P),
    "SL-Try.dc.html": dict(x=930, y=1860, w=756, h=962, title="Try it", page=P, is_interactive=True),
}
notes = {
    "tSL": dict(x=0, y=-320, page=P, kind="title1", maxW=3136, text="A second line for what's going on"),
    "nSLstart": dict(x=3216, y=0, w=640, page=P, text=(
        "Decision 16 took the sidebar's rows to one line, 32 points tall, so that nearly twice as many fit. "
        "The second line it dropped was mostly the folder, which repeated the branch. Since decision 47, an agent "
        "has a short line about what it's doing, and today that line only shows in the mark's tooltip and in the "
        "worktree menu. These boards put it under the row's name instead. Every board draws the same made-up acme "
        "organization in a window 860 points tall: 12 repositories, three agents at work or waiting, two that "
        "finished, and infra stuck in a rebase. Nothing is chosen yet.")),
    "nSLToday": dict(x=0, y=1004, w=680, page=P, text=(
        "The app today. The mark before the count says whether an agent is working, waiting or finished, and "
        "what it's doing takes a hover and the tooltip's delay, one row at a time. These 17 rows need 576 of the "
        "776 points the window has for the list.")),
    "nSLA": dict(x=804, y=1004, w=680, page=P, text=(
        "Every row gets 48 points. Under a quiet row goes its latest commit's subject, as S5 drew, so the second "
        "line is never empty. That costs a git log -1 for each worktree whenever the sidebar looks, which is small "
        "but grows with the list. The bigger cost is room: these 17 rows need 848 points, so the last two scroll "
        "away, and with the 32 repositories of the Sidebar at scale page about 15 rows fit rather than 22. The "
        "quiet rows' subjects also compete with the lines that need you, since both are gray text in the same place.")),
    "nSLB": dict(x=1608, y=1004, w=680, page=P, text=(
        "The one I'd pick. A row grows to 48 points only while there's something to say: an agent at work, "
        "waiting or finished, or a rebase or merge that stopped partway. Quiet rows stay at 32, so these 17 rows "
        "need 672 points and all of them fit. The mark moves to the front of the line, so the line can leave out "
        "the agent's name. Decision 47 named the agent in the menu so that \"git push · 2 min\" couldn't read as "
        "something Roga is doing, and here the mark does that job. The cost is movement: a row grows when an "
        "agent starts and shrinks once you've seen it finish, and every row under it shifts by 16 points. Those "
        "are the rows you're watching anyway. If it feels busy, a row could keep its height until the pointer "
        "leaves the sidebar, so nothing moves under it.")),
    "nSLB2": dict(x=2412, y=1004, w=680, page=P, text=(
        "B with the mark where it is today, before the count. The marks stay in one column, so you can run your "
        "eye down the right edge for amber. But nothing at the start of the line says an agent wrote it, so the "
        "line has to name the agent, and \"Claude Code: \" takes about a third of a worktree's row before what "
        "it's doing starts. Each row also asks you to look in two places rather than one.")),
    "tSL2": dict(x=0, y=1560, page=P, kind="title1", maxW=2326, text="State by state, and to try"),
    "nSLStates": dict(x=0, y=3110, w=760, page=P, text=(
        "What B's second line says, in the order it wins when there's more than one thing: an agent waiting for "
        "you, then a worktree stuck partway, then an agent at work or finished. A waiting agent beats a rebase "
        "because the rebase can wait for you and the agent can't, and the red count still says there are "
        "conflicts. Time follows the tooltip: none in the first minute, and none once an agent has finished. A "
        "finished agent's line is the first line of its reply, and it goes with the blue dot when you select the "
        "row. Deleting… and Folder missing stay at the right of the first line, as today, since they're about "
        "the row itself.")),
    "nSLTry": dict(x=1766, y=1860, w=560, page=P, text=(
        "Press Play. An agent event comes every two seconds, and each one moves the clock a minute. Switch Rows "
        "between Today, A and B to compare how much the list moves, and Mark between its two places. Click a row "
        "to select it, which clears a finished agent's dot, and in B its line too. Pause and Next event step "
        "through one event at a time. The organization and its agents are made up.")),
}

def body(d, indent=4):
    s = json.dumps(d, indent=2, ensure_ascii=False)
    lines = s.split("\n")[1:-1]
    return "\n".join(" " * (indent - 2) + l for l in lines)

def entries(d):
    out = []
    for k, v in d.items():
        inner = json.dumps(v, indent=2, ensure_ascii=False).split("\n")
        inner = [inner[0]] + ["    " + l for l in inner[1:]]
        out.append(f'    {json.dumps(k)}: ' + "\n".join(inner))
    return ",\n".join(out)

edits = [
    {"old_text": '"name": "Worktree switcher"\n    }\n  ],',
     "new_text": '"name": "Worktree switcher"\n    },\n    {\n      "id": "secondline",\n      "name": "Second line"\n    }\n  ],'},
    {"old_text": '"boards": {\n', "new_text": '"boards": {\n' + entries(boards) + ",\n"},
    {"old_text": '"order": [\n', "new_text": '"order": [\n' + ",\n".join("    " + json.dumps(k) for k in boards) + ",\n"},
    {"old_text": '"notes": {\n', "new_text": '"notes": {\n' + entries(notes) + ",\n"},
]
json.dump(edits, open(sys.argv[1] if len(sys.argv) > 1 else "edits.json", "w"), ensure_ascii=False, indent=1)
# Check the result would still be valid JSON by applying to a small stand-in.
sample = '{\n  "pages": [\n    {\n      "id": "worktrees",\n      "name": "Worktree switcher"\n    }\n  ],\n  "boards": {\n    "X": {}\n  },\n  "order": [\n    "X"\n  ],\n  "notes": {\n    "n": {}\n  }\n}'
for e in edits:
    assert sample.count(e["old_text"]) == 1
    sample = sample.replace(e["old_text"], e["new_text"])
json.loads(sample)
print("ok", len(boards), "boards,", len(notes), "notes")
