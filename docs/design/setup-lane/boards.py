# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Setup lane boards for the design canvas "yaga layout options".

Setup's floor, which the house runs along, drawn as one lane of a commit graph
in history's style: a commit for each screen, with the screen's small title as
its subject, the house standing on the one setup is at, and a click on one
that's done going back to it. Today's window, two options (A and B), A at
every step and under the pointer, and A in the dark appearance.

    uv run docs/design/setup-lane/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

The window is the size setup opens at, 1,280 by 800 points (decision 69), and
the house stands where `SetupFloor.spot(at:in:)` puts it.
"""

from __future__ import annotations

import html
import importlib.util
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
PAGE_ID = "setuplane"
PAGE_NAME = "Setup lane"

_spec = importlib.util.spec_from_file_location("settings_boards", HERE.parent / "settings" / "boards.py")
_settings = importlib.util.module_from_spec(_spec)
sys.modules["settings_boards"] = _settings
_spec.loader.exec_module(_settings)
HOUSE_PATH = _settings.house_path()


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

WIN_W, WIN_H = 1280, 800      # SetupLayout.window
FLOOR_INSET = 64              # SetupFloor.inset
HOUSE_H = 46                  # SetupFloor.houseHeight
HOUSE_W = 46                  # the mark is square
FLOOR_FROM_BOTTOM = 30        # SetupFloor.fromBottom, today
LANE_FROM_BOTTOM = 44         # the lane sits higher, to leave room for subjects
STRIP_H = 150                 # the bottom of the window, on the step boards
COLUMN = 620                  # SetupLayout.column

# The screens, with today's small titles and the drafted commit subjects.
STEPS = [
    ("welcome", "", "Initial commit"),
    ("looking", "Your Mac", "Look around"),
    ("git", "Git", "Choose git"),
    ("agents", "Agents", "Add agents"),
    ("hooks", "Hooks", "Install hooks"),
    ("ready", "Ready", "Open Roga"),
]


def commit_x(index: int, count: int) -> float:
    """The middle of the house when it stands at a step, from SetupFloor."""
    room = WIN_W - 2 * FLOOR_INSET - HOUSE_W
    return FLOOR_INSET + room * (index / (count - 1)) + HOUSE_W / 2


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--surface:#fff;--tx:#1c1c1a;--tx2:#696964;--tx3:#a3a39e;--card:#f1f1ef;--line:#d6d6d3;--hair:#e3e3e0;--ink:#1a1a18;--onink:#fff;--eyebrow:#b83e02;--lane:#db1c61;--head:#547a02;--hover:rgba(0,0,0,.10);--tip:#fff;--tipb:rgba(0,0,0,.16)}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--surface:#252524;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--card:#2f2f2e;--line:#4a4a47;--hair:#393938;--ink:#ececea;--onink:#16150e;--eyebrow:#f0813f;--lane:#ff3478;--head:#a6e22e;--hover:rgba(255,255,255,.15);--tip:#353534;--tipb:rgba(255,255,255,.16)}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start;flex-wrap:nowrap}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.win{position:relative;background:var(--surface);color:var(--tx);border-radius:12px;overflow:hidden;box-shadow:0 0 0 .5px rgba(0,0,0,.25),0 18px 50px rgba(0,0,0,.18);flex:none}
.tl{position:absolute;left:20px;top:16px;display:flex;gap:8px}
.tl i{width:12px;height:12px;border-radius:50%;display:block}
.tl i:nth-child(1){background:#ff5f57}.tl i:nth-child(2){background:#febc2e}.tl i:nth-child(3){background:#28c840}
.dots{position:absolute;top:19px;left:0;right:0;display:flex;justify-content:center;gap:6px}
.dots i{height:6px;width:6px;border-radius:3px;background:var(--line);display:block}
.dots i.done{background:var(--tx2)}
.dots i.now{width:20px;background:var(--ink)}
.col{position:absolute;top:64px;left:50%;width:620px;margin-left:-310px;display:flex;flex-direction:column;gap:14px}
.head{display:flex;flex-direction:column;align-items:center;gap:8px;text-align:center;padding-bottom:6px}
.eb{font-size:11.5px;font-weight:600;letter-spacing:.9px;color:var(--eyebrow);text-transform:uppercase}
.h1{font-size:28px;font-weight:600;letter-spacing:-.4px}
.sub{font-size:14px;line-height:22px;color:var(--tx2);height:44px}
.card{background:var(--card);border-radius:14px;display:flex;align-items:center;gap:14px;padding:13px 14px 13px 16px;min-height:68px}
.icon{width:38px;height:38px;border-radius:10px;background:var(--surface);display:flex;align-items:center;justify-content:center;color:var(--tx2)}
.rname{font-size:14.5px;font-weight:600}
.rver{font-size:13.5px;color:var(--tx2);margin-left:8px}
.rok{font-size:12px;font-weight:500;color:#3f7d00;margin-left:10px}
.rpath{font:11.5px ui-monospace,"SF Mono",Menlo,monospace;color:var(--tx2);margin-top:3px}
.sel{margin-left:auto;height:30px;border-radius:9px;border:1px solid var(--line);background:var(--surface);padding:0 8px 0 12px;display:flex;align-items:center;gap:8px;font-weight:500}
.note{text-align:center;font-size:12.5px;color:var(--tx2)}
.acts{display:flex;align-items:center;padding-top:8px}
.acts .back{padding:0 12px;height:36px;line-height:36px;color:var(--tx2);font-size:13.5px;font-weight:500;border-radius:10px}
.acts .go{margin-left:auto;width:168px;height:36px;line-height:36px;text-align:center;border-radius:10px;background:var(--ink);color:var(--onink);font-size:13.5px;font-weight:500}
.floor{position:absolute;left:0;right:0;height:1px;background:var(--hair)}
.house{position:absolute;width:46px;height:46px}
.house svg{width:46px;height:46px;display:block}
.lane{position:absolute;inset:0;pointer-events:none}
.subj{position:absolute;font-size:11.5px;line-height:14px;white-space:nowrap;transform:translateX(-50%);color:var(--tx3)}
.subj.done{color:var(--tx2)}
.subj.now{color:var(--tx);font-weight:600}
.subj.hov{color:var(--tx);text-decoration:underline;text-decoration-color:var(--tx3);text-underline-offset:2px}
.badge{position:absolute;transform:translateX(-50%);height:18px;line-height:18px;padding:0 7px;border-radius:5px;background:var(--head);color:var(--onink);font-size:11px;font-weight:600;white-space:nowrap}
.tip{position:absolute;transform:translateX(-50%);padding:4px 8px;border-radius:6px;background:var(--tip);box-shadow:0 0 0 .5px var(--tipb),0 4px 14px rgba(0,0,0,.14);font-size:12px;white-space:nowrap;color:var(--tx)}
.ptr{position:absolute;width:14px;height:20px}
"""


def page(title: str, body: str, w: int, h: int) -> str:
    props = json.dumps({"$preview": {"width": w, "height": h}})
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{esc(title)}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<style>
{CSS}
</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{props}'>
class Component extends DCLogic {{
  renderVals() {{ return {{}}; }}
}}
</script>
</body>
</html>
"""


@dataclass
class Board:
    file: str
    title: str
    w: int
    h: int
    html: str


def board(file: str, title: str, cells: list[tuple[str, str, int, int]], theme: str = "th-l") -> Board:
    """One row of cells, each its caption, its drawing, and the drawing's size."""
    w = 80 + sum(cw for _, _, cw, _ in cells) + 48 * (len(cells) - 1)
    h = 34 + 36 + 12 + max(ch for _, _, _, ch in cells) + 40
    inner = "".join(f'<div class="cell"><div class="cap">{cap}</div>{draw}</div>' for cap, draw, _, _ in cells)
    body = f'<div class="board {theme}" style="width:{w}px;height:{h}px"><div class="cells">{inner}</div></div>'
    return Board(file, title, w, h, page(title, body, w, h))


def rows_board(file: str, title: str, rows: list[list[tuple[str, str, int, int]]], theme: str = "th-l") -> Board:
    w = 80 + max(sum(cw for _, _, cw, _ in r) + 48 * (len(r) - 1) for r in rows)
    h = 34 + sum(36 + 12 + max(ch for _, _, _, ch in r) for r in rows) + 36 * (len(rows) - 1) + 40
    inner = "".join(
        '<div class="cells">' + "".join(f'<div class="cell"><div class="cap">{cap}</div>{draw}</div>' for cap, draw, _, _ in r) + "</div>"
        for r in rows
    )
    body = f'<div class="board {theme}" style="width:{w}px;height:{h}px">{inner}</div>'
    return Board(file, title, w, h, page(title, body, w, h))


# ---------------------------------------------------------------- the window


def house(x: float, foot_y: float) -> str:
    return (
        f'<div class="house" style="left:{x - HOUSE_W / 2:.1f}px;top:{foot_y - HOUSE_H:.1f}px">'
        f'<svg viewBox="0 0 573 573" aria-hidden="true"><path transform="translate(-305.5 -132)" fill="#D54802" '
        f'fill-rule="evenodd" d="{HOUSE_PATH}"></path></svg></div>'
    )


def git_screen(eyebrow: str) -> str:
    branch = ('<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" '
              'stroke-linecap="round" stroke-linejoin="round"><path d="M6 3v12"/><circle cx="18" cy="6" r="3"/>'
              '<circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg>')
    chevrons = ('<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
                'stroke-linecap="round" stroke-linejoin="round" style="color:var(--tx2)"><path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/></svg>')
    return (
        '<div class="col">'
        f'<div class="head"><div class="eb">{esc(eyebrow)}</div><div class="h1">Git 2.52.0 is ready</div>'
        '<div class="sub">Roga runs the Git on your Mac, with your own configuration, and needs 2.45 or newer.</div></div>'
        f'<div class="card"><div class="icon">{branch}</div><div><div><span class="rname">Git</span>'
        '<span class="rver">2.52.0</span><span class="rok">✓ Detected</span></div>'
        f'<div class="rpath">/opt/homebrew/bin/git</div></div><div class="sel">Homebrew {chevrons}</div></div>'
        '<div class="note">Found 3 Gits. This is the first one in your PATH.</div>'
        '<div class="acts"><div class="back">Back</div><div class="go">Continue</div></div>'
        "</div>"
    )


def today_floor(at: int, steps: list[tuple[str, str, str]], height: int) -> str:
    """Today's hairline floor and the house on it. Welcome isn't on the floor,
    so the house's run starts at Looking."""
    on_floor = [s for s in steps if s[0] != "welcome"]
    index = [s[0] for s in on_floor].index(steps[at][0])
    y = height - FLOOR_FROM_BOTTOM
    x = commit_x(index, len(on_floor))
    return f'<div class="floor" style="top:{y}px"></div>' + house(x, y)


ARC_RISE = 22                 # how far above the lane a bypass runs
ARC_TURN = 40                 # how far along the lane a bypass takes to rise


def bypass_path(xa: float, xb: float, y: float) -> str:
    """A bypass from one commit to another, as history draws a branch: it
    leaves the first commit sideways, rises to a lane of its own above, runs
    along it, and comes down into the second."""
    top = y - ARC_RISE
    return (f"M{xa:.1f},{y} C{xa + ARC_TURN:.1f},{y} {xa + ARC_TURN:.1f},{top} {xa + 2 * ARC_TURN:.1f},{top} "
            f"L{xb - 2 * ARC_TURN:.1f},{top} C{xb - ARC_TURN:.1f},{top} {xb - ARC_TURN:.1f},{y} {xb:.1f},{y}")


def lane(at: int, steps: list[tuple[str, str, str]], height: int, *, option: str = "A", hover: int | None = None,
         bypass: tuple[int, int] | None = None, leaping: bool = False) -> str:
    """The floor as a lane: a commit for each screen, the house standing on the
    one setup is at, which is HEAD. Done commits are solid, later ones hollow,
    and the line past HEAD is faint. A step that was answered No is skipped: a
    bypass runs above it from the commit before it to the next one taken, and
    the skipped commits stay on a faint stretch of the lane, hollow."""
    count = len(steps)
    y = height - LANE_FROM_BOTTOM
    xs = [commit_x(i, count) for i in range(count)]
    skipped = set(range(bypass[0] + 1, bypass[1])) if bypass else set()
    svg = [f'<svg class="lane" width="{WIN_W}" height="{height}" viewBox="0 0 {WIN_W} {height}">']

    def segment(a: int, b: int, faint: bool) -> None:
        if b <= a:
            return
        style = 'stroke-opacity=".3" stroke-dasharray="1 6"' if faint else ""
        svg.append(f'<line x1="{xs[a]:.1f}" y1="{y}" x2="{xs[b]:.1f}" y2="{y}" stroke="var(--lane)" {style} stroke-width="2" stroke-linecap="round"/>')

    if bypass:
        a, b = bypass
        segment(0, min(a, at), False)
        segment(a, b, True)
        svg.append(f'<path d="{bypass_path(xs[a], xs[b], y)}" fill="none" stroke="var(--lane)" stroke-width="2" stroke-linecap="round"/>')
        segment(b, at, False)
    else:
        segment(0, at, False)
    segment(at, count - 1, True)
    for i, x in enumerate(xs):
        if hover == i:
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="11" fill="var(--hover)"/>')
        if i in skipped:
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="3.5" fill="var(--surface)" stroke="var(--lane)" stroke-opacity=".45" stroke-width="1.5"/>')
        elif i < at:
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="{5.5 if hover == i else 4}" fill="var(--lane)"/>')
        elif i == at:
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="8" fill="none" stroke="var(--head)" stroke-width="2"/>')
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="4" fill="var(--lane)"/>')
        else:
            svg.append(f'<circle cx="{x:.1f}" cy="{y}" r="3.5" fill="var(--surface)" stroke="var(--lane)" stroke-opacity=".45" stroke-width="1.5"/>')
    svg.append("</svg>")
    parts = ["".join(svg)]
    for i, (_, _, subject) in enumerate(steps):
        x = xs[i]
        if option == "A":
            cls = "now" if i == at else "hov" if hover == i else "" if i in skipped else "done" if i < at else ""
            parts.append(f'<div class="subj {cls}" style="left:{x:.1f}px;top:{y + 14}px">{esc(subject)}</div>')
        elif i == at:
            parts.append(f'<div class="badge" style="left:{x:.1f}px;top:{y + 13}px">{esc(subject)}</div>')
    if hover is not None:
        x = xs[hover]
        parts.append(f'<div class="tip" style="left:{x:.1f}px;top:{y - 44}px">Back to {esc(steps[hover][2])}</div>')
        parts.append(
            f'<svg class="ptr" style="left:{x + 3:.1f}px;top:{y - 1}px" viewBox="0 0 14 20"><path d="M1 1v15l4-4 3 7 3-1-3-7h5z" '
            'fill="#000" stroke="#fff" stroke-width="1.2" stroke-linejoin="round"/></svg>'
        )
    if leaping and bypass:
        # Halfway through the leap: over the skipped commits, above the bypass.
        mid = (xs[bypass[0] + 1] + xs[bypass[1]]) / 2
        parts.append(house(mid, y - ARC_RISE - 18))
    else:
        parts.append(house(xs[at], y))
    return "".join(parts)


def window(content: str, height: int = WIN_H, *, dots: int | None = None, steps_shown: int = 5) -> str:
    top = '<div class="tl"><i></i><i></i><i></i></div>'
    if dots is not None:
        top += '<div class="dots">' + "".join(
            f'<i class="{"now" if i == dots else "done" if i < dots else ""}"></i>' for i in range(steps_shown)
        ) + "</div>"
    return f'<div class="win" style="width:{WIN_W}px;height:{height}px">{top}{content}</div>'


def strip(content: str) -> str:
    """The bottom of the window, where the lane is."""
    return f'<div class="win" style="width:{WIN_W}px;height:{STRIP_H}px;border-radius:0 0 12px 12px">{content}</div>'


# ---------------------------------------------------------------- boards

GIT = 2


def board_today() -> Board:
    draw = window(git_screen("Git") + today_floor(GIT, STEPS, WIN_H), dots=1)
    return board("Sn-Today.dc.html", "Setup's floor today", [("Today <i>· dots at the top, a hairline floor at the bottom</i>", draw, WIN_W, WIN_H)])


def board_options() -> Board:
    a = window(git_screen("Choose git") + lane(GIT, STEPS, WIN_H, option="A"))
    b = window(git_screen("Choose git") + lane(GIT, STEPS, WIN_H, option="B"))
    return board("Sn-Options.dc.html", "The floor as a lane", [
        ("A <i>· every commit's subject under it</i>", a, WIN_W, WIN_H),
        ("B <i>· only HEAD's subject, in a badge</i>", b, WIN_W, WIN_H),
    ])


def board_steps() -> Board:
    rows = []
    names = ["Look around", "Choose git", "Add agents", "Install hooks", "Open Roga"]
    for at in range(1, len(STEPS)):
        rows.append([(f"On {esc(STEPS[at][1])} <i>· HEAD is {esc(names[at - 1])}</i>", strip(lane(at, STEPS, STRIP_H)), WIN_W, STRIP_H)])
    return rows_board("Sn-Steps.dc.html", "A at every step", rows)


def board_hover() -> Board:
    return board("Sn-Hover.dc.html", "Going back from the lane", [
        ("On Install hooks, the pointer on Choose git <i>· a click runs the house back there</i>", strip(lane(4, STEPS, STRIP_H, hover=GIT)), WIN_W, STRIP_H),
    ])


AGENTS, HOOKS, READY = 3, 4, 5


def board_skips() -> Board:
    return rows_board("Sn-Skips.dc.html", "Steps answered No", [
        [("Don't Use Agents, or no agents found <i>· the house skips Add agents and Install hooks</i>",
          strip(lane(READY, STEPS, STRIP_H, bypass=(GIT, READY))), WIN_W, STRIP_H)],
        [("Not Now on Hooks <i>· the house skips Install hooks</i>",
          strip(lane(READY, STEPS, STRIP_H, bypass=(AGENTS, READY))), WIN_W, STRIP_H)],
        [("The moment after Don't Use Agents <i>· the house leaps from Add agents over the bypass</i>",
          strip(lane(READY, STEPS, STRIP_H, bypass=(GIT, READY), leaping=True)), WIN_W, STRIP_H)],
        [("The pointer on a skipped commit <i>· a click goes back to Add agents, and the bypass goes</i>",
          strip(lane(READY, STEPS, STRIP_H, bypass=(GIT, READY), hover=AGENTS)), WIN_W, STRIP_H)],
    ])


def board_dark() -> Board:
    draw = window(git_screen("Choose git") + lane(GIT, STEPS, WIN_H, option="A"))
    return board("Sn-Dark.dc.html", "A in the dark", [("A <i>· the lane in Monokai's dark pink, HEAD's ring in its green</i>", draw, WIN_W, WIN_H)], theme="th-d")


def all_boards() -> list[list[Board]]:
    return [[board_today()], [board_options()], [board_steps(), board_hover()], [board_skips()], [board_dark()]]


TITLES = ["Setup's floor today", "The floor as a lane", "A at every step", "Steps answered No", "A in the dark"]

INTROS = [
    "Dots at the top of the window say how far along setup is, and the house runs along a hairline floor at the bottom. The two say the same thing twice, far apart, and neither says what the steps are.",
    "The floor becomes one lane of a commit graph, in history's style: a commit for each screen, from Welcome's Initial commit to Ready's Open Roga, with the house standing on the commit setup is at, which is HEAD. The screen's small title above its heading is the commit's subject, so the words already exist and stay in step with the screens. The dots at the top go. Done commits are solid, HEAD has history's green ring, and later commits are hollow, past a faint line. A click on a done commit goes back to it, as Back does.",
    "A on each screen. The lane sits 14 points higher than today's floor, to leave room for the subjects under it, and it always has all six commits, so nothing moves along it when a step is answered.",
    "A step answered No is skipped rather than taken off the lane, the way a branch goes around commits in history: a bypass leaves the commit before it, runs on a lane of its own above, and comes down into the next commit setup takes. The skipped commits stay where they were, hollow on a faint stretch of the lane, so the six commits never move and the house's run never changes length. Don't Use Agents, and finding no agents, skip Add agents and Install hooks. Not Now on Hooks skips Install hooks. Either way the house leaps over what it skips, with the bypass drawing in under it, and fades there with Reduce Motion.",
    "The same window in the dark appearance. The lane takes Monokai's dark-mode pink and HEAD's ring its green, as history's first lane and the current branch do.",
]

NOTES = {
    "Sn-Today.dc.html": "On main, on the Git screen, the second of five dots. Welcome isn't on the floor, so the house's run starts at Looking.",
    "Sn-Options.dc.html": "I'd build A. It says what's coming and what's done in words, at a glance, and it's the only place setup lists its steps. B is quieter and looks more like history, where only branches get names, but a row of bare dots says no more than today's dots at the top. In both, each commit is a button that VoiceOver reads by its subject, and the house runs back along the lane, or fades there with Reduce Motion.",
    "Sn-Steps.dc.html": "Initial commit is done from the start, since Welcome comes before the floor: the house leaps down onto Look around, and a click on Initial commit sends it back up to Welcome.",
    "Sn-Skips.dc.html": "A skipped commit was still a screen someone saw, so it's a button like any commit that's done, and its tooltip says where it goes. Going back to it takes the bypass away, so the answer can change. VoiceOver reads it as Add agents, skipped. It's not quite git, where a line that joins two commits has commits of its own, but a bypass reads at once, and the house jumping over the steps it skipped is the point.",
    "Sn-Hover.dc.html": "A done commit under the pointer grows and gets the fill a button has under the pointer, its subject is underlined, and its tooltip says where it goes. HEAD and the commits after it aren't buttons, so nothing jumps ahead of a step that hasn't been answered.",
    "Sn-Dark.dc.html": "The subjects use the screens' note gray for what's done, ink for HEAD, and the faintest gray for what's to come.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tSn{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nSn{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
        x = 0
        tallest = 0
        for b in row_boards:
            boards[b.file] = {"x": x, "y": y, "w": b.w, "h": b.h, "page": PAGE_ID, "title": b.title}
            notes["n" + re.sub(r"[^A-Za-z0-9]", "", b.file.removesuffix(".dc.html"))] = {
                "x": x, "y": y + b.h + 40, "w": min(b.w, 720), "text": NOTES[b.file], "page": PAGE_ID,
            }
            x += b.w + 80
            tallest = max(tallest, b.h)
        y += tallest + 40 + 300 + 640
    return boards, notes


@click.command()
@click.option("--out", "out", type=click.Path(file_okay=False, path_type=Path), required=True, help="The folder that holds project/.")
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Setup lane page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Setup lane boards, and optionally merge them into a canvas.json."""
    rows = all_boards()
    project = out / "project"
    project.mkdir(parents=True, exist_ok=True)
    for b in (b for r in rows for b in r):
        (project / b.file).write_text(b.html)
        click.echo(f"{b.file}  {b.w}×{b.h}  {len(b.html) // 1024} KB")
    if canvas:
        data = json.loads(canvas.read_text())
        boards, notes = layout(rows)
        clashes = sorted(k for k in notes if k in data["notes"] and data["notes"][k].get("page") != PAGE_ID)
        if clashes:
            raise click.ClickException(f"Note ids already used on other pages: {', '.join(clashes)}")
        stale = sorted(k for k, v in data["boards"].items() if v.get("page") == PAGE_ID and k not in boards)
        data["boards"] = {k: v for k, v in data["boards"].items() if v.get("page") != PAGE_ID}
        data["notes"] = {k: v for k, v in data["notes"].items() if v.get("page") != PAGE_ID}
        data["boards"].update(boards)
        data["notes"].update(notes)
        data["order"] = [f for f in data["order"] if f in data["boards"]] + [f for f in boards if f not in data["order"]]
        if not any(p["id"] == PAGE_ID for p in data["pages"]):
            data["pages"].append({"id": PAGE_ID, "name": PAGE_NAME})
        canvas.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        click.echo(f"Merged {len(boards)} boards and {len(notes)} notes into {canvas}")
        for name in stale:
            click.echo(f"No longer drawn, remove from the canvas: project/{name}")


if __name__ == "__main__":
    main()
