# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Branches boards for the design canvas "yaga layout options".

How the refs panel could show branches: one height for every row, smaller
icons and indents, a worktree's branch marked by its icon, counts in the
tabs' gray, merged branches, and pointing at a branch lighting up its remote
copy and its worktree's tab.

    uv run docs/design/branch-list/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Every part is drawn at its size in points. The refs panel is 288 points wide
in a window 860 tall, its header 44, and the middle column 680. The branches
are this repository's own, as they stood on 27 November 2026.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass
from pathlib import Path

import click

PAGE_ID = "branches"
PAGE_NAME = "Branches"
ICONS = Path(__file__).resolve().parents[1] / "icons"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

PANEL_W = 288      # the refs panel's default width
WIN_H = 860        # the window's height on these boards
HEAD_H = 44        # the panel's header, beside the title row
LIST_H = WIN_H - HEAD_H
MID_W = 680        # the middle column in the default window
SECTION_H = 32     # a section's header
ROW1 = 28          # a row with one line
ROW2 = 40          # a row with two
TODAY_STEP = 22    # how far in a folder or a remote moves its rows today
NEW_STEP = 16      # and in A and B
TAB_W = 98         # each of the six tabs, squeezed into the middle's 680 points


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--surface:#fff;--title:#f3f3f2;--line:#e2e2e2;--tx:#1f1f1e;--tx2:#6b6b66;--tx3:#a3a39e;--hov:rgba(0,0,0,.06);--bhov:rgba(0,0,0,.09);--cur:#547a02;--sky:#10819e;--lk:rgba(16,129,158,.13);--lkc:rgba(84,122,2,.13);--glow:rgba(16,129,158,.5);--glowc:rgba(84,122,2,.5);--red:#cd1755;--grn:#4d7000;--act:#c94402;--tabon:#fff;--tabedge:#dedede;--tabsh:rgba(0,0,0,.12);--tip:#f6f6f6;--tiptx:#1a1a1a;--seg:#ecebe8;--segon:#fff;--l1:#db1c61;--pillbg:#fff;--sheet:#fff;--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2)}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--surface:#222;--title:#1b1b1b;--line:#393939;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--hov:rgba(255,255,255,.06);--bhov:rgba(255,255,255,.12);--cur:#a6e22e;--sky:#66d9ef;--lk:rgba(102,217,239,.14);--lkc:rgba(166,226,46,.14);--glow:rgba(102,217,239,.55);--glowc:rgba(166,226,46,.55);--red:#fc5884;--grn:#a6e22e;--act:#f0813f;--tabon:#3b3b3b;--tabedge:#4d4d4d;--tabsh:rgba(0,0,0,.4);--tip:#3a3a39;--tiptx:#f0f0f0;--seg:#2c2c2b;--segon:#4a4a47;--l1:#ff3478;--pillbg:#2e2e2d;--sheet:#2a2a29;--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16)}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
svg{fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}

.panel{position:relative;width:288px;flex:none;background:var(--surface);color:var(--tx);display:flex;flex-direction:column;overflow:hidden;border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
.ph{height:44px;flex:none;display:flex;align-items:center;justify-content:flex-end;gap:2px;padding:0 8px;background:var(--title);border-bottom:1px solid var(--line)}
.ib{width:28px;height:28px;display:grid;place-items:center;color:var(--tx2);border-radius:7px;flex:none}
.ib svg{width:16px;height:16px;stroke-width:1.75}
.ib.sm{width:22px;height:22px;border-radius:6px}
.ib.sm svg{width:13px;height:13px;stroke-width:2}
.lw{position:relative;flex:1;min-height:0}
.list{height:100%;overflow:hidden;padding-bottom:10px}
.list.sc{overflow-y:auto}

.sh{height:32px;display:flex;align-items:center;gap:3px;padding:0 10px 0 16px;font-size:12px;font-weight:500;color:var(--tx2);white-space:nowrap}
.sh .cv{margin-left:1px}
.sp{flex:1 1 0;min-width:0}
.r{position:relative;display:flex;align-items:center;margin:0 6px;padding-right:8px;border-radius:6px;white-space:nowrap;transition:background-color .15s ease}
.r.h28{height:28px}
.r.h40{height:40px}
.ri{flex:none;display:grid;place-items:center;color:var(--tx2)}
.ri.cur{color:var(--cur)}
.ri.sky{color:var(--sky)}
.t .ri{width:16px;margin-right:8px}
.t .ri svg{width:15px;height:15px;stroke-width:2}
.n .ri{width:14px;margin-right:6px}
.n .ri svg{width:12px;height:12px;stroke-width:2.4}
.tx{flex:1 1 0;min-width:0;display:flex;flex-direction:column;justify-content:center;gap:1px}
.l1{display:flex;align-items:center;gap:6px;min-width:0;height:17px;line-height:17px}
.nm{flex:1 1 0;min-width:0;overflow:hidden;font-size:13px;-webkit-mask-image:linear-gradient(90deg,#000 calc(100% - 18px),transparent);mask-image:linear-gradient(90deg,#000 calc(100% - 18px),transparent)}
.nm.dim{color:var(--tx2)}
.nm.fo,.nm.rn{flex:0 1 auto;-webkit-mask-image:none;mask-image:none}
.nm.fo{color:var(--tx2)}
.cv{width:10px;height:10px;color:var(--tx2);margin-left:-3px}
.cv svg{width:10px;height:10px;stroke-width:2.6}
.addr{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;font-size:11.5px;color:var(--tx2)}
.tr{flex:none;display:flex;align-items:center;gap:6px;margin-left:auto}
.l2{font-size:11.5px;line-height:15px;height:15px;color:var(--tx2);overflow:hidden;-webkit-mask-image:linear-gradient(90deg,#000 calc(100% - 18px),transparent);mask-image:linear-gradient(90deg,#000 calc(100% - 18px),transparent)}
.ck{display:grid;place-items:center;color:var(--tx2)}
.ck svg{width:12px;height:12px;stroke-width:2.4}
.abt{display:flex;gap:6px;font:11px/1 ui-monospace,"SF Mono",Menlo,monospace}
.abt .dn{color:var(--red)}
.abt .up{color:var(--grn)}
.ab{display:flex;gap:5px;font-size:12px;color:var(--tx2);font-variant-numeric:tabular-nums}
.mg{font-size:11.5px;color:var(--tx3)}
.dt{font-size:11.5px;color:var(--tx2)}
.r.hv{background:var(--hov)}
.r.lk{background:var(--lk)}
.r.lkc{background:var(--lkc)}

.edge{position:absolute;left:50%;transform:translateX(-50%);z-index:4;display:flex;align-items:center;gap:5px;height:24px;max-width:250px;padding:0 10px 0 8px;border-radius:12px;background:var(--pillbg);color:var(--tx);font-size:11.5px;white-space:nowrap;box-shadow:0 0 0 1px var(--gc),0 3px 10px rgba(0,0,0,.14)}
.edge.s{--gc:var(--sky)}
.edge.c{--gc:var(--cur)}
.edge.bot{bottom:10px}
.edge.top{top:6px}
.edge svg{width:12px;height:12px;color:var(--gc);stroke-width:2.4}
.edge span{min-width:0;overflow:hidden;text-overflow:ellipsis}

.win{position:relative;width:968px;height:860px;flex:none;display:flex;flex-direction:column;background:var(--surface);color:var(--tx);border-radius:10px;overflow:hidden;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
.wtop{height:44px;flex:none;display:flex;background:var(--title);border-bottom:1px solid var(--line)}
.tabs{width:680px;flex:none;display:flex;align-items:center;gap:4px;padding:0 8px;min-width:0}
.ptop{flex:1;display:flex;align-items:center;justify-content:flex-end;gap:2px;padding:0 8px;border-left:1px solid var(--line)}
.wbody{flex:1;min-height:0;display:flex}
.mid{width:680px;flex:none;display:flex;flex-direction:column;border-right:1px solid var(--line);min-width:0}
.rp{flex:1;min-width:0;display:flex;flex-direction:column}
.tab{position:relative;height:32px;display:flex;align-items:center;gap:6px;padding:0 6px 0 9px;border-radius:8px;flex:none;min-width:0;color:var(--tx);transition:box-shadow .15s ease,background-color .15s ease}
.tab.on{background:var(--tabon);box-shadow:0 0 0 1px var(--tabedge),0 0 4px var(--tabsh)}
.tab.hv:not(.on){background:var(--hov)}
.ti{width:16px;height:16px;display:grid;place-items:center;color:var(--tx2);flex:none}
.ti svg{width:15px;height:15px;stroke-width:1.75}
.tab .nm .fo{color:var(--tx2)}
.tab.gl{--gc:var(--sky);--gg:var(--glow)}
.tab.glc{--gc:var(--cur);--gg:var(--glowc)}
.tab.gl,.tab.glc{box-shadow:0 0 0 1.5px var(--gc),0 0 12px 2px var(--gg)}
.tab.gl:not(.on){background:var(--lk)}
.tab.glc:not(.on){background:var(--lkc)}
.tab.once{animation:tabonce 1s ease-out 1}
.tab.breathe{animation:tabbreathe 1.8s ease-in-out infinite}
@keyframes tabonce{0%{box-shadow:0 0 0 1.5px var(--gc),0 0 0 0 var(--gg)}30%{box-shadow:0 0 0 2px var(--gc),0 0 22px 7px var(--gg)}100%{box-shadow:0 0 0 1.5px var(--gc),0 0 12px 2px var(--gg)}}
@keyframes tabbreathe{0%,100%{box-shadow:0 0 0 1.5px var(--gc),0 0 5px 0 var(--gg)}50%{box-shadow:0 0 0 1.5px var(--gc),0 0 20px 6px var(--gg)}}
@media (prefers-reduced-motion:reduce){.tab.once,.tab.breathe{animation:none}}
.tsep{width:1px;height:16px;background:var(--line);flex:none;margin:0 2px}
.tplus{width:28px;height:28px;display:grid;place-items:center;color:var(--tx2);flex:none}
.tplus svg{width:15px;height:15px;stroke-width:1.75}

.brow{height:44px;flex:none;display:flex;align-items:center;gap:4px;padding:0 6px;border-bottom:1px solid var(--line);white-space:nowrap}
.chip{height:32px;display:flex;align-items:center;gap:5px;padding:0 7px 0 5px;border-radius:7px;color:var(--tx);flex:none}
.chip .ci{color:var(--tx2)}
.chip .ci svg{width:14px;height:14px}
.cnt{height:28px;display:flex;align-items:center;gap:3px;padding:0 6px;border-radius:7px;color:var(--tx2);flex:none;font-variant-numeric:tabular-nums}
.cnt svg{width:15px;height:15px;stroke-width:1.9}
.cnt.act{color:var(--act);font-weight:600}
.vs{width:1px;height:18px;background:var(--line);margin:0 6px;flex:none}
.hist{position:relative;flex:1;min-height:0;overflow:hidden;padding-top:4px}
.lane{position:absolute;left:17px;width:2px;background:var(--l1);top:4px;bottom:0}
.hr{position:relative;height:28px;display:flex;align-items:center;gap:8px;padding:0 12px 0 36px;white-space:nowrap;min-width:0;color:var(--tx)}
.hr .dot{position:absolute;left:12px;top:8px;width:12px;height:12px;border-radius:50%;background:var(--l1);box-shadow:0 0 0 2px var(--surface)}
.hr .msg{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.hr .hs{color:var(--tx2);font:11.5px ui-monospace,"SF Mono",Menlo,monospace;flex:none}

.tip{position:absolute;z-index:6;width:262px;padding:5px 9px;border-radius:6px;background:var(--tip);color:var(--tiptx);font-size:11.5px;line-height:15px;white-space:pre-line;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 6px 16px rgba(0,0,0,.16)}
.ptr{position:absolute;z-index:7;width:12px;height:18px}

.stg{display:grid;grid-template-columns:250px repeat(4,288px);column-gap:24px;row-gap:8px;align-items:center}
.sth{font-size:12.5px;font-weight:600;color:var(--wtx);padding-bottom:4px}
.stl{font-size:13px;font-weight:500;color:var(--wtx);line-height:17px}
.stl i{display:block;font-style:normal;font-weight:400;color:var(--wtx2);font-size:12px;line-height:16px;margin-top:2px}
.stc{height:52px;display:flex;align-items:center;background:var(--surface);color:var(--tx);border-radius:8px;font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;box-shadow:0 0 0 .5px rgba(0,0,0,.12)}
.stc .r{flex:1;min-width:0}
.stsep{grid-column:1 / -1;height:1px;background:rgba(127,127,127,.25);margin:6px 0}

.cc{display:flex;flex-direction:column;gap:10px;width:288px;flex:none}
.ccb{height:96px;display:flex;flex-direction:column;justify-content:center;gap:2px;background:var(--surface);color:var(--tx);border-radius:10px;padding:0 4px;box-shadow:0 0 0 .5px rgba(0,0,0,.12);font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;overflow:hidden}
.ccb.ttl{background:var(--title)}
.mrow{display:flex;flex-direction:column;gap:2px;padding:0 12px}
.mrow b{font-weight:500}
.mrow span{font-size:12px;color:var(--tx2)}

.sheet{display:flex;flex-direction:column;gap:18px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:28px}
.bar{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center}
.grp{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--wtx2)}
.seg{display:flex;background:var(--seg);border-radius:8px;padding:2px;gap:2px}
.sg{border:0;background:none;font:inherit;font-size:12.5px;color:var(--wtx2);height:26px;padding:0 10px;border-radius:6px;cursor:pointer}
.sg.on{background:var(--segon);color:var(--wtx);font-weight:500;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.meta{font-size:12.5px;color:var(--wtx2);max-width:968px}
.r,.tab{cursor:default}
"""


# ---------------------------------------------------------------- icons

def _paths(svg: str) -> str:
    """A Lucide file's shapes, with each one closed the long way, which the
    canvas's format asks for."""
    inner = re.sub(r"^.*?<svg[^>]*>|</svg>\s*$", "", svg.strip(), flags=re.S)
    inner = re.sub(r"<!--.*?-->", "", inner, flags=re.S)
    inner = re.sub(r"<(\w+)([^>]*?)\s*/>", r"<\1\2></\1>", inner)
    return re.sub(r">\s+<", "><", inner).strip()


def lucide(name: str) -> str:
    folder = "roga" if (ICONS / "roga" / f"{name}.svg").exists() else "lucide"
    return _paths((ICONS / folder / f"{name}.svg").read_text())


def svg(paths: str) -> str:
    return f'<svg viewBox="0 0 24 24" aria-hidden="true">{paths}</svg>'


P = {
    "branch": lucide("git-branch"),
    "work": lucide("folder-git-2"),
    "lock": lucide("lock"),
    "folder": lucide("folder"),
    "cloud": lucide("cloud"),
    "check": lucide("check"),
    "chev": lucide("chevron-down"),
    "filter": lucide("list-filter"),
    "dots": lucide("ellipsis"),
    "panel": lucide("panel-right"),
    "plus": lucide("plus"),
    "minus": lucide("git-branch-minus"),
    "repo": lucide("folder-git"),
    "fetch": lucide("fetch"),
    "newbranch": lucide("git-branch-plus"),
    "pull": lucide("arrow-down-to-dot"),
    "push": lucide("arrow-up-from-dot"),
    "order": '<path d="M3 12h.01"></path><path d="M3 18h.01"></path><path d="M3 6h.01"></path><path d="M8 12h13"></path><path d="M8 18h13"></path><path d="M8 6h13"></path>',
    "down": '<path d="M12 5v14"></path><path d="m19 12-7 7-7-7"></path>',
    "up": '<path d="m5 12 7-7 7 7"></path><path d="M12 19V5"></path>',
}
I = {k: svg(v) for k, v in P.items()}

POINTER = ('<svg class="ptr" style="left:{x}px;top:{y}px;stroke-width:1" viewBox="0 0 12 18" aria-hidden="true">'
           '<path d="M1 1v14l3.6-3.4 2.6 5.6 2.2-1-2.6-5.4H12z" fill="#000" stroke="#fff"></path></svg>')


# ---------------------------------------------------------------- the branches

REMOTE = "origin"
ADDRESS = "github.com/tmarkovski/roga.git"


@dataclass
class Local:
    name: str
    up: str | None = None          # its upstream, as origin/tm/x
    gone: bool = False             # an upstream that's gone from the remote
    wt: str | None = None          # the folder of another worktree that has it
    locked: bool = False
    current: bool = False          # checked out in the window's worktree
    today: tuple[int, int, str] = (0, 0, "")  # ahead, behind and of what, as the panel counts today
    behind_up: int = 0             # behind its upstream
    ahead_up: int = 0              # ahead of its upstream
    unpushed: int = 0              # commits no remote has, for a branch without an upstream
    merged: bool = False           # every commit in main, and it has moved since it was made
    subject: str = ""              # its latest commit that isn't a merge
    date: str = ""
    tab: str = ""                  # its worktree's tab


@dataclass
class Remote:
    name: str                      # without the remote, as tm/x
    tracked_by: str | None
    merged: bool
    subject: str
    date: str


def up(name: str) -> str:
    return f"{REMOTE}/{name}"


# In the order the panel lists them: the current branch first in its folder,
# the rest from A to Z, then the branches without a folder.
LOCALS = [
    Local("tm/settings-gray-boxes", up("tm/settings-gray-boxes"), current=True, today=(0, 0, up("tm/settings-gray-boxes")),
          merged=True, subject="Time out the system's shell in the time-limit test, not a new script", date="Nov 27", tab="roga"),
    Local("tm/agent-line-shimmer", up("tm/agent-line-shimmer"), wt="agent-chip-shimmer", today=(0, 0, up("tm/agent-line-shimmer")),
          merged=True, subject="Shimmer the agent line's words instead of turning a ring there", date="Nov 26", tab="agent"),
    Local("tm/code-font-separator", today=(1, 120, "main"), unpushed=1,
          subject="Draw the usual line above Code font in Settings", date="Nov 18"),
    Local("tm/codex-plugin-check-marketplace", gone=True, today=(0, 118, "main"), merged=True,
          subject="Require Codex 0.137.0, the first whose plugin list answers in JSON", date="Nov 18"),
    Local("tm/commit-box-composer", up("tm/commit-box-composer"), today=(0, 0, up("tm/commit-box-composer")), merged=True,
          subject="Put the message box's buttons in a row under its text (decision 98)", date="Nov 23"),
    Local("tm/default-agent-selection-design-245d03", up("tm/default-agent-selection-design-245d03"),
          today=(0, 0, up("tm/default-agent-selection-design-245d03")), merged=True,
          subject="Choose the model and effort from submenus that name the choice", date="Nov 17"),
    Local("tm/identity-in-the-box", gone=True, today=(0, 32, "main"), merged=True,
          subject="Keep the Signature line in place, and let checking be turned off (decision 109)", date="Nov 25"),
    Local("tm/keep-house-while-pushed", up("tm/keep-house-while-pushed"), today=(0, 0, up("tm/keep-house-while-pushed")), merged=True,
          subject="Add Claude Code launch config for the landing page dev server", date="Nov 19"),
    Local("tm/locked-worktree-force-remove-785d1a", up("tm/locked-worktree-force-remove-785d1a"), wt="locked-worktree-force-remove-785d1a",
          today=(0, 0, up("tm/locked-worktree-force-remove-785d1a")), merged=True,
          subject="Unlock a locked worktree from its menu, and give the lock's reason in more tooltips", date="Nov 27", tab="locked"),
    Local("tm/plain-settings-text", up("tm/plain-settings-text"), wt="commit-identity", today=(0, 0, up("tm/plain-settings-text")),
          merged=True, subject="Make Sign commits one choice of Off or a format in the identity popover", date="Nov 26", tab="plain"),
    Local("tm/pre-release-fixes", up("tm/pre-release-fixes"), today=(0, 0, up("tm/pre-release-fixes")), merged=True,
          subject="Fill a file row's buttons with gray only under the pointer", date="Nov 24"),
    Local("tm/report-an-issue", gone=True, today=(0, 103, "main"), merged=True,
          subject="Serve the landing page from this checkout's site folder", date="Nov 19"),
    Local("tm/roga-launch-time-4b9d09", gone=True, today=(0, 84, "main"), merged=True,
          subject="Show history sooner at launch, and add scripts that time launch", date="Nov 23"),
    Local("tm/signature-key-menu", up("tm/signature-key-menu"), wt="tm+signature-key-menu", locked=True,
          today=(0, 0, up("tm/signature-key-menu")), merged=True,
          subject="Copy a signature's key, or add it to GitHub, from the Signature line", date="Nov 27", tab="sig"),
    Local("main", up("main"), today=(0, 9, up("main")), behind_up=9,
          subject="Shimmer the agent line's words instead of turning a ring there", date="Nov 26"),
    Local("worktree-branch-bar-mock", wt="branch-bar-mock", locked=True, today=(0, 0, "main"),
          subject="Draw boards for what the branch row could say", date="Nov 27", tab="mock"),
]

REMOTES = [
    Remote("tm/agent-line-shimmer", "tm/agent-line-shimmer", True, LOCALS[1].subject, "Nov 26"),
    Remote("tm/commit-box-composer", "tm/commit-box-composer", True, LOCALS[4].subject, "Nov 23"),
    Remote("tm/default-agent-selection-design-245d03", "tm/default-agent-selection-design-245d03", True, LOCALS[5].subject, "Nov 17"),
    Remote("tm/keep-house-while-pushed", "tm/keep-house-while-pushed", True, LOCALS[7].subject, "Nov 19"),
    Remote("tm/locked-worktree-force-remove-785d1a", "tm/locked-worktree-force-remove-785d1a", True, LOCALS[8].subject, "Nov 27"),
    Remote("tm/plain-settings-text", "tm/plain-settings-text", True, LOCALS[9].subject, "Nov 26"),
    Remote("tm/pre-release-fixes", "tm/pre-release-fixes", True, LOCALS[10].subject, "Nov 24"),
    Remote("tm/settings-gray-boxes", "tm/settings-gray-boxes", True, LOCALS[0].subject, "Nov 27"),
    Remote("tm/signature-key-menu", "tm/signature-key-menu", True, LOCALS[13].subject, "Nov 27"),
    Remote("main", "main", False, "Merge pull request #132 from tmarkovski/tm/signature-key-menu", "Nov 27"),
]

LOCAL_BY_NAME = {b.name: b for b in LOCALS}
CURRENT = next(b for b in LOCALS if b.current)
DELETABLE = [b for b in LOCALS if b.merged and not b.current and not b.wt]

# The window's worktrees as tabs, in the order git lists them (decision 95).
TABS = [
    {"id": "roga", "icon": "repo", "fo": "", "nm": "roga", "on": True, "row": "l:tm/settings-gray-boxes"},
    {"id": "agent", "icon": "work", "fo": "tm/", "nm": "agent-line-shimmer", "on": False, "row": "l:tm/agent-line-shimmer"},
    {"id": "mock", "icon": "lock", "fo": "", "nm": "worktree-branch-bar-mock", "on": False, "row": "l:worktree-branch-bar-mock"},
    {"id": "plain", "icon": "work", "fo": "tm/", "nm": "plain-settings-text", "on": False, "row": "l:tm/plain-settings-text"},
    {"id": "locked", "icon": "work", "fo": "tm/", "nm": "locked-worktree-force-remove-785d1a", "on": False, "row": "l:tm/locked-worktree-force-remove-785d1a"},
    {"id": "sig", "icon": "lock", "fo": "tm/", "nm": "signature-key-menu", "on": False, "row": "l:tm/signature-key-menu"},
]

HISTORY = [
    ("87d7c37", "Merge pull request #132 from tmarkovski/tm/signature-key-menu"),
    ("a8c6003", "Merge pull request #131 from tmarkovski/tm/locked-worktree-force-remove-785d1a"),
    ("305a087", "Merge pull request #130 from tmarkovski/tm/settings-gray-boxes"),
    ("6a17b7c", "Merge pull request #129 from tmarkovski/tm/agent-line-shimmer"),
    ("efbe5e5", "Add 0.0.9's notes"),
    ("e59b3b3", "Merge pull request #127 from tmarkovski/tm/changes-panel-ui-14fee2"),
    ("5a17c15", "Merge pull request #125 from tmarkovski/tm/house-off-switch-02ee9b"),
    ("471204f", "Merge pull request #124 from tmarkovski/tm/popovers-on-press-4716cd"),
    ("029b258", "Merge pull request #126 from tmarkovski/tm/clone-from-url-06a4c6"),
    ("39092ea", "Merge pull request #120 from tmarkovski/tm/plain-settings-text"),
    ("1db628e", "Merge pull request #118 from tmarkovski/tm/identity-in-the-box"),
    ("21d7ea9", "Merge pull request #114 from tmarkovski/tm/pre-release-fixes"),
    ("4671121", "Merge pull request #116 from tmarkovski/tm/commit-identity"),
    ("ac9a48c", "Merge pull request #113 from tmarkovski/tm/amend-chevron-first-commit"),
    ("b63b152", "Merge pull request #112 from tmarkovski/tm/agent-info-display-ux-4eff11"),
    ("bd96edd", "Merge pull request #111 from tmarkovski/tm/gray-title-band"),
    ("6b5f799", "Merge pull request #110 from tmarkovski/tm/sidebar-repo-load-animations-20b83b"),
    ("0870819", "Merge pull request #109 from tmarkovski/tm/tab-ahead-of-main"),
    ("6394c70", "Merge pull request #108 from tmarkovski/tm/branch-chip-height"),
    ("305b8ec", "Merge pull request #107 from tmarkovski/tm/commit-box-composer"),
    ("ef2806e", "Merge pull request #105 from tmarkovski/tm/worktree-tab-shadow"),
    ("bae535f", "Merge pull request #106 from tmarkovski/tm/roga-launch-time-4b9d09"),
    ("3757b63", "Add 0.0.8's notes"),
    ("fdfd9a1", "Merge pull request #104 from tmarkovski/tm/intelligent-sagan-zsgoip-684465"),
    ("55df9f0", "Merge pull request #103 from tmarkovski/tm/wait-for-commit-list-report"),
    ("c7d5fe1", "Add 0.0.7's notes"),
]


# ---------------------------------------------------------------- rows

def leaf(name: str) -> str:
    return name.rsplit("/", 1)[-1]


def plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def summary(ahead: int, behind: int, other: str) -> str:
    """BranchComparison.summary, as the panel says it today."""
    if ahead == 0 and behind == 0:
        return f"up to date with {other}"
    if behind == 0:
        return f"{ahead} ahead of {other}"
    if ahead == 0:
        return f"{behind} behind {other}"
    return f"{ahead} ahead, {behind} behind {other}"


def blank() -> dict:
    return {
        "id": "", "isHead": False, "isRow": True, "title": "", "hasMinus": False, "hasPlus": False, "cmdTip": "",
        "cls": "", "style": "", "icCls": "ri", "iBranch": False, "iWork": False, "iLock": False, "iFolder": False, "iCloud": False,
        "name": "", "nmCls": "nm", "hasChev": False, "hasAddr": False, "addr": "", "hasSub": False, "sub": "",
        "hasCheck": False, "hasAbt": False, "hasTdn": False, "tdn": "", "hasTup": False, "tup": "",
        "hasAb": False, "hasNdn": False, "ndn": "", "hasNup": False, "nup": "", "hasMg": False, "hasDate": False, "date": "",
        "tip": "", "pair": "", "tab": "", "cur": False, "full": "", "y": 0, "h": ROW1,
    }


def icon_flag(kind: str) -> str:
    return {"branch": "iBranch", "work": "iWork", "lock": "iLock", "folder": "iFolder", "cloud": "iCloud"}[kind]


def local_tip(b: Local) -> str:
    lines = [b.name]
    if b.current:
        lines.append("Checked out here")
    elif b.wt:
        lines.append(f"In the worktree {b.wt}" + (", which is locked" if b.locked else ""))
    if b.up:
        if b.behind_up and b.ahead_up:
            lines.append(f"{b.behind_up} behind and {b.ahead_up} ahead of {b.up}")
        elif b.behind_up:
            lines.append(f"{b.behind_up} behind {b.up}")
        elif b.ahead_up:
            lines.append(f"{b.ahead_up} ahead of {b.up}")
        else:
            lines.append(f"Up to date with {b.up}")
    elif b.gone:
        lines.append(f"Its upstream, {up(b.name)}, is gone")
    elif b.unpushed:
        lines.append(f"{plural(b.unpushed, 'commit')} no remote has · {b.today[1]} behind main")
    if b.merged:
        lines.append("Merged into main")
    lines.append(f"Last commit {b.date}")
    return "\n".join(lines)


def remote_tip(r: Remote) -> str:
    lines = [up(r.name)]
    lines.append(f"Tracked by {r.tracked_by}" if r.tracked_by else "No branch here tracks it")
    if r.merged:
        lines.append("Merged into main")
    lines.append(f"Last commit {r.date}")
    return "\n".join(lines)


def build(variant: str) -> list[dict]:
    """Every row of the panel's list in today's panel, A or B, with where it
    sits, for the board that tries them and for the pill that points to a
    row out of view."""
    new = variant != "today"
    two = variant == "B"
    step = NEW_STEP if new else TODAY_STEP
    rows: list[dict] = []
    y = 0

    def add(row: dict) -> None:
        nonlocal y
        row["y"] = y
        y += row["h"]
        rows.append(row)

    def base(id_: str, depth: int, h: int) -> dict:
        row = blank()
        row.update(id=id_, h=h, cls=f"r {'n' if new else 't'} h{h}", style=f"padding-left:{8 + depth * step}px")
        return row

    def head(id_: str, title: str, *, minus: bool = False, plus: bool = False) -> None:
        row = blank()
        row.update(id=id_, isHead=True, isRow=False, title=title, h=SECTION_H, hasMinus=minus, hasPlus=plus,
                   cmdTip=f"Delete {len(DELETABLE)} merged branches…" if minus else "")
        add(row)

    def folder(id_: str, name: str, path: str, count: int, depth: int) -> None:
        row = base(id_, depth, ROW1)
        row.update(iFolder=True, name=name, nmCls="nm fo", hasChev=True, tip=f"{path} · {count} branches")
        add(row)

    def local(b: Local, depth: int) -> None:
        h = ROW2 if (two or not new) else ROW1
        row = base("l:" + b.name, depth, h)
        row.update(name=leaf(b.name), full=b.name)
        if not new:
            row.update(iBranch=True, icCls="ri cur" if b.current else "ri")
            parts = []
            if not b.current and b.wt:
                parts.append("in " + b.wt)
            parts.append(summary(*b.today))
            row.update(hasSub=True, sub=" · ".join(parts))
            if b.current:
                row["hasCheck"] = True
            elif b.today[0] or b.today[1]:
                row.update(hasAbt=True, hasTdn=b.today[1] > 0, tdn=f"↓{b.today[1]}", hasTup=b.today[0] > 0, tup=f"↑{b.today[0]}")
            add(row)
            return
        kind = "branch" if (b.current or not b.wt) else ("lock" if b.locked else "work")
        row[icon_flag(kind)] = True
        row["icCls"] = "ri cur" if b.current else "ri sky"
        row["nmCls"] = "nm dim" if (b.merged and not b.current and not b.wt) else "nm"
        if b.current:
            row["hasCheck"] = True
        elif b.behind_up or b.ahead_up:
            row.update(hasAb=True, hasNdn=b.behind_up > 0, ndn=f"↓{b.behind_up}", hasNup=b.ahead_up > 0, nup=f"↑{b.ahead_up}")
        elif not b.up and b.unpushed:
            row.update(hasAb=True, hasNup=True, nup=f"↑{b.unpushed}")
        elif b.merged:
            row["hasMg"] = True
        if two:
            row.update(hasSub=True, sub=b.subject)
        row.update(tip=local_tip(b), pair="r:" + b.up if b.up else "", tab=b.tab, cur=b.current)
        add(row)

    def remote_branch(r: Remote, depth: int) -> None:
        h = ROW2 if two else ROW1
        row = base("r:" + up(r.name), depth, h)
        row.update(iBranch=True, name=leaf(r.name), full=up(r.name))
        if not new:
            row.update(hasDate=True, date=r.date)
            add(row)
            return
        tracker = LOCAL_BY_NAME.get(r.tracked_by or "")
        row["icCls"] = "ri cur" if tracker and tracker.current else "ri sky" if tracker else "ri"
        row["nmCls"] = "nm dim" if r.merged else "nm"
        row["hasMg"] = r.merged
        if two:
            row.update(hasSub=True, sub=r.subject)
        row.update(tip=remote_tip(r), pair="l:" + tracker.name if tracker else "", tab=tracker.tab if tracker else "",
                   cur=bool(tracker and tracker.current))
        add(row)

    head("h:branches", "Branches", minus=new)
    tm = [b for b in LOCALS if b.name.startswith("tm/")]
    folder("f:tm", "tm", "tm/", len(tm), 0)
    for b in tm:
        local(b, 1)
    for b in LOCALS:
        if "/" not in b.name:
            local(b, 0)
    head("h:remotes", "Remotes", plus=True)
    remote = base("remote:" + REMOTE, 0, ROW1)
    remote.update(iCloud=True, name=REMOTE, nmCls="nm rn", hasAddr=True, addr=ADDRESS, tip=f"https://{ADDRESS}")
    add(remote)
    rtm = [r for r in REMOTES if r.name.startswith("tm/")]
    folder("f:origin/tm", "tm", "origin/tm/", len(rtm), 0 if new else 1)
    for r in rtm:
        remote_branch(r, 1 if new else 2)
    for r in REMOTES:
        if "/" not in r.name:
            remote_branch(r, 0 if new else 1)
    return rows


VARIANTS = {v: build(v) for v in ("today", "A", "B")}


def row_html(r: dict, extra: str = "") -> str:
    """One row as markup, the same as the template on the board that tries them."""
    if r["isHead"]:
        cmd = ""
        if r["hasMinus"]:
            cmd += f'<span class="ib sm" title="{esc(r["cmdTip"])}">{I["minus"]}</span>'
        if r["hasPlus"]:
            cmd += f'<span class="ib sm">{I["plus"]}</span>'
        return f'<div class="sh"><span>{esc(r["title"])}</span><span class="cv">{I["chev"]}</span><span class="sp"></span>{cmd}</div>'
    icon = next(I[k] for k, f in (("branch", "iBranch"), ("work", "iWork"), ("lock", "iLock"), ("folder", "iFolder"), ("cloud", "iCloud")) if r[f])
    trail = ""
    if r["hasCheck"]:
        trail += f'<span class="ck">{I["check"]}</span>'
    if r["hasAbt"]:
        trail += ('<span class="abt">' + (f'<span class="dn">{r["tdn"]}</span>' if r["hasTdn"] else "")
                  + (f'<span class="up">{r["tup"]}</span>' if r["hasTup"] else "") + "</span>")
    if r["hasAb"]:
        trail += ('<span class="ab">' + (f'<span>{r["ndn"]}</span>' if r["hasNdn"] else "")
                  + (f'<span>{r["nup"]}</span>' if r["hasNup"] else "") + "</span>")
    if r["hasMg"]:
        trail += '<span class="mg">merged</span>'
    if r["hasDate"]:
        trail += f'<span class="dt">{esc(r["date"])}</span>'
    l1 = (f'<span class="{r["nmCls"]}">{esc(r["name"])}</span>'
          + (f'<span class="cv">{I["chev"]}</span>' if r["hasChev"] else "")
          + (f'<span class="addr">{esc(r["addr"])}</span>' if r["hasAddr"] else "")
          + f'<span class="tr">{trail}</span>')
    l2 = f'<span class="l2">{esc(r["sub"])}</span>' if r["hasSub"] else ""
    return (f'<div class="{r["cls"]}{extra}" style="{r["style"]}" title="{esc(r["tip"])}">'
            f'<span class="{r["icCls"]}">{icon}</span><span class="tx"><span class="l1">{l1}</span>{l2}</span></div>')


def panel_header() -> str:
    return f'<span class="ib">{I["filter"]}</span><span class="ib">{I["dots"]}</span><span class="ib">{I["panel"]}</span>'


def edge_pill(row: dict, below: bool) -> str:
    tone = "c" if row["cur"] else "s"
    return (f'<div class="edge {tone} {"bot" if below else "top"}">{I["down"] if below else I["up"]}'
            f'<span>{esc(row["full"])}</span></div>')


def list_html(variant: str, *, hover: str = "", link: str = "", cur: bool = False, pill: bool = False) -> str:
    rows = VARIANTS[variant]
    out = []
    for r in rows:
        extra = " hv" if r["id"] == hover else (" lkc" if cur else " lk") if r["id"] == link else ""
        out.append(row_html(r, extra))
    pill_html = ""
    if pill and link:
        target = next(r for r in rows if r["id"] == link)
        pill_html = edge_pill(target, below=target["y"] + target["h"] > LIST_H)
    return f'<div class="lw"><div class="list">{"".join(out)}</div>{pill_html}</div>'


def panel(variant: str, *, overlay: str = "", **kw) -> str:
    return (f'<div class="panel" style="height:{WIN_H}px"><div class="ph">{panel_header()}</div>'
            f'{list_html(variant, **kw)}{overlay}</div>')


def visible(variant: str, row_id: str) -> bool:
    r = next(r for r in VARIANTS[variant] if r["id"] == row_id)
    return r["y"] + r["h"] <= LIST_H


def count_visible(variant: str, prefix: str) -> int:
    return sum(1 for r in VARIANTS[variant] if r["id"].startswith(prefix) and r["y"] + r["h"] <= LIST_H)


def list_height(variant: str, prefix: str) -> int:
    return sum(r["h"] for r in VARIANTS[variant] if r["id"].startswith(prefix))


# ---------------------------------------------------------------- the window's top

def tab_html(t: dict, cls: str = "") -> str:
    on = " on" if t["on"] else ""
    fo = f'<span class="fo">{esc(t["fo"])}</span>' if t["fo"] else ""
    return (f'<span class="tab{on}{cls}" style="width:{TAB_W}px"><span class="ti">{I[t["icon"]]}</span>'
            f'<span class="nm">{fo}{esc(t["nm"])}</span></span>')


def tabs_html(glow: str = "", cur: bool = False, hover: str = "") -> str:
    out = []
    for i, t in enumerate(TABS):
        cls = (" glc" if cur else " gl") if t["id"] == glow else ""
        cls += " hv" if t["id"] == hover else ""
        out.append(tab_html(t, cls))
        if i == 0:
            out.append('<i class="tsep"></i>')
    out.append(f'<span class="tplus">{I["plus"]}</span>')
    return "".join(out)


def middle_html() -> str:
    rows = "".join(f'<div class="hr"><span class="dot"></span><span class="msg">{esc(s)}</span><span class="hs">{h}</span></div>'
                   for h, s in HISTORY)
    return (f'<div class="brow"><span class="chip"><span class="ci">{I["branch"]}</span><span>{esc(CURRENT.name)}</span>'
            f'<span class="cv">{I["chev"]}</span></span><span class="sp"></span><span class="ib">{I["fetch"]}</span>'
            f'<span class="ib">{I["newbranch"]}</span><i class="vs"></i><span class="ib">{I["order"]}</span></div>'
            f'<div class="hist"><i class="lane" style="bottom:auto;top:14px;height:{(len(HISTORY) - 1) * 28}px"></i>{rows}</div>')


def window_html(*, glow: str = "", cur: bool = False, tab_hover: str = "", hover: str = "", link: str = "",
                pill: bool = False, overlay: str = "") -> str:
    return (f'<div class="win"><div class="wtop"><div class="tabs">{tabs_html(glow, cur, tab_hover)}</div>'
            f'<div class="ptop">{panel_header()}</div></div>'
            f'<div class="wbody"><div class="mid">{middle_html()}</div>'
            f'<div class="rp">{list_html("A", hover=hover, link=link, cur=cur, pill=pill)}</div></div>{overlay}</div>')


# ---------------------------------------------------------------- boards


@dataclass
class Board:
    file: str
    title: str
    w: int
    h: int
    html: str
    interactive: bool = False


def page(title: str, body: str, w: int, h: int, script: str = "  renderVals() { return {}; }", head: str = "") -> str:
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
{CSS.strip()}
</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{props}'>
{head}
class Component extends DCLogic {{
{script}
}}
</script>
</body>
</html>
"""


def cell(caption: str, sub: str, stage: str) -> str:
    sub_html = f" <i>· {esc(sub)}</i>" if sub else ""
    return f'<div class="cell"><div class="cap">{esc(caption)}{sub_html}</div>{stage}</div>'


def panel_board(file: str, title: str, variant: str, captions: tuple[str, str], overlay: str = "") -> Board:
    """The panel in both appearances, side by side."""
    cells = [
        f'<div class="th-l">{cell(captions[0], "light", panel(variant, overlay=overlay))}</div>',
        f'<div class="th-d">{cell(captions[1], "dark", panel(variant))}</div>',
    ]
    w = 80 + 2 * PANEL_W + 48
    h = 34 + 36 + 12 + WIN_H + 40
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="cells">{"".join(cells)}</div></div>'
    return Board(file, title, w, h, page(title, body, w, h))


def board_today() -> Board:
    return panel_board("Br-Today.dc.html", "Today", "today", ("Today", "Today"))


def remote_tip_overlay() -> str:
    """A's tooltip over a remote branch, which is where the date went."""
    r = next(r for r in VARIANTS["A"] if r["id"] == "r:origin/tm/commit-box-composer")
    top = HEAD_H + r["y"]
    return (f'<div class="tip" style="left:18px;top:{top + 30}px">{esc(r["tip"])}</div>'
            + POINTER.format(x=150, y=top + 10))


def board_a() -> Board:
    return panel_board("Br-A.dc.html", "A · One line for every row (the one I'd pick)", "A",
                       ("A · one line", "A · one line"), remote_tip_overlay())


def board_b() -> Board:
    return panel_board("Br-B.dc.html", "B · Two lines for every branch, the second its last commit", "B",
                       ("B · two lines", "B · two lines"))


# Each state as today draws it and as A does, as rows of their own.
def state_rows() -> list[tuple[str, str, dict | None, dict | None]]:
    def mk(variant: str, **kw) -> dict:
        row = blank()
        new = variant != "today"
        row.update(cls=f"r {'n' if new else 't'} h{kw.pop('h', ROW1)}", style="padding-left:8px")
        row.update(kw)
        return row

    def t2(name: str, sub: str, **kw) -> dict:
        return mk("today", h=ROW2, iBranch=True, name=name, hasSub=True, sub=sub, **kw)

    def a(name: str, icon: str = "branch", ic: str = "ri sky", **kw) -> dict:
        return mk("A", **{icon_flag(icon): True}, icCls=ic, name=name, **kw)

    return [
        ("The branch checked out here", "Green, as in history and the graph, with its check",
         t2("fix-login", "up to date with origin/tm/fix-login", icCls="ri cur", hasCheck=True),
         a("fix-login", ic="ri cur", hasCheck=True)),
        ("Checked out in another worktree", "Its icon is its tab's, and pointing at it lights the tab",
         t2("add-tests", "in add-tests · up to date with origin/agent/add-tests"),
         a("add-tests", "work")),
        ("In a locked worktree", "The lock its tab has",
         t2("rate-limits", "in rate-limits · up to date with origin/agent/rate-limits"),
         a("rate-limits", "lock")),
        ("Up to date with its upstream", "Nothing to say, so it says nothing",
         t2("docs-pass", "up to date with origin/tm/docs-pass"),
         a("docs-pass")),
        ("Behind its upstream", "Gray, as on the tabs; a click selects, it doesn't pull",
         t2("main", "9 behind origin/main", hasAbt=True, hasTdn=True, tdn="↓9"),
         a("main", hasAb=True, hasNdn=True, ndn="↓9")),
        ("Ahead of its upstream", "",
         t2("docs-pass", "2 ahead of origin/tm/docs-pass", hasAbt=True, hasTup=True, tup="↑2"),
         a("docs-pass", hasAb=True, hasNup=True, nup="↑2")),
        ("Both", "",
         t2("retry-webhooks", "2 ahead, 1 behind origin/tm/retry-webhooks", hasAbt=True, hasTdn=True, tdn="↓1", hasTup=True, tup="↑2"),
         a("retry-webhooks", hasAb=True, hasNdn=True, ndn="↓1", hasNup=True, nup="↑2")),
        ("Never pushed, with work main hasn't got", "↑ counts what no remote has, as the tab does; behind main goes to the tooltip",
         t2("code-font-separator", "1 ahead, 120 behind main", hasAbt=True, hasTdn=True, tdn="↓120", hasTup=True, tup="↑1"),
         a("code-font-separator", hasAb=True, hasNup=True, nup="↑1")),
        ("Merged, never pushed", "Every commit is in main",
         t2("report-an-issue", "103 behind main", hasAbt=True, hasTdn=True, tdn="↓103"),
         a("report-an-issue", nmCls="nm dim", hasMg=True)),
        ("Merged, pushed", "Today it looks like any branch in step with its remote",
         t2("commit-box-composer", "up to date with origin/tm/commit-box-composer"),
         a("commit-box-composer", nmCls="nm dim", hasMg=True)),
        ("Merged, but a worktree has it", "The name stays dark, since it can't be deleted from here",
         t2("agent-line-shimmer", "in agent-chip-shimmer · up to date with origin/tm/agent-line-shimmer"),
         a("agent-line-shimmer", "work", hasMg=True)),
        ("Made from main, no commits yet", "Not merged: its reflog says it never moved",
         t2("worktree-branch-bar-mock", "in branch-bar-mock · up to date with main"),
         a("worktree-branch-bar-mock", "lock")),
        (None, None, None, None),
        ("A remote branch the branch here tracks", "Green, like the branch it goes with",
         mk("today", iBranch=True, name="fix-login", hasDate=True, date="Nov 27"),
         a("fix-login", ic="ri cur")),
        ("A remote branch another branch tracks", "Sky, as a branch's name is in history",
         mk("today", iBranch=True, name="add-tests", hasDate=True, date="Nov 26"),
         a("add-tests")),
        ("A remote branch nobody here tracks", "Gray, as a remote branch's badge is",
         mk("today", iBranch=True, name="onboarding-copy", hasDate=True, date="Nov 21"),
         a("onboarding-copy", ic="ri")),
        ("A merged remote branch", "",
         mk("today", iBranch=True, name="commit-box-composer", hasDate=True, date="Nov 23"),
         a("commit-box-composer", nmCls="nm dim", hasMg=True)),
    ]


def board_states() -> Board:
    states = state_rows()
    heads = ('<span></span><span class="sth">Today</span><span class="sth">A</span>'
             '<span class="sth">Today, dark</span><span class="sth">A, dark</span>')
    cells = []
    for label, sub, today, a in states:
        if label is None:
            cells.append('<i class="stsep"></i>')
            continue
        sub_html = f"<i>{esc(sub)}</i>" if sub else ""
        cells.append(f'<div class="stl">{esc(label)}{sub_html}</div>')
        for theme in ("th-l", "th-d"):
            for row in (today, a):
                cells.append(f'<div class="stc {theme}">{row_html(row)}</div>')
    n = sum(1 for s in states if s[0] is not None)
    w = 80 + 250 + 4 * PANEL_W + 4 * 24
    h = 34 + (24 + 8) + n * (52 + 8) + (1 + 12 + 8) + 40
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="stg">{heads}{"".join(cells)}</div></div>'
    return Board("Br-States.dc.html", "State by state", w, h, page("State by state", body, w, h))


def board_counts() -> Board:
    """Ahead and behind in each place Roga shows them."""
    def brow() -> str:
        return (f'<div class="brow" style="border:0"><span class="chip"><span class="ci">{I["branch"]}</span><span>fix-login</span>'
                f'<span class="cv">{I["chev"]}</span></span><span class="cnt act">{I["pull"]}3</span>'
                f'<span class="cnt">{I["push"]}1</span></div>')

    def tab() -> str:
        return (f'<div style="display:flex;padding:0 8px"><span class="tab" style="width:170px"><span class="ti">{I["work"]}</span>'
                '<span class="nm"><span class="fo">agent/</span>fix-login</span>'
                '<span class="ab" style="margin-left:auto">↓3</span></span></div>')

    def menu() -> str:
        return ('<div class="mrow"><b>agent/fix-login</b><span>↓3 ↑1 · ~/git/roga-fix-login</span></div>')

    def today() -> str:
        return (row_html(next(r for r in VARIANTS["today"] if r["id"] == "l:tm/code-font-separator"))
                + row_html(next(r for r in VARIANTS["today"] if r["id"] == "l:main")))

    def proposed() -> str:
        return (row_html(next(r for r in VARIANTS["A"] if r["id"] == "l:tm/code-font-separator"))
                + row_html(next(r for r in VARIANTS["A"] if r["id"] == "l:main")))

    places = [
        ("The branch row", "orange when a click pulls or pushes", brow, " ttl"),
        ("A worktree's tab", "always gray", tab, " ttl"),
        ("The worktree menu", "gray", menu, ""),
        ("The refs panel today", "pink and green, monospaced", today, ""),
        ("The refs panel, proposed", "gray, as the tabs", proposed, ""),
    ]
    rows = []
    for theme, word in (("th-l", ""), ("th-d", ", dark")):
        cells = "".join(f'<div class="cc"><div class="cap">{esc(t)}{esc(word)} <i>· {esc(s)}</i></div>'
                        f'<div class="ccb{bg}">{f()}</div></div>' for t, s, f, bg in places)
        rows.append(f'<div class="cells {theme}" style="gap:24px">{cells}</div>')
    w = 80 + 5 * PANEL_W + 4 * 24
    h = 34 + 2 * (36 + 10 + 96) + 36 + 40
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px">{"".join(rows)}</div>'
    return Board("Br-Counts.dc.html", "Ahead and behind, everywhere", w, h, page("Ahead and behind, everywhere", body, w, h))


def row_top(variant: str, row_id: str) -> int:
    return HEAD_H + next(r for r in VARIANTS[variant] if r["id"] == row_id)["y"]


def tab_left(tab_id: str) -> int:
    index = next(i for i, t in enumerate(TABS) if t["id"] == tab_id)
    return 8 + index * (TAB_W + 4) + (5 + 4 if index > 0 else 0)


def board_link() -> Board:
    rp = MID_W + 1  # where the refs panel's list starts across the window
    moments = [
        ("Pointing at a branch a worktree has", "its tab glows, and its remote copy tints",
         window_html(glow="agent", hover="l:tm/agent-line-shimmer", link="r:origin/tm/agent-line-shimmer",
                     overlay=POINTER.format(x=rp + 120, y=row_top("A", "l:tm/agent-line-shimmer") + 10))),
        ("Pointing at a remote branch", "the local branch that tracks it tints, and its tab glows",
         window_html(glow="plain", hover="r:origin/tm/plain-settings-text", link="l:tm/plain-settings-text",
                     overlay=POINTER.format(x=rp + 140, y=row_top("A", "r:origin/tm/plain-settings-text") + 10))),
        ("Pointing at a tab", "its branch's row tints",
         window_html(tab_hover="mock", link="l:worktree-branch-bar-mock",
                     overlay=POINTER.format(x=tab_left("mock") + 50, y=20))),
        ("Pointing at the branch checked out here", "green, and its remote copy is out of view, so a pill points to it",
         window_html(glow="roga", cur=True, hover="l:tm/settings-gray-boxes", link="r:origin/tm/settings-gray-boxes", pill=True,
                     overlay=POINTER.format(x=rp + 130, y=row_top("A", "l:tm/settings-gray-boxes") + 10))),
    ]
    cells = [cell(c, s, stage) for c, s, stage in moments]
    w = 80 + 2 * 968 + 48
    h = 34 + 2 * (36 + 12 + WIN_H) + 36 + 40
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px">'
            f'<div class="cells">{cells[0]}{cells[1]}</div><div class="cells">{cells[2]}{cells[3]}</div></div>')
    return Board("Br-Link.dc.html", "What pointing at a branch lights up", w, h, page("What pointing at a branch lights up", body, w, h))


# ---------------------------------------------------------------- try it

TRY_JS = r"""
const ROWS = __ROWS__;
const TABS = __TABS__;
const VIEW_H = __VIEW_H__;

class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { rows: "A", glow: "once", look: "light", hover: null, st: 0 };
  }

  renderVals() {
    const s = this.state;
    const list = ROWS[s.rows];
    const linking = s.rows !== "today";
    const byId = {};
    list.forEach((r) => { byId[r.id] = r; });
    let hoverRow = "", hoverTab = "", glowTab = "", cur = false, target = null;
    const linked = {};
    if (s.hover && s.hover.kind === "row") {
      hoverRow = s.hover.id;
      const r = byId[hoverRow];
      if (r && linking) {
        if (r.pair && byId[r.pair]) { linked[r.pair] = true; target = byId[r.pair]; }
        if (r.tab) glowTab = r.tab;
        cur = !!r.cur;
      }
    } else if (s.hover && s.hover.kind === "tab") {
      hoverTab = s.hover.id;
      const t = TABS.find((x) => x.id === hoverTab);
      const r = t ? byId[t.row] : null;
      if (r && linking) { linked[r.id] = true; target = r; cur = !!r.cur; }
    }
    let showPill = false, pillDown = false, pillText = "";
    if (target && !(target.y >= s.st && target.y + target.h <= s.st + VIEW_H)) {
      showPill = true;
      pillDown = target.y > s.st;
      pillText = target.full;
    }
    const leave = () => this.setState({ hover: null });
    const rows = list.map((r) => Object.assign({}, r, {
      rcls: r.cls + (r.id === hoverRow ? " hv" : "") + (linked[r.id] ? (cur ? " lkc" : " lk") : ""),
      enter: () => this.setState({ hover: { kind: "row", id: r.id } }),
      leave,
    }));
    const anim = s.glow === "once" ? " once" : s.glow === "breathe" ? " breathe" : "";
    const tabs = TABS.map((t, i) => Object.assign({}, t, {
      tcls: "tab" + (t.on ? " on" : "") + (t.id === hoverTab ? " hv" : "") + (t.id === glowTab ? (cur ? " glc" : " gl") + anim : ""),
      hasFo: t.fo.length > 0,
      first: i === 0,
      iRepo: t.icon === "repo", iWork: t.icon === "work", iLock: t.icon === "lock",
      enter: () => this.setState({ hover: { kind: "tab", id: t.id } }),
      leave,
    }));
    const group = (name, key, options) => ({
      name,
      btns: options.map(([v, t]) => ({
        t, cls: "sg" + (s[key] === v ? " on" : ""), pressed: s[key] === v ? "true" : "false",
        pick: () => this.setState({ [key]: v, hover: null, st: key === "rows" ? 0 : s.st }),
      })),
    });
    const onScroll = (e) => {
      const el = e.currentTarget || e.target;
      this.setState({ st: el.scrollTop });
    };
    return {
      groups: [
        group("Rows", "rows", [["today", "Today"], ["A", "A · one line"], ["B", "B · two lines"]]),
        group("Glow", "glow", [["steady", "Steady"], ["once", "One pulse"], ["breathe", "Breathing"]]),
        group("Look", "look", [["light", "Light"], ["dark", "Dark"]]),
      ],
      sheetCls: "sheet " + (s.look === "dark" ? "th-d" : "th-l"),
      isToday: s.rows === "today", isA: s.rows === "A", isB: s.rows === "B",
      rows, tabs, onScroll,
      showPill, pillCls: "edge " + (cur ? "c" : "s") + (pillDown ? " bot" : " top"), pillDown, pillUp: !pillDown, pillText,
    };
  }
}
"""


def sc_if(cond: str, body: str, placeholder: str = "false") -> str:
    return f'<sc-if value="{{{{{cond}}}}}" hint-placeholder-val="{{{{{placeholder}}}}}">{body}</sc-if>'


def try_rows() -> str:
    """The template for the list's rows, mirroring row_html."""
    head = ('<div class="sh"><span>{{r.title}}</span><span class="cv">' + I["chev"] + '</span><span class="sp"></span>'
            + sc_if("r.hasMinus", '<span class="ib sm" title="{{r.cmdTip}}">' + I["minus"] + "</span>")
            + sc_if("r.hasPlus", '<span class="ib sm">' + I["plus"] + "</span>") + "</div>")
    icons = "".join(sc_if("r." + f, I[k], "true" if k == "branch" else "false")
                    for k, f in (("branch", "iBranch"), ("work", "iWork"), ("lock", "iLock"), ("folder", "iFolder"), ("cloud", "iCloud")))
    trail = (sc_if("r.hasCheck", '<span class="ck">' + I["check"] + "</span>")
             + sc_if("r.hasAbt", '<span class="abt">' + sc_if("r.hasTdn", '<span class="dn">{{r.tdn}}</span>')
                     + sc_if("r.hasTup", '<span class="up">{{r.tup}}</span>') + "</span>")
             + sc_if("r.hasAb", '<span class="ab">' + sc_if("r.hasNdn", "<span>{{r.ndn}}</span>")
                     + sc_if("r.hasNup", "<span>{{r.nup}}</span>") + "</span>")
             + sc_if("r.hasMg", '<span class="mg">merged</span>')
             + sc_if("r.hasDate", '<span class="dt">{{r.date}}</span>'))
    row = ('<div class="{{r.rcls}}" style="{{r.style}}" title="{{r.tip}}" onMouseEnter="{{r.enter}}" onMouseLeave="{{r.leave}}">'
           '<span class="{{r.icCls}}">' + icons + '</span><span class="tx"><span class="l1">'
           '<span class="{{r.nmCls}}">{{r.name}}</span>'
           + sc_if("r.hasChev", '<span class="cv">' + I["chev"] + "</span>")
           + sc_if("r.hasAddr", '<span class="addr">{{r.addr}}</span>')
           + '<span class="tr">' + trail + "</span></span>"
           + sc_if("r.hasSub", '<span class="l2">{{r.sub}}</span>') + "</span></div>")
    return ('<sc-for list="{{rows}}" as="r" hint-placeholder-count="24">'
            + sc_if("r.isHead", head) + sc_if("r.isRow", row, "true") + "</sc-for>")


def try_window() -> str:
    tabs = ('<sc-for list="{{tabs}}" as="t" hint-placeholder-count="6">'
            f'<span class="{{{{t.tcls}}}}" style="width:{TAB_W}px" onMouseEnter="{{{{t.enter}}}}" onMouseLeave="{{{{t.leave}}}}">'
            '<span class="ti">' + sc_if("t.iRepo", I["repo"]) + sc_if("t.iWork", I["work"], "true") + sc_if("t.iLock", I["lock"]) + "</span>"
            '<span class="nm">' + sc_if("t.hasFo", '<span class="fo">{{t.fo}}</span>') + "{{t.nm}}</span></span>"
            + sc_if("t.first", '<i class="tsep"></i>') + "</sc-for>"
            f'<span class="tplus">{I["plus"]}</span>')
    lists = "".join(sc_if(flag, f'<div class="list sc" onScroll="{{{{onScroll}}}}">{try_rows()}</div>', "true" if flag == "isA" else "false")
                    for flag in ("isToday", "isA", "isB"))
    pill = sc_if("showPill", '<div class="{{pillCls}}">' + sc_if("pillDown", I["down"]) + sc_if("pillUp", I["up"])
                 + "<span>{{pillText}}</span></div>")
    return (f'<div class="win"><div class="wtop"><div class="tabs">{tabs}</div><div class="ptop">{panel_header()}</div></div>'
            f'<div class="wbody"><div class="mid">{middle_html()}</div><div class="rp"><div class="lw">{lists}{pill}</div></div></div></div>')


def board_try() -> Board:
    w = 28 + 968 + 28
    h = 28 + 30 + 18 + WIN_H + 18 + 52 + 28
    body = (
        f'<div class="{{{{sheetCls}}}}" style="width:{w}px;height:{h}px">'
        '<div class="bar"><sc-for list="{{groups}}" as="gp" hint-placeholder-count="3"><div class="grp"><span>{{gp.name}}</span>'
        '<div class="seg"><sc-for list="{{gp.btns}}" as="b" hint-placeholder-count="3">'
        '<button class="{{b.cls}}" type="button" aria-pressed="{{b.pressed}}" onClick="{{b.pick}}">{{b.t}}</button>'
        "</sc-for></div></div></sc-for></div>"
        f"{try_window()}"
        '<div class="meta">Point at a branch, a remote branch or a tab. In A and B, a branch and its remote copy tint each other, '
        "and a branch a worktree has lights that worktree's tab, as pointing at the tab tints the branch. Scroll the list so that "
        "the other row is out of view and a pill at the edge names it. The tooltips are the ones the rows would have. Today has none of this.</div>"
        "</div>"
    )
    rows_json = {v: [{k: r[k] for k in r} for r in rows] for v, rows in VARIANTS.items()}
    script = (TRY_JS.replace("__ROWS__", json.dumps(rows_json, ensure_ascii=False))
              .replace("__TABS__", json.dumps(TABS, ensure_ascii=False))
              .replace("__VIEW_H__", str(LIST_H)))
    head, _, body_js = script.partition("class Component extends DCLogic {")
    body_js = body_js.rstrip().removesuffix("}")
    return Board("Br-Try.dc.html", "Try it", w, h, page("Try it", body, w, h, body_js, head), interactive=True)


# ---------------------------------------------------------------- the page


def all_boards() -> list[list[Board]]:
    return [
        [board_today(), board_a(), board_b()],
        [board_states(), board_counts()],
        [board_link(), board_try()],
    ]


TODAY_LOCAL = list_height("today", "l:")
A_LOCAL = list_height("A", "l:")
TODAY_REMOTES = count_visible("today", "r:")
A_REMOTES = count_visible("A", "r:")
B_REMOTES = count_visible("B", "r:")
MERGED = sum(1 for b in LOCALS if b.merged)

TITLES = [
    "What a branch row says",
    "State by state, and the counts",
    "Tying a branch to its remote copy and its tab",
]

INTROS = [
    "The refs panel's branches at their real size, 288 points wide in a window 860 tall, with this repository's own branches as they "
    "stood on 27 November. Today a local branch takes two lines and every other row one, its icon sits in a 16-point column with 8 "
    "points after it, and each folder or remote moves a row 22 points in, so a remote's branches start their names 82 points from the "
    "panel's edge and the local ones 60. A and B both give every branch one height, take the icon to 12 points in a 14-point column "
    "with 6 after it, move a folder's rows 16 points in, and stop indenting a remote's rows under the remote, so a branch and its "
    "remote copy start at the same place, 50 points in.",
    "Each state a branch row can be in, as today draws it and as A does, in both appearances. Then how ahead and behind look in the "
    "places Roga shows them, which is where the refs panel parts from the rest.",
    "Pointing at a branch lights up its other rows and its tab, so you don't have to read two long names to see that they're the same "
    "branch. A remote branch and the local branch that tracks it tint each other, in sky, or in green for the branch checked out here. "
    "A branch that another worktree has lights that worktree's tab, and pointing at a tab tints its branch. When the other row is "
    "scrolled out of view, a pill at the edge of the list names it and points to where it is.",
]

PICK = (
    "What I'd do, each of which can land on its own: "
    "1. Draw the panel's counts in the tabs' gray and leave how far behind main a branch is out of the row, since that's its age rather "
    "than something to do. "
    f"2. Say merged, and add a button that deletes the merged branches no worktree has. {MERGED} of these 16 branches are merged into "
    "main, and nothing in today's panel says so. "
    "3. One line for every row, with a worktree's branch wearing its tab's icon. "
    "4. The tint and the tab's glow on hover, with one pulse. "
    "5. The smaller icons and indents. "
    "B is the alternative if a second line is worth keeping: it's the only second line that says something the name can't."
)

NOTES = {
    "Br-Today.dc.html":
        "The app today. A local branch's second line mostly repeats the row: up to date with origin/tm/commit-box-composer restates "
        "the branch's own name, and 1 ahead, 120 behind main repeats the arrows beside it. What it adds is the worktree, and the "
        f"remote's name when it differs. Behind main is pink, the color of conflicts and deleting. The local branches take {TODAY_LOCAL} "
        f"of the list's {LIST_H} points, so {TODAY_REMOTES} remote branch is in view.",
    "Br-A.dc.html":
        "The one I'd pick. Every row is one line, 28 points, as a remote's rows already are. A branch that another worktree has "
        "wears that worktree's icon, or the lock its tab has, in place of the branch icon. The counts are gray, as on the tabs. A "
        "branch whose commits are all in main says merged, and its name goes gray unless a worktree has it. The icon's color says "
        "whose a branch is, as the badges in history do: green for the branch checked out here, sky for the rest of yours, and on a "
        "remote, sky for a branch one of yours tracks and gray for one nobody here does. The rest, with a remote branch's date, is in "
        f"the tooltip. The local branches take {A_LOCAL} points, and {A_REMOTES} remote branches are in view. Branches gets a button "
        f"that deletes the {len(DELETABLE)} merged branches no worktree has, in decision 38's dialog.",
    "Br-B.dc.html":
        "B keeps two lines for every branch, local or remote, and gives the second to the one thing a name can't say: what the "
        "branch's last commit was about. It skips merge commits, so a branch that only merged main in still says what its own work "
        "was. It costs 40 points a branch and a git log for each one as it scrolls into view, which a remote with thousands of "
        f"branches can afford only that way. {B_REMOTES} remote branches are in view.",
    "Br-States.dc.html":
        "Merged means every commit on the branch is in main, main's upstream or the branch origin/HEAD names, which are the commits "
        "Roga already uses to count a branch ahead, and that the branch has moved since it was made. That second part comes from the "
        "branch's reflog, and keeps a branch just made from an older main from reading as merged before its first commit. git "
        "for-each-ref can count every branch against main in one run with %(ahead-behind:main). A squashed pull request leaves its "
        "branch looking unmerged, as git sees it too, though its upstream going gone after a fetch with pruning says the same.",
    "Br-Counts.dc.html":
        "Decision 27 gave the refs panel's arrows the colors of added and removed lines, at 11 points in a monospaced font. "
        "Everywhere else they're gray: the tabs, the worktree menu, and the branch row, which turns ↓ or ↑ orange only when a click "
        "would pull or push (decision 19). Pink is also what conflicts and deleting use, so a pink ↓120 next to an old branch reads "
        "as something wrong with it. Proposed: gray at 12 points with digits of one width, as the tabs draw them, since a click on a "
        "row selects it rather than pulling.",
    "Br-Link.dc.html":
        "Four moments in the default window. The tab is the one link that's always on screen, so it's the one that glows: a ring in "
        "the branch's color and a soft light around it. In the app it would wait until the pointer has rested on a row for about "
        "150 milliseconds, so that running down the list doesn't flash every tab on the way. A row's tint is the selection's gray in "
        "the branch's color, so it can't be taken for a selection.",
    "Br-Try.dc.html":
        "Point at branches and tabs, and scroll. Rows switches between today, A and B. Glow compares a steady ring, one pulse as it "
        "arrives, and a slow breathing that goes on while the pointer stays. I'd pick one pulse: it catches the eye when the tab is "
        "far from the pointer, then holds still. Breathing keeps moving at the edge of your view, where an agent's ring already turns "
        "on a tab. Reduce Motion gets the steady ring.",
}

PREFIX = "Br"


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"t{PREFIX}{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"n{PREFIX}{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
        if index == 0:
            notes[f"n{PREFIX}Pick"] = {"x": width + 80, "y": y, "w": 640, "text": PICK, "page": PAGE_ID}
        x = 0
        tallest = 0
        for b in row_boards:
            entry = {"x": x, "y": y, "w": b.w, "h": b.h, "page": PAGE_ID, "title": b.title}
            if b.interactive:
                entry["is_interactive"] = True
            boards[b.file] = entry
            notes["n" + re.sub(r"[^A-Za-z0-9]", "", b.file.removesuffix(".dc.html"))] = {
                "x": x, "y": y + b.h + 40, "w": min(b.w, 720), "text": NOTES[b.file], "page": PAGE_ID,
            }
            x += b.w + 80
            tallest = max(tallest, b.h)
        y += tallest + 40 + 300 + 640
    return boards, notes


@click.command()
@click.option("--out", "out", type=click.Path(file_okay=False, path_type=Path), required=True, help="The folder that holds project/.")
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Branches page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Branches boards, and optionally merge them into a canvas.json."""
    rows = all_boards()
    project = out / "project"
    project.mkdir(parents=True, exist_ok=True)
    for b in (b for r in rows for b in r):
        (project / b.file).write_text(b.html)
        click.echo(f"{b.file}  {b.w}×{b.h}  {len(b.html) // 1024} KB")
    click.echo(f"Local branches take {TODAY_LOCAL} points today and {A_LOCAL} in A; remote branches in view: "
               f"today {TODAY_REMOTES}, A {A_REMOTES}, B {B_REMOTES}")
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
