# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Hooks picture boards for the design canvas "yaga layout options".

Setup's Hooks screen runs taller than the room above the lane (decision 69),
mostly because of its picture of the sidebar's marks, which stands three
worktrees and the rows around them on top of each other. These boards lay the
three out across the column instead: today's screen, the picture across at
the column's width (A), across and wider than the column (B), and A in the
dark appearance.

    uv run docs/design/hooks-picture/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

The window is setup's, 1,280 by 800 points, with the lane pinned along its
bottom, drawn by `docs/design/setup-lane/boards.py`. The screen is a first
run's, with the hooks not installed in either agent.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
PAGE_ID = "hookspicture"
PAGE_NAME = "Hooks picture"

_spec = importlib.util.spec_from_file_location("setup_lane_boards", HERE.parent / "setup-lane" / "boards.py")
sl = importlib.util.module_from_spec(_spec)
sys.modules["setup_lane_boards"] = sl
_spec.loader.exec_module(sl)
esc, Board = sl.esc, sl.Board

WIN_W, WIN_H = sl.WIN_W, sl.WIN_H
LANE_BOX = 90            # SetupLane.height: the lane and the house on it
HOOKS = 4                # Install hooks, on the lane

CSS = sl.CSS + r"""
.th-l{--panel:#efefef;--sel:rgba(0,0,0,.11);--count:#c94402;--warn:#a85b00;--blue:#2f6de1;--term:#272822;--rule:#e1e1de}
.th-d{--panel:#232322;--sel:rgba(255,255,255,.11);--count:#f0813f;--warn:#ffb340;--blue:#4a8cff;--term:#1a1b17;--rule:#464644}
.col{overflow:visible}
.say{font-size:13.5px;line-height:21px}
.say b{font-weight:600}
.hcard{background:var(--card);border-radius:14px;overflow:hidden}
.hrow{display:flex;align-items:flex-start;gap:12px;padding:11px 14px 11px 16px;border-top:1px solid var(--rule)}
.hrow:first-child{border-top:none}
.hname{font-size:13.5px;font-weight:600}
.haside{font-size:12px;color:var(--tx2);margin-left:8px}
.hstatus{margin-left:auto;font-size:12.5px;color:var(--tx2);white-space:nowrap}
.term{background:var(--term);padding:12px 16px;font:11px/18px ui-monospace,"SF Mono",Menlo,monospace;color:#f8f8f2;white-space:nowrap;overflow:hidden}
.term .p{color:#a59f85}.term .v{color:#66d9ef}.term .o{color:#e6db74}
.acts .sec{margin-left:auto;margin-right:8px;padding:0 18px;height:36px;line-height:36px;border-radius:10px;background:var(--card);font-size:13.5px;font-weight:500}
.acts .sec + .go{margin-left:0}
.lanebox{position:absolute;left:0;right:0;bottom:0;height:90px;background:var(--surface)}
.lanebox::before{content:"";position:absolute;left:0;right:0;top:-20px;height:20px;background:linear-gradient(rgba(255,255,255,0),var(--surface))}
.th-d .lanebox::before{background:linear-gradient(rgba(37,37,36,0),var(--surface))}
.glimpse{position:relative;background:var(--panel);box-shadow:inset 1px 0 0 rgba(0,0,0,.05),inset -1px 0 0 rgba(0,0,0,.05);padding:10px 8px;-webkit-mask-image:linear-gradient(#0000,#000 12px,#000 calc(100% - 12px),#0000);mask-image:linear-gradient(#0000,#000 12px,#000 calc(100% - 12px),#0000)}
.srow{position:relative;height:52px;border-radius:8px;padding:0 4px 0 10px}
.srow.on{background:var(--sel)}
.l1{display:flex;align-items:center;height:32px;gap:6px;font-size:13px}
.l2{display:flex;align-items:center;height:16px;margin-top:-4px;font-size:13px;color:var(--tx2);padding-right:7px}
.fade{flex:1;min-width:0;white-space:nowrap;overflow:hidden;-webkit-mask-image:linear-gradient(90deg,#000 calc(100% - 18px),#0000);mask-image:linear-gradient(90deg,#000 calc(100% - 18px),#0000)}
.cnt{color:var(--count);font-size:13px;margin-left:auto}
.mk{width:24px;height:24px;display:flex;align-items:center;justify-content:center;flex:none}
.l2 .t{margin-left:8px;flex:none}
.l2.warn{color:var(--warn)}
.three{display:flex;gap:16px;justify-content:center}
.ex{display:flex;flex-direction:column;gap:8px;flex:none}
.ex .ti{font-size:13px;font-weight:600;text-align:center;margin-top:2px}
.ex .me{font-size:12.5px;line-height:17px;color:var(--tx2);text-align:center}
.vpic{position:relative;height:284px}
.over{position:absolute;left:0;right:0;border-top:1px dashed rgba(196,18,63,.6);z-index:3}
.overl{position:absolute;right:12px;font-size:11px;color:#c4123f;background:var(--surface);padding:0 4px;z-index:3}
"""

# ---------------------------------------------------------------- the marks

RING = ('<svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true"><circle cx="7" cy="7" r="5.5" fill="none" '
        'stroke="var(--line)" stroke-width="1.6"/><path d="M7 1.5 A5.5 5.5 0 0 1 12.5 7" fill="none" stroke="var(--count)" '
        'stroke-width="1.6" stroke-linecap="round"/></svg>')
WAIT = ('<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="var(--warn)" stroke-width="2" stroke-linecap="round" '
        'aria-hidden="true"><circle cx="12" cy="12" r="10"/><path d="M12 8v4M12 16h.01"/></svg>')
DOT = '<svg width="9" height="9" viewBox="0 0 9 9" aria-hidden="true"><circle cx="4.5" cy="4.5" r="4" fill="var(--blue)"/></svg>'

SAMPLES = [
    # branch, files, mark, second line, time, selected, waits, title, meaning
    ("agent/fix-login", 3, RING, "Editing LoginView.swift", "2 min", True, False, "Working", "Agent active in this worktree."),
    ("agent/payments", 1, WAIT, "Approval required: git push", "1 min", False, True, "Waiting", "Approval or response required."),
    ("agent/search-index", 7, DOT, "Claude Code finished", "", False, False, "Finished", "Session finished, changes not yet reviewed."),
]


def sidebar_row(branch: str, files: int, mark: str, line: str, time: str, selected: bool, waits: bool) -> str:
    t = f'<span class="t">{esc(time)}</span>' if time else ""
    return (
        f'<div class="srow{" on" if selected else ""}">'
        f'<div class="l1"><span class="fade">{esc(branch)}</span><span class="cnt">{files}</span><span class="mk">{mark}</span></div>'
        f'<div class="l2{" warn" if waits else ""}"><span class="fade">{esc(line)}</span>{t}</div></div>'
    )


def three_across(width: int) -> tuple[str, int]:
    """The three worktrees across, each in its own glimpse of the sidebar,
    with what its mark means under it. Returns the html and its height."""
    each = (width - 2 * 16) // 3
    parts = []
    for branch, files, mark, line, time, selected, waits, title, meaning in SAMPLES:
        parts.append(
            f'<div class="ex" style="width:{each}px"><div class="glimpse">{sidebar_row(branch, files, mark, line, time, selected, waits)}</div>'
            f'<div class="ti">{esc(title)}</div><div class="me">{esc(meaning)}</div></div>'
        )
    overhang = (width - sl.COLUMN) // 2
    return (f'<div class="three" style="width:{width}px;margin-left:{-overhang}px">{"".join(parts)}</div>', 72 + 8 + 20 + 8 + 34)


def vertical_picture() -> str:
    """Today's picture: a glimpse of the sidebar 280 points wide, with a
    repository and three of its worktrees, and a line from each mark out to
    what it means."""
    rows = [
        '<div style="height:32px;line-height:32px;text-align:center;color:var(--tx3);font-size:12px">acme</div>',
        '<div class="srow" style="height:32px"><div class="l1">api ⌄<span class="cnt">2</span><span class="mk"></span></div></div>',
    ]
    callouts = []
    y = 64
    for branch, files, mark, line, time, selected, waits, title, meaning in SAMPLES:
        rows.append(sidebar_row(branch, files, mark, line, time, selected, waits).replace('class="srow', 'style="margin-left:20px" class="srow'))
        callouts.append(
            f'<div style="position:absolute;left:266px;top:{y + 15}px;display:flex;gap:10px;align-items:flex-start;white-space:nowrap">'
            f'<div style="width:30px;height:1px;background:var(--tx3);margin-top:0"></div><div style="margin-top:-9px">'
            f'<div style="font-weight:600;font-size:13px">{esc(title)}</div><div style="font-size:12.5px;color:var(--tx2)">{esc(meaning)}</div></div></div>'
        )
        y += 54
    rows += [
        '<div class="srow" style="height:32px"><div class="l1">web ›</div></div>',
        '<div class="srow" style="height:32px"><div class="l1" style="color:var(--tx3)">website</div></div>',
    ]
    return (f'<div class="vpic"><div class="glimpse" style="position:absolute;left:58px;top:0;width:280px;height:284px;padding:0 8px">'
            f'{"".join(rows)}</div><div style="position:absolute;left:58px;top:0">{"".join(callouts)}</div></div>')


def hooks_card() -> str:
    term = [
        '<span class="p">$</span> claude plugin marketplace add <span class="v">~/Library/Application\\ Support/sh.roga.app/plugins</span>',
        '<span class="p">$</span> claude plugin install <span class="v">roga-hooks@roga</span> <span class="o">--scope</span> <span class="v">user</span>',
        '<span class="p">$</span> codex plugin marketplace add <span class="v">~/Library/Application\\ Support/sh.roga.app/plugins</span>',
        '<span class="p">$</span> codex plugin install <span class="v">roga-hooks@roga</span>',
    ]
    return (
        '<div class="hcard">'
        '<div class="hrow"><span class="hname">Claude Code</span><span class="hstatus">Not installed</span></div>'
        '<div class="hrow"><span class="hname">Codex</span><span class="haside">asks you to trust the hooks before it runs them</span>'
        '<span class="hstatus">Not installed</span></div>'
        f'<div class="term">{"<br>".join(term)}</div></div>'
    )


def hooks_screen(picture: str) -> str:
    return (
        '<div class="col">'
        f'<div class="head"><div class="eb">Install hooks</div><div class="h1">Agent status</div>'
        '<div class="sub">Install hooks to show working, waiting and finished states beside each worktree in the sidebar.</div></div>'
        f"{picture}"
        '<div class="say"><b>Install Hooks</b> installs the roga-hooks plugin in Claude Code and Codex using the commands below. '
        "Hooks report session activity without changing agent behavior.</div>"
        f"{hooks_card()}"
        '<div class="acts"><div class="back">Back</div><div class="sec">Not Now</div><div class="go">Install Hooks</div></div>'
        "</div>"
    )


def window(content: str) -> str:
    lane = f'<div class="lanebox">{sl.lane(HOOKS, sl.STEPS, LANE_BOX)}</div>'
    return sl.window(content + lane)


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


def board(file: str, title: str, cells: list[tuple[str, str]], theme: str = "th-l") -> Board:
    w = 80 + len(cells) * WIN_W + 48 * (len(cells) - 1)
    h = 34 + 36 + 12 + WIN_H + 40
    inner = "".join(f'<div class="cell"><div class="cap">{cap}</div>{draw}</div>' for cap, draw in cells)
    body = f'<div class="board {theme}" style="width:{w}px;height:{h}px"><div class="cells">{inner}</div></div>'
    return Board(file, title, w, h, page(title, body, w, h))


# ---------------------------------------------------------------- boards


def board_today() -> Board:
    over = ('<div class="over" style="top:690px"></div>'
            '<div class="overl" style="top:682px">the lane starts here; the rest scrolls under it</div>')
    return board("Hk-Today.dc.html", "The Hooks screen today", [
        ("Today <i>· the picture stands the worktrees one over another, and the screen runs under the lane</i>", window(hooks_screen(vertical_picture())) .replace('<div class="lanebox">', over + '<div class="lanebox">')),
    ])


def board_options() -> Board:
    a, _ = three_across(sl.COLUMN)
    b, _ = three_across(800)
    return board("Hk-Across.dc.html", "The picture across", [
        ("A <i>· three across the column, 196 points each</i>", window(hooks_screen(a))),
        ("B <i>· three across, 800 points wide, past the column on each side</i>", window(hooks_screen(b))),
    ])


def board_dark() -> Board:
    a, _ = three_across(sl.COLUMN)
    return board("Hk-Dark.dc.html", "A in the dark", [("A <i>· in the dark appearance</i>", window(hooks_screen(a)))], theme="th-d")


def all_boards() -> list[list[Board]]:
    return [[board_today()], [board_options()], [board_dark()]]


TITLES = ["The Hooks screen today", "The picture across", "A in the dark"]

INTROS = [
    "On a first run, with the hooks in neither agent, the Hooks screen is about 725 points tall, and the window has about 645 above the lane, so its buttons are under the lane until it scrolls. The picture of the sidebar's marks is 284 of those points: a group's label, a repository, its three worktrees and two repositories after them, one over another.",
    "The three worktrees go across, each in a glimpse of the sidebar of its own, with what its mark means under it rather than beside it. The repository rows around them go, since they only set the scene. The picture is about half as tall, 142 points instead of 284, and the screen ends about 60 points above the lane. Settings › Agents keeps the tall picture, where there's room for it.",
    "A in the dark appearance, with the sidebar's darker panel behind each worktree.",
]

NOTES = {
    "Hk-Today.dc.html": "The dashed line is where the lane starts. The commands, the buttons and the last of the agents' rows are under it until the screen scrolls, and with Codex inside the ChatGPT app its longer path adds a line to the commands.",
    "Hk-Across.dc.html": "I'd build B. At 196 points, A cuts the waiting worktree's line short, and Approval required: git push fades out at git, which is the part that says what's wanted. B gives each worktree 256 points, enough for every line whole with its time, and its edges line up with nothing on the screen, so reaching past the column reads as a picture set into the page rather than a mistake. Both cut the screen by the same 142 points.",
    "Hk-Dark.dc.html": "The panel is the sidebar's dark gray, a step darker than the page, as in the window.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tHk{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nHk{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Hooks picture page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Hooks picture boards, and optionally merge them into a canvas.json."""
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
