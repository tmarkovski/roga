# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Commit box boards for the design canvas "yaga layout options".

How the message box under the worktree's files could hold its buttons inside
the text box's border, on one row under the text, the way a chat box does.
Today's box, three options (A, B and C), every state of B in both
appearances, and a board to try today's box and B side by side.

    uv run docs/design/commit-box/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Every box is drawn with explicit heights from the constants below, so the
number beside it is its real height in points at that width.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import click

PAGE_ID = "commitbox"
PAGE_NAME = "Commit box"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

LINE = 17          # one line of the message, 13-point text
TOOLBAR = 38       # the row of buttons inside the box
MIN_LINES = 3      # the box's least text, in the options
STAGE_H = 360      # a column on the comparison boards
STATE_H = 280      # a column on the states boards
WIDTH = 320        # the panel's default width (`commitPanelWidth`)
RULER = 78         # room to the right of a column for its height

# Today's box, from CommitBox.swift.
T_HEAD = 32
T_FOOT = 44
T_SHORTEST = 56
T_TALLEST = 240
T_ROOM = 27        # GenerateButton.height + 6 + 4 - 7
T_BARS = 54
T_STATUS = 24      # 8 over a line of 12-point text
T_FAIL = 72        # 8 over a red box of 64


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--sheet:#fff;--surface:#fafaf9;--tx:#1c1c1a;--tx2:#696964;--tx3:#a3a39e;--card:#f0f0ee;--line:#d6d6d3;--hair:#e6e6e3;--ink:#1a1a18;--onink:#fff;--hover:rgba(0,0,0,.05);--mbg:#f6f6f5;--accent:#2f6de1;--red:#c4123f;--redb:#fcedf1;--edge:rgba(201,68,2,.42);--edgeh:rgba(201,68,2,.85);--glow:rgba(201,68,2,.14);--org:#c94402;--act:#c94402;--actf:#c94402;--focus:#a3a39e;--add:#4d7000;--del:#cd1755;--mod:#b35c00;--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2)}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--sheet:#2a2a29;--surface:#252524;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--card:#363635;--line:#4a4a47;--hair:#393938;--ink:#ececea;--onink:#16150e;--hover:rgba(255,255,255,.07);--mbg:#2e2e2d;--accent:#2f6de1;--red:#ff6b8f;--redb:#3a2229;--edge:rgba(240,129,63,.45);--edgeh:rgba(240,129,63,.9);--glow:rgba(240,129,63,.16);--org:#f0813f;--act:#f0813f;--actf:#c94402;--focus:#77776f;--add:#a6e22e;--del:#fc5884;--mod:#ff9f0a;--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16)}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cells.tight{gap:40px}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.stage{position:relative;flex:none}
.gap{flex:1 1 0;min-width:0}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:13px;height:13px;stroke-width:2}
.ic.xs{width:11px;height:11px;stroke-width:2.2}
.ring{width:13px;height:13px;flex:none;display:block;animation:cbspin 1.1s linear infinite;transform-origin:50% 50%}
.ring .rt{fill:none;stroke:var(--line);stroke-width:1.8}
.ring .ra{fill:none;stroke:var(--org);stroke-width:1.8;stroke-linecap:round}
.ring.g .ra{stroke:var(--tx2)}
@keyframes cbspin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.ring{animation:none}}

.col{position:absolute;left:0;top:0;background:var(--sheet);color:var(--tx);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);overflow:hidden;display:flex;flex-direction:column}
.lst{display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden;flex:none}
.gh{display:flex;align-items:center;height:36px;padding:10px 14px 6px;font-size:12px;font-weight:500;flex:none}
.fr{display:flex;align-items:center;gap:8px;height:24px;margin:0 6px;padding:0 8px;border-radius:6px;font-size:12.5px;white-space:nowrap;flex:none}
.fl{width:12px;flex:none;font:500 11.5px ui-monospace,"SF Mono",Menlo,monospace;text-align:center}
.lM{color:var(--mod)}.lA{color:var(--add)}
.fn{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.ff{flex:0 1000 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;color:var(--tx2);font-size:12px}
.num{margin-left:auto;display:flex;gap:6px;font-size:12px;font-variant-numeric:tabular-nums;flex:none}
.plus{color:var(--add)}.minus{color:var(--del)}
.empty{padding:12px 14px;color:var(--tx2);font-size:12.5px}

.rul{position:absolute;width:64px;border-left:1px solid var(--wtx2)}
.rul::before,.rul::after{content:"";position:absolute;left:-4px;width:7px;height:1px;background:var(--wtx2)}
.rul::before{top:0}
.rul::after{bottom:0}
.rv{position:absolute;left:9px;top:50%;transform:translateY(-50%);font-size:12.5px;font-weight:500;line-height:1.3;color:var(--wtx);font-variant-numeric:tabular-nums;white-space:nowrap}
.rv i{display:block;font-style:normal;font-weight:400;font-size:11.5px;color:var(--wtx2)}

.area{position:relative;flex:none;background:var(--surface);box-shadow:inset 0 1px 0 var(--hair);display:flex;flex-direction:column;overflow:hidden}
.tx{display:flex;flex-direction:column;padding:0 10px;flex:none;overflow:hidden}
.ln{height:17px;line-height:17px;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:none}
.ln.s{font-weight:600;display:flex;align-items:baseline;gap:8px}
.ln.s .st{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.cnt{flex:none;font-size:11px;font-weight:400;color:var(--tx2);font-variant-numeric:tabular-nums}
.cnt.over{color:var(--red);font-weight:600}
.ph{color:var(--tx2)}
.tx.ro .ln{color:var(--tx2)}
.bars{display:flex;flex-direction:column;flex:none;padding:5px 10px 0;overflow:hidden}
.bars i{display:block;height:8px;border-radius:4px;background:var(--card);flex:none}

.card{position:relative;flex:none;margin:8px 10px 0;border:1px solid var(--line);border-radius:10px;background:var(--sheet);display:flex;flex-direction:column;box-shadow:0 1px 2px rgba(0,0,0,.04)}
.area.a .card{margin-top:0}
.card.foc,.card:focus-within{border-color:var(--focus)}
.card.lit{border-color:var(--edgeh);box-shadow:0 0 0 3px var(--glow)}
.tb{display:flex;align-items:center;gap:6px;height:38px;padding:0 6px;flex:none;margin-top:auto;overflow:hidden}

.spw{position:relative;display:inline-flex;flex:0 1 auto;min-width:0}
.sp{position:relative;display:inline-flex;align-items:stretch;flex:0 1 auto;min-width:0;font-weight:500;color:var(--tx);height:26px;border-radius:7px;background:var(--card);font-size:12px}
.sp::after{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;box-shadow:inset 0 0 0 1px var(--edge)}
.sp button{border:0;background:none;color:inherit;font:inherit;display:inline-flex;align-items:center;padding:0 8px;white-space:nowrap;cursor:default;border-radius:inherit;min-width:0}
.sp .m{display:block;line-height:26px;overflow:hidden;text-overflow:ellipsis}
.sp .chv{padding:0 5px;color:var(--tx2);border-left:1px solid var(--line);border-radius:0 7px 7px 0;flex:none}
.sp.t24{height:24px}
.sp.t24 .m{line-height:24px}
.sp.off{color:var(--tx3)}
.sp.off::after{box-shadow:inset 0 0 0 1px var(--line)}
.sp.off .chv,.sp button:disabled{color:var(--tx3)}

.cb{display:inline-flex;align-items:stretch;height:26px;border-radius:7px;background:var(--actf);color:#fff;font-size:12.5px;font-weight:500;flex:none;overflow:hidden}
.cb button{border:0;background:none;color:inherit;font:inherit;padding:0 10px;white-space:nowrap;cursor:default;display:inline-flex;align-items:center}
.cb .chv{padding:0 6px;border-left:1px solid rgba(255,255,255,.32)}
.cb.off{background:var(--card);color:var(--tx3)}
.cb.off .chv{border-left-color:var(--line);color:var(--tx2)}
.cb.open .chv{background:rgba(0,0,0,.16)}
.cb.off.open .chv{background:var(--hover);color:var(--tx)}
.cb .chv:disabled{color:var(--tx3)}
.go{height:26px;padding:0 12px;border:0;border-radius:7px;background:var(--actf);color:#fff;font:inherit;font-size:12.5px;font-weight:500;white-space:nowrap;flex:none;cursor:default}
.go.off{background:var(--card);color:var(--tx3)}
.b2{height:26px;padding:0 10px;border:0;border-radius:7px;background:var(--sheet);box-shadow:inset 0 0 0 1px var(--line);color:var(--tx);font:inherit;font-size:12px;white-space:nowrap;flex:none;cursor:default}

.lnk{display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 6px;border:0;border-radius:6px;background:none;color:var(--act);font:inherit;font-size:12px;font-weight:500;white-space:nowrap;flex:none;cursor:default}
.dot{width:7px;height:7px;border-radius:50%;background:var(--accent);flex:none;display:block}
.icb{position:relative;width:26px;height:26px;border:0;border-radius:7px;background:none;color:var(--act);display:grid;place-items:center;padding:0;flex:none;cursor:default}
.icb .dot{position:absolute;top:3px;right:3px;width:6px;height:6px}
.stop{position:relative;display:inline-flex;align-items:center;gap:6px;height:26px;padding:0 10px 0 8px;border:0;border-radius:7px;background:var(--card);color:var(--tx);font:inherit;font-size:12px;font-weight:500;white-space:nowrap;flex:none;cursor:default}
.stop.ag::after{content:"";position:absolute;inset:0;border-radius:inherit;box-shadow:inset 0 0 0 1px var(--edgeh);pointer-events:none}
.secs{font-size:12px;color:var(--tx2);font-variant-numeric:tabular-nums;white-space:nowrap;flex:none}
.run{font-size:12px;color:var(--tx2);white-space:nowrap;min-width:0;overflow:hidden;text-overflow:ellipsis;padding-left:4px}

.strip{flex:none;display:flex;flex-direction:column;gap:6px;padding:7px 7px 0;overflow:hidden}
.chip{display:inline-flex;align-items:center;gap:5px;align-self:flex-start;height:22px;padding:0 8px 0 7px;border-radius:6px;background:var(--card);color:var(--tx);font-size:12px;white-space:nowrap;max-width:100%;flex:none}
.chip.x{padding-right:2px}
.chip b{font-weight:600}
.chip.ink{background:var(--ink);color:var(--onink)}
.chip .xb{width:18px;height:18px;border:0;border-radius:4px;background:none;color:inherit;display:grid;place-items:center;padding:0;opacity:.75;cursor:default}
.snote{font-size:12px;line-height:16px;color:var(--tx2);padding:0 3px;overflow:hidden;flex:none}
.snote b{color:var(--tx);font-weight:500}
.nwrap{flex:none;padding:6px 6px 0}
.notice{border-radius:7px;background:var(--redb);padding:6px 8px 7px;font-size:12px;overflow:hidden}
.notice b{display:block;height:16px;line-height:16px;color:var(--red);font-weight:600}
.notice pre{margin:4px 0 0;font:11px/15px ui-monospace,"SF Mono",Menlo,monospace;color:var(--tx2);white-space:pre;overflow:hidden;text-overflow:ellipsis}
.notice .na{display:flex;gap:14px;margin-top:4px;height:16px;line-height:16px}
.notice .na button{border:0;background:none;padding:0;color:var(--act);font:inherit;font-weight:500;cursor:default}

.thead{display:flex;align-items:center;gap:5px;height:32px;padding:0 14px;font-size:12px;flex:none;white-space:nowrap}
.thead .ld{color:var(--tx2)}
.thead b{font-weight:500}
.ckb{display:inline-flex;align-items:center;gap:5px;border:0;background:none;padding:0;color:var(--tx2);font:inherit;font-size:12px;flex:none;cursor:default}
.cbx{width:12px;height:12px;border:1px solid var(--tx3);border-radius:3px;display:grid;place-items:center;background:var(--sheet);color:transparent}
.cbx.on{background:var(--ink);border-color:var(--ink);color:var(--onink)}
.ted{position:relative;flex:none;margin:0 10px;border:1px solid var(--line);border-radius:8px;padding-top:7px;overflow:hidden}
.ted:focus-within{border-color:var(--focus)}
.ted.lit{border-color:var(--edgeh);box-shadow:0 0 0 3px var(--glow)}
.ted .tx{padding:0 9px}
.ted .bars{padding:5px 9px 0}
.ted .gpos{position:absolute;right:6px;bottom:6px;display:flex}
.tstat{display:flex;align-items:center;gap:7px;height:24px;padding:8px 12px 0;font-size:12px;color:var(--tx2);flex:none;white-space:nowrap;overflow:hidden}
.tstat .lnk{height:16px;padding:0}
.tfail{flex:none;margin:8px 10px 0;border:1px solid var(--red);border-radius:7px;padding:6px 8px;font-size:12px;overflow:hidden}
.tfail b{display:block;color:var(--red);font-weight:600;height:16px;line-height:16px}
.tfail pre{margin:4px 0 0;font:11px/15px ui-monospace,"SF Mono",Menlo,monospace;color:var(--tx2);white-space:pre;overflow:hidden;text-overflow:ellipsis}
.tfoot{display:flex;align-items:center;gap:8px;height:44px;padding:0 10px 0 14px;flex:none}
.kb{font-size:12px;color:var(--tx2)}

.tog{display:inline-flex;align-items:center;gap:5px;height:26px;padding:0 9px;border:0;border-radius:7px;background:none;box-shadow:inset 0 0 0 1px var(--line);color:var(--tx2);font:inherit;font-size:12px;white-space:nowrap;flex:none;cursor:default}
.tog.on{background:var(--ink);color:var(--onink);box-shadow:none}
.tog:disabled{color:var(--tx3)}
.sw{font-size:12px;color:var(--tx2);white-space:nowrap;flex:none}
.send{width:28px;height:28px;border:0;border-radius:50%;background:var(--actf);color:#fff;display:grid;place-items:center;padding:0;flex:none;cursor:default}
.send.off{background:var(--card);color:var(--tx3)}

.menu{position:absolute;z-index:10;width:236px;padding:5px;background:var(--mbg);color:var(--tx);border-radius:10px;box-shadow:var(--msh);font-size:13px;display:flex;flex-direction:column;text-align:left}
.mh{height:22px;line-height:22px;padding:0 10px 0 26px;font-size:11px;font-weight:600;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:none}
.mi{display:flex;align-items:center;width:100%;height:22px;padding:0 10px 0 4px;border:0;border-radius:5px;background:none;color:inherit;font:inherit;white-space:nowrap;text-align:left;cursor:default;flex:none}
.mi .ck{width:22px;flex:none;display:grid;place-items:center}
.mi .tr{margin-left:auto;padding-left:18px;color:var(--tx2);font-size:12.5px}
.mi.hl{background:var(--accent);color:#fff}
.mi.hl .tr{color:rgba(255,255,255,.85)}
.mi:disabled,.mi:disabled .tr{color:var(--tx3)}
.ms{height:1px;background:var(--hair);margin:5px 10px;flex:none}

.try{position:relative;display:flex;flex-direction:column;gap:18px;padding:26px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.try button{cursor:pointer}
.bar{position:relative;z-index:2;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.bar .gl{font-size:12px;color:var(--wtx2);margin:0 4px 0 14px}
.bar .gl:first-child{margin-left:0}
.pill{height:28px;padding:0 12px;border:0;border-radius:8px;background:var(--hover);color:var(--wtx);font:inherit;font-size:12.5px}
.pill.on{background:var(--ink);color:var(--onink);font-weight:500}
.toast{height:28px;display:flex;align-items:center;gap:10px;font-size:12.5px;color:var(--wtx2)}
.toast b{color:var(--wtx);font-weight:500}
.tlnk{border:0;background:none;padding:0;color:var(--act);font:inherit;font-weight:500}
.tcols{display:flex;gap:64px;align-items:flex-start}
.scrim{position:absolute;inset:0;border:0;background:none;padding:0;z-index:5}
.si{display:flex;align-items:baseline;gap:8px;height:17px;flex:none}
.ei{flex:1;min-width:0;border:0;background:none;outline:none;color:var(--tx);font:inherit;font-size:13px;font-weight:600;line-height:17px;height:17px;padding:0}
.ei::placeholder{font-weight:400;color:var(--tx2)}
.et{display:block;width:100%;border:0;background:none;outline:none;resize:none;color:var(--tx);font:inherit;font-size:13px;line-height:17px;padding:0;overflow:hidden;flex:none}
.ei:disabled,.et:disabled{color:var(--tx2);background:none}
"""


# ---------------------------------------------------------------- icons

def _ic(paths: str, cls: str = "ic xs") -> str:
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{paths}</svg>'


CHEV = _ic('<path d="m6 9 6 6 6-6"></path>')
CHECK = _ic('<path d="M20 6 9 17l-5-5"></path>')
CHECK_S = _ic('<path d="M20 6 9 17l-5-5"></path>', "ic s")
XMARK = _ic('<path d="M18 6 6 18M6 6l12 12"></path>')
UNDO = _ic('<path d="M9 14 4 9l5-5"></path><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"></path>', "ic s")
MERGE = _ic('<circle cx="18" cy="18" r="3"></circle><circle cx="6" cy="6" r="3"></circle><path d="M6 21V9a9 9 0 0 0 9 9"></path>', "ic s")
COMMIT = _ic('<circle cx="12" cy="12" r="3"></circle><path d="M3 12h6M15 12h6"></path>', "ic s")
BRANCH = _ic('<path d="M6 3v12"></path><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path>', "ic s")
RING = ('<svg class="ring" viewBox="0 0 14 14" aria-hidden="true"><circle class="rt" cx="7" cy="7" r="5.25"></circle>'
        '<path class="ra" d="M7 1.75a5.25 5.25 0 0 1 5.25 5.25"></path></svg>')
RING_G = RING.replace('class="ring"', 'class="ring g"')


# ---------------------------------------------------------------- what's drawn

UNSTAGED = [
    ("M", "AuthClient.swift", "Sources/Auth", 12, 3),
    ("A", "RetryPolicy.swift", "Sources/Auth", 31, 0),
    ("M", "Info.plist", "App", 1, 1),
    ("A", "LoginViewTests.swift", "Tests/Login", 48, 0),
    ("M", "README.md", "", 4, 1),
]
STAGED = [
    ("M", "LoginView.swift", "Sources/Login", 9, 4),
    ("M", "LoginModel.swift", "Sources/Login", 6, 2),
]


@dataclass
class Msg:
    """A message as the box shows it: the subject first, and "" for the blank
    line git expects after it."""
    lines: list[str] = field(default_factory=list)
    readonly: bool = False


EMPTY = Msg()
READY = Msg(["Reset the retry count after a sign-in", "", "The count only went up, so a third", "mistyped password locked the button."])
AMEND_MSG = Msg(["Log failed sign-ins", "", "A sign-in that failed left nothing in", "the log, so the bug took a day to find."])
LONG = Msg(["Reset the retry count after a sign-in, and stop the button staying disabled forever"])
MERGE_MSG = Msg(["Merge branch 'main' into agent/fix-login"])
REBASE_MSG = Msg(["Add a retry button to the login screen", "", "It shows after a failed sign-in, and", "only while the network is reachable."], readonly=True)

HOOK_OUT = ["LoginView.swift:52: line is too long", "1 violation, 1 serious"]
WRITTEN_TIP = "Generated by Claude Code · haiku in 3 s. Puts back what was there before."


def file_row(f: tuple) -> str:
    letter, name, folder, plus, minus = f
    ff = f'<span class="ff">{esc(folder)}</span>' if folder else ""
    nums = (f'<span class="plus">+{plus}</span>' if plus else "") + (f'<span class="minus">−{minus}</span>' if minus else "")
    return f'<div class="fr"><span class="fl l{letter}">{letter}</span><span class="fn">{esc(name)}</span>{ff}<span class="num">{nums}</span></div>'


def file_list(unstaged: list = UNSTAGED, staged: list = STAGED) -> str:
    out = ""
    if unstaged:
        out += '<div class="gh">Unstaged</div>' + "".join(file_row(f) for f in unstaged)
    if staged:
        out += '<div class="gh">Staged</div>' + "".join(file_row(f) for f in staged)
    return out


# ---------------------------------------------------------------- the text


def text_block(m: Msg, min_h: int, *, bars: bool = False, margin_top: int = 0) -> tuple[str, int]:
    """The message's lines, or the gray bars while an agent writes, at least
    `min_h` tall."""
    mt = f"margin-top:{margin_top}px;" if margin_top else ""
    if bars:
        h = min_h
        return (f'<div class="bars" style="{mt}height:{h}px" role="img" aria-label="Generating commit message">'
                '<i style="width:78%"></i><i style="width:92%;margin-top:12px"></i><i style="width:60%;margin-top:6px"></i></div>', h)
    if not m.lines:
        inner = '<div class="ln ph">Message</div>'
        used = 0
    else:
        subject = m.lines[0]
        count = len(subject)
        over = " over" if count > 72 else ""
        inner = (f'<div class="ln s"><span class="st">{esc(subject)}</span><span class="cnt{over}">{count}</span></div>'
                 + "".join(f'<div class="ln">{esc(line) if line else "&#8203;"}</div>' for line in m.lines[1:]))
        used = len(m.lines) * LINE
    h = max(used, min_h)
    ro = " ro" if m.readonly else ""
    return f'<div class="tx{ro}" style="{mt}height:{h}px">{inner}</div>', h


# ---------------------------------------------------------------- controls


def gen_split(label: str, *, off: bool = False, t24: bool = False) -> str:
    cls = "sp" + (" t24" if t24 else "") + (" off" if off else "")
    return (f'<span class="spw"><span class="{cls}"><button class="m" type="button">{esc(label)}</button>'
            f'<button class="chv" type="button" aria-label="Choose an agent">{CHEV}</button></span></span>')


def commit_split(label: str, *, off: bool = False, chevron: bool = True, open_: bool = False) -> str:
    cls = "cb" + (" off" if off else "") + (" open" if open_ else "")
    chv = f'<button class="chv" type="button" aria-label="More ways to commit">{CHEV}</button>' if chevron else ""
    return f'<span class="{cls}"><button class="m" type="button">{esc(label)}</button>{chv}</span>'


def go(label: str, *, off: bool = False) -> str:
    return f'<button class="go{" off" if off else ""}" type="button">{esc(label)}</button>'


def undo_text() -> str:
    return f'<button class="lnk" type="button" title="{esc(WRITTEN_TIP)}"><span class="dot"></span>Undo</button>'


def undo_icon() -> str:
    return f'<button class="icb" type="button" aria-label="Undo" title="{esc(WRITTEN_TIP)}">{UNDO}<span class="dot"></span></button>'


def stop_tile(*, agent: bool = True) -> str:
    return f'<button class="stop{" ag" if agent else ""}" type="button">{RING if agent else RING_G}Stop</button>'


def secs(n: int) -> str:
    return f'<span class="secs">{n} s</span>'


def toggle(label: str = "Amend", *, on: bool = False, off: bool = False) -> str:
    mark = CHECK if on else ""
    dis = " disabled" if off else ""
    return f'<button class="tog{" on" if on else ""}" type="button" aria-pressed="{"true" if on else "false"}"{dis}>{mark}{esc(label)}</button>'


def chip(icon: str, words: str, *, ink: bool = False, close: bool = False) -> str:
    cls = "chip" + (" ink" if ink else "") + (" x" if close else "")
    x = f'<button class="xb" type="button" aria-label="Stop amending">{XMARK}</button>' if close else ""
    return f'<span class="{cls}">{icon}<span>{words}</span>{x}</span>'


# ---------------------------------------------------------------- sections at the top of the box


def chip_strip(chip_html: str, note: str | None = None, note_lines: int = 2) -> tuple[str, int]:
    h = 7 + 22 + (6 + 16 * note_lines if note else 0)
    note_html = f'<div class="snote" style="height:{16 * note_lines}px">{note}</div>' if note else ""
    return f'<div class="strip" style="height:{h}px">{chip_html}{note_html}</div>', h


def note_strip(note: str, lines: int = 2) -> tuple[str, int]:
    h = 7 + 16 * lines
    return f'<div class="strip" style="height:{h}px"><div class="snote" style="height:{16 * lines}px">{note}</div></div>', h


def notice(title: str, out: list[str] | None, actions: list[str]) -> tuple[str, int]:
    nh = 6 + 16 + (4 + 15 * len(out) if out else 0) + (4 + 16 if actions else 0) + 7
    joined = "\n".join(out) if out else ""
    pre = f"<pre>{esc(joined)}</pre>" if out else ""
    acts = ('<div class="na">' + "".join(f'<button type="button">{esc(a)}</button>' for a in actions) + "</div>") if actions else ""
    return f'<div class="nwrap" style="height:{6 + nh}px"><div class="notice" style="height:{nh}px"><b>{esc(title)}</b>{pre}{acts}</div></div>', 6 + nh


# ---------------------------------------------------------------- boxes


@dataclass
class Box:
    html: str
    h: int
    text_h: int
    overlay: str = ""


def card(m: Msg, *, left: str, right: str, section: tuple[str, int] | None = None, cls: str = "", bars: bool = False) -> tuple[str, int, int]:
    """The text box with its row of buttons inside its border."""
    sec_html, sec_h = section or ("", 0)
    pad = 6 if section else 9
    tx, th = text_block(m, MIN_LINES * LINE, bars=bars, margin_top=pad)
    h = 2 + sec_h + pad + th + TOOLBAR
    classes = f"card {cls}" if cls else "card"
    return (f'<div class="{classes}" style="height:{h}px">{sec_html}{tx}'
            f'<div class="tb">{left}<span class="gap"></span>{right}</div></div>', h, th)


def b_box(m: Msg, *, left: str, right: str, section: tuple[str, int] | None = None, cls: str = "", bars: bool = False, overlay: str = "") -> Box:
    """B and C: the box alone, with nothing over it."""
    c, ch, th = card(m, left=left, right=right, section=section, cls=cls, bars=bars)
    h = 8 + ch + 10
    return Box(f'<div class="area" style="height:{h}px">{c}</div>', h, th, overlay)


def a_box(m: Msg, *, left: str, right: str, heading: tuple[str, str] = ("Commit to", "agent/fix-login"), cls: str = "", bars: bool = False) -> Box:
    """A: today's heading over the box."""
    c, ch, th = card(m, left=left, right=right, cls=cls, bars=bars)
    h = T_HEAD + ch + 10
    head = f'<div class="thead"><span class="ld">{esc(heading[0])}</span><b>{esc(heading[1])}</b></div>'
    return Box(f'<div class="area a" style="height:{h}px">{head}{c}</div>', h, th)


def today_box(m: Msg, *, gen: str | None = "Generate with Claude", gen_off: bool = False, amend: bool | None = False,
              heading: tuple[str, str] = ("Commit to", "agent/fix-login"), status: str | None = None,
              failure: list[str] | None = None, button: str = "Commit 2 Files", button_off: bool = False,
              skip: bool = False, bars: bool = False) -> Box:
    """Today's box, sized the way CommitBox.swift sizes it."""
    room = T_ROOM
    used = len(m.lines) * LINE
    fitted = min(max(used, T_SHORTEST - room), T_TALLEST - room)
    if bars:
        fitted = max(fitted, T_BARS)
    ed_h = 7 + fitted + 7 + room
    tx, _ = text_block(m, fitted, bars=bars)
    gpos = f'<span class="gpos">{gen_split(gen, off=gen_off, t24=True)}</span>' if gen and not bars else ""
    ted = f'<div class="ted{" lit" if bars else ""}" style="height:{ed_h}px">{tx}{gpos}</div>'
    st = f'<div class="tstat">{status}</div>' if status else ""
    fail = ""
    if failure:
        joined = "\n".join(failure)
        fail = f'<div class="tfail" style="height:{T_FAIL - 8}px"><b>The commit didn\'t go through</b><pre>{esc(joined)}</pre></div>'
    if amend is None:
        check = ""
    else:
        check = (f'<button class="ckb" type="button" role="checkbox" aria-checked="{"true" if amend else "false"}">'
                 f'<span class="cbx{" on" if amend else ""}">{CHECK}</span>Amend</button>')
    head = f'<div class="thead"><span class="ld">{esc(heading[0])}</span><b>{esc(heading[1])}</b><span class="gap"></span>{check}</div>'
    skip_html = '<button class="b2" type="button">Skip Hooks</button>' if skip else ""
    foot = f'<div class="tfoot"><span class="kb">⌘↩</span><span class="gap"></span>{skip_html}{go(button, off=button_off)}</div>'
    h = T_HEAD + ed_h + (T_STATUS if status else 0) + (T_FAIL if failure else 0) + T_FOOT
    return Box(f'<div class="area" style="height:{h}px">{head}{ted}{st}{fail}{foot}</div>', h, fitted)


# ---------------------------------------------------------------- columns and cells


def column(box: Box, *, width: int = WIDTH, stage_h: int = STAGE_H, files: str | None = None, note: str = "") -> str:
    """A column of the panel at `width`, with the files above the box and
    the box's height to its right."""
    list_h = stage_h - box.h
    assert list_h >= 0, f"a box of {box.h} doesn't fit a stage of {stage_h}"
    lst = file_list() if files is None else files
    rv_note = f"<i>{esc(note)}</i>" if note else ""
    ruler = (f'<div class="rul" style="left:{width + 14}px;top:{list_h}px;height:{box.h}px">'
             f'<span class="rv">{box.h} pt{rv_note}</span></div>')
    return (f'<div class="stage" style="width:{width + RULER}px;height:{stage_h}px">'
            f'<div class="col" style="width:{width}px;height:{stage_h}px"><div class="lst" style="height:{list_h}px">{lst}</div>'
            f'{box.html}{box.overlay}</div>{ruler}</div>')


def cell(caption: str, sub: str, stage: str) -> str:
    return f'<div class="cell"><div class="cap">{esc(caption)} <i>· {esc(sub)}</i></div>{stage}</div>'


def text_note(box: Box) -> str:
    return f"text: {box.text_h} pt"


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
{CSS}
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


def row_width(stages: list[int], gap: int = 48) -> int:
    return sum(stages) + gap * (len(stages) - 1)


def static_board(file: str, title: str, rows: list[list[tuple[str, int]]], *, theme: str = "th-l", gap: int = 48, stage_h: int = STAGE_H) -> Board:
    """A board of cells in rows. Each cell is its html and its stage's width."""
    w = 80 + max(row_width([sw for _, sw in r], gap) for r in rows)
    h = 34 + len(rows) * (36 + 12 + stage_h) + (len(rows) - 1) * 36 + 40
    cls = "cells tight" if gap == 40 else "cells"
    body = (f'<div class="board {theme}" style="width:{w}px;height:{h}px">'
            + "".join(f'<div class="{cls}">{"".join(c for c, _ in r)}</div>' for r in rows) + "</div>")
    return Board(file, title, w, h, page(title, body, w, h))


def sized(html_: str, width: int = WIDTH) -> tuple[str, int]:
    return html_, width + RULER


# ---------------------------------------------------------------- status lines, today


def written_line() -> str:
    return '<span class="dot"></span><span>Generated by Claude Code · haiku in 3 s.</span><button class="lnk" type="button">Undo</button>'


def writing_line() -> str:
    return f'{RING}<span>Generating with Claude Code… 4 s</span><span class="gap"></span><button class="lnk" type="button">Stop</button>'


# ---------------------------------------------------------------- the commit menu


def commit_menu(label: str, *, amend_on: bool = False, right: int = 10, bottom: int = 47, push_off: bool = False) -> str:
    check = CHECK if amend_on else ""
    push_dis = " disabled" if push_off else ""
    return (f'<div class="menu" role="menu" aria-label="Commit" style="right:{right}px;bottom:{bottom}px">'
            '<div class="mh">On agent/fix-login</div>'
            f'<button class="mi hl" type="button" role="menuitem"><span class="ck"></span><span>{esc(label)}</span><span class="tr">⌘↩</span></button>'
            f'<button class="mi" type="button" role="menuitem"{push_dis}><span class="ck"></span><span>Commit and Push</span><span class="tr">⇧⌘↩</span></button>'
            '<div class="ms"></div>'
            f'<button class="mi" type="button" role="menuitemcheckbox" aria-checked="{"true" if amend_on else "false"}"><span class="ck">{check}</span><span>Amend</span><span class="tr">⌥⌘↩</span></button>'
            '</div>')


# ---------------------------------------------------------------- boards: today and the options


def board_today() -> Board:
    empty = today_box(EMPTY, button_off=True)
    written = today_box(READY, gen="Rewrite", status=written_line())
    failed = today_box(READY, gen="Rewrite", failure=HOOK_OUT, skip=True, button="Try Again")
    cells = [
        sized(cell("Empty", "Generate keeps the box's last 27 points free", column(empty, note=text_note(empty)))),
        sized(cell("After Claude wrote it", "the note goes between the text and Commit", column(written, note=text_note(written)))),
        sized(cell("A hook failed", "its output goes there too, and Skip Hooks joins Commit", column(failed, note=text_note(failed)))),
    ]
    return static_board("Cb-Today.dc.html", "Today", [cells])


def board_a() -> Board:
    empty = a_box(EMPTY, left=toggle() + gen_split("Generate"), right=go("Commit 2 Files", off=True), cls="foc")
    written = a_box(READY, left=toggle() + gen_split("Rewrite") + undo_icon(), right=go("Commit 2 Files"))
    writing = a_box(EMPTY, left=toggle(off=True) + stop_tile() + secs(4), right=go("Commit 2 Files", off=True), cls="lit", bars=True)
    amending = a_box(AMEND_MSG, heading=("Amend", "4be21c0"), left=toggle(on=True) + gen_split("Rewrite"), right=go("Amend Commit"))
    cells = [
        sized(cell("Empty", "Generate can't name the agent here, for room", column(empty, note=text_note(empty)))),
        sized(cell("After Claude wrote it", "Undo has to be an icon", column(written, note=text_note(written)))),
        sized(cell("While Claude writes", "Generate turns into Stop", column(writing, note=text_note(writing)))),
        sized(cell("Amending", "the toggle fills in, and the heading says which commit", column(amending, note=text_note(amending)))),
    ]
    return static_board("Cb-A.dc.html", "A · Amend as a toggle in the row", [cells])


AMEND_CHIP = chip(COMMIT, "Amending <b>4be21c0</b>", ink=True, close=True)


def board_b() -> Board:
    empty = b_box(EMPTY, left=gen_split("Generate with Claude"), right=commit_split("Commit 2 Files", off=True), cls="foc")
    written = b_box(READY, left=gen_split("Rewrite") + undo_text(), right=commit_split("Commit 2 Files"))
    writing = b_box(EMPTY, left=stop_tile() + secs(4), right=commit_split("Commit 2 Files", off=True), cls="lit", bars=True)
    amending = b_box(AMEND_MSG, section=chip_strip(AMEND_CHIP), left=gen_split("Rewrite"), right=commit_split("Amend Commit"))
    menu = b_box(READY, left=gen_split("Rewrite"), right=commit_split("Commit 2 Files", open_=True), cls="foc",
                 overlay=commit_menu("Commit 2 Files"))
    cells = [
        sized(cell("Empty", "Generate on the left, Commit on the right", column(empty, note=text_note(empty)))),
        sized(cell("After Claude wrote it", "Undo sits beside Rewrite", column(written, note=text_note(written)))),
        sized(cell("While Claude writes", "Generate turns into Stop", column(writing, note=text_note(writing)))),
        sized(cell("Amending", "a chip says so, and its ✕ brings your draft back", column(amending, note=text_note(amending)))),
        sized(cell("Commit's menu", "the Changes menu's own three items", column(menu, note=text_note(menu)))),
    ]
    return static_board("Cb-B.dc.html", "B · Generate left, Commit right, Amend in Commit's menu", [cells])


def send(*, off: bool = False) -> str:
    return f'<button class="send{" off" if off else ""}" type="button" aria-label="Commit">{CHECK_S}</button>'


def board_c() -> Board:
    empty = b_box(EMPTY, left=toggle() + gen_split("Generate"), right='<span class="sw">2 files</span>' + send(off=True), cls="foc")
    ready = b_box(READY, left=toggle() + gen_split("Rewrite"), right='<span class="sw">2 files</span>' + send())
    nothing = b_box(READY, left=toggle() + gen_split("Rewrite", off=True), right='<span class="sw">Stage all 7</span>' + send())
    merge = b_box(MERGE_MSG, section=chip_strip(chip(MERGE, "Merging <b>main</b>")), left=gen_split("Rewrite"),
                  right='<span class="sw">2 conflicts left</span>' + send(off=True))
    all_unstaged = file_list(UNSTAGED + STAGED, [])
    cells = [
        sized(cell("Empty", "a round button, with its words beside it", column(empty, note=text_note(empty)))),
        sized(cell("Ready", "a check rather than an arrow, since ↑ means push", column(ready, note=text_note(ready)))),
        sized(cell("Nothing staged", "the words now carry what the button does", column(nothing, files=all_unstaged, note=text_note(nothing)))),
        sized(cell("A merge with conflicts", "the reason it's off is a caption", column(merge, note=text_note(merge)))),
    ]
    return static_board("Cb-C.dc.html", "C · A round button that sends", [cells])


# ---------------------------------------------------------------- boards: B in every state


def board_states(dark: bool) -> Board:
    staged_only = file_list([], STAGED)
    nothing_staged = file_list(UNSTAGED + STAGED, [])

    def col(box: Box, *, width: int = WIDTH, files: str = staged_only) -> str:
        return column(box, width=width, stage_h=STATE_H, files=files)

    empty = b_box(EMPTY, left=gen_split("Generate with Claude"), right=commit_split("Commit 2 Files", off=True))
    typing = b_box(READY, left=gen_split("Rewrite"), right=commit_split("Commit 2 Files"), cls="foc")
    long_ = b_box(LONG, left=gen_split("Rewrite"), right=commit_split("Commit 2 Files"), cls="foc")
    nothing = b_box(READY, left=gen_split("Rewrite", off=True), right=commit_split("Stage All and Commit"))
    writing = b_box(EMPTY, left=stop_tile() + secs(4), right=commit_split("Commit 2 Files", off=True), cls="lit", bars=True)
    written = b_box(READY, left=gen_split("Rewrite") + undo_text(), right=commit_split("Commit 2 Files"))

    changed = b_box(READY, section=note_strip("<b>Staged files changed</b> while Claude Code wrote this, so it may not cover all of them."),
                    left=gen_split("Rewrite") + undo_text(), right=commit_split("Commit 2 Files"))
    gen_failed = b_box(EMPTY, section=notice("Claude Code generation failed", ["claude stopped after 60 s"], ["Try Again", "Agent Settings…", "Show Output"]),
                       left=gen_split("Generate with Claude"), right=commit_split("Commit 2 Files", off=True))
    menu = b_box(READY, left=gen_split("Rewrite"), right=commit_split("Commit 2 Files", open_=True), cls="foc",
                 overlay=commit_menu("Commit 2 Files"))
    amending = b_box(AMEND_MSG, section=chip_strip(AMEND_CHIP), left=gen_split("Rewrite"), right=commit_split("Amend Commit"))
    pushed = b_box(AMEND_MSG, section=chip_strip(AMEND_CHIP, "<b>4be21c0 is on origin/agent/fix-login,</b> so pushing this afterward will need a force push."),
                   left=gen_split("Rewrite"), right=commit_split("Amend Commit"))
    detached = b_box(READY, section=chip_strip(chip(COMMIT, "Detached <b>HEAD</b>"), "No branch will point to this commit until you start one from it."),
                     left=gen_split("Rewrite"), right=commit_split("Commit 2 Files"))

    merge = b_box(MERGE_MSG, section=chip_strip(chip(MERGE, "Merging <b>main</b>")), left=gen_split("Rewrite"),
                  right=commit_split("2 Conflicts Left", off=True, chevron=False))
    rebase = b_box(REBASE_MSG, section=chip_strip(chip(BRANCH, "Rebasing <b>agent/fix-login</b> · 3 of 5")), left=gen_split("Rewrite", off=True),
                   right=commit_split("Continue Rebase", chevron=False))
    hooks = b_box(READY, left='<span class="run">Waiting for hooks or signing…</span>', right=stop_tile(agent=False))
    hook_failed = b_box(READY, section=notice("The commit didn't go through", HOOK_OUT, ["Skip Hooks"]),
                        left=gen_split("Rewrite"), right=commit_split("Try Again"))
    narrow = b_box(READY, left=gen_split("Rewrite") + undo_icon(), right=commit_split("Commit"))
    wide = b_box(EMPTY, left=gen_split("Generate with Claude"), right=commit_split("Commit 2 Files", off=True))

    def c(caption: str, sub: str, box: Box, *, width: int = WIDTH, files: str = staged_only) -> tuple[str, int]:
        return cell(caption, sub, col(box, width=width, files=files)), width + RULER

    rows = [
        [
            c("Empty", "Commit stays off until there's a message, but its chevron still opens for Amend", empty),
            c("Typing", "the count follows the first line, as it does today", typing),
            c("A long subject", "the count turns red past 72, and nothing stops you", long_),
            c("Nothing staged", "Commit offers everything listed, and Generate waits for something staged", nothing, files=nothing_staged),
            c("While Claude writes", "Generate turns into Stop, and the light runs around the box", writing),
            c("After Claude wrote it", "Undo's tooltip says who wrote it and how fast", written),
        ],
        [
            c("Staged files changed meanwhile", "the warning goes at the top, and stays until you edit", changed),
            c("Claude couldn't write it", "the failure says why, with its own Try Again", gen_failed),
            c("Commit's menu", "the Changes menu's three items, with their keys", menu),
            c("Amending", "a chip says so, and its ✕ brings your draft back", amending),
            c("Amending what's pushed", "today's sentence, under the chip", pushed),
            c("Detached HEAD", "a chip, and today's sentence", detached),
        ],
        [
            c("A merge", "Commit waits, and has no chevron, since its menu has nothing to choose", merge),
            c("A rebase that stopped", "the message can't change yet, so Generate is off", rebase),
            c("Waiting for hooks", "Commit turns into Stop, and the words go where Generate was", hooks),
            c("A hook failed", "Skip Hooks goes with what failed, and Commit says Try Again", hook_failed),
            c("At 260 points", "Undo becomes an icon and Commit drops its count", narrow, width=260),
            c("At 420 points", "everything has its full words", wide, width=420),
        ],
    ]
    theme = "th-d" if dark else "th-l"
    file = "Cb-States-Dark.dc.html" if dark else "Cb-States.dc.html"
    title = "B in every state · dark" if dark else "B in every state · light"
    return static_board(file, title, rows, theme=theme, gap=40, stage_h=STATE_H)


# ---------------------------------------------------------------- try it

TRY_HEAD = r"""
const LINE = 17;
const HEAD = { hash: '4be21c0', subject: 'Log failed sign-ins', body: 'A sign-in that failed left nothing in\nthe log, so the bug took a day to find.' };
const WRITTEN = { subject: 'Reset the retry count after a sign-in', body: 'The count only went up, so a third\nmistyped password locked the button.' };
const HASHES = ['9e1f2a4', '3c7b0d9', 'a41e6f2', '58d2c10', 'b07e3a1'];
""" + "const UNSTAGED = " + json.dumps(
    [{"letter": l, "name": n, "folder": f, "plus": f"+{p}" if p else "", "minus": f"−{m}" if m else ""} for l, n, f, p, m in UNSTAGED],
    ensure_ascii=False) + ";\nconst STAGED = " + json.dumps(
    [{"letter": l, "name": n, "folder": f, "plus": f"+{p}" if p else "", "minus": f"−{m}" if m else ""} for l, n, f, p, m in STAGED],
    ensure_ascii=False) + ";\n"

TRY_SCRIPT = r"""
  constructor(props) {
    super(props);
    this.timers = {};
    this.state = Object.assign(this.fresh(), { theme: 'light', width: 320 });
  }
  fresh() {
    return { unstaged: UNSTAGED.slice(), staged: STAGED.slice(), subject: '', body: '', amend: false, draft: null,
      gen: 'idle', secs: 0, before: null, phase: 'idle', slow: false, failNext: false, menu: false,
      toast: '', undoSnap: null, made: 0 };
  }
  componentWillUnmount() { this.clearTimers(); }
  clearTimers() {
    Object.keys(this.timers).forEach((k) => { clearTimeout(this.timers[k]); clearInterval(this.timers[k]); });
    this.timers = {};
  }
  busy() { return this.state.gen === 'writing' || this.state.phase === 'committing'; }
  hasText() { return !!(this.state.subject.trim() || this.state.body.trim()); }
  files() { return this.state.staged.length + this.state.unstaged.length; }
  canGenerate() { return this.state.staged.length > 0 && !this.busy(); }
  canCommit() { return !this.busy() && this.hasText() && (this.files() > 0 || this.state.amend); }

  edited(change) {
    const s = this.state;
    this.setState(Object.assign({ gen: s.gen === 'written' ? 'idle' : s.gen }, change));
  }
  focus(id) { const el = document.getElementById(id); if (el) el.focus(); }
  key(e, body) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      if (e.altKey) this.toggleAmend(); else this.commit(e.shiftKey, false);
      return;
    }
    if (e.code === 'KeyL' && e.metaKey && e.altKey) { e.preventDefault(); this.generate(); return; }
    if (body && e.key === 'Enter' && this.state.subject) { e.preventDefault(); this.focus(body); }
  }

  generate() {
    if (!this.canGenerate()) return;
    const s = this.state;
    this.setState({ gen: 'writing', secs: 0, before: { subject: s.subject, body: s.body }, menu: false, phase: s.phase === 'failed' ? 'idle' : s.phase });
    this.timers.tick = setInterval(() => this.setState({ secs: this.state.secs + 1 }), 1000);
    this.timers.gen = setTimeout(() => {
      clearInterval(this.timers.tick);
      this.setState({ gen: 'written', subject: WRITTEN.subject, body: WRITTEN.body });
    }, 3200);
  }
  stopGen() {
    clearInterval(this.timers.tick); clearTimeout(this.timers.gen);
    const b = this.state.before || { subject: '', body: '' };
    this.setState({ gen: 'idle', subject: b.subject, body: b.body, before: null });
  }
  undo() {
    const b = this.state.before || { subject: '', body: '' };
    this.setState({ gen: 'idle', subject: b.subject, body: b.body, before: null });
  }

  commit(push, skipping) {
    if (!this.canCommit()) return;
    const fails = this.state.failNext && !skipping;
    this.setState({ phase: 'committing', slow: false, menu: false });
    this.timers.slow = setTimeout(() => this.setState({ slow: true }), 600);
    this.timers.commit = setTimeout(() => {
      clearTimeout(this.timers.slow);
      if (fails) { this.setState({ phase: 'failed', slow: false, failNext: false }); return; }
      this.made(push);
    }, fails ? 2200 : 1800);
  }
  made(push) {
    const s = this.state;
    const snap = { unstaged: s.unstaged, staged: s.staged, subject: s.subject, body: s.body, amend: s.amend, draft: s.draft };
    const stagesAll = !s.amend && s.staged.length === 0;
    const hash = HASHES[s.made % HASHES.length];
    this.setState({ phase: 'idle', slow: false, subject: '', body: '', gen: 'idle', before: null, staged: [],
      unstaged: stagesAll ? [] : s.unstaged, amend: false, draft: null, made: s.made + 1,
      toast: (s.amend ? 'Amended ' : 'Committed ') + hash + (push ? ' · Pushed' : ''), undoSnap: push ? null : snap });
  }
  undoCommit() {
    const u = this.state.undoSnap;
    if (!u) return;
    this.setState(Object.assign({ toast: '', undoSnap: null }, u));
  }
  stopCommit() {
    clearTimeout(this.timers.slow); clearTimeout(this.timers.commit);
    this.setState({ phase: 'idle', slow: false });
  }
  toggleAmend() {
    const s = this.state;
    if (this.busy()) return;
    const phase = s.phase === 'failed' ? 'idle' : s.phase;
    if (!s.amend) {
      this.setState({ amend: true, draft: { subject: s.subject, body: s.body }, subject: HEAD.subject, body: HEAD.body, menu: false, gen: 'idle', phase });
    } else {
      const d = s.draft || { subject: '', body: '' };
      this.setState({ amend: false, draft: null, subject: d.subject, body: d.body, menu: false, gen: 'idle', phase });
    }
  }
  setStaging(which) {
    if (this.busy()) return;
    if (which === 'none') this.setState({ staged: [], unstaged: UNSTAGED.concat(STAGED), menu: false });
    else this.setState({ staged: STAGED.slice(), unstaged: UNSTAGED.slice(), menu: false });
  }
  startOver() {
    this.clearTimers();
    this.setState(Object.assign(this.fresh(), { theme: this.state.theme, width: this.state.width }));
  }

  renderVals() {
    const s = this.state;
    const w = s.width;
    const hasText = this.hasText();
    const files = this.files();
    const n = s.staged.length;
    const writing = s.gen === 'writing';
    const written = s.gen === 'written';
    const committing = s.phase === 'committing';
    const failed = s.phase === 'failed';
    const slow = committing && s.slow;
    const busy = writing || committing;
    const commitOn = this.canCommit();
    const narrow = w < 300;
    const full = committing ? 'Committing…' : failed ? 'Try Again' : s.amend ? 'Amend Commit'
      : n === 0 ? (files ? 'Stage All and Commit' : 'Commit') : 'Commit ' + n + (n === 1 ? ' File' : ' Files');
    const short = committing ? 'Committing…' : failed ? 'Try Again' : s.amend ? 'Amend' : n === 0 ? (files ? 'Commit All' : 'Commit') : 'Commit';
    const genOn = this.canGenerate();
    const genTip = n === 0 ? 'Stage changes to generate a commit message'
      : hasText ? 'Rewrite the commit message with Claude Code using the current draft (⌥⌘L)' : 'Generate a commit message with Claude Code (⌥⌘L)';

    // The text: the subject, then as many lines as the rest has.
    const bodyLines = s.body ? s.body.split('\n').length : (s.subject ? 1 : 0);
    const textH = hasText || s.subject ? LINE + LINE * bodyLines : 0;

    // Today, sized as CommitBox.swift sizes it.
    const room = 27;
    let fitted = Math.min(Math.max(textH, 56 - room), 240 - room);
    if (writing) fitted = Math.max(fitted, 54);
    const edH = 14 + room + fitted;
    const todayH = 32 + edH + ((writing || written || slow) ? 24 : 0) + (failed ? 72 : 0) + 44;

    // B.
    const section = (s.amend ? 29 : 0) + (failed ? 89 : 0);
    const pad = section ? 6 : 9;
    const th = writing ? 51 : Math.max(textH, 51);
    const cardH = 2 + section + pad + th + 38;
    const bH = 8 + cardH + 10;

    const stageH = 600;
    const pick = (list, cur, set) => list.map(([value, label]) => ({ label, cls: 'pill' + (cur === value ? ' on' : ''), pick: () => set(value) }));
    const count = s.subject.length;
    return {
      themeCls: 'try ' + (s.theme === 'dark' ? 'th-d' : 'th-l'),
      themes: pick([['light', 'Light'], ['dark', 'Dark']], s.theme, (v) => this.setState({ theme: v })),
      widths: pick([[260, '260'], [320, '320'], [420, '420']], w, (v) => this.setState({ width: v, menu: false })),
      stagings: pick([['two', '2 files'], ['none', 'Nothing']], n > 0 ? 'two' : 'none', (v) => this.setStaging(v)),
      failCls: 'pill' + (s.failNext ? ' on' : ''),
      toggleFail: () => this.setState({ failNext: !s.failNext }),
      startOver: () => this.startOver(),
      hasToast: !!s.toast,
      toastText: s.toast,
      canUndoCommit: !!s.undoSnap,
      undoCommit: () => this.undoCommit(),
      menuOpen: s.menu,
      closeMenu: () => this.setState({ menu: false }),

      unstaged: s.unstaged.map((f) => Object.assign({ fl: 'fl l' + f.letter }, f)),
      staged: s.staged.map((f) => Object.assign({ fl: 'fl l' + f.letter }, f)),
      hasUnstaged: s.unstaged.length > 0,
      hasStaged: n > 0,
      noFiles: files === 0,

      subject: s.subject,
      body: s.body,
      onSubject: (e) => this.edited({ subject: e.target.value }),
      onBody: (e) => this.edited({ body: e.target.value }),
      onSubjectKeyT: (e) => this.key(e, 'cbt-tb'),
      onSubjectKeyB: (e) => this.key(e, 'cbt-bb'),
      onBodyKey: (e) => this.key(e, null),
      textOff: busy,
      bodyStyle: 'height:' + (LINE * bodyLines) + 'px',
      hasCount: count > 0,
      count: String(count),
      cntCls: 'cnt' + (count > 72 ? ' over' : ''),

      writing, notWriting: !writing, written, slow, notSlow: !slow, failed, amend: s.amend,
      secsText: s.secs + ' s',
      genWords: 'Generating with Claude Code…' + (s.secs >= 1 ? ' ' + s.secs + ' s' : ''),
      generate: () => this.generate(),
      stopGen: () => this.stopGen(),
      undo: () => this.undo(),
      undoTip: 'Generated by Claude Code · haiku in 3 s. Puts back what was there before.',
      genOff: !genOn,
      genTip,
      commitNow: () => this.commit(false, false),
      commitPush: () => this.commit(true, false),
      skipHooks: () => this.commit(false, true),
      stopCommit: () => this.stopCommit(),
      toggleAmend: () => this.toggleAmend(),
      toggleMenu: () => this.setState({ menu: !s.menu }),
      commitOff: !commitOn,
      pushOff: !commitOn,
      amendOff: busy,
      menuOff: busy,
      commitTip: full + ' on agent/fix-login (⌘↩)',
      fullLabel: s.amend ? 'Amend Commit' : (n === 0 ? (files ? 'Stage All and Commit' : 'Commit') : 'Commit ' + n + (n === 1 ? ' File' : ' Files')),

      colStyle: 'width:' + w + 'px;height:' + stageH + 'px',

      todayH: todayH + ' pt',
      tListStyle: 'height:' + (stageH - todayH) + 'px',
      tAreaStyle: 'height:' + todayH + 'px',
      tRulStyle: 'left:' + (w + 14) + 'px;top:' + (stageH - todayH) + 'px;height:' + todayH + 'px',
      tLead: s.amend ? 'Amend' : 'Commit to',
      tSubj: s.amend ? HEAD.hash : 'agent/fix-login',
      tCbxCls: 'cbx' + (s.amend ? ' on' : ''),
      tEdCls: 'ted' + (writing ? ' lit' : ''),
      tEdStyle: 'height:' + edH + 'px',
      tTxStyle: 'height:' + fitted + 'px',
      tShowGen: !writing,
      tGenCls: 'sp t24' + (genOn ? '' : ' off'),
      tGenText: hasText ? 'Rewrite' : 'Generate with Claude',
      tGoCls: 'go' + (commitOn ? '' : ' off'),
      tGoText: full,

      bH: bH + ' pt',
      bListStyle: 'height:' + (stageH - bH) + 'px',
      bAreaStyle: 'height:' + bH + 'px',
      bRulStyle: 'left:' + (w + 14) + 'px;top:' + (stageH - bH) + 'px;height:' + bH + 'px',
      bCardCls: 'card' + (writing ? ' lit' : ''),
      bCardStyle: 'height:' + cardH + 'px',
      bTxStyle: 'height:' + th + 'px;margin-top:' + pad + 'px',
      bBarsStyle: 'height:51px;margin-top:' + pad + 'px',
      bShowGen: !writing && !slow,
      bGenCls: 'sp' + (genOn ? '' : ' off'),
      bGenText: hasText ? 'Rewrite' : (w >= 400 || (w >= 320 && n > 0)) ? 'Generate with Claude' : 'Generate',
      undoText: written && !narrow,
      undoIcon: written && narrow,
      bCbCls: 'cb' + (commitOn ? '' : ' off') + (s.menu ? ' open' : ''),
      bCommitText: narrow ? short : full
    };
  }
"""

FILES_LIVE = (
    '<sc-if value="{{hasUnstaged}}" hint-placeholder-val="{{true}}"><div class="gh">Unstaged</div>'
    '<sc-for list="{{unstaged}}" as="f" hint-placeholder-count="5"><div class="fr"><span class="{{f.fl}}">{{f.letter}}</span>'
    '<span class="fn">{{f.name}}</span><span class="ff">{{f.folder}}</span><span class="num"><span class="plus">{{f.plus}}</span>'
    '<span class="minus">{{f.minus}}</span></span></div></sc-for></sc-if>'
    '<sc-if value="{{hasStaged}}" hint-placeholder-val="{{true}}"><div class="gh">Staged</div>'
    '<sc-for list="{{staged}}" as="f" hint-placeholder-count="2"><div class="fr"><span class="{{f.fl}}">{{f.letter}}</span>'
    '<span class="fn">{{f.name}}</span><span class="ff">{{f.folder}}</span><span class="num"><span class="plus">{{f.plus}}</span>'
    '<span class="minus">{{f.minus}}</span></span></div></sc-for></sc-if>'
    '<sc-if value="{{noFiles}}" hint-placeholder-val="{{false}}"><div class="empty">No changes</div></sc-if>'
)

BARS_LIVE = ('<div class="bars" style="{{STYLE}}" role="img" aria-label="Generating commit message">'
             '<i style="width:78%"></i><i style="width:92%;margin-top:12px"></i><i style="width:60%;margin-top:6px"></i></div>')


def inputs_live(subject_id: str, body_id: str, key: str) -> str:
    return (
        f'<div class="si"><input id="{subject_id}" class="ei" aria-label="Commit message, first line" placeholder="Message" '
        f'value="{{{{subject}}}}" onChange="{{{{onSubject}}}}" onKeyDown="{{{{{key}}}}}" disabled="{{{{textOff}}}}">'
        '<sc-if value="{{hasCount}}" hint-placeholder-val="{{false}}"><span class="{{cntCls}}">{{count}}</span></sc-if></div>'
        f'<textarea id="{body_id}" class="et" aria-label="Commit message, the rest" style="{{{{bodyStyle}}}}" value="{{{{body}}}}" '
        'onChange="{{onBody}}" onKeyDown="{{onBodyKey}}" disabled="{{textOff}}"></textarea>'
    )


HOOK_PRE = esc("\n".join(HOOK_OUT))

TODAY_LIVE = (
    '<div class="area" style="{{tAreaStyle}}">'
    '<div class="thead"><span class="ld">{{tLead}}</span><b>{{tSubj}}</b><span class="gap"></span>'
    '<button class="ckb" type="button" role="checkbox" aria-checked="{{amend}}" onClick="{{toggleAmend}}" disabled="{{amendOff}}" '
    'title="Replace the commit HEAD is on (⌥⌘↩)"><span class="{{tCbxCls}}">' + CHECK + '</span>Amend</button></div>'
    '<div class="{{tEdCls}}" style="{{tEdStyle}}">'
    '<sc-if value="{{writing}}" hint-placeholder-val="{{false}}">' + BARS_LIVE.replace("{{STYLE}}", "{{tTxStyle}}") + '</sc-if>'
    '<sc-if value="{{notWriting}}" hint-placeholder-val="{{true}}"><div class="tx" style="{{tTxStyle}}">'
    + inputs_live("cbt-ts", "cbt-tb", "onSubjectKeyT") + '</div></sc-if>'
    '<sc-if value="{{tShowGen}}" hint-placeholder-val="{{true}}"><span class="gpos"><span class="{{tGenCls}}">'
    '<button class="m" type="button" onClick="{{generate}}" disabled="{{genOff}}" title="{{genTip}}">{{tGenText}}</button>'
    '<button class="chv" type="button" aria-label="Choose an agent" title="Opens the agent popover, as today" disabled="{{genOff}}">' + CHEV + '</button>'
    '</span></span></sc-if></div>'
    '<sc-if value="{{writing}}" hint-placeholder-val="{{false}}"><div class="tstat">' + RING + '<span>{{genWords}}</span><span class="gap"></span>'
    '<button class="lnk" type="button" onClick="{{stopGen}}" title="Stop generation and restore the previous message">Stop</button></div></sc-if>'
    '<sc-if value="{{written}}" hint-placeholder-val="{{false}}"><div class="tstat"><span class="dot"></span><span>Generated by Claude Code · haiku in 3 s.</span>'
    '<button class="lnk" type="button" onClick="{{undo}}" title="Restore the previous commit message">Undo</button></div></sc-if>'
    '<sc-if value="{{slow}}" hint-placeholder-val="{{false}}"><div class="tstat">' + RING_G + '<span>Waiting for hooks or signing…</span><span class="gap"></span>'
    '<button class="lnk" type="button" onClick="{{stopCommit}}">Stop</button></div></sc-if>'
    '<sc-if value="{{failed}}" hint-placeholder-val="{{false}}"><div class="tfail" style="height:64px"><b>The commit didn&#x27;t go through</b><pre>' + HOOK_PRE + '</pre></div></sc-if>'
    '<div class="tfoot"><span class="kb">⌘↩</span><span class="gap"></span>'
    '<sc-if value="{{failed}}" hint-placeholder-val="{{false}}"><button class="b2" type="button" onClick="{{skipHooks}}" title="git commit --no-verify">Skip Hooks</button></sc-if>'
    '<button class="{{tGoCls}}" type="button" onClick="{{commitNow}}" disabled="{{commitOff}}">{{tGoText}}</button></div>'
    '</div>'
)

B_LIVE = (
    '<div class="area" style="{{bAreaStyle}}"><div class="{{bCardCls}}" style="{{bCardStyle}}">'
    '<sc-if value="{{amend}}" hint-placeholder-val="{{false}}"><div class="strip" style="height:29px"><span class="chip ink x">' + COMMIT
    + '<span>Amending <b>4be21c0</b></span><button class="xb" type="button" aria-label="Stop amending" title="Put back your draft (⌥⌘↩)" '
    'onClick="{{toggleAmend}}" disabled="{{amendOff}}">' + XMARK + '</button></span></div></sc-if>'
    '<sc-if value="{{failed}}" hint-placeholder-val="{{false}}"><div class="nwrap" style="height:89px"><div class="notice" style="height:83px">'
    '<b>The commit didn&#x27;t go through</b><pre>' + HOOK_PRE + '</pre><div class="na">'
    '<button type="button" onClick="{{skipHooks}}" title="git commit --no-verify">Skip Hooks</button></div></div></div></sc-if>'
    '<sc-if value="{{writing}}" hint-placeholder-val="{{false}}">' + BARS_LIVE.replace("{{STYLE}}", "{{bBarsStyle}}") + '</sc-if>'
    '<sc-if value="{{notWriting}}" hint-placeholder-val="{{true}}"><div class="tx" style="{{bTxStyle}}">'
    + inputs_live("cbt-bs", "cbt-bb", "onSubjectKeyB") + '</div></sc-if>'
    '<div class="tb">'
    '<sc-if value="{{writing}}" hint-placeholder-val="{{false}}"><button class="stop ag" type="button" onClick="{{stopGen}}" '
    'title="Stop Claude Code and put back the message">' + RING + 'Stop</button><span class="secs">{{secsText}}</span></sc-if>'
    '<sc-if value="{{slow}}" hint-placeholder-val="{{false}}"><span class="run">Waiting for hooks or signing…</span></sc-if>'
    '<sc-if value="{{bShowGen}}" hint-placeholder-val="{{true}}"><span class="spw"><span class="{{bGenCls}}">'
    '<button class="m" type="button" onClick="{{generate}}" disabled="{{genOff}}" title="{{genTip}}">{{bGenText}}</button>'
    '<button class="chv" type="button" aria-label="Choose an agent" title="Opens the agent popover, as today" disabled="{{genOff}}">' + CHEV + '</button>'
    '</span></span>'
    '<sc-if value="{{undoText}}" hint-placeholder-val="{{false}}"><button class="lnk" type="button" onClick="{{undo}}" title="{{undoTip}}"><span class="dot"></span>Undo</button></sc-if>'
    '<sc-if value="{{undoIcon}}" hint-placeholder-val="{{false}}"><button class="icb" type="button" aria-label="Undo" onClick="{{undo}}" title="{{undoTip}}">' + UNDO + '<span class="dot"></span></button></sc-if>'
    '</sc-if>'
    '<span class="gap"></span>'
    '<sc-if value="{{slow}}" hint-placeholder-val="{{false}}"><button class="stop" type="button" onClick="{{stopCommit}}" title="Stop the commit">' + RING_G + 'Stop</button></sc-if>'
    '<sc-if value="{{notSlow}}" hint-placeholder-val="{{true}}"><span class="{{bCbCls}}">'
    '<button class="m" type="button" onClick="{{commitNow}}" disabled="{{commitOff}}" title="{{commitTip}}">{{bCommitText}}</button>'
    '<button class="chv" type="button" aria-label="More ways to commit" onClick="{{toggleMenu}}" disabled="{{menuOff}}">' + CHEV + '</button></span></sc-if>'
    '</div></div></div>'
    '<sc-if value="{{menuOpen}}" hint-placeholder-val="{{false}}"><div class="menu" role="menu" aria-label="Commit" style="right:10px;bottom:47px">'
    '<div class="mh">On agent/fix-login</div>'
    '<button class="mi" type="button" role="menuitem" onClick="{{commitNow}}" disabled="{{commitOff}}"><span class="ck"></span><span>{{fullLabel}}</span><span class="tr">⌘↩</span></button>'
    '<button class="mi" type="button" role="menuitem" onClick="{{commitPush}}" disabled="{{pushOff}}"><span class="ck"></span><span>Commit and Push</span><span class="tr">⇧⌘↩</span></button>'
    '<div class="ms"></div>'
    '<button class="mi" type="button" role="menuitemcheckbox" aria-checked="{{amend}}" onClick="{{toggleAmend}}" disabled="{{amendOff}}"><span class="ck">'
    '<sc-if value="{{amend}}" hint-placeholder-val="{{false}}">' + CHECK + '</sc-if></span><span>Amend</span><span class="tr">⌥⌘↩</span></button>'
    '</div></sc-if>'
)


def board_try() -> Board:
    stage_w = 420 + RULER
    w = 80 + stage_w * 2 + 64
    h = 26 + 28 + 18 + 28 + 18 + 36 + 12 + 600 + 40
    pills = lambda name: (f'<sc-for list="{{{{{name}}}}}" as="p" hint-placeholder-count="2">'
                          '<button class="{{p.cls}}" type="button" onClick="{{p.pick}}">{{p.label}}</button></sc-for>')
    stage = lambda list_style, area, rul_style, height, overlay="": (
        f'<div class="stage" style="width:{stage_w}px;height:600px"><div class="col" style="{{{{colStyle}}}}">'
        f'<div class="lst" style="{{{{{list_style}}}}}">{FILES_LIVE}</div>{area}{overlay}</div>'
        f'<div class="rul" style="{{{{{rul_style}}}}}"><span class="rv">{{{{{height}}}}}</span></div></div>'
    )
    body = (
        f'<div class="{{{{themeCls}}}}" style="width:{w}px;height:{h}px">'
        '<sc-if value="{{menuOpen}}" hint-placeholder-val="{{false}}"><button class="scrim" type="button" aria-label="Close the menu" onClick="{{closeMenu}}"></button></sc-if>'
        '<div class="bar"><span class="gl">Appearance</span>' + pills("themes")
        + '<span class="gl">Panel width</span>' + pills("widths")
        + '<span class="gl">Staged</span>' + pills("stagings")
        + '<span class="gl">Next commit</span><button class="{{failCls}}" type="button" onClick="{{toggleFail}}">Fails a hook</button>'
        '<span class="gl"></span><button class="pill" type="button" onClick="{{startOver}}">Start Over</button></div>'
        '<div class="toast"><sc-if value="{{hasToast}}" hint-placeholder-val="{{false}}"><span>The title row says</span><b>{{toastText}}</b>'
        '<sc-if value="{{canUndoCommit}}" hint-placeholder-val="{{false}}"><button class="tlnk" type="button" onClick="{{undoCommit}}">Undo</button></sc-if></sc-if></div>'
        '<div class="tcols">'
        '<div class="cell"><div class="cap">Today <i>· on main</i></div>' + stage("tListStyle", TODAY_LIVE, "tRulStyle", "todayH") + '</div>'
        '<div class="cell"><div class="cap">B <i>· the buttons inside the box</i></div>' + stage("bListStyle", B_LIVE, "bRulStyle", "bH") + '</div>'
        '</div></div>'
    )
    return Board("Cb-Try.dc.html", "Try it · today and B", w, h, page("Try it · today and B", body, w, h, TRY_SCRIPT, TRY_HEAD), interactive=True)


# ---------------------------------------------------------------- the page


def all_boards() -> list[list[Board]]:
    return [
        [board_today()],
        [board_a(), board_b(), board_c()],
        [board_states(False), board_states(True)],
        [board_try()],
    ]


TITLES = [
    "The message box today",
    "Buttons inside the box",
    "B in every state",
    "Try it",
]

INTROS = [
    "Today the message box is three bands stacked under the files. The heading says where the commit goes and holds Amend, the text box holds Generate in its corner, and a footer holds ⌘↩ and Commit. At the default width of 320 points, an empty box takes 146 points and the text gets 29 of them, because the box keeps room under the text for Generate. The agent's note and the hooks' line go between the text and Commit, so Commit moves down whenever one of them shows.",
    "Each option puts the buttons inside the text box's border, on one row under the text, the way a chat box does, with tools on the left and the button that sends on the right. All three are drawn at 320 points in the same few moments, with the files above them, so you can see how much of the list each one gives back. The number beside each box is its height from the separator to the bottom of the panel, and the smaller number under it is how much of that the text gets.",
    "Every state the box has today, drawn in B. Two rules place everything. Something that's running shows where it was started, with Stop in that button's place, so Generate turns into Stop while the agent writes, and Commit turns into Stop while hooks or signing take a while. Anything about the commit itself, such as a mode, a warning or a failure, shows at the top of the box with its own fix beside it, so the row of buttons never moves.",
    "Press Play. Today and B share one message, so typing in either one fills both, and you can watch how much room each takes as it changes. Press Generate, then Stop, Undo or Rewrite. Open Commit's chevron for Amend, and press ⌘↩ to commit. The bar changes the appearance, the panel's width, whether anything is staged and whether the next commit fails a hook, so you can see how B's labels shorten at 260 points.",
]

EXTRA_NOTES = {
    "nCbPick": {
        "x": 1080, "row": 1, "w": 900,
        "text": "I'd build B. Empty, it's 28 points shorter than today, and with a message an agent wrote it's 74 shorter, which matters most on a laptop, where the list of files is already short. Its text gets three lines instead of one and a half, and Commit's menu is the Changes menu's own group, so there's nothing new to learn. What it gives up is that Amend takes two clicks or ⌥⌘↩ rather than one, and the heading that named the branch is gone for an ordinary commit. If you amend often, A's toggle can join B's row, but then Generate can't name the agent at 320 points.",
    },
    "nCbOpen": {
        "x": 2060, "row": 1, "w": 900,
        "text": "Still open. Should an ordinary commit still name its branch inside the box, as a quiet first line that would cost 26 points? Should Undo say on screen who wrote the message, as today's line under the box does, rather than in its tooltip? And should the subject's count stay at the end of the first line, or move into the row beside Commit, where a chat box would put it? Nothing here is built.",
    },
}

NOTES = {
    "Cb-Today.dc.html": "On main. Generate and Commit end up stacked at the right edge, 30 points apart, so they read as a pair even though one writes the message and the other commits it. With a four-line message and the agent's note under it, the box takes 209 points. A failed hook adds its output between the text and Commit and puts Skip Hooks in the footer, for 257.",
    "Cb-A.dc.html": "A keeps the heading and moves Amend into the row as a toggle, the way a chat box shows a mode such as web search. It's the closest copy of a chat box, but three controls don't fit on one row at 320 points with their full names, so Generate can't name the agent and Undo has to be an icon. Empty, it's only 4 points shorter than today, though its text gets three full lines rather than one and a half. With a four-line message, it's 159 points against today's 209.",
    "Cb-B.dc.html": "B, the one I'd pick. Generate is on the left and Commit is on the right, and Commit's chevron opens the three items the Changes menu already groups together: Commit, Commit and Push, and Amend. The heading goes, because the branch row at the top of the window names the branch. A chip appears at the top of the box only when the commit isn't an ordinary one, such as Amending 4be21c0, whose ✕ brings back your draft. Empty, it's 118 points, 28 fewer than today, and with a four-line message it's 135 against 209.",
    "Cb-C.dc.html": "C looks the most like a chat box, with a round button that sends and its words beside it in gray. It's the narrowest, but Commit's words do real work in Roga. Stage All and Commit, 2 Conflicts Left and Continue Rebase say what a click will do, and as gray text next to an icon they read as a caption rather than as the button. It can't use the arrow chat boxes use either, because ↑ means push in the branch row, so it's a check, as in VS Code.",
    "Cb-States.dc.html": "Commit's chevron goes away when its menu would have nothing to choose, as during a merge or a rebase, when Roga already turns off both Commit and Push and Amend. The ⌘↩ hint moves from the footer into Commit's tooltip and its menu, which lists all three keys. At 260 points Undo becomes an icon and Commit drops its count, and at 420 every label has its full words.",
    "Cb-States-Dark.dc.html": "The same states in the dark appearance. The agent's orange line and the light around the box are today's, from decision 68.",
    "Cb-Try.dc.html": "Today and B, live, with one message between them. Generate's chevron only shows where the agent popover opens, since the Agent picker page has that popover.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    row_y: list[int] = []
    y = 0
    for index, row_boards in enumerate(rows):
        row_y.append(y)
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tCb{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nCb{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Commit box page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Commit box boards, and optionally merge them into a canvas.json."""
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
