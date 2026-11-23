# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Agent line boards for the design canvas "yaga layout options".

Where the window could say what the agent in the worktree on screen is doing,
now that the sidebar lists only repositories by default (decision 95) and the
worktree's own line shows nowhere but its tab's tooltip. Today's middle
column, four options (A, A2, B and C), every option state by state in both
appearances, the popover that holds the detail, and a board to try them.

    uv run docs/design/agent-line/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Every part is drawn at its size in points: the title row and the branch row
are 44 points tall, a tab 32, a row of history 28. The middle column is 680
points wide in the default window of 1280 with the sidebar (312) and the
refs panel (288) showing, and 480 in a narrower one.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass, field, replace
from pathlib import Path

import click

PAGE_ID = "agentline"
PAGE_NAME = "Agent line"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

WIDE = 680         # the middle column in the default window
NARROW = 480       # and in a narrower one
TITLE_H = 44       # the title row, with the tabs (decision 96)
BAR_H = 44         # the branch row, as tall as a panel's header
ROW_H = 28         # a row of history (CommitCellView.height)
STRIP_H = 30       # one session's line in option B
STAGE_H = 320      # a column on the comparison boards
CELL_H = 132       # a cell on the states boards: the branch row, B's strip and history
SHORT = 600        # under this width, history's count goes before the agent's words


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--surface:#fff;--title:#f3f3f2;--line:#e2e2e2;--tx:#1f1f1e;--tx2:#6b6b66;--tx3:#a3a39e;--hov:rgba(0,0,0,.075);--bhov:rgba(0,0,0,.10);--tabon:#fff;--tabedge:#dedede;--tabsh:rgba(0,0,0,.12);--cnt:#e57a00;--act:#c94402;--warn:#9a5200;--fin:#2f6de1;--red:#cd1755;--track:#d6d6d3;--pill:rgba(0,0,0,.05);--strip:#fafaf9;--sheet:#fff;--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2);--l1:#db1c61;--cur:#547a02;--oncur:#fff;--edge:#c9c9c4;--tip:#f6f6f6;--tiptx:#1a1a1a;--seg:#ecebe8;--segon:#fff;--addb:#edf5dc;--delb:#fdebf1}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--surface:#222;--title:#1b1b1b;--line:#393939;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--hov:rgba(255,255,255,.075);--bhov:rgba(255,255,255,.15);--tabon:#3b3b3b;--tabedge:#4d4d4d;--tabsh:rgba(0,0,0,.4);--cnt:#ff9f0a;--act:#f0813f;--warn:#f0a54a;--fin:#4c8dff;--red:#fc5884;--track:#4a4a47;--pill:rgba(255,255,255,.07);--strip:#262626;--sheet:#2a2a29;--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16);--l1:#ff3478;--cur:#a6e22e;--oncur:#272822;--edge:#62625c;--tip:#3a3a39;--tiptx:#f0f0f0;--seg:#2c2c2b;--segon:#4a4a47;--addb:#29331a;--delb:#3b1d27}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:14px;height:14px;stroke-width:2}
.ic.xs{width:11px;height:11px;stroke-width:2.4}

.mid{position:relative;flex:none;background:var(--surface);color:var(--tx);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);overflow:hidden;display:flex;flex-direction:column;font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
.sp{flex:1 1 0;min-width:0}

.trow{height:44px;flex:none;display:flex;align-items:center;gap:4px;padding:0 8px;background:var(--title);border-bottom:1px solid var(--line);white-space:nowrap;min-width:0}
.tab{position:relative;height:32px;display:flex;align-items:center;gap:6px;padding:0 4px 0 9px;border-radius:8px;flex:0 1 auto;min-width:56px;color:var(--tx)}
.tab.on{background:var(--tabon);box-shadow:0 0 0 1px var(--tabedge),0 0 4px var(--tabsh)}
.tab .ic{color:var(--tx2)}
.tab .nm{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tab .fo{color:var(--tx2)}
.tab .bd{width:24px;flex:none;text-align:center;font-size:12.5px;color:var(--tx2);font-variant-numeric:tabular-nums}
.tab .bd.org{color:var(--cnt)}
.tab .bd.red{color:var(--red)}
.tsep{width:1px;height:16px;background:var(--line);flex:none;margin:0 2px}
.tplus{width:28px;height:28px;display:grid;place-items:center;color:var(--tx2);flex:none}

.brow{height:44px;flex:none;display:flex;align-items:center;padding:0 6px;background:var(--surface);border-bottom:1px solid var(--line);white-space:nowrap;min-width:0}
.chip{height:32px;display:flex;align-items:center;gap:5px;padding:0 7px 0 5px;border:0;border-radius:7px;background:none;color:var(--tx);font:inherit;flex:none}
.chip .ic{color:var(--tx2)}
.chip .nm{min-width:0;overflow:hidden;text-overflow:ellipsis}
.cnt{height:28px;display:flex;align-items:center;gap:3px;padding:0 6px;border-radius:7px;color:var(--tx2);flex:none;font-variant-numeric:tabular-nums}
.cnt.act{color:var(--act)}
.stk{height:28px;display:flex;align-items:center;gap:5px;padding:0 6px;border-radius:7px;color:var(--red);flex:0 0 auto}
.say{color:var(--tx2);margin-left:8px;flex:none}
.undo{height:24px;padding:0 8px;margin-left:6px;border:0;border-radius:7px;background:none;color:var(--act);font:inherit;font-weight:500;flex:none}
.alw{position:relative;display:flex;flex:0 1 auto;min-width:0;margin-left:10px}
.al{height:28px;display:flex;align-items:center;gap:6px;padding:0 8px;border:0;border-radius:7px;background:none;color:var(--tx2);font:inherit;min-width:0;max-width:100%}
.al.hov,.al:hover{background:var(--bhov)}
.al .w,.pill .w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.al .t,.pill .t{flex:none}
.al.warn,.pill.warn,.strip.warn .w,.strip.warn .t,.wag.warn{color:var(--warn)}
.alw2{position:relative;display:flex;flex:0 1 auto;min-width:0;margin:0 10px}
.pill{height:26px;display:flex;align-items:center;gap:6px;padding:0 12px 0 8px;border:0;border-radius:13px;background:var(--pill);color:var(--tx2);font:inherit;font-size:12.5px;min-width:0;max-width:100%}
.rg{display:flex;align-items:center;gap:6px;flex:none;margin-left:12px}
.ib{width:32px;height:32px;display:grid;place-items:center;border:0;border-radius:8px;background:none;color:var(--tx2);padding:0;flex:none}
.ib.sm{width:26px;height:26px;border-radius:6px}
.vs{width:1px;height:18px;background:var(--line);margin:0 6px;flex:none}
.nc{color:var(--tx2);font-size:12.5px}

.strip{height:30px;flex:none;display:flex;align-items:center;gap:6px;padding:0 6px 0 13px;background:var(--strip);border-bottom:1px solid var(--line);font-size:12.5px;color:var(--tx2);white-space:nowrap;min-width:0}
.strip b{font-weight:600;color:var(--tx);flex:none}
.strip .w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.strip .x,.strip .t{flex:none}

.hist{position:relative;flex:1;min-height:0;overflow:hidden;padding-top:4px}
.lane{position:absolute;left:17px;width:2px;background:var(--l1);top:0;bottom:0}
.lane.wt{background:none;border-left:2px dotted var(--tx3);width:0}
.hr{position:relative;height:28px;display:flex;align-items:center;gap:8px;padding:0 12px 0 36px;white-space:nowrap;min-width:0}
.hr .dot{position:absolute;left:12px;top:9px;width:12px;height:12px;border-radius:50%;background:var(--l1);box-shadow:0 0 0 2px var(--surface)}
.hr .dot.wt{background:var(--surface);border:2px solid var(--tx3)}
.hr .mkl{position:absolute;left:11px;top:7px;background:var(--surface);border-radius:50%;padding:0;box-shadow:0 0 0 2px var(--surface)}
.hr .msg{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.hr.wt .msg{color:var(--tx2);flex:none}
.hr.wt .msg.shim{background:linear-gradient(90deg,var(--tx2) 0%,var(--tx2) 38%,var(--act) 50%,var(--tx2) 62%,var(--tx2) 100%);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:alshim 2.4s linear infinite}
@keyframes alshim{from{background-position:100% 0}to{background-position:0 0}}
@media (prefers-reduced-motion:reduce){.hr.wt .msg.shim{animation:none;background:none;color:var(--tx2)}}
.wag{display:flex;align-items:center;gap:6px;min-width:0;flex:0 1 auto;color:var(--tx2)}
.wag .w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.wag .sep{color:var(--tx3);flex:none}
.hr .au{margin-left:auto;color:var(--tx2);font-size:12px;flex:none}
.hr .hs{color:var(--tx2);font:11.5px ui-monospace,"SF Mono",Menlo,monospace;flex:none;width:58px;text-align:right}
.hr .tm{margin-left:auto;color:var(--tx2);flex:none}
.dph{height:44px;flex:none;display:flex;align-items:center;gap:8px;padding:0 6px 0 14px;border-bottom:1px solid var(--line);white-space:nowrap}
.dfn{font-weight:600}
.dfs{color:var(--tx2);font-size:12px}
.dbody{padding:6px 0;font:12px/20px ui-monospace,"SF Mono",Menlo,monospace}
.dl{display:flex;height:20px;white-space:pre}
.dl.add{background:var(--addb)}
.dl.del{background:var(--delb)}
.dn{width:44px;flex:none;text-align:right;padding-right:12px;color:var(--tx3)}
.dc{min-width:0;overflow:hidden;text-overflow:ellipsis}
.bdg{display:inline-block;font-size:11.5px;line-height:16px;padding:0 6px;border-radius:5px;border:1px solid var(--edge);color:var(--tx);margin-right:6px}
.bdg.cur{background:var(--cur);border-color:var(--cur);color:var(--oncur)}

.mk{position:relative;width:14px;height:14px;flex:none;display:block}
.mk svg{position:absolute;left:0;top:0;width:14px;height:14px;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.mk .trk{stroke:var(--track)}
.mk .arc{stroke:var(--act);animation:alspin 1s linear infinite;transform-origin:50% 50%}
.mk .alert{stroke:var(--warn)}
.mk .done{stroke:var(--tx2)}
.mk .fail{stroke:var(--red)}
.mk .tri{stroke:var(--red)}
.mk .dot{position:absolute;left:3.5px;top:3.5px;width:7px;height:7px;border-radius:50%;background:var(--fin)}
@keyframes alspin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.mk .arc{animation:none}}

.tip{position:absolute;z-index:4;width:300px;padding:5px 9px;border-radius:6px;background:var(--tip);color:var(--tiptx);font-size:11.5px;line-height:15px;white-space:pre-line;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 6px 16px rgba(0,0,0,.16)}
.ptr{position:absolute;z-index:5;width:12px;height:18px}

.pop{position:absolute;z-index:4;left:-6px;top:38px;width:340px;background:var(--sheet);color:var(--tx);border-radius:10px;box-shadow:var(--msh);white-space:normal;text-align:left}
.pop::before{content:"";position:absolute;left:28px;top:-6px;width:12px;height:12px;background:var(--sheet);transform:rotate(45deg);box-shadow:-.5px -.5px 0 0 rgba(0,0,0,.14)}
.ps{position:relative;display:flex;flex-direction:column;gap:3px;padding:11px 14px 11px}
.ps+.ps{border-top:1px solid var(--line)}
.p1{display:flex;align-items:center;gap:7px;height:18px}
.p1 b{font-weight:600}
.p1 .st{color:var(--tx2)}
.p1 .st.warn{color:var(--warn)}
.p1 .t{margin-left:auto;color:var(--tx2);font-size:12px}
.p2{padding-left:21px;font-size:13px;line-height:17px;color:var(--tx)}
.p3{padding-left:21px;font-size:12px;line-height:16px;color:var(--tx2)}
.pf{display:flex;gap:4px;padding:6px;border-top:1px solid var(--line)}
.pb{height:28px;display:flex;align-items:center;gap:6px;padding:0 8px;border:0;border-radius:6px;background:none;color:var(--tx);font:inherit;font-size:13px}
.pb .ic{color:var(--tx2)}
.pb.hov{background:var(--bhov)}

.st-grid{display:grid;column-gap:32px;row-gap:16px;align-items:start}
.st-h{font-size:13px;font-weight:600;color:var(--wtx)}
.st-l{font-size:13px;font-weight:500;color:var(--wtx);padding-top:12px}
.st-l i{display:block;font-style:normal;font-weight:400;color:var(--wtx2);margin-top:2px}

.sheet{display:flex;flex-direction:column;gap:18px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:28px}
.bar{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center}
.grp{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--wtx2)}
.seg{display:flex;background:var(--seg);border-radius:8px;padding:2px;gap:2px}
.sg{border:0;background:none;font:inherit;font-size:12.5px;color:var(--wtx2);height:26px;padding:0 10px;border-radius:6px;cursor:pointer}
.sg.on{background:var(--segon);color:var(--wtx);font-weight:500;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.main{display:flex;gap:28px;align-items:flex-start}
.side{display:flex;flex-direction:column;gap:12px;width:330px;flex:none}
.meta{font-size:12.5px;color:var(--wtx2)}
.meta b{color:var(--wtx);font-weight:600}
.log{display:flex;flex-direction:column;gap:6px;margin:0;padding:0;list-style:none}
.log li{font-size:12.5px;color:var(--wtx2);line-height:1.35}
.log li i{font-style:normal;color:var(--wtx2);opacity:.7;margin-right:6px;font-variant-numeric:tabular-nums}
.log li.new{color:var(--wtx);font-weight:500}
.al,.pill,.ib.more{cursor:pointer}
"""


# ---------------------------------------------------------------- icons

def _ic(paths: str, cls: str = "ic") -> str:
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{paths}</svg>'


P_CHEV = '<path d="m6 9 6 6 6-6"></path>'
P_BRANCH = '<line x1="6" x2="6" y1="3" y2="15"></line><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path>'
P_NEWBRANCH = '<path d="M6 3v12"></path><path d="M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path><path d="M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path><path d="M15 6a9 9 0 0 0-9 9"></path><path d="M18 15v6"></path><path d="M21 18h-6"></path>'
P_FETCH = '<path d="M12 2v9"></path><path d="m8 7 4 4 4-4"></path><circle cx="12" cy="18" r="3"></circle>'
P_PUSH = '<path d="m5 9 7-7 7 7"></path><path d="M12 16V2"></path><circle cx="12" cy="21" r="1"></circle>'
P_ORDER = '<path d="M3 12h.01"></path><path d="M3 18h.01"></path><path d="M3 6h.01"></path><path d="M8 12h13"></path><path d="M8 18h13"></path><path d="M8 6h13"></path>'
P_REPO = '<circle cx="12" cy="13" r="2"></circle><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path><path d="M14 13h3"></path><path d="M7 13h3"></path>'
P_WORKTREE = '<path d="M9 20H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v5"></path><circle cx="13" cy="12" r="2"></circle><path d="M18 19c-2.8 0-5-2.2-5-5v8"></path><circle cx="20" cy="19" r="2"></circle>'
P_PLUS = '<path d="M5 12h14"></path><path d="M12 5v14"></path>'
P_TRI = '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path>'
P_TERM = '<path d="M12 19h8"></path><path d="m4 17 6-6-6-6"></path>'
P_DIFF = '<path d="M12 3v14"></path><path d="M5 10h14"></path><path d="M5 21h14"></path>'
P_DOTS = '<circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle><circle cx="5" cy="12" r="1"></circle>'
P_RESTORE = '<polyline points="4 14 10 14 10 20"></polyline><polyline points="20 10 14 10 14 4"></polyline><line x1="14" x2="21" y1="10" y2="3"></line><line x1="3" x2="10" y1="21" y2="14"></line>'

CHEV = _ic(P_CHEV, "ic xs")
BRANCH = _ic(P_BRANCH, "ic s")
NEWBRANCH = _ic(P_NEWBRANCH)
FETCH = _ic(P_FETCH)
PUSH = _ic(P_PUSH, "ic s")
ORDER = _ic(P_ORDER)
REPO = _ic(P_REPO, "ic s")
WORKTREE = _ic(P_WORKTREE, "ic s")
PLUS = _ic(P_PLUS, "ic s")
TRI = _ic(P_TRI, "ic s")
TERM = _ic(P_TERM, "ic s")
DIFF = _ic(P_DIFF, "ic s")
DOTS = _ic(P_DOTS, "ic s")
RESTORE = _ic(P_RESTORE)

RING = ('<span class="mk"><svg class="trk" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5"></circle></svg>'
        '<svg class="arc" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5A5.5 5.5 0 0 1 13.5 8"></path></svg></span>')
WAIT = ('<span class="mk"><svg class="alert" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<line x1="12" x2="12" y1="8" y2="12"></line><line x1="12" x2="12.01" y1="16" y2="16"></line></svg></span>')
DONE = ('<span class="mk"><svg class="done" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<path d="m9 12 2 2 4-4"></path></svg></span>')
FAIL = ('<span class="mk"><svg class="fail" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<path d="m15 9-6 6"></path><path d="m9 9 6 6"></path></svg></span>')
FIN = '<span class="mk"><i class="dot"></i></span>'
CONFLICT = f'<span class="mk"><svg class="tri" viewBox="0 0 24 24" aria-hidden="true">{P_TRI}</svg></span>'
MARK = {"working": RING, "waiting": WAIT, "finished": DONE, "failed": FAIL}


# ---------------------------------------------------------------- what's drawn


@dataclass
class Agent:
    state: str               # working, waiting, finished or failed
    words: str               # the line the helper made, or the agent's name when it has none
    time: str = ""           # "6 min", or "" in the first minute and once it has finished
    who: str = "Claude Code"
    state_words: str = ""    # what the popover says after the name
    subagents: int = 0

    @property
    def tone(self) -> str:
        return "warn" if self.state == "waiting" else ""


@dataclass
class Scene:
    agents: list[Agent] = field(default_factory=list)
    files: int = 3            # uncommitted files; with none, history has no row for them
    ahead: int = 2
    roga: str = ""            # what Roga says after the counts, as "Committed 9f2c1ab"
    stuck: str = ""           # what replaces the counts, as "Rebasing main · 2 conflicts"
    long_name: bool = False   # a longer branch, for the narrow column
    maximized: bool = False   # the panels cover history, up to the branch row
    scrolled: bool = False    # history is scrolled down past its first rows

    @property
    def lead(self) -> Agent | None:
        """What one line says for every session: the waiting one first, then
        the working one, as the tooltip and the sidebar pick it."""
        if not self.agents:
            return None
        if len(self.agents) == 1:
            return self.agents[0]
        waiting = [a for a in self.agents if a.state == "waiting"]
        if waiting:
            a = waiting[0]
            return replace(a, words=f"{a.who} {a.words[0].lower()}{a.words[1:]}")
        working = [a for a in self.agents if a.state == "working"]
        times = [a.time for a in working if a.time]
        return Agent("working", f"{len(self.agents)} agents working", times[0] if times else "")


def working(words: str, time: str = "6 min", **kw) -> Agent:
    return Agent("working", words, time, state_words="working", **kw)


RUN_TESTS = working("Run the test suite", subagents=2)
ALLOW_PUSH = Agent("waiting", "Needs your OK: git push", "2 min", state_words="needs your OK")
ASK_PLAN = Agent("waiting", "Wants a plan approved", "4 min", state_words="waiting for you")
FINISHED = Agent("finished", "Added the lockout tests and updated the changelog", state_words="finished")
FAILED = Agent("failed", "Claude Code stopped with an error", state_words="stopped with an error")
CODEX = working("Reading README.md", "1 min", who="Codex")
CODEX_PUSH = Agent("waiting", "Needs your OK: git push", "1 min", who="Codex", state_words="needs your OK")

BRANCH_NAME = "agent/fix-login"

COMMITS = [
    (["cur:agent/fix-login"], "Add tests for the login lockout", "TM", "48ba644"),
    ([], "Lock the login after five failed attempts", "TM", "5405371"),
    ([], "Show the lockout message on the login screen", "TM", "2f1c9d0"),
    (["main"], "Update the changelog", "AK", "bb3b6b6"),
    ([], "Retry webhooks when the endpoint times out", "AK", "7a03e5c"),
    ([], "Add parser tests", "JL", "9c41e02"),
    ([], "Move the rate limiter into its own package", "JL", "e18f7d3"),
    ([], "Pin the payment client to 4.2", "AK", "1b5a0c9"),
    ([], "Add a health check for the queue", "JL", "3d9e2a1"),
    ([], "Index the new product fields", "AK", "c07b4f8"),
    ([], "Batch push notifications by user", "TM", "a91e6d3"),
]
SCROLLED_BY = 3    # rows of history above the view when it's scrolled

# The diff panel's file, while the panels are maximized over history.
DIFF_FILE = "LoginStore.swift"
DIFF_LINES = [
    ("ctx", "41", "    func attempt(_ password: String) async throws {"),
    ("ctx", "42", "        guard !isLocked else { throw LoginError.locked }"),
    ("del", "43", "        failures += 1"),
    ("add", "43", "        failures = min(failures + 1, limit)"),
    ("add", "44", "        if failures == limit { lock(for: .minutes(5)) }"),
    ("ctx", "45", "        try await session.signIn(password)"),
    ("ctx", "46", "    }"),
]


# ---------------------------------------------------------------- the middle column


def mark(agent: Agent) -> str:
    return MARK[agent.state]


def tab(icon_html: str, folder: str, name: str, badge: str = "", badge_cls: str = "", *, on: bool = False, tip: str = "") -> str:
    fo = f'<span class="fo">{esc(folder)}</span>' if folder else ""
    return (f'<span class="tab{" on" if on else ""}">{icon_html}<span class="nm">{fo}{esc(name)}</span>'
            f'<span class="bd {badge_cls}">{esc(badge)}</span>{tip}</span>')


def title_row(s: Scene, *, tip: str = "") -> str:
    lead = s.lead
    if lead and lead.state == "waiting":
        m = WAIT
    elif s.stuck:
        m = CONFLICT
    elif lead and lead.state == "working":
        m = RING
    else:
        m = WORKTREE
    if s.stuck:
        badge, cls = "2", "red"
    elif s.files:
        badge, cls = str(s.files), "org"
    else:
        badge, cls = f"↑{s.ahead}", ""
    tabs = [
        tab(REPO, "", "roga"),
        '<i class="tsep"></i>',
        tab(m, "agent/", "fix-login", badge, cls, on=True, tip=tip),
        tab(WORKTREE, "agent/", "add-tests", "4", "org"),
        tab(WAIT, "agent/", "rate-limits", "1", "org"),
        f'<span class="tplus">{PLUS}</span>',
    ]
    return f'<div class="trow">{"".join(tabs)}</div>'


def agent_button(a: Agent, cls: str, *, hover: bool = False, attrs: str = "") -> str:
    t = f'<span class="t">· {esc(a.time)}</span>' if a.time else ""
    tone = f" {a.tone}" if a.tone else ""
    hov = " hov" if hover else ""
    return (f'<button class="{cls}{tone}{hov}" type="button"{attrs}>{mark(a)}'
            f'<span class="w">{esc(a.words)}</span>{t}</button>')


def branch_row(s: Scene, option: str, width: int, *, popover: str = "", hover: bool = False) -> str:
    lead = s.lead
    speaks = bool(lead) and not s.roga and option in ("A", "A2", "AC", "AS")
    name = "agent/fix-login-lockout-and-messages" if s.long_name else BRANCH_NAME
    parts = [f'<button class="chip" type="button">{BRANCH}<span class="nm">{esc(name)}</span>{CHEV}</button>']
    if s.stuck:
        parts.append(f'<span class="stk">{TRI}<span>{esc(s.stuck)}</span>{CHEV}</span>')
    else:
        parts.append(f'<span class="cnt act">{PUSH}{s.ahead}</span>')
    if s.roga:
        parts.append(f'<span class="say">{esc(s.roga)}</span><button class="undo" type="button">Undo</button>')
    if speaks and option in ("A", "AC", "AS"):
        parts.append(f'<span class="alw">{agent_button(lead, "al", hover=hover)}{popover}</span>')
        parts.append('<span class="sp"></span>')
    elif speaks and option == "A2":
        parts.append('<span class="sp"></span>')
        parts.append(f'<span class="alw2">{agent_button(lead, "pill", hover=hover)}{popover}</span>')
        parts.append('<span class="sp"></span>')
    else:
        parts.append('<span class="sp"></span>')
    count = "" if speaks and width < SHORT else '<span class="nc">128 commits</span>'
    parts.append(f'<span class="rg"><span class="ib">{FETCH}</span><span class="ib">{NEWBRANCH}</span>'
                 f'<i class="vs"></i>{count}<span class="ib">{ORDER}</span></span>')
    return f'<div class="brow">{"".join(parts)}</div>'


def strips(s: Scene) -> str:
    """Option B: a line for each session, under the branch row."""
    out = []
    for a in s.agents:
        extra = f'<span class="x">· {a.subagents} subagents</span>' if a.subagents else ""
        t = f'<span class="t">{esc(a.time)}</span>' if a.time else ""
        # A line that already names the agent, as before it has said
        # anything, doesn't name it twice.
        who = "" if a.words.startswith(a.who) else f"<b>{esc(a.who)}</b>"
        out.append(f'<div class="strip{" " + a.tone if a.tone else ""}">{mark(a)}{who}'
                   f'<span class="w">{esc(a.words)}</span>{extra}<span class="sp"></span>{t}'
                   f'<span class="ib sm">{TERM}</span><span class="ib sm more">{DOTS}</span></div>')
    return "".join(out)


def named(a: Agent, sessions: int = 1) -> str:
    """The line with the agent's name in front, for C's row, which has no
    other place to say whose words they are, as decision 47's menu does."""
    if sessions > 1 or a.words.startswith(a.who):
        return a.words
    if a.words.startswith("Needs your OK"):
        return f"{a.who} n{a.words[1:]}"
    return f"{a.who}: {a.words}"


def history(s: Scene, option: str, rows: int = 8) -> str:
    """History's first rows. C writes the agent's line on the row for
    uncommitted changes, and brings that row back when there are none. A+C
    only turns the row's dot into the agent's mark while it works or waits,
    and A+S runs a light through the row's words while it works. Both leave
    the row to come and go with the files."""
    lead = s.lead
    on_row = option == "C" and lead is not None and not s.scrolled
    ring_row = (option == "AC" and lead is not None and s.files > 0 and not s.scrolled
                and lead.state in ("working", "waiting"))
    shimmer = (option == "AS" and lead is not None and s.files > 0 and not s.scrolled
               and lead.state == "working")
    out = ['<div class="hist">']
    wt_row = (s.files > 0 or on_row) and not s.scrolled
    lane_top = 4 + ROW_H + 14 if wt_row else 0 if s.scrolled else 4 + 14
    out.append(f'<i class="lane" style="top:{lane_top}px"></i>')
    if wt_row:
        out.append(f'<i class="lane wt" style="top:{4 + 21}px;height:{ROW_H - 12}px"></i>')
        words = f"{s.files} uncommitted file{'s' if s.files != 1 else ''}" if s.files else "Nothing uncommitted yet"
        agent = ""
        if on_row or ring_row:
            dot = f'<span class="mkl">{mark(lead)}</span>'
        else:
            dot = '<span class="dot wt"></span>'
        if on_row:
            t = f'<span class="tm">{esc(lead.time)}</span>' if lead.time else ""
            agent = (f'<span class="wag{" " + lead.tone if lead.tone else ""}"><span class="sep">·</span>'
                     f'<span class="w">{esc(named(lead, len(s.agents)))}</span></span>{t}')
        out.append(f'<div class="hr wt">{dot}<span class="msg{" shim" if shimmer else ""}">{esc(words)}</span>{agent}</div>')
    first = SCROLLED_BY if s.scrolled else 0
    for badges, msg, au, hs in COMMITS[first: first + rows - (1 if wt_row else 0)]:
        b = "".join(f'<span class="bdg{" cur" if x.startswith("cur:") else ""}">{esc(x.removeprefix("cur:"))}</span>' for x in badges)
        out.append(f'<div class="hr"><span class="dot"></span><span class="msg">{b}{esc(msg)}</span>'
                   f'<span class="au">{au}</span><span class="hs">{hs}</span></div>')
    out.append("</div>")
    return "".join(out)


def middle(s: Scene, option: str, width: int, height: int, *, tabs: bool = True, tip: str = "", popover: str = "", hover: bool = False) -> str:
    parts = []
    if tabs:
        parts.append(title_row(s, tip=tip))
    parts.append(branch_row(s, option, width, popover=popover, hover=hover))
    if option == "B" and s.agents:
        parts.append(strips(s))
    parts.append(diff_panel() if s.maximized else history(s, option))
    return f'<div class="mid" style="width:{width}px;height:{height}px">{"".join(parts)}</div>'


def diff_panel() -> str:
    """The diff panel's header and its first lines, which is all that shows
    under the branch row while the panels are maximized (decision 52)."""
    lines = "".join(
        f'<div class="dl {kind}"><span class="dn">{n}</span><span class="dc">{esc(text)}</span></div>'
        for kind, n, text in DIFF_LINES)
    return (f'<div class="dph"><span class="dfn">{DIFF_FILE}</span><span class="dfs">+2 −1</span><span class="sp"></span>'
            f'<span class="ib">{RESTORE}</span></div><div class="dbody">{lines}</div>')


def popover_html(s: Scene, *, files: int | None = None) -> str:
    """The detail behind the line: one section for each session, then what
    you can do about them."""
    secs = []
    for a in s.agents:
        st_cls = " warn" if a.state == "waiting" else ""
        t = f'<span class="t">{esc(a.time)}</span>' if a.time else ""
        words = a.words if a.state != "failed" else "It stopped before the end of its turn."
        if a.state == "waiting" and a.words.startswith("Needs your OK: "):
            words = a.words.removeprefix("Needs your OK: ")
        sub = f'<div class="p3">{a.subagents} subagents running</div>' if a.subagents else ""
        secs.append(f'<div class="ps"><div class="p1">{mark(a)}<b>{esc(a.who)}</b><span class="st{st_cls}">{esc(a.state_words)}</span>{t}</div>'
                    f'<div class="p2">{esc(words)}</div>{sub}</div>')
    n = s.files if files is None else files
    review = f'<button class="pb" type="button">{DIFF}Review {n} File{"s" if n != 1 else ""}</button>' if n else ""
    secs.append(f'<div class="pf"><button class="pb" type="button">{TERM}Show Terminal</button>{review}</div>')
    return f'<div class="pop">{"".join(secs)}</div>'


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
    return f'<div class="cell"><div class="cap">{esc(caption)} <i>· {esc(sub)}</i></div>{stage}</div>'


WORKING = Scene([RUN_TESTS])
TIP_TODAY = (f"{BRANCH_NAME}  ⌘2\n"
             "Claude Code: Run the test suite · 6 min · 3 uncommitted files · ↑2 · ~/git/roga-fix-login")
POINTER = ('<svg class="ptr" style="left:118px;top:20px" viewBox="0 0 12 18" aria-hidden="true">'
           '<path d="M1 1v14l3.6-3.4 2.6 5.6 2.2-1-2.6-5.4H12z" fill="#000" stroke="#fff" stroke-width="1"></path></svg>')


def option_board(file: str, title: str, option: str, captions: tuple[str, str], scene: Scene = WORKING, *, tip: bool = False) -> Board:
    """The middle column at the default width and a narrower one."""
    tip_html = f'<div class="tip" style="left:-20px;top:40px">{esc(TIP_TODAY)}</div>{POINTER}' if tip else ""
    cells = [
        cell(captions[0], f"{WIDE} points, the default window", middle(scene, option, WIDE, STAGE_H, tip=tip_html)),
        cell(captions[1], f"{NARROW} points, a narrower window", middle(scene, option, NARROW, STAGE_H)),
    ]
    w = 80 + WIDE
    h = 34 + 2 * (36 + 12 + STAGE_H) + 36 + 40
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px">'
            + "".join(f'<div class="cells">{c}</div>' for c in cells) + "</div>")
    return Board(file, title, w, h, page(title, body, w, h))


def board_today() -> Board:
    return option_board("Al-Today.dc.html", "Today", "today",
                        ("Today", "The same, narrower"), tip=True)


def board_a() -> Board:
    return option_board("Al-A.dc.html", "A · After the counts", "A",
                        ("A · After the counts", "A, narrower: history's count goes first"))


def board_a2() -> Board:
    return option_board("Al-A2.dc.html", "A2 · A pill in the middle", "A2",
                        ("A2 · A pill in the middle", "A2, narrower"))


def board_b() -> Board:
    return option_board("Al-B.dc.html", "B · A strip under the branch row", "B",
                        ("B · A strip under the branch row", "B, narrower"))


def board_c() -> Board:
    return option_board("Al-C.dc.html", "C · On the row for uncommitted changes", "C",
                        ("C · On the row for uncommitted changes", "C, narrower"))


def board_ac() -> Board:
    return option_board("Al-AC.dc.html", "A+C · A's line, and C's mark on the row", "AC",
                        ("A+C · A's line, and C's mark on the row", "A+C, narrower"))


def board_as() -> Board:
    return option_board("Al-AS.dc.html", "A+S · A's line, and the row's words shimmer", "AS",
                        ("A+S · A's line, and the row's words shimmer", "A+S, narrower"))


STATES: list[tuple[str, str, Scene]] = [
    ("No agent here", "Every option is today's row", Scene()),
    ("Working", "The helper's line, and how long", Scene([RUN_TESTS])),
    ("Before it has said anything", "The agent's name, which is all there is", Scene([working("Claude Code is working", "")])),
    ("Waiting to be allowed", "Amber, like the mark", Scene([ALLOW_PUSH])),
    ("Waiting for an answer", "", Scene([ASK_PLAN])),
    ("Finished", "The reply's first line, until the next turn", Scene([FINISHED])),
    ("Finished with an error", "StopFailure leaves no line, so Roga says it", Scene([FAILED])),
    ("Two agents in one worktree", "One line can't speak for both", Scene([RUN_TESTS, CODEX])),
    ("Two agents, one waiting", "The waiting one wins and is named", Scene([RUN_TESTS, CODEX_PUSH])),
    ("Too long for the row", "The words are cut, and the time stays",
     Scene([working("Subagent: Review the login screen's error states and the lockout message", "12 min")])),
    ("Roga says what just happened", "Its words take the place for their 8 seconds",
     Scene([RUN_TESTS], files=0, ahead=3, roga="Committed 9f2c1ab")),
    ("Stuck partway, with conflicts", "The conflicts stay whole",
     Scene([working("Editing LoginView.swift", "3 min")], stuck="Rebasing main · 2 conflicts")),
    ("Nothing uncommitted yet", "C has to bring its row back for the agent",
     Scene([working("Reading AuthStore.swift", "")], files=0)),
    ("Panels maximized", "Reading the agent's diff hides history",
     Scene([working("Editing LoginStore.swift", "4 min")], maximized=True)),
    ("History scrolled down", "Its first rows are out of view",
     Scene([RUN_TESTS], scrolled=True)),
]

OPTIONS = [("A", "A · After the counts"), ("A2", "A2 · A pill in the middle"),
           ("B", "B · A strip under the branch row"), ("C", "C · On the uncommitted row"),
           ("AC", "A+C · A's line, and C's mark on the row"),
           ("AS", "A+S · A's line, and the row's words shimmer")]


def board_states(dark: bool) -> Board:
    label_w = 230
    cols = f"{label_w}px " + " ".join(f"{WIDE}px" for _ in OPTIONS)
    cells = ['<span class="st-h"></span>'] + [f'<span class="st-h">{esc(t)}</span>' for _, t in OPTIONS]
    for label, sub, scene in STATES:
        cells.append(f'<div class="st-l">{esc(label)}' + (f"<i>{esc(sub)}</i>" if sub else "") + "</div>")
        for option, _ in OPTIONS:
            cells.append(middle(scene, option, WIDE, CELL_H, tabs=False))
    w = 80 + label_w + len(OPTIONS) * (WIDE + 32)
    h = 34 + 20 + len(STATES) * (CELL_H + 16) + 40
    theme = "th-d" if dark else "th-l"
    body = (f'<div class="board {theme}" style="width:{w}px;height:{h}px;display:block">'
            f'<div class="st-grid" style="grid-template-columns:{cols}">{"".join(cells)}</div></div>')
    title = "Every option, state by state" + (", dark" if dark else "")
    return Board("Al-States-Dark.dc.html" if dark else "Al-States.dc.html", title, w, h, page(title, body, w, h))


POP_H = 330


def board_popover() -> Board:
    cases = [
        ("One agent", "a click on A's line", Scene([RUN_TESTS])),
        ("Two agents, one waiting", "each gets its own section", Scene([RUN_TESTS, CODEX_PUSH])),
        ("Finished", "what it said, and its files to review", Scene([replace(FINISHED, words="Added the lockout tests and updated the changelog. Both test suites pass, and the lockout message now names how long to wait.")])),
    ]
    rows = []
    for theme in ("th-l", "th-d"):
        cells = []
        for title, sub, scene in cases:
            stage = middle(scene, "A", WIDE, POP_H, tabs=False, popover=popover_html(scene), hover=True)
            cells.append(f'<div class="{theme}">{cell(title + (", dark" if theme == "th-d" else ""), sub, stage)}</div>')
        rows.append(f'<div class="cells {theme}" style="padding:20px;margin:-20px;border-radius:12px;background:var(--bg)">{"".join(cells)}</div>')
    w = 80 + 3 * WIDE + 2 * 48
    h = 34 + 2 * (36 + 12 + POP_H) + 36 + 40 + 20
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px">{"".join(rows)}</div>'
    return Board("Al-Popover.dc.html", "The popover behind the line", w, h, page("The popover behind the line", body, w, h))


# ---------------------------------------------------------------- try it

# Each step is what the worktree on screen looks like after one event, and
# what the log says about it. A step's agents are [state, who, words, time,
# subagents]. Each step is a minute.
TRY_STEPS = [
    {"log": "Nothing running in agent/fix-login", "agents": [], "files": 0, "ahead": 2},
    {"log": "Claude Code starts a turn", "agents": [["working", "Claude Code", "Claude Code is working", "", 0]], "files": 0, "ahead": 2},
    {"log": "It reads a file", "agents": [["working", "Claude Code", "Reading AuthStore.swift", "1 min", 0]], "files": 0, "ahead": 2},
    {"log": "It asks you to approve its plan", "agents": [["waiting", "Claude Code", "Wants a plan approved", "", 0]], "files": 0, "ahead": 2},
    {"log": "You approve, and it edits", "agents": [["working", "Claude Code", "Editing LoginView.swift", "3 min", 0]], "files": 1, "ahead": 2},
    {"log": "It starts a subagent", "agents": [["working", "Claude Code", "Subagent: Write tests for the lockout", "4 min", 1]], "files": 2, "ahead": 2},
    {"log": "Codex starts in the same worktree", "agents": [["working", "Claude Code", "Subagent: Write tests for the lockout", "5 min", 1], ["working", "Codex", "Reading README.md", "", 0]], "files": 2, "ahead": 2},
    {"log": "Codex quits", "agents": [["working", "Claude Code", "Run the test suite", "6 min", 0]], "files": 3, "ahead": 2},
    {"log": "Claude Code finishes", "agents": [["finished", "Claude Code", "Added the lockout tests and updated the changelog", "", 0]], "files": 3, "ahead": 2},
    {"log": "You commit the three files", "agents": [["finished", "Claude Code", "Added the lockout tests and updated the changelog", "", 0]], "files": 0, "ahead": 3, "roga": "Committed 9f2c1ab"},
    {"log": "You ask it to push", "agents": [["working", "Claude Code", "Claude Code is working", "", 0]], "files": 0, "ahead": 3},
    {"log": "It wants to run git push", "agents": [["waiting", "Claude Code", "Needs your OK: git push", "", 0]], "files": 0, "ahead": 3},
    {"log": "Two minutes later, still waiting", "agents": [["waiting", "Claude Code", "Needs your OK: git push", "2 min", 0]], "files": 0, "ahead": 3},
    {"log": "You allow it, and it pushes", "agents": [["finished", "Claude Code", "Pushed agent/fix-login", "", 0]], "files": 0, "ahead": 0},
    {"log": "It rebases on main and hits conflicts", "agents": [["working", "Claude Code", "Editing LoginView.swift", "1 min", 0]], "files": 2, "ahead": 0, "stuck": "Rebasing main · 2 conflicts"},
    {"log": "It resolves them and finishes", "agents": [["finished", "Claude Code", "Rebased on main and fixed both conflicts", "", 0]], "files": 0, "ahead": 4},
    {"log": "You quit Claude Code", "agents": [], "files": 0, "ahead": 4},
]

TRY_JS = r"""
const STEPS = __STEPS__;
const COMMITS = __COMMITS__;
const SCROLLED_BY = __SCROLLED_BY__;
const TICK_MS = 2400;
const SHORT = __SHORT__;

function lead(agents) {
  if (agents.length === 0) return null;
  const one = (a) => ({ state: a[0], who: a[1], words: a[2], time: a[3], subs: a[4] });
  if (agents.length === 1) return one(agents[0]);
  const waiting = agents.filter((a) => a[0] === "waiting");
  if (waiting.length) { const a = one(waiting[0]); a.words = a.who + " " + a.words[0].toLowerCase() + a.words.slice(1); return a; }
  const timed = agents.filter((a) => a[3]);
  return { state: "working", who: "", words: agents.length + " agents working", time: timed.length ? timed[0][3] : "", subs: 0 };
}

function marks(prefix, state) {
  const out = {};
  out[prefix + "Ring"] = state === "working";
  out[prefix + "Wait"] = state === "waiting";
  out[prefix + "Done"] = state === "finished";
  return out;
}

class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { opt: "A", width: 680, view: "top", look: "light", running: true, step: 0, pop: false, seen: [0] };
    this.timer = null;
  }
  componentDidMount() { this.timer = setInterval(() => { if (this.state.running) this.advance(); }, TICK_MS); }
  componentWillUnmount() { clearInterval(this.timer); }
  advance() {
    const step = (this.state.step + 1) % STEPS.length;
    const seen = [step].concat(this.state.seen).slice(0, 7);
    this.setState({ step, seen });
  }

  renderVals() {
    const s = this.state;
    const sc = STEPS[s.step];
    const l = lead(sc.agents);
    const opt = s.opt;
    const roga = sc.roga || "";
    const stuck = sc.stuck || "";
    const speaks = !!l && !roga && (opt === "A" || opt === "A2" || opt === "AC" || opt === "AS");
    const top = s.view === "top";
    const onRow = opt === "C" && !!l && top;
    const ringRow = opt === "AC" && !!l && sc.files > 0 && top && (l.state === "working" || l.state === "waiting");
    const wtRow = (sc.files > 0 || onRow) && top;
    const rowMark = onRow || ringRow;
    const shimmer = opt === "AS" && !!l && sc.files > 0 && top && l.state === "working";
    const rows = COMMITS.slice(s.view === "scrolled" ? SCROLLED_BY : 0).map((c) => ({
      cur: c[0].length > 0 && c[0][0].startsWith("cur:"), plain: c[0].length > 0 && !c[0][0].startsWith("cur:"),
      badge: c[0].length > 0 ? c[0][0].replace("cur:", "") : "", msg: c[1], au: c[2], hs: c[3],
    }));
    const tone = l && l.state === "waiting" ? " warn" : "";
    const group = (name, key, options) => ({
      name,
      btns: options.map(([v, t]) => ({ t, cls: "sg" + (s[key] === v ? " on" : ""), pressed: s[key] === v ? "true" : "false", pick: () => this.setState({ [key]: v, pop: false }) })),
    });
    let tabBadge = "", tabBadgeCls = "bd";
    if (stuck) { tabBadge = "2"; tabBadgeCls = "bd red"; }
    else if (sc.files) { tabBadge = String(sc.files); tabBadgeCls = "bd org"; }
    else if (sc.ahead) { tabBadge = "↑" + sc.ahead; }
    const tabState = l && l.state === "waiting" ? "waiting" : stuck ? "conflict" : l && l.state === "working" ? "working" : "none";
    const strips = opt === "B" ? sc.agents.map((a) => Object.assign({
      cls: "strip" + (a[0] === "waiting" ? " warn" : ""), named: !a[2].startsWith(a[1]), who: a[1], words: a[2], hasTime: !!a[3], time: a[3],
      hasSubs: a[4] > 0, subs: "· " + a[4] + " subagent" + (a[4] === 1 ? "" : "s"),
    }, marks("s", a[0]))) : [];
    const sessions = sc.agents.map((a) => Object.assign({
      who: a[1],
      stateWords: a[0] === "working" ? "working" : a[0] === "finished" ? "finished" : a[2].startsWith("Needs your OK") ? "needs your OK" : "waiting for you",
      stCls: "st" + (a[0] === "waiting" ? " warn" : ""),
      words: a[2].startsWith("Needs your OK: ") ? a[2].slice(15) : a[2],
      hasTime: !!a[3], time: a[3], hasSubs: a[4] > 0, subs: a[4] + " subagent" + (a[4] === 1 ? "" : "s") + " running",
    }, marks("p", a[0])));
    const files = sc.files;
    const wtWords = files ? files + " uncommitted file" + (files === 1 ? "" : "s") : "Nothing uncommitted yet";
    let rowWords = l ? l.words : "";
    if (l && l.who && sc.agents.length === 1 && !l.words.startsWith(l.who)) {
      rowWords = l.words.startsWith("Needs your OK") ? l.who + " n" + l.words.slice(1) : l.who + ": " + l.words;
    }
    const togglePop = () => this.setState({ pop: !s.pop, running: s.pop ? s.running : false });
    return Object.assign({
      groups: [
        group("Option", "opt", [["today", "Today"], ["A", "A"], ["A2", "A2"], ["B", "B"], ["C", "C"], ["AC", "A+C"], ["AS", "A+S"]]),
        group("Width", "width", [[680, "680"], [480, "480"]]),
        group("History", "view", [["top", "At the top"], ["scrolled", "Scrolled"], ["max", "Maximized"]]),
        group("Look", "look", [["light", "Light"], ["dark", "Dark"]]),
      ],
      runLabel: s.running ? "Pause" : "Play",
      toggleRun: () => this.setState({ running: !s.running, pop: false }),
      stepOnce: () => { this.setState({ pop: false }); this.advance(); },
      reset: () => this.setState({ step: 0, seen: [0], pop: false }),
      sheetCls: "sheet " + (s.look === "dark" ? "th-d" : "th-l"),
      midStyle: "width:" + s.width + "px;height:380px",
      tabMarkRing: tabState === "working", tabMarkWait: tabState === "waiting", tabMarkTri: tabState === "conflict", tabMarkIcon: tabState === "none",
      tabBadge, tabBadgeCls,
      stuck: !!stuck, notStuck: !stuck, stuckWords: stuck, ahead: String(sc.ahead), hasAhead: !stuck && sc.ahead > 0,
      roga: !!roga, rogaWords: roga,
      showA: speaks && (opt === "A" || opt === "AC" || opt === "AS"), showPill: speaks && opt === "A2", noPill: !(speaks && opt === "A2"),
      alCls: "al" + tone + (s.pop ? " hov" : ""), pillCls: "pill" + tone + (s.pop ? " hov" : ""),
      words: l ? l.words : "", hasTime: !!(l && l.time), time: l ? "· " + l.time : "",
      showCount: !(speaks && s.width < SHORT),
      strips, hasStrips: strips.length > 0,
      wtRow, wtWords, onRow, rowMark, wtDot: wtRow && !rowMark, wtMsgCls: "msg" + (shimmer ? " shim" : ""),
      wagCls: "wag" + tone, wagWords: rowWords, rowTime: l ? l.time : "", hasRowTime: !!(l && l.time),
      laneTop: "top:" + (s.view === "scrolled" ? 0 : wtRow ? 46 : 18) + "px",
      rows, showHist: s.view !== "max", showDiff: s.view === "max",
      showPop: s.pop && !!l && (speaks || opt === "B"), popStyle: opt === "B" ? "left:auto;right:6px;top:30px" : "",
      sessions, hasFiles: files > 0, reviewWords: "Review " + files + " File" + (files === 1 ? "" : "s"),
      togglePop,
      log: s.seen.map((i, n) => ({ t: "min " + i, text: STEPS[i].log, cls: n === 0 ? "new" : "" })),
    }, marks("a", l ? l.state : ""), marks("w", l ? l.state : ""));
  }
"""


def sc_if(cond: str, body: str, placeholder: str = "false") -> str:
    return f'<sc-if value="{{{{{cond}}}}}" hint-placeholder-val="{{{{{placeholder}}}}}">{body}</sc-if>'


def mark_ifs(prefix: str) -> str:
    return (sc_if(prefix + "Ring", RING, "true") + sc_if(prefix + "Wait", WAIT) + sc_if(prefix + "Done", DONE))


def try_middle() -> str:
    tab_mark = (sc_if("tabMarkRing", RING, "true") + sc_if("tabMarkWait", WAIT) + sc_if("tabMarkTri", CONFLICT)
                + sc_if("tabMarkIcon", WORKTREE))
    tabs = [
        tab(REPO, "", "roga"),
        '<i class="tsep"></i>',
        f'<span class="tab on">{tab_mark}<span class="nm"><span class="fo">agent/</span>fix-login</span>'
        '<span class="{{tabBadgeCls}}">{{tabBadge}}</span></span>',
        tab(WORKTREE, "agent/", "add-tests", "4", "org"),
        tab(WAIT, "agent/", "rate-limits", "1", "org"),
        f'<span class="tplus">{PLUS}</span>',
    ]
    pop = sc_if("showPop", (
        '<div class="pop" style="{{popStyle}}"><sc-for list="{{sessions}}" as="p" hint-placeholder-count="1">'
        '<div class="ps"><div class="p1">' + mark_ifs("p.p") + '<b>{{p.who}}</b><span class="{{p.stCls}}">{{p.stateWords}}</span>'
        + sc_if("p.hasTime", '<span class="t">{{p.time}}</span>') + '</div><div class="p2">{{p.words}}</div>'
        + sc_if("p.hasSubs", '<div class="p3">{{p.subs}}</div>') + '</div></sc-for>'
        f'<div class="pf"><button class="pb" type="button">{TERM}Show Terminal</button>'
        + sc_if("hasFiles", f'<button class="pb" type="button">{DIFF}{{{{reviewWords}}}}</button>') + '</div></div>'))
    line_inner = mark_ifs("a") + '<span class="w">{{words}}</span>' + sc_if("hasTime", '<span class="t">{{time}}</span>')
    brow = (
        '<div class="brow">'
        f'<button class="chip" type="button">{BRANCH}<span class="nm">{BRANCH_NAME}</span>{CHEV}</button>'
        + sc_if("stuck", f'<span class="stk">{TRI}<span>{{{{stuckWords}}}}</span>{CHEV}</span>')
        + sc_if("hasAhead", f'<span class="cnt act">{PUSH}{{{{ahead}}}}</span>', "true")
        + sc_if("roga", '<span class="say">{{rogaWords}}</span><button class="undo" type="button">Undo</button>')
        + sc_if("showA", '<span class="alw"><button class="{{alCls}}" type="button" onClick="{{togglePop}}">' + line_inner + "</button>" + pop + "</span>", "true")
        + '<span class="sp"></span>'
        + sc_if("showPill", '<span class="alw2"><button class="{{pillCls}}" type="button" onClick="{{togglePop}}">' + line_inner + "</button>" + pop + '</span><span class="sp"></span>')
        + f'<span class="rg"><span class="ib">{FETCH}</span><span class="ib">{NEWBRANCH}</span><i class="vs"></i>'
        + sc_if("showCount", '<span class="nc">128 commits</span>', "true")
        + f'<span class="ib">{ORDER}</span></span></div>'
    )
    strip = ('<div style="position:relative"><sc-for list="{{strips}}" as="x" hint-placeholder-count="1"><div class="{{x.cls}}">' + mark_ifs("x.s")
             + sc_if("x.named", '<b>{{x.who}}</b>', "true") + '<span class="w">{{x.words}}</span>' + sc_if("x.hasSubs", '<span class="x">{{x.subs}}</span>')
             + '<span class="sp"></span>' + sc_if("x.hasTime", '<span class="t">{{x.time}}</span>')
             + f'<span class="ib sm">{TERM}</span><button class="ib sm more" type="button" onClick="{{{{togglePop}}}}">{DOTS}</button></div></sc-for>'
             + sc_if("hasStrips", pop) + '</div>')
    wt = sc_if("wtRow", (
        f'<i class="lane wt" style="top:{4 + 21}px;height:{ROW_H - 12}px"></i>'
        '<div class="hr wt">' + sc_if("wtDot", '<span class="dot wt"></span>', "true")
        + sc_if("rowMark", '<span class="mkl">' + mark_ifs("w") + "</span>")
        + '<span class="{{wtMsgCls}}">{{wtWords}}</span>'
        + sc_if("onRow", '<span class="{{wagCls}}"><span class="sep">·</span><span class="w">{{wagWords}}</span></span>'
                + sc_if("hasRowTime", '<span class="tm">{{rowTime}}</span>'))
        + "</div>"), "true")
    rows = ('<sc-for list="{{rows}}" as="c" hint-placeholder-count="8"><div class="hr"><span class="dot"></span><span class="msg">'
            + sc_if("c.cur", '<span class="bdg cur">{{c.badge}}</span>') + sc_if("c.plain", '<span class="bdg">{{c.badge}}</span>')
            + '{{c.msg}}</span><span class="au">{{c.au}}</span><span class="hs">{{c.hs}}</span></div></sc-for>')
    hist = (sc_if("showHist", '<div class="hist"><i class="lane" style="{{laneTop}}"></i>' + wt + rows + "</div>", "true")
            + sc_if("showDiff", diff_panel()))
    return f'<div class="mid" style="{{{{midStyle}}}}"><div class="trow">{"".join(tabs)}</div>{brow}{strip}{hist}</div>'


def board_try() -> Board:
    w = 28 + WIDE + 28 + 330 + 28
    h = 28 + 2 * 30 + 12 + 18 + 380 + 28   # the bar's controls take two lines
    body = (
        f'<div class="{{{{sheetCls}}}}" style="width:{w}px;height:{h}px">'
        '<div class="bar"><sc-for list="{{groups}}" as="gp" hint-placeholder-count="3"><div class="grp"><span>{{gp.name}}</span>'
        '<div class="seg"><sc-for list="{{gp.btns}}" as="b" hint-placeholder-count="3">'
        '<button class="{{b.cls}}" type="button" aria-pressed="{{b.pressed}}" onClick="{{b.pick}}">{{b.t}}</button>'
        '</sc-for></div></div></sc-for>'
        '<div class="grp"><span>Agents</span><div class="seg">'
        '<button class="sg on" type="button" onClick="{{toggleRun}}">{{runLabel}}</button>'
        '<button class="sg" type="button" onClick="{{stepOnce}}">Next</button>'
        '<button class="sg" type="button" onClick="{{reset}}">Start over</button></div></div></div>'
        f'<div class="main"><div style="width:{WIDE}px;flex:none">{try_middle()}</div>'
        '<div class="side"><div class="meta">What just happened in agent/fix-login, newest first</div>'
        '<ul class="log"><sc-for list="{{log}}" as="l" hint-placeholder-count="5"><li class="{{l.cls}}"><i>{{l.t}}</i>{{l.text}}</li></sc-for></ul>'
        '<div class="meta">Each event is a minute and comes every two and a half seconds. Click the agent\'s line in A or A2, '
        "or the … in B's strip, to open its popover, which pauses the play. Switch Option while it plays to see what moves: "
        "B's strips push history down as agents come and go, and C's row comes and goes with the files.</div>"
        "</div></div></div>"
    )
    script = (TRY_JS.replace("__STEPS__", json.dumps(TRY_STEPS, ensure_ascii=False))
              .replace("__COMMITS__", json.dumps(COMMITS, ensure_ascii=False))
              .replace("__SCROLLED_BY__", str(SCROLLED_BY))
              .replace("__SHORT__", str(SHORT)))
    # The script is a whole class body after `class Component extends DCLogic {`.
    head, _, body_js = script.partition("class Component extends DCLogic {")
    return Board("Al-Try.dc.html", "Try it", w, h, page("Try it", body, w, h, body_js, head), interactive=True)


# ---------------------------------------------------------------- the page


def all_boards() -> list[list[Board]]:
    return [
        [board_today(), board_a(), board_a2(), board_b(), board_c(), board_ac(), board_as()],
        [board_states(False)],
        [board_states(True)],
        [board_popover(), board_try()],
    ]


TITLES = [
    "Where the agent's line could go",
    "Every option, state by state",
    "The same, dark",
    "The detail, and trying it",
]

INTROS = [
    "Decision 95 turned the sidebar's worktrees off by default, so a repository's row speaks for its most urgent worktree, which may not be the one on screen. The line that says what the agent in this worktree is doing now shows only in its tab's tooltip. Each board draws the middle column of the default window, 680 points wide with the sidebar and the refs panel showing, and the same column at 480 points. The tabs, the branch row and history are drawn at their real sizes, and Claude Code is running the tests in agent/fix-login.",
    "Each option in the same fifteen moments, from no agent at all to a rebase that stopped with conflicts, the panels maximized over history, and history scrolled down. The words are decision 48's, so nothing here is new to learn. Only the branch row and the top of history are drawn, so B's strip shows as one row of history fewer. The last three rows are where A and C part: C has to bring its row back when there are no files, and loses its line when history is hidden or scrolled, where A keeps it.",
    "The same moments in the dark appearance.",
    "A click on the line opens a popover with a section for each session, which is where the room for detail is. Try it plays one worktree's story, from a plan through a commit, a push that waits for you and a rebase with conflicts, in whichever option you pick.",
]

EXTRA_NOTES = {
    "nAlPick": {
        "x": 1080, "row": 0, "w": 900,
        "text": "Decided as decision 100: A, with its popover, and A+S's shimmer on the row for uncommitted changes. A fills room the branch row already leaves empty, costs no height, and keeps saying what the agent is doing whether or not there are uncommitted files, with history scrolled or with the panels maximized, which makes the agents' work hard to miss. C sits closest to the files the agent makes, but only while that row is on screen. A+C's mark on that row was left out, since a busy agent would then turn in three places: its tab, the branch row and history. A+S ties the row to the agent with a light running through its words instead, which says that those files are still being made without a third mark.",
    },
    "nAlOpen": {
        "x": 1080, "row": 1, "w": 900,
        "text": "Decision 99 keeps a finished reply in the branch row until the agent's next turn, as drawn, and has the line step aside while Roga's own words show. It leaves Show Terminal out of the popover, since it would need new code and couldn't pick the terminal's tab. Still open: a short history of the agent's last few lines in the popover, which would need AgentMonitor to keep them.",
    },
}

NOTES = {
    "Al-Today.dc.html": "On main. The branch row says where the branch stands and holds Fetch, New Branch and history's commands, and the middle of it is empty unless Roga is saying what just happened. The tab's mark turns while the agent works, and what it's doing takes a hover over the tab and the tooltip's delay.",
    "Al-A.dc.html": "A puts the agent's line where Roga says what just happened, after the counts, with the mark in front so that a bare git push can't read as Roga's own. It's a button that fills gray under the pointer and opens the popover. Its words are cut first when the row is short, then history's count goes, as in the narrower column, and then the branch's name is cut.",
    "Al-A2.dc.html": "A2 puts the same line in a pill centered in the room between the two ends of the row, as Xcode's toolbar shows its activity. It reads more clearly as something to click, and it stands apart from the branch. But it moves whenever either end changes width, as when the counts come and go, and it fights Roga's own words for the middle.",
    "Al-B.dc.html": "B adds a strip under the branch row for each session while there's something to say, with the agent's name, its whole line, its subagents, how long, Show Terminal and a menu. It has the most room and lists every agent, but each strip pushes history down 30 points, so the rows you're reading and the one you selected move whenever an agent starts or quits. Decision 48 noted that kind of jump in the sidebar.",
    "Al-C.dc.html": "C writes the line on history's row for uncommitted changes, whose dot becomes the agent's mark, since that row is what the agent is making. It costs nothing, but the row is only there while there are uncommitted files, so it has to come back for an agent that's only reading, and it scrolls away with history.",
    "Al-AC.dc.html": "A+C is A, plus the agent's mark in place of the dot on history's row for uncommitted changes while the agent works or waits, so the graph also shows which change is still being made. The row keeps its own words and still comes and goes with the files, and a finished agent leaves the plain dot.",
    "Al-AS.dc.html": "A+S is A, plus a light in Roga's orange that runs through the gray words of history's row for uncommitted changes while the agent works, as the light runs around the message box while an agent writes (decision 68). It needs no third mark, and it stops while the agent waits for you, once it finishes, and under Reduce Motion.",
    "Al-States.dc.html": "Where an option has no room, its words are cut at their end and the time stays. While Roga says what just happened, A and A2 give it their place and the tab's mark goes on turning. A finished agent keeps its reply in gray with a check, since the worktree on screen counts as seen at once and its tab never shows the blue dot.",
    "Al-States-Dark.dc.html": "The amber of a waiting agent and the red of conflicts are the sidebar's, so they read the same in the tab, the row and the popover.",
    "Al-Popover.dc.html": "One section for each session, in the order the sidebar ranks them, with its whole line, which can run to 120 characters, and how many subagents it has running. Show Terminal would bring forward the terminal app the agent runs in, and decision 100 leaves it out. Review Files selects the row for uncommitted changes, which is what you'd do next after an agent finishes.",
    "Al-Try.dc.html": "One worktree's story in each option. Pick an option, a width and how history is shown, and press Play, or step with Next. Scrolled and Maximized are where C's line goes away and A's stays.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    row_y: list[int] = []
    y = 0
    for index, row_boards in enumerate(rows):
        row_y.append(y)
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tAl{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nAl{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
    for key, note in EXTRA_NOTES.items():
        notes[key] = {"x": note["x"], "y": row_y[note["row"]] - 340, "w": note["w"], "text": note["text"], "page": PAGE_ID}
    return boards, notes


@click.command()
@click.option("--out", "out", type=click.Path(file_okay=False, path_type=Path), required=True, help="The folder that holds project/.")
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Agent line page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Agent line boards, and optionally merge them into a canvas.json."""
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
