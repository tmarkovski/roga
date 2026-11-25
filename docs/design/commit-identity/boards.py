# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Commit identity boards for the design canvas "yaga layout options".

Where the window could say who a repository's commits go out as, read from
git config, and whether they're signed (issue 115). Today's window, three
options (A, B and C) for the branch row and the message box, every option
moment by moment in both appearances, the popover that changes the identity
with `git config`, a board to try it, the sidebar and Settings › Git, and how
history and the commit panel show signed commits. After decision 103 was
built, the page starts with G, which puts a person icon at the end of the
tabs row, for the repository and every worktree and agent in it, keeps the
box's line all the time with the same icon, and marks the sidebar's
exceptions with it. D, which showed the line with initials and nothing in
the header, and where else the initials could go, the end of the tabs row
(E) or beside the number of commits (F), come after it.

    uv run docs/design/commit-identity/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Every part is drawn at its size in points: the title row and the branch row
are 44 points tall, a row of history 28, and the message box is sized the way
CommitBox.swift sizes it, as built after decision 98, without the canvas's
card. The middle column is 680 points wide in the default window, and the
commit panel 320. The Settings board borrows the window and rows of
`docs/design/agent-settings/boards.py`, so it stays one family with the
other Settings pages.
"""

from __future__ import annotations

import html
import importlib.util
import json
import re
import sys
from dataclasses import dataclass, replace
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
LUCIDE = HERE.parent / "icons" / "lucide"
PAGE_ID = "identity"
PAGE_NAME = "Commit identity"

_spec = importlib.util.spec_from_file_location("agent_settings_boards", HERE.parent / "agent-settings" / "boards.py")
asb = importlib.util.module_from_spec(_spec)
sys.modules["agent_settings_boards"] = asb
_spec.loader.exec_module(asb)
st = asb.s   # the settings boards, which the agent settings boards borrow from


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

WIDE = 680         # the middle column in the default window
PANEL = 320        # the commit panel's default width (`commitPanelWidth`)
ROW_H = 28         # a row of history
MID_H = 268        # a middle column on the option boards
PANEL_H = 330      # a commit panel on the option boards
LINE = 17          # one line of the message
SHORTEST = 48      # CommitBox.shortest: the least room the text gets
BOX_ROW = 38       # CommitBox.rowHeight
CELL_W = WIDE      # a cell on the states boards


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--surface:#fff;--title:#f3f3f2;--line:#e2e2e2;--hair:#eaeae7;--tx:#1f1f1e;--tx2:#6b6b66;--tx3:#a3a39e;--hov:rgba(0,0,0,.075);--bhov:rgba(0,0,0,.10);--tabon:#fff;--tabedge:#dedede;--tabsh:rgba(0,0,0,.12);--cnt:#e57a00;--act:#c94402;--actf:#c94402;--warn:#9a5200;--warnb:#fbf0e1;--red:#cd1755;--ok:#3f7d00;--track:#d6d6d3;--sheet:#fff;--boxbg:#fafaf9;--card:#f0f0ee;--edgeb:#d6d6d3;--ink:#1a1a18;--onink:#fff;--focus:#2f6de1;--ring:rgba(47,109,225,.18);--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2);--mbg:#f6f6f5;--l1:#db1c61;--cur:#547a02;--oncur:#fff;--edge:#c9c9c4;--tip:#f6f6f6;--tiptx:#1a1a1a;--seg:#ecebe8;--segon:#fff;--add:#4d7000;--mod:#b35c00;--del:#cd1755;--term:#272822;--nav:#f4f3f2;--t1:rgba(0,0,0,.85);--t2:rgba(0,0,0,.5);--sel:rgba(0,0,0,.11);--navedge:#e2e2e2;--idp:#6b3fc9;--idpb:rgba(107,63,201,.13);--idw:#0b7489;--idwb:rgba(11,116,137,.13);--ido:#4d7000;--idob:rgba(77,112,0,.14)}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--surface:#222;--title:#1b1b1b;--line:#393939;--hair:#393938;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--hov:rgba(255,255,255,.075);--bhov:rgba(255,255,255,.15);--tabon:#3b3b3b;--tabedge:#4d4d4d;--tabsh:rgba(0,0,0,.4);--cnt:#ff9f0a;--act:#f0813f;--actf:#c94402;--warn:#f0a54a;--warnb:#3a2c19;--red:#fc5884;--ok:#a6e22e;--track:#4a4a47;--sheet:#2a2a29;--boxbg:#252524;--card:#363635;--edgeb:#4a4a47;--ink:#ececea;--onink:#16150e;--focus:#4c8dff;--ring:rgba(76,141,255,.25);--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16);--mbg:#2e2e2d;--l1:#ff3478;--cur:#a6e22e;--oncur:#272822;--edge:#62625c;--tip:#3a3a39;--tiptx:#f0f0f0;--seg:#2c2c2b;--segon:#4a4a47;--add:#a6e22e;--mod:#ff9f0a;--del:#fc5884;--term:#1a1b17;--nav:#191918;--t1:rgba(255,255,255,.85);--t2:rgba(255,255,255,.55);--sel:rgba(255,255,255,.11);--navedge:#393939;--idp:#c3a6ff;--idpb:rgba(174,129,255,.2);--idw:#7fdcef;--idwb:rgba(102,217,239,.17);--ido:#b8e86a;--idob:rgba(166,226,46,.16)}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.stage{position:relative;flex:none}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:14px;height:14px;stroke-width:2}
.ic.t{width:13px;height:13px;stroke-width:2}
.ic.xs{width:11px;height:11px;stroke-width:2.4}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}
.sp{flex:1 1 0;min-width:0}
.gap{flex:1 1 0;min-width:0}
.off{color:var(--tx3)}

.mid{position:relative;flex:none;background:var(--surface);color:var(--tx);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);overflow:visible;display:flex;flex-direction:column;font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
.mid>.clip{display:flex;flex-direction:column;flex:1;min-height:0;overflow:hidden;border-radius:10px}
.trow{height:44px;flex:none;display:flex;align-items:center;gap:4px;padding:0 8px;background:var(--title);border-bottom:1px solid var(--line);white-space:nowrap;min-width:0;border-radius:10px 10px 0 0}
.tab{position:relative;height:32px;display:flex;align-items:center;gap:6px;padding:0 4px 0 9px;border-radius:8px;flex:0 1 auto;min-width:56px;color:var(--tx)}
.tab.on{background:var(--tabon);box-shadow:0 0 0 1px var(--tabedge),0 0 4px var(--tabsh)}
.tab .ic{color:var(--tx2)}
.tab .nm{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tab .fo{color:var(--tx2)}
.tab .bd{width:24px;flex:none;text-align:center;font-size:12.5px;color:var(--tx2);font-variant-numeric:tabular-nums}
.tab .bd.org{color:var(--cnt)}
.tsep{width:1px;height:16px;background:var(--line);flex:none;margin:0 2px}
.tplus{width:28px;height:28px;display:grid;place-items:center;color:var(--tx2);flex:none}
.brow{height:44px;flex:none;display:flex;align-items:center;padding:0 6px;background:var(--surface);border-bottom:1px solid var(--line);white-space:nowrap;min-width:0;border-radius:inherit}
.brow.alone{border:0;border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);color:var(--tx);position:relative}
.chip{position:relative;height:32px;display:flex;align-items:center;gap:5px;padding:0 7px 0 5px;border:0;border-radius:7px;background:none;color:var(--tx);font:inherit;flex:none}
.chip.hov{background:var(--bhov)}
.chip .ic{color:var(--tx2)}
.cnt{height:28px;display:flex;align-items:center;gap:3px;padding:0 6px;border-radius:7px;color:var(--act);flex:none;font-variant-numeric:tabular-nums}
.rg{display:flex;align-items:center;gap:6px;flex:none;margin-left:12px}
.ib{position:relative;width:32px;height:32px;display:grid;place-items:center;border:0;border-radius:8px;background:none;color:var(--tx2);padding:0;flex:none;font:inherit}
.ib.hov,.idw.hov,.idl.hov{background:var(--bhov)}
.vs{width:1px;height:18px;background:var(--line);margin:0 6px;flex:none}
.nc{color:var(--tx2);font-size:12.5px}
.hist{position:relative;flex:1;min-height:0;overflow:hidden;padding-top:4px}
.lane{position:absolute;left:17px;width:2px;background:var(--l1);top:18px;bottom:0}
.hr{position:relative;height:28px;display:flex;align-items:center;gap:8px;padding:0 12px 0 36px;white-space:nowrap;min-width:0}
.hr .dot{position:absolute;left:12px;top:9px;width:12px;height:12px;border-radius:50%;background:var(--l1);box-shadow:0 0 0 2px var(--surface)}
.hr .msg{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.hr .au{margin-left:auto;color:var(--tx2);font-size:12px;flex:none}
.hr .sg{width:14px;flex:none;color:var(--tx2);display:grid;place-items:center}
.hr .hs{color:var(--tx2);font:11.5px ui-monospace,"SF Mono",Menlo,monospace;flex:none;width:54px;text-align:right}
.hr.on{background:var(--sel)}
.bdg{display:inline-block;font-size:11.5px;line-height:16px;padding:0 6px;border-radius:5px;border:1px solid var(--edge);color:var(--tx);margin-right:6px}
.bdg.cur{background:var(--cur);border-color:var(--cur);color:var(--oncur)}

.av{position:relative;width:22px;height:22px;border-radius:50%;display:grid;place-items:center;font-size:9.5px;font-weight:600;letter-spacing:.02em;line-height:1;flex:none}
.av.sm{width:18px;height:18px;font-size:8px}
.av.p{background:var(--idpb);color:var(--idp)}
.av.w{background:var(--idwb);color:var(--idw)}
.av.o{background:var(--idob);color:var(--ido)}
.av.n{background:var(--card);color:var(--tx2)}
.av .bg{position:absolute;right:-5px;bottom:-4px;width:14px;height:14px;border-radius:50%;background:var(--surface);display:grid;place-items:center}
.av .bg svg{width:10px;height:10px;fill:none;stroke:var(--tx);stroke-width:2.4;stroke-linecap:round;stroke-linejoin:round;display:block}
.av .bg.warn svg{stroke:var(--warn)}
.box .av .bg{background:var(--boxbg)}
.sbw .av .bg{background:var(--nav)}
.idw{height:28px;display:flex;align-items:center;gap:5px;padding:0 8px;border:0;border-radius:7px;background:none;color:var(--tx2);font:inherit;font-size:12.5px;white-space:nowrap;min-width:0;max-width:230px;flex:0 1 auto}
.idw .e{min-width:0;overflow:hidden;text-overflow:ellipsis}
.idw.warn{color:var(--warn)}
.rel{position:relative;display:flex;align-items:center;flex:none}
.tip{position:absolute;z-index:6;width:max-content;max-width:330px;padding:5px 9px;border-radius:6px;background:var(--tip);color:var(--tiptx);font-size:11.5px;line-height:15px;white-space:pre-line;text-align:left;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 6px 16px rgba(0,0,0,.16)}
.ptr{position:absolute;z-index:7;width:12px;height:18px}

.cpanel{position:relative;flex:none;background:var(--sheet);color:var(--tx);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);display:flex;flex-direction:column}
.cpanel>.clip{display:flex;flex-direction:column;flex:1;min-height:0;overflow:hidden;border-radius:10px}
.files{display:flex;flex-direction:column;justify-content:flex-end;overflow:hidden;flex:1 1 0;min-height:0}
.gh{display:flex;align-items:center;height:36px;padding:10px 14px 6px;font-size:12px;font-weight:500;flex:none}
.fr{display:flex;align-items:center;gap:8px;height:24px;margin:0 6px;padding:0 8px;border-radius:6px;font-size:12.5px;white-space:nowrap;flex:none}
.fl{width:12px;flex:none;font:500 11.5px ui-monospace,"SF Mono",Menlo,monospace;text-align:center}
.lM{color:var(--mod)}.lA{color:var(--add)}
.fn{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.ff{flex:0 1000 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;color:var(--tx2);font-size:12px}
.num{margin-left:auto;display:flex;gap:6px;font-size:12px;font-variant-numeric:tabular-nums;flex:none}
.plus{color:var(--add)}.minus{color:var(--del)}
.box{position:relative;flex:none;background:var(--boxbg);box-shadow:inset 0 1px 0 var(--line);display:flex;flex-direction:column;color:var(--tx)}
.box.alone{border-radius:10px;box-shadow:inset 0 1px 0 var(--line),0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06)}
.btop{display:flex;flex-direction:column;gap:6px;padding:8px 8px 0;flex:none}
.btx{padding:0 14px;overflow:hidden;flex:none}
.ln{height:17px;line-height:17px;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ln.s{font-weight:600;display:flex;align-items:baseline;gap:8px}
.ln.s .st{flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.ln.s .sc{flex:none;font-size:11px;font-weight:400;color:var(--tx2);font-variant-numeric:tabular-nums}
.ln.ph{color:var(--tx2)}
.brw{display:flex;align-items:center;gap:6px;height:38px;padding:0 8px;margin-bottom:2px;flex:none}
.gs{position:relative;display:inline-flex;align-items:stretch;flex:0 1 auto;min-width:0;font-weight:500;color:var(--tx);height:26px;border-radius:7px;background:var(--card);font-size:12px}
.gs::after{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;box-shadow:inset 0 0 0 1px var(--edgeb)}
.gs button{border:0;background:none;color:inherit;font:inherit;display:inline-flex;align-items:center;padding:0 8px;white-space:nowrap;border-radius:inherit;min-width:0}
.gs .chv{padding:0 5px;color:var(--tx2);border-left:1px solid var(--line);border-radius:0 7px 7px 0;flex:none}
.cb{display:inline-flex;align-items:stretch;height:26px;border-radius:7px;background:var(--actf);color:#fff;font-size:12.5px;font-weight:500;flex:none;overflow:hidden}
.cb button{border:0;background:none;color:inherit;font:inherit;padding:0 10px;white-space:nowrap;display:inline-flex;align-items:center}
.cb .chv{padding:0 6px;border-left:1px solid rgba(255,255,255,.32)}
.cb.hov .m{background:rgba(0,0,0,.12)}
.avb{position:relative;width:26px;height:26px;border:0;border-radius:7px;background:none;display:grid;place-items:center;padding:0;flex:none}
.idl{display:flex;align-items:center;gap:6px;height:22px;padding:0 6px;border:0;border-radius:6px;background:none;color:var(--tx2);font:inherit;font-size:12px;white-space:nowrap;min-width:0;width:100%;text-align:left;flex:none}
.idl .e{min-width:0;overflow:hidden;text-overflow:ellipsis}
.idl b{font-weight:500;color:var(--tx)}
.idl .r{margin-left:auto;display:flex;align-items:center;gap:4px;flex:none;padding-left:8px}
.idl.q b{color:inherit}
.av .ic{width:13px;height:13px;stroke-width:2}
.av.sm .ic{width:11px;height:11px;stroke-width:2.2}
.av.x{background:var(--warnb);color:var(--warn)}
.trow .av .bg{background:var(--title)}
.hue-p{color:var(--idp);display:flex}.hue-w{color:var(--idw);display:flex}.hue-o{color:var(--ido);display:flex}
.gp{position:relative;width:22px;height:22px;display:grid;place-items:center;flex:none}
.gp>.cut{width:22px;height:22px;display:grid;place-items:center;-webkit-mask:radial-gradient(circle at calc(100% - 2px) calc(100% - 3px),transparent 7px,#000 7.5px);mask:radial-gradient(circle at calc(100% - 2px) calc(100% - 3px),transparent 7px,#000 7.5px)}
.gp>.bg{position:absolute;right:-5px;bottom:-4px;width:14px;height:14px;display:grid;place-items:center}
.gp>.bg svg{width:10px;height:10px;fill:none;stroke:currentColor;stroke-width:2.4;stroke-linecap:round;stroke-linejoin:round;display:block}
.gp.p{color:var(--idp)}.gp.w{color:var(--idw)}.gp.o{color:var(--ido)}.gp.x{color:var(--warn)}
.tint{display:grid;place-items:center}.tint.p{color:var(--idp)}.tint.w{color:var(--idw)}.tint.o{color:var(--ido)}.tint.x{color:var(--warn)}
.piece{border:0;border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14);-webkit-mask-image:linear-gradient(90deg,transparent 0,#000 56px);mask-image:linear-gradient(90deg,transparent 0,#000 56px)}
.panes{display:flex;gap:24px;align-items:flex-start}
.wn{border-radius:7px;background:var(--warnb);padding:6px 8px 7px;font-size:12px;overflow:hidden;flex:none}
.wn b{display:flex;align-items:center;gap:5px;height:16px;line-height:16px;color:var(--warn);font-weight:600}
.wn p{margin:4px 0 0;line-height:16px;color:var(--tx2)}
.wn .na{display:flex;gap:14px;margin-top:4px;height:16px;line-height:16px}
.wn .na button{border:0;background:none;padding:0;color:var(--act);font:inherit;font-weight:500}
.rul{position:absolute;width:64px;border-left:1px solid var(--wtx2)}
.rul::before,.rul::after{content:"";position:absolute;left:-4px;width:7px;height:1px;background:var(--wtx2)}
.rul::before{top:0}.rul::after{bottom:0}
.rv{position:absolute;left:9px;top:50%;transform:translateY(-50%);font-size:12.5px;font-weight:500;line-height:1.3;color:var(--wtx);font-variant-numeric:tabular-nums;white-space:nowrap}

.menu{position:absolute;z-index:10;width:300px;padding:5px;background:var(--mbg);color:var(--tx);border-radius:10px;box-shadow:var(--msh);font-size:13px;display:flex;flex-direction:column;text-align:left;white-space:normal}
.mh{padding:3px 10px 4px 26px;font-size:12px;line-height:16px;color:var(--tx2);flex:none}
.mid2{display:flex;align-items:center;gap:6px;width:100%;padding:3px 10px 3px 4px;border:0;border-radius:5px;background:none;color:var(--tx2);font:inherit;font-size:12px;line-height:16px;text-align:left;flex:none}
.mid2 .ck{width:22px;flex:none;display:grid;place-items:center}
.mid2 .e{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mid2.hl{background:var(--focus);color:#fff}
.mi{display:flex;align-items:center;width:100%;height:22px;padding:0 10px 0 4px;border:0;border-radius:5px;background:none;color:inherit;font:inherit;white-space:nowrap;text-align:left;flex:none}
.mi .ck{width:22px;flex:none;display:grid;place-items:center}
.mi .tr{margin-left:auto;padding-left:18px;color:var(--tx2);font-size:12.5px}
.mi.hl{background:var(--focus);color:#fff}
.mi.hl .tr{color:rgba(255,255,255,.85)}
.ms{height:1px;background:var(--hair);margin:5px 10px;flex:none}

.pop{position:relative;width:344px;background:var(--sheet);color:var(--tx);border-radius:12px;box-shadow:var(--msh);display:flex;flex-direction:column;text-align:left;font-size:13px;white-space:normal;flex:none}
.pop .arr{position:absolute;top:-6px;width:12px;height:12px;background:var(--sheet);transform:rotate(45deg);box-shadow:-.5px -.5px 0 0 rgba(0,0,0,.14)}
.pop .arr.dn{top:auto;bottom:-6px;box-shadow:.5px .5px 0 0 rgba(0,0,0,.14)}
.pin{position:relative;display:flex;flex-direction:column;border-radius:12px;overflow:hidden}
.phd{display:flex;flex-direction:column;gap:1px;padding:13px 16px 2px}
.phd b{font-size:13px;font-weight:600}
.phd span{font-size:12px;color:var(--tx2)}
.pfd{position:relative;display:flex;flex-direction:column;gap:4px;padding:10px 16px 0}
.pl{display:flex;align-items:baseline;gap:8px;font-size:12px;min-width:0}
.pl label{font-weight:500;color:var(--tx);flex:none}
.pl .o{margin-left:auto;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.pl .o.new{color:var(--act)}
.pl .ug{border:0;background:none;padding:0;color:var(--act);font:inherit;font-weight:500;flex:none}
.tf{height:28px;width:100%;border:1px solid var(--edgeb);border-radius:7px;padding:0 9px;font:inherit;font-size:13px;background:var(--sheet);color:var(--tx);outline:none;display:block}
.tf.mono{font:12px ui-monospace,"SF Mono",Menlo,monospace}
.tf.foc,.tf:focus{border-color:var(--focus);box-shadow:0 0 0 3px var(--ring)}
.tf::placeholder{color:var(--tx3)}
.psw{display:flex;align-items:center;gap:8px;padding:14px 16px 0}
.psw .l{flex:1;font-size:13px;font-weight:500}
.psw .l i{display:block;font-style:normal;font-weight:400;font-size:12px;color:var(--tx2)}
.tg{width:30px;height:18px;border-radius:9px;border:0;background:var(--edgeb);position:relative;padding:0;flex:none}
.tg i{position:absolute;left:2px;top:2px;width:14px;height:14px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25)}
.tg.on{background:var(--ink)}
.tg.on i{left:14px;background:var(--sheet)}
.seg{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:2px;padding:2px;background:var(--card);border-radius:8px}
.seg button{height:22px;padding:0 8px;border:0;border-radius:6px;background:none;color:var(--tx2);font:inherit;font-size:12px;font-weight:500;white-space:nowrap}
.seg button.on{background:var(--sheet);color:var(--tx);box-shadow:0 0 0 .5px var(--edgeb),0 1px 2px rgba(0,0,0,.08)}
.pnote{padding:6px 16px 0;font-size:12px;line-height:16px;color:var(--tx2)}
.pnote.warn{color:var(--warn)}
.pbtn{display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:14px 16px 12px}
.b{height:26px;padding:0 12px;border-radius:7px;border:0;font:inherit;font-size:12.5px;font-weight:500;white-space:nowrap}
.b.sec{background:var(--card);color:var(--tx)}
.b.pri{background:var(--ink);color:var(--onink)}
.b.pri:disabled{background:var(--card);color:var(--tx3)}
.cmd{position:relative;background:var(--term);padding:9px 38px 10px 14px;color:#f8f8f2;font:11.5px/1.6 ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}
.cmd .cp{position:absolute;top:6px;right:8px;width:24px;height:24px;border:0;background:none;color:#a59f85;display:grid;place-items:center;padding:0;border-radius:6px}
.cl{padding-left:1.2em;text-indent:-1.2em;white-space:pre-wrap;overflow-wrap:anywhere}
.cl .tk::after{content:" "}
.cl.cm{padding-left:0;text-indent:0;color:#a59f85}
.t-p{color:#a59f85}.t-g{color:#f8f8f2}.t-f{color:#e6db74}.t-r{color:#66d9ef}.t-s{color:#ae81ff}
.sug{position:absolute;z-index:5;left:16px;right:16px;top:168px;padding:5px;background:var(--mbg);border-radius:9px;box-shadow:var(--msh);display:flex;flex-direction:column;gap:1px}
.sg2{display:flex;flex-direction:column;gap:0;padding:4px 8px;border-radius:5px;font-size:13px;line-height:17px}
.sg2 i{font-style:normal;font-size:11.5px;line-height:15px;color:var(--tx2)}
.sg2.hl{background:var(--focus);color:#fff}
.sg2.hl i{color:rgba(255,255,255,.85)}

.sbw{position:relative;width:312px;flex:none;background:var(--nav);color:var(--t1);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14);display:flex;flex-direction:column;overflow:visible;font-size:14px}
.sbw .tl{height:52px;flex:none;display:flex;align-items:center;gap:8px;padding-left:20px}
.sbw .tl i{width:12px;height:12px;border-radius:50%;display:block}
.tr2{height:32px;flex:none;display:flex;align-items:center;gap:10px;margin:0 8px 2px;padding:0 10px;border-radius:8px}
.tr2 .ic{color:var(--t2)}
.nsep{height:1px;background:var(--navedge);margin:6px 0 8px;flex:none}
.shd{height:32px;flex:none;display:flex;align-items:center;padding:0 12px 0 18px}
.shd b{font-size:14px;font-weight:600;flex:1}
.shd .ic{color:var(--t2)}
.glb{height:30px;flex:none;display:flex;align-items:flex-end;gap:6px;padding:0 18px 6px;font-size:12px;color:var(--t2);white-space:nowrap;overflow:hidden}
.glb .e{opacity:.8;min-width:0;overflow:hidden;text-overflow:ellipsis}
.sr{position:relative;height:32px;flex:none;display:flex;align-items:flex-start;margin:0 8px 2px;padding:0 4px 0 10px;border-radius:8px;white-space:nowrap}
.sr.two{height:52px}
.sr.on{background:var(--sel)}
.sr .tx{flex:1 1 0;min-width:0;display:flex;flex-direction:column;padding-top:7px}
.sr .l1{display:flex;align-items:center;gap:3px;height:18px;line-height:18px;min-width:0}
.sr .nm{min-width:0;overflow:hidden;text-overflow:ellipsis;flex:0 1 auto}
.sr .dt{font-size:13px;color:var(--t2);padding-left:4px;min-width:0;overflow:hidden;text-overflow:ellipsis}
.sr .l2{display:flex;align-items:center;gap:5px;height:18px;margin-top:2px;line-height:16px;font-size:13px;color:var(--t2);min-width:0}
.sr .l2.warn{color:var(--warn)}
.sr .trail{flex:none;display:flex;align-items:center;gap:6px;height:24px;margin-top:4px;padding-left:6px}
.sr .ct{font-size:13px;color:var(--cnt);font-variant-numeric:tabular-nums}
.sr .mkp{width:24px;height:24px;flex:none;display:grid;place-items:center}

.cph{height:44px;flex:none;display:flex;align-items:center;gap:8px;padding:0 8px 0 14px;border-bottom:1px solid var(--line);font-weight:600;white-space:nowrap}
.cph .hs2{font:500 12px ui-monospace,"SF Mono",Menlo,monospace;color:var(--tx2)}
.cpb{display:flex;flex-direction:column;gap:8px;padding:12px 14px}
.cpb .sj{font-weight:600}
.ppl{display:flex;flex-direction:column;gap:2px;font-size:12px;line-height:16px}
.ppl .lb{color:var(--tx2);display:inline-block;width:62px}
.ppl .g{color:var(--tx2)}
.sgl{display:flex;align-items:flex-start;gap:0;font-size:12px;line-height:16px}
.sgl .lb{color:var(--tx2);width:62px;flex:none}
.sgl .w{display:flex;flex-direction:column;gap:1px;min-width:0}
.sgl .h{display:flex;align-items:center;gap:5px}
.sgl .h svg{width:13px;height:13px;flex:none}
.sgl .g{color:var(--tx2)}
.sgl.good .h svg{color:var(--ok)}
.sgl.bad .h{color:var(--red)}
.spin{width:12px;height:12px;border-radius:50%;border:1.5px solid var(--track);border-top-color:var(--tx2);flex:none}
.lk{color:var(--act);font:500 12px ui-monospace,"SF Mono",Menlo,monospace}

.try{position:relative;display:flex;flex-direction:column;gap:18px;padding:26px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.try button{cursor:pointer}
.bar{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center}
.grp{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--wtx2)}
.sega{display:flex;background:var(--seg);border-radius:8px;padding:2px;gap:2px}
.sga{border:0;background:none;font:inherit;font-size:12.5px;color:var(--wtx2);height:26px;padding:0 10px;border-radius:6px}
.sga.on{background:var(--segon);color:var(--wtx);font-weight:500;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.tmain{display:flex;gap:40px;align-items:flex-start}
.tleft{display:flex;flex-direction:column;gap:16px;flex:none}
.meta{font-size:12.5px;color:var(--wtx2);max-width:344px}
.log{display:flex;flex-direction:column;gap:6px;margin:0;padding:0;list-style:none;max-width:680px}
.log li{font:12px/1.4 ui-monospace,"SF Mono",Menlo,monospace;color:var(--wtx2)}
.log li.new{color:var(--wtx)}
"""


# ---------------------------------------------------------------- icons


def _ic(paths: str, cls: str = "ic") -> str:
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{paths}</svg>'


def lucide(name: str) -> str:
    """The inside of one of the Lucide icons the repository keeps, with every
    element closed the long way, as the canvas's files need."""
    text = (LUCIDE / f"{name}.svg").read_text()
    inner = re.search(r"<svg[^>]*>(.*)</svg>", text, re.S).group(1)
    inner = re.sub(r"<!--.*?-->", "", inner, flags=re.S)
    inner = re.sub(r"<(\w+)([^<>]*?)\s*/>", r"<\1\2></\1>", inner)
    return re.sub(r"\s+", " ", inner).strip()


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
P_CHECK = '<path d="M20 6 9 17l-5-5"></path>'
P_COPY = '<rect x="9" y="9" width="13" height="13" rx="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>'
P_FILTER = '<path d="M3 6h18"></path><path d="M7 12h10"></path><path d="M10 18h4"></path>'
# The shields are drawn after Lucide's `shield`, `shield-check`, `shield-alert`,
# `shield-question` and `shield-off`, which docs/design/icons/lucide doesn't
# keep yet. Building the feature would copy them there (decision 24).
P_SHIELD = ('<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 '
            '6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"></path>')
P_SH_CHECK = P_SHIELD + '<path d="m9 12 2 2 4-4"></path>'
P_SH_ALERT = P_SHIELD + '<path d="M12 8v4"></path><path d="M12 16h.01"></path>'
P_SH_Q = P_SHIELD + '<path d="M9.1 9a3 3 0 0 1 5.82 1c0 2-3 3-3 3"></path><path d="M12 17h.01"></path>'
P_SH_OFF = ('<path d="m2 2 20 20"></path><path d="M5 5a1 1 0 0 0-1 1v7c0 5 3.5 7.5 7.67 8.94a1 1 0 0 0 .67.01c2.35-.82 '
            '4.48-1.97 5.9-3.71"></path><path d="M9.309 3.652A12.252 12.252 0 0 0 11.24 2.28a1.17 1.17 0 0 1 1.52 0C14.51 '
            '3.81 17 5 19 5a1 1 0 0 1 1 1v7a9.784 9.784 0 0 1-.08 1.264"></path>')

CHEV = _ic(P_CHEV, "ic xs")
BRANCH = _ic(P_BRANCH, "ic s")
NEWBRANCH = _ic(P_NEWBRANCH)
FETCH = _ic(P_FETCH)
PUSH = _ic(P_PUSH, "ic s")
ORDER = _ic(P_ORDER)
REPO = _ic(P_REPO, "ic s")
WORKTREE = _ic(P_WORKTREE, "ic s")
PLUS = _ic(P_PLUS, "ic s")
TRI = _ic(P_TRI, "ic t")
CHECK = _ic(P_CHECK, "ic xs")
COPY = _ic(P_COPY, "ic t")
FILTER = _ic(P_FILTER)
USER = _ic(lucide("user"), "ic t")
USER16 = _ic(lucide("user"))
SETTINGS = _ic(lucide("settings"))
FOLDER_PLUS = _ic(lucide("folder-plus"))
SHIELD = _ic(P_SHIELD, "ic t")
SH_CHECK = _ic(P_SH_CHECK, "ic t")
SH_ALERT = _ic(P_SH_ALERT, "ic t")
SH_Q = _ic(P_SH_Q, "ic t")
SH_OFF = _ic(P_SH_OFF, "ic t")


def badge(paths: str, warn: bool = False) -> str:
    return f'<span class="bg{" warn" if warn else ""}"><svg viewBox="0 0 24 24" aria-hidden="true">{paths}</svg></span>'


POINTER = ('<svg class="ptr" style="left:{x}px;top:{y}px" viewBox="0 0 12 18" aria-hidden="true">'
           '<path d="M1 1v14l3.6-3.4 2.6 5.6 2.2-1-2.6-5.4H12z" fill="#000" stroke="#fff" stroke-width="1"></path></svg>')


def pointer(x: int, y: int) -> str:
    return POINTER.replace("{x}", str(x)).replace("{y}", str(y))


# ---------------------------------------------------------------- what's drawn


GLOBAL_FILE = "~/.gitconfig"
WORK_FILE = "~/.gitconfig-work"


@dataclass(frozen=True)
class Ident:
    """Who commits in a repository go out as, and how they're signed, as one
    `git config --show-scope --show-origin` read would give them."""
    name: str
    email: str
    origin: str = "global"    # global, include or local
    sign: str = "off"         # off, ssh or openpgp
    key: str = ""
    hue: str = "p"            # the tint the email gets: p, w or o
    problem: str = ""         # "", noemail or nokey

    @property
    def initials(self) -> str:
        return "".join(part[0] for part in self.name.split()[:2]).upper() or "?"

    @property
    def signed(self) -> bool:
        return self.sign != "off" and not self.problem

    @property
    def own(self) -> bool:
        return self.origin != "global"

    @property
    def domain(self) -> str:
        return self.email.partition("@")[2]

    @property
    def sign_words(self) -> str:
        return {"ssh": "SSH", "openpgp": "OpenPGP"}.get(self.sign, "")

    @property
    def from_words(self) -> str:
        return {
            "global": f"From {GLOBAL_FILE}",
            "include": f"From {WORK_FILE}, which {GLOBAL_FILE} includes for ~/work/",
            "local": "This repository's own, in .git/config",
        }[self.origin]

    @property
    def tip(self) -> str:
        if self.problem == "noemail":
            return (f"{self.name}, with no email\n{self.from_words}\n"
                    "git would refuse to commit, or make an email up from your login and this Mac's name.")
        who = f"{self.name} <{self.email}>"
        if self.problem == "nokey":
            return f"{who}\n{self.from_words}\nSigning is on, but no key is set, so a commit would stop at signing."
        how = f"Signed with {self.sign_words} · {self.key}" if self.signed else "Not signed"
        return f"{who}\n{self.from_words}\n{how}"


GLOBAL = Ident("Sam Rivera", "sam@rivera.dev", sign="ssh", key="~/.ssh/id_ed25519.pub")
UNSIGNED = replace(GLOBAL, sign="off", key="")
WORK = Ident("Sam Rivera", "sam.rivera@acme.com", origin="include", sign="ssh", key="~/.ssh/acme_ed25519.pub", hue="w")
OWN = Ident("Sam Rivera", "sam@oss.example", origin="local", hue="o")
NO_EMAIL = Ident("Sam Rivera", "", hue="n", problem="noemail")
NO_KEY = Ident("Sam Rivera", "sam@rivera.dev", sign="ssh", problem="nokey")

MOMENTS: list[tuple[str, str, Ident | None]] = [
    ("The global identity, signed", f"{GLOBAL_FILE} signs with an SSH key", GLOBAL),
    ("The global identity, not signed", "How most people commit", UNSIGNED),
    ("From a file included for ~/work/", f"includeIf in {GLOBAL_FILE} reads {WORK_FILE}", WORK),
    ("The repository's own", "user.email in .git/config", OWN),
    ("No email anywhere", "git refuses, or makes one up", NO_EMAIL),
    ("Signing on, with no key", "the commit would stop at signing", NO_KEY),
    ("Not read yet", "the first moments after the repository opens", None),
]

COMMITS = [
    (["cur:agent/fix-login"], "Add tests for the login lockout", "SR", "48ba644", True),
    ([], "Lock the login after five failed attempts", "SR", "5405371", True),
    ([], "Show the lockout message on the login screen", "Claude", "2f1c9d0", False),
    (["main"], "Update the changelog", "AK", "bb3b6b6", True),
    ([], "Retry webhooks when the endpoint times out", "AK", "7a03e5c", True),
    ([], "Add parser tests", "JL", "9c41e02", False),
    ([], "Move the rate limiter into its own package", "JL", "e18f7d3", False),
    ([], "Pin the payment client to 4.2", "AK", "1b5a0c9", True),
    ([], "Add a health check for the queue", "JL", "3d9e2a1", False),
    ([], "Index the new product fields", "AK", "c07b4f8", True),
]

UNSTAGED = [("M", "AuthClient.swift", "Sources/Auth", 12, 3), ("A", "RetryPolicy.swift", "Sources/Auth", 31, 0),
            ("M", "Info.plist", "App", 1, 1), ("A", "LoginViewTests.swift", "Tests/Login", 48, 0)]
STAGED = [("M", "LoginView.swift", "Sources/Login", 9, 4), ("M", "LoginModel.swift", "Sources/Login", 6, 2)]
MESSAGE = ["Reset the retry count after a sign-in", "", "The count only went up, so a third", "mistyped password locked the button."]


# ---------------------------------------------------------------- the identity, wherever it shows


def avatar(i: Ident, cls: str = "", *, gray: bool = False, marks: bool = True) -> str:
    """The initials in a circle tinted by the email, with a shield when
    commits are signed and a triangle when committing would go wrong. D and
    the places after it draw the global identity's circle in gray."""
    if not marks:
        mark = ""
    elif i.problem:
        mark = badge(P_TRI, warn=True)
    elif i.signed:
        mark = badge(P_SHIELD)
    else:
        mark = ""
    extra = f" {cls}" if cls else ""
    hue = "n" if gray else i.hue
    return f'<span class="av {hue}{extra}" aria-hidden="true">{esc(i.initials)}{mark}</span>'


def quiet(i: Ident) -> bool:
    """Whether D draws the identity in gray: the global one, nothing wrong."""
    return not i.own and not i.problem


def sign_icon(i: Ident) -> str:
    if i.problem == "nokey":
        return f'<span style="color:var(--warn);display:flex">{SH_ALERT}</span>'
    if i.signed:
        return SHIELD
    return f'<span class="off" style="display:flex">{SH_OFF}</span>'


def row_identity(i: Ident | None, option: str, *, hover: bool = False) -> str:
    """What the branch row shows before Fetch."""
    if i is None or option not in ("A", "B", "C"):
        return ""
    hov = " hov" if hover else ""
    label = f'aria-label="Commit identity: {esc(i.tip.splitlines()[0])}"'
    if option == "A":
        return f'<button class="ib{hov}" type="button" {label}>{avatar(i)}</button>'
    if i.problem == "noemail":
        return f'<button class="idw warn{hov}" type="button" {label}>{TRI}<span class="e">No email</span></button>'
    if option == "C" and not i.own and not i.problem:
        return ""
    return f'<button class="idw{hov}" type="button" {label}><span class="e">{esc(i.email)}</span>{sign_icon(i)}</button>'


def box_line(i: Ident, *, hover: bool = False) -> str:
    """B's line at the top of the box, and C's while the identity isn't the
    global one."""
    hov = " hov" if hover else ""
    if i.signed:
        right = f'<span class="r">{SHIELD}Signed</span>'
    else:
        right = f'<span class="r off">{SH_OFF}Not signed</span>'
    whose = f'<b>{esc(i.name)}</b> &lt;{esc(i.email)}&gt;'
    return f'<button class="idl{hov}" type="button">{USER}<span class="e">{whose}</span>{right}</button>'


# How wide "Sam Rivera <email>" is on the line, at 12 points.
WHO_WIDTH = {"sam@rivera.dev": 173, "sam.rivera@acme.com": 211, "sam@oss.example": 187}


def box_line_d(i: Ident, *, hover: bool = False, width: int = PANEL) -> str:
    """D's line, always at the top of the box: the initials, the name and the
    email, then whether commits are signed. It's gray with a gray circle for
    the global identity, and anyone else gets the email's tint and the name
    in ink. The words for signing go before the email is cut, as built."""
    hov = " hov" if hover else ""
    q = " q" if quiet(i) else ""
    who = f"{i.name} <{i.email}>"
    words = "Signed" if i.signed else "Not signed"
    # The room for the name and the email: the box's 8-point insets, the
    # line's 6, the circle and the gaps on either side of the words, and the
    # shield with its words, as drawn. Each width was measured in a browser.
    room = width - 16 - 12 - 18 - 12 - (64 if i.signed else 87)
    shows_words = WHO_WIDTH.get(i.email, len(who) * 6.7) <= room
    icon = SHIELD if i.signed else SH_OFF
    right = f'<span class="r{"" if i.signed else " off"}">{icon}{words if shows_words else ""}</span>'
    whose = f'<b>{esc(i.name)}</b> &lt;{esc(i.email)}&gt;'
    circle = avatar(i, "sm", gray=quiet(i), marks=False)
    return f'<button class="idl{q}{hov}" type="button">{circle}<span class="e">{whose}</span>{right}</button>'


def header_mark(i: Ident | None, option: str) -> str:
    """E's initials at the end of the tabs row, or F's beside the number of
    commits: for the exceptions only, or always with a "+"."""
    if i is None or option[:1] not in ("E", "F"):
        return ""
    always = option.endswith("+")
    if not always and quiet(i):
        return ""
    return f'<span class="ib" aria-label="Commit identity">{avatar(i, gray=quiet(i))}</span>'


def person(i: Ident) -> str:
    """G's person in the tabs row for anyone but the global identity: the
    row's icon in the email's tint, or in amber when committing would go
    wrong. It has no circle, whose faint fill turns muddy on the button's
    gray under the pointer."""
    hue = "x" if i.problem else i.hue
    return f'<span class="tint {hue}" aria-hidden="true">{USER16}</span>'


def bare_person(i: Ident) -> str:
    """G's person in the sidebar: in the email's tint, as large as the box's
    line draws it."""
    return f'<span class="hue-{i.hue}" aria-hidden="true">{USER}</span>'


def marked(inner: str, i: Ident, hue: str = "") -> str:
    """The person in the tabs row with its mark at the lower right: a
    triangle when committing would go wrong, and otherwise a shield while
    commits are signed. The mark's circle is cut out of the person, as the
    build does, so the button's gray shows through it under the pointer."""
    if i.problem:
        mark = badge(P_TRI, warn=True)
    elif i.signed:
        mark = badge(P_SHIELD)
    else:
        return inner
    cls = f"gp {hue}" if hue else "gp"
    return f'<span class="{cls}"><span class="cut">{inner}</span>{mark}</span>'


def tabs_mark(i: Ident | None, *, hover: bool = False) -> str:
    """G's button at the end of the tabs row: a plain person icon for the
    global identity, like the row's other icon buttons, and the same icon in
    the email's tint for anyone else, with a shield while commits are
    signed. Nothing until git config has answered."""
    if i is None:
        return ""
    hov = " hov" if hover else ""
    if quiet(i):
        inner = marked(USER16, i)
    else:
        inner = marked(person(i), i, "x" if i.problem else i.hue)
    label = f'aria-label="Commit identity: {esc(i.tip.splitlines()[0])}"'
    return f'<button class="ib{hov}" type="button" {label}>{inner}</button>'


def box_line_g(i: Ident, *, hover: bool = False, width: int = PANEL) -> str:
    """G's line, always at the top of the box: the person icon as built, the
    name and the email, then whether commits are signed. It's gray for the
    global identity, and anyone else gets the icon in the email's tint and
    the name in ink."""
    hov = " hov" if hover else ""
    q = " q" if quiet(i) else ""
    who = f"{i.name} <{i.email}>"
    words = "Signed" if i.signed else "Not signed"
    # As box_line_d, with the 13-point icon in place of the 18-point circle.
    room = width - 16 - 12 - 13 - 12 - (64 if i.signed else 87)
    shows_words = WHO_WIDTH.get(i.email, len(who) * 6.7) <= room
    icon = SHIELD if i.signed else SH_OFF
    right = f'<span class="r{"" if i.signed else " off"}">{icon}{words if shows_words else ""}</span>'
    whose = f'<b>{esc(i.name)}</b> &lt;{esc(i.email)}&gt;'
    lead = USER if quiet(i) else f'<span class="hue-{i.hue}">{USER}</span>'
    return f'<button class="idl{q}{hov}" type="button">{lead}<span class="e">{whose}</span>{right}</button>'


def warning(i: Ident) -> tuple[str, int]:
    """The notice at the top of the box, where decision 98 puts what's wrong."""
    if i.problem == "noemail":
        title, text, acts = "No email to commit with", "git would refuse to commit, or make one up from your login and this Mac's name.", ["Set Identity…"]
    else:
        title, text, acts = "Signing is on, but there's no key", "user.signingkey isn't set, so the commit would stop at signing.", ["Set Key…", "Stop Signing"]
    lines = 2
    h = 6 + 16 + 4 + 16 * lines + 4 + 16 + 7
    buttons = "".join(f'<button type="button">{esc(a)}</button>' for a in acts)
    return (f'<div class="wn" style="height:{h}px"><b>{TRI}{esc(title)}</b><p>{esc(text)}</p>'
            f'<div class="na">{buttons}</div></div>', h)


# ---------------------------------------------------------------- the middle column


def tab(icon_html: str, folder: str, name: str, badge_text: str = "", badge_cls: str = "", *, on: bool = False) -> str:
    fo = f'<span class="fo">{esc(folder)}</span>' if folder else ""
    return (f'<span class="tab{" on" if on else ""}">{icon_html}<span class="nm">{fo}{esc(name)}</span>'
            f'<span class="bd {badge_cls}">{esc(badge_text)}</span></span>')


def title_row(i: Ident | None = None, option: str = "", *, hover: bool = False, repo: str = "roga") -> str:
    tabs = [
        tab(REPO, "", repo),
        '<i class="tsep"></i>',
        tab(WORKTREE, "agent/", "fix-login", "3", "org", on=True),
        tab(WORKTREE, "agent/", "add-tests", "4", "org"),
        f'<span class="tplus">{PLUS}</span>',
    ]
    if option == "G" and i is not None:
        tabs += ['<span class="sp"></span>', tabs_mark(i, hover=hover)]
    if option.startswith("E"):
        mark = header_mark(i, option)
        if mark:
            tabs += ['<span class="sp"></span>', mark]
    return f'<div class="trow">{"".join(tabs)}</div>'


def branch_row(i: Ident | None, option: str, *, tip: str = "", menu: str = "", hover: bool = False,
               chip_hover: bool = False, alone: bool = False) -> str:
    ident = row_identity(i, option, hover=hover)
    ident_html = f'<span class="rel">{ident}{tip}</span>' if ident else ""
    chip = (f'<span class="rel"><button class="chip{" hov" if chip_hover else ""}" type="button">{BRANCH}'
            f'<span class="nm">agent/fix-login</span>{CHEV}</button>{menu}</span>')
    cls = "brow alone" if alone else "brow"
    style = f' style="width:{WIDE}px"' if alone else ""
    by_count = header_mark(i, option) if option.startswith("F") else ""
    return (f'<div class="{cls}"{style}>{chip}<span class="cnt">{PUSH}2</span><span class="sp"></span>'
            f'<span class="rg">{ident_html}<span class="ib">{FETCH}</span><span class="ib">{NEWBRANCH}</span>'
            f'<i class="vs"></i>{by_count}<span class="nc">128 commits</span><span class="ib">{ORDER}</span></span></div>')


def history(rows: int = 6, *, marks: bool = False, selected: int = -1, tip: str = "") -> str:
    out = ['<div class="hist"><i class="lane"></i>']
    for n, (badges, msg, au, hs, signed) in enumerate(COMMITS[:rows]):
        b = "".join(f'<span class="bdg{" cur" if x.startswith("cur:") else ""}">{esc(x.removeprefix("cur:"))}</span>' for x in badges)
        mark = ""
        if marks:
            inner = SHIELD if signed else ""
            extra = tip if (signed and n == 1 and tip) else ""
            mark = f'<span class="sg" style="position:relative">{inner}{extra}</span>'
        on = " on" if n == selected else ""
        out.append(f'<div class="hr{on}"><span class="dot"></span><span class="msg">{b}{esc(msg)}</span>'
                   f'<span class="au">{esc(au)}</span>{mark}<span class="hs">{hs}</span></div>')
    out.append("</div>")
    return "".join(out)


def middle(i: Ident | None, option: str, height: int = MID_H, *, tip: str = "", menu: str = "", hover: bool = False,
           chip_hover: bool = False, overlay: str = "", repo: str = "roga") -> str:
    return (f'<div class="mid" style="width:{WIDE}px;height:{height}px">'
            f'{branch_overlay_wrap(title_row(i, option, hover=hover and option == "G", repo=repo) + branch_row(i, option, tip=tip, menu=menu, hover=hover, chip_hover=chip_hover) + history())}'
            f'{overlay}</div>')


def branch_overlay_wrap(inner: str) -> str:
    # The tooltips and menus hang out of the column, so only the history clips.
    return f'<div style="display:flex;flex-direction:column;flex:1;min-height:0;border-radius:10px">{inner}</div>'


# ---------------------------------------------------------------- the commit panel


def file_row(f: tuple) -> str:
    letter, name, folder, plus, minus = f
    ff = f'<span class="ff">{esc(folder)}</span>' if folder else ""
    nums = (f'<span class="plus">+{plus}</span>' if plus else "") + (f'<span class="minus">−{minus}</span>' if minus else "")
    return f'<div class="fr"><span class="fl l{letter}">{letter}</span><span class="fn">{esc(name)}</span>{ff}<span class="num">{nums}</span></div>'


def file_list() -> str:
    return ('<div class="gh">Unstaged</div>' + "".join(file_row(f) for f in UNSTAGED)
            + '<div class="gh">Staged</div>' + "".join(file_row(f) for f in STAGED))


def text_block(lines: list[str]) -> tuple[str, int]:
    if not lines:
        return '<div class="ln ph">Message</div>', SHORTEST
    subject = lines[0]
    inner = (f'<div class="ln s"><span class="st">{esc(subject)}</span><span class="sc">{len(subject)}</span></div>'
             + "".join(f'<div class="ln">{esc(line) if line else "&#8203;"}</div>' for line in lines[1:]))
    return inner, max(SHORTEST, len(lines) * LINE)


def commit_box(i: Ident | None, option: str, *, lines: list[str] | None = None, hover: str = "",
               alone: bool = False, width: int = PANEL) -> tuple[str, int]:
    """The message box as CommitBox.swift lays it out, with what each option
    adds. `hover` is "line", "avatar" or "commit"."""
    lines = MESSAGE if lines is None else lines
    tops: list[tuple[str, int]] = []
    if i is not None and option != "today":
        if i.problem:
            tops.append(warning(i))
        elif option == "G":
            tops.append((box_line_g(i, hover=hover == "line", width=width), 22))
        elif option[:1] in ("D", "E", "F"):
            tops.append((box_line_d(i, hover=hover == "line", width=width), 22))
        elif option == "B" or (option == "C" and i.own):
            tops.append((box_line(i, hover=hover == "line"), 22))
    elif option[:1] in ("D", "E", "F", "G"):
        # Until git config answers, the box keeps the line's room, so the
        # message doesn't move down when the line arrives.
        tops.append(('<div style="height:22px"></div>', 22))
    top_html = ""
    top_h = 0
    if tops:
        top_h = 8 + sum(h for _, h in tops) + 6 * (len(tops) - 1)
        top_html = f'<div class="btop">{"".join(h for h, _ in tops)}</div>'
    tx, th = text_block(lines)
    pad = 7 if tops else 10
    gen = "Rewrite" if lines else "Generate with Claude"
    if option == "A" and i is not None and not lines:
        # The initials take 32 points of the row, so Generate leaves out the
        # agent's name, which is the first step decision 98's row takes when
        # it's short of room.
        gen = "Generate"
    left = (f'<span class="gs"><button class="m" type="button">{gen}</button>'
            f'<button class="chv" type="button" aria-label="Choose an agent">{CHEV}</button></span>')
    av = ""
    if option == "A" and i is not None:
        av = f'<button class="avb{" hov" if hover == "avatar" else ""}" type="button" aria-label="Commit identity">{avatar(i)}</button>'
    commit = (f'<span class="cb{" hov" if hover == "commit" else ""}"><button class="m" type="button">Commit 2 Files</button>'
              f'<button class="chv" type="button" aria-label="More ways to commit">{CHEV}</button></span>')
    h = top_h + pad + th + 2 + BOX_ROW + 2
    cls = "box alone" if alone else "box"
    style = f"height:{h}px;width:{width}px" if alone else f"height:{h}px"
    return (f'<div class="{cls}" style="{style}">{top_html}<div class="btx" style="padding-top:{pad}px;height:{pad + th}px">{tx}</div>'
            f'<div style="height:2px"></div><div class="brw">{left}<span class="gap"></span>{av}{commit}</div></div>', h)


def panel(i: Ident | None, option: str, *, hover: str = "", overlay: str = "", ruler: bool = True) -> str:
    box, h = commit_box(i, option, hover=hover)
    rul = (f'<div class="rul" style="left:{PANEL + 14}px;top:{PANEL_H - h}px;height:{h}px"><span class="rv">{h} pt</span></div>'
           if ruler else "")
    return (f'<div class="stage" style="width:{PANEL + 78}px;height:{PANEL_H}px">'
            f'<div class="cpanel" style="width:{PANEL}px;height:{PANEL_H}px"><div class="clip"><div class="files">{file_list()}</div>{box}</div>{overlay}</div>{rul}</div>')


# ---------------------------------------------------------------- menus, tooltips and the popover


def tip_box(text: str, left: int, top: int, *, right: bool = False) -> str:
    side = f"right:{left}px" if right else f"left:{left}px"
    return f'<div class="tip" style="{side};top:{top}px">{esc(text)}</div>'


def chip_menu(i: Ident, option: str) -> str:
    """The branch chip's menu, which C uses to say who commits go out as."""
    if i.signed:
        how = f"signed with {i.sign_words}"
    else:
        how = "not signed"
    ident = (f'<button class="mid2 hl" type="button"><span class="ck">{USER}</span>'
             f'<span class="e">Committing as {esc(i.email)} · {how}</span></button>')
    items = [("Pull", "⇧⌘L"), ("Push", "⇧⌘P"), ("Fetch", "⇧⌘F"), ("New Branch…", "⇧⌘B"), ("Switch Branch…", "⌃⌘B")]
    rows = "".join(f'<button class="mi" type="button"><span class="ck"></span><span>{t}</span><span class="tr">{k}</span></button>' for t, k in items)
    return (f'<div class="menu" style="left:0;top:36px">'
            '<div class="mh">origin/agent/fix-login · 2 ahead · fetched 4 min ago</div>'
            f'{ident}<div class="ms"></div>{rows}</div>')


def tokens(line: list[tuple[str, str]], cls: str = "cl") -> str:
    return f'<div class="{cls}">' + "".join(f'<span class="tk {c}">{esc(t)}</span>' for c, t in line) + "</div>"


def config_line(scope: str, key: str, value: str | None) -> list[tuple[str, str]]:
    line = [("t-p", "$"), ("t-g", "git"), ("t-g", "config"), ("t-f", f"--{scope}")]
    if value is None:
        return line + [("t-f", "--unset"), ("t-r", key)]
    shown = f'"{value}"' if " " in value else value
    return line + [("t-r", key), ("t-s", shown)]


def command_block(lines: list[list[tuple[str, str]]], comment: str = "") -> str:
    cm = f'<div class="cl cm"># {esc(comment)}</div>' if comment else ""
    return (f'<div class="cmd"><button class="cp" type="button" aria-label="Copy the command">{COPY}</button>'
            f'{cm}{"".join(tokens(l) for l in lines)}</div>')


@dataclass
class Field:
    label: str
    value: str
    origin: str
    new: bool = False         # the origin line says where Save will put it
    mono: bool = False
    focus: bool = False
    use_global: bool = False
    placeholder: str = ""


def field_html(f: Field) -> str:
    o_cls = "o new" if f.new else "o"
    ug = '<button class="ug" type="button">Use Global</button>' if f.use_global else ""
    tf = "tf mono" if f.mono else "tf"
    tf += " foc" if f.focus else ""
    ph = f' placeholder="{esc(f.placeholder)}"' if f.placeholder else ""
    return (f'<div class="pfd"><div class="pl"><label>{esc(f.label)}</label><span class="{o_cls}">{esc(f.origin)}</span>{ug}</div>'
            f'<input class="{tf}" type="text" value="{esc(f.value)}"{ph} aria-label="{esc(f.label)}"></div>')


def seg_html(options: list[str], on: str, label: str) -> str:
    return (f'<div class="seg" role="group" aria-label="{esc(label)}">'
            + "".join(f'<button type="button" class="{"on" if o == on else ""}" aria-pressed="{"true" if o == on else "false"}">{esc(o)}</button>' for o in options)
            + "</div>")


def popover(*, repo: str = "roga", fields: list[Field], sign: bool, fmt: str = "SSH", key: Field | None = None,
            scope: str = "This repository", note: str = "", note_warn: bool = False,
            cmd: list[list[tuple[str, str]]] | None = None, comment: str = "", save: bool = True,
            arrow: int | None = 30, arrow_down: bool = False, suggestions: str = "", style: str = "") -> str:
    arr = ""
    if arrow is not None:
        arr = f'<i class="arr{" dn" if arrow_down else ""}" style="left:{arrow}px"></i>'
    body = [f'<div class="phd"><b>Commit identity</b><span>For {esc(repo)} and every worktree of it</span></div>']
    body += [field_html(f) for f in fields]
    if suggestions:
        body.append(suggestions)
    tg = "tg on" if sign else "tg"
    body.append(f'<div class="psw"><span class="l">Sign commits</span><button class="{tg}" type="button" aria-pressed="{"true" if sign else "false"}" aria-label="Sign commits"><i></i></button></div>')
    if sign:
        body.append(f'<div class="pfd">{seg_html(["OpenPGP", "SSH", "X.509"], fmt, "Format")}</div>')
        if key:
            body.append(field_html(key))
    body.append(f'<div class="pfd" style="padding-top:14px"><div class="pl"><label>Save to</label></div>'
                f'{seg_html(["This repository", "Every repository"], scope, "Save to")}</div>')
    if note:
        body.append(f'<div class="pnote{" warn" if note_warn else ""}">{esc(note)}</div>')
    dis = "" if save else " disabled"
    body.append(f'<div class="pbtn"><button class="b sec" type="button">Cancel</button><button class="b pri" type="button"{dis}>Save</button></div>')
    body.append(command_block(cmd or [], comment))
    return f'<div class="pop" style="{style}">{arr}<div class="pin">{"".join(body)}</div></div>'


def name_field(i: Ident, **kw) -> Field:
    return Field("Name", i.name, origin_short(i.origin), **kw)


def origin_short(origin: str) -> str:
    return {"global": f"from {GLOBAL_FILE}", "include": f"from {WORK_FILE}, for ~/work/", "local": "this repository's own"}[origin]


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


def two_rows_board(file: str, title: str, rows: list[list[str]], *, stage_h: int, theme: str = "th-l") -> Board:
    w = 80 + WIDE + 48 + PANEL + 78
    h = 34 + len(rows) * (36 + 12 + stage_h) + (len(rows) - 1) * 36 + 40
    body = (f'<div class="board {theme}" style="width:{w}px;height:{h}px">'
            + "".join(f'<div class="cells">{"".join(r)}</div>' for r in rows) + "</div>")
    return Board(file, title, w, h, page(title, body, w, h))


def board_today() -> Board:
    rows = [[
        cell("Today", "nothing says who commits go out as", middle(None, "today")),
        cell("The message box", "the author shows only after the commit", panel(None, "today")),
    ]]
    return two_rows_board("Id-Today.dc.html", "Today", rows, stage_h=PANEL_H)


def board_a() -> Board:
    i = GLOBAL
    tip = tip_box(i.tip, -250, 38)
    rows = [
        [cell("A · Initials before Fetch", "tinted by the email, a shield when signed", middle(i, "A")),
         cell("A · Initials before Commit", "no height of its own", panel(i, "A"))],
        [cell("A · The pointer over them", "the tooltip names the email and where it comes from", middle(i, "A", tip=tip, hover=True)),
         cell("A · From ~/work/", "another email, another tint", panel(WORK, "A"))],
    ]
    return two_rows_board("Id-A.dc.html", "A · Initials", rows, stage_h=PANEL_H)


def board_b() -> Board:
    i = GLOBAL
    tip = tip_box(i.tip, -120, 38)
    rows = [
        [cell("B · The email before Fetch", "with a shield, or a crossed one", middle(i, "B")),
         cell("B · A line over the message", "27 points of its own", panel(i, "B"))],
        [cell("B · The pointer over it", "the same tooltip as A's", middle(i, "B", tip=tip, hover=True)),
         cell("B · Not signed", "the line says so in words", panel(UNSIGNED, "B"))],
    ]
    return two_rows_board("Id-B.dc.html", "B · The email", rows, stage_h=PANEL_H)


def board_c() -> Board:
    i = GLOBAL
    menu = chip_menu(i, "C")
    commit_tip = tip_box("Commit as sam@rivera.dev, signed with SSH  ⌘↩", 8, PANEL_H - 76, right=True)
    rows = [
        [cell("C · Nothing at rest", "the global identity, nothing wrong", middle(i, "C")),
         cell("C · Nothing in the box either", "", panel(i, "C"))],
        [cell("C · In the branch chip's menu", "and in Commit's tooltip", middle(i, "C", menu=menu, chip_hover=True)),
         cell("C · Commit's tooltip", "", panel(i, "C", hover="commit", overlay=commit_tip))],
        [cell("C · The repository's own", "now it shows, as B's does", middle(OWN, "C")),
         cell("C · The same, in the box", "", panel(OWN, "C"))],
    ]
    return two_rows_board("Id-C.dc.html", "C · Only when it isn't the global one", rows, stage_h=PANEL_H)


OPTIONS = [("A", "A · Initials"), ("B", "B · The email"), ("C", "C · Only when it isn't the global one")]
STATE_BOX_H = 196


def state_cell(i: Ident | None, option: str) -> str:
    box, h = commit_box(i, option, lines=[], alone=True)
    return (f'<div style="display:flex;flex-direction:column;gap:10px;width:{CELL_W}px;height:{44 + 10 + STATE_BOX_H}px">'
            f'{branch_row(i, option, alone=True)}{box}</div>')


def board_states(dark: bool) -> Board:
    label_w = 230
    cols = f"{label_w}px " + " ".join(f"{CELL_W}px" for _ in OPTIONS)
    cells = ['<span class="cap" style="height:auto"></span>'] + [f'<span class="cap" style="height:auto;font-weight:600">{esc(t)}</span>' for _, t in OPTIONS]
    for label, sub, i in MOMENTS:
        cells.append(f'<div class="cap" style="height:auto;padding-top:12px">{esc(label)}<i style="display:block;margin-top:2px">{esc(sub)}</i></div>')
        for option, _ in OPTIONS:
            cells.append(state_cell(i, option))
    cell_h = 44 + 10 + STATE_BOX_H
    w = 80 + label_w + len(OPTIONS) * (CELL_W + 32)
    h = 34 + 24 + len(MOMENTS) * (cell_h + 20) + 40
    theme = "th-d" if dark else "th-l"
    body = (f'<div class="board {theme}" style="width:{w}px;height:{h}px;display:block">'
            f'<div style="display:grid;grid-template-columns:{cols};column-gap:32px;row-gap:20px;align-items:start">{"".join(cells)}</div></div>')
    title = "Every option, moment by moment" + (", dark" if dark else "")
    return Board("Id-States-Dark.dc.html" if dark else "Id-States.dc.html", title, w, h, page(title, body, w, h))


# ---------------------------------------------------------------- the popover


def popover_frames() -> list[tuple[str, str, str]]:
    g = GLOBAL
    w = WORK
    frames = []
    frames.append(("Opened on the global identity", "nothing to save yet", popover(
        fields=[name_field(g), Field("Email", g.email, origin_short("global"))],
        sign=True, key=Field("Key", g.key, origin_short("global"), mono=True),
        note="Every worktree of roga commits with it.", save=False, comment="Nothing to change yet")))
    frames.append(("A new email for this repository", "Save writes .git/config", popover(
        fields=[name_field(g), Field("Email", "sam@oss.example", "this repository's own after Save", new=True, focus=True)],
        sign=True, key=Field("Key", g.key, origin_short("global"), mono=True),
        note="Every worktree of roga commits with it.",
        cmd=[config_line("local", "user.email", "sam@oss.example")])))
    frames.append(("The same, for every repository", "never the default here", popover(
        fields=[name_field(g), Field("Email", "sam@oss.example", f"{GLOBAL_FILE} after Save", new=True)],
        sign=True, key=Field("Key", g.key, origin_short("global"), mono=True), scope="Every repository",
        note="Every repository that doesn't set its own email commits with it, including 9 in the sidebar.",
        cmd=[config_line("global", "user.email", "sam@oss.example")])))
    frames.append(("The repository's own email", "Use Global takes it out", popover(
        fields=[name_field(OWN), Field("Email", OWN.email, origin_short("local"), use_global=True)],
        sign=False, note="Every worktree of roga commits with it.", save=False, comment="Nothing to change yet")))
    frames.append(("After Use Global", "the global email comes back", popover(
        fields=[name_field(OWN), Field("Email", g.email, f"from {GLOBAL_FILE} after Save", new=True)],
        sign=False, note="Every worktree of roga commits with it.",
        cmd=[config_line("local", "user.email", None)])))
    frames.append(("From a file included for ~/work/", "a global change wouldn't show here", popover(
        repo="api-gateway",
        fields=[name_field(w), Field("Email", "sam@acme.com", f"{GLOBAL_FILE} after Save", new=True)],
        sign=True, key=Field("Key", w.key, origin_short("include"), mono=True), scope="Every repository",
        note=f"{WORK_FILE} sets the email after {GLOBAL_FILE}, so api-gateway would go on committing as sam.rivera@acme.com. "
             "Save to this repository, or change the email in that file.",
        note_warn=True, save=False, cmd=[config_line("global", "user.email", "sam@acme.com")])))
    frames.append(("Turning signing on", "with an SSH key", popover(
        fields=[name_field(g), Field("Email", g.email, origin_short("global"))],
        sign=True, fmt="SSH", key=Field("Key", "~/.ssh/id_ed25519.pub", "this repository's own after Save", new=True, mono=True),
        note="git signs with ssh-keygen, or with what gpg.ssh.program names.",
        cmd=[config_line("local", "commit.gpgsign", "true"), config_line("local", "gpg.format", "ssh"),
             config_line("local", "user.signingkey", "~/.ssh/id_ed25519.pub")])))
    sugg = ('<div class="sug" role="listbox" aria-label="Emails">'
            f'<div class="sg2 hl" role="option">sam@rivera.dev<i>{GLOBAL_FILE}</i></div>'
            f'<div class="sg2" role="option">sam.rivera@acme.com<i>{WORK_FILE}, for ~/work/</i></div>'
            '<div class="sg2" role="option">sam@oss.example<i>oss-tools and 1 more repository</i></div></div>')
    frames.append(("Emails Roga has already read", "from other repositories' config, not stored", popover(
        fields=[name_field(g), Field("Email", "sam", "", focus=True)],
        sign=False, note="Every worktree of roga commits with it.", save=False, suggestions=sugg,
        comment="Nothing to change yet")))
    return frames


POP_CELL_H = 560


def board_popover() -> Board:
    frames = popover_frames()
    per_row = 4
    rows = [frames[n:n + per_row] for n in range(0, len(frames), per_row)]
    w = 80 + per_row * 344 + (per_row - 1) * 40
    h = 34 + len(rows) * (36 + 12 + POP_CELL_H) + (len(rows) - 1) * 36 + 40
    out = []
    for r in rows:
        cells = "".join(
            f'<div class="cell" style="width:344px"><div class="cap">{esc(c)} <i>· {esc(s)}</i></div>'
            f'<div class="stage" style="width:344px;height:{POP_CELL_H}px;padding-top:8px">{p}</div></div>'
            for c, s, p in r)
        out.append(f'<div class="cells" style="gap:40px">{cells}</div>')
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px">{"".join(out)}</div>'
    return Board("Id-Popover.dc.html", "The identity popover", w, h, page("The identity popover", body, w, h))


# ---------------------------------------------------------------- try it

TRY_START = {
    "global": {"name": "Sam Rivera", "email": "sam@rivera.dev", "sign": True, "format": "ssh", "key": "~/.ssh/id_ed25519.pub",
               "origin": "global", "repo": "roga", "hue": "p"},
    "include": {"name": "Sam Rivera", "email": "sam.rivera@acme.com", "sign": True, "format": "ssh", "key": "~/.ssh/acme_ed25519.pub",
                "origin": "include", "repo": "api-gateway", "hue": "w"},
    "local": {"name": "Sam Rivera", "email": "sam@oss.example", "sign": False, "format": "ssh", "key": "",
              "origin": "local", "repo": "oss-tools", "hue": "o"},
}

TRY_JS = r"""
const START = __START__;
const GLOBAL = START.global;
const ORIGIN = { global: "from ~/.gitconfig", include: "from ~/.gitconfig-work, for ~/work/", local: "this repository's own" };
const FORMATS = [["openpgp", "OpenPGP"], ["ssh", "SSH"], ["x509", "X.509"]];

function initials(name) { return name.split(/\s+/).filter(Boolean).slice(0, 2).map((p) => p[0].toUpperCase()).join("") || "?"; }
function quote(v) { return /\s/.test(v) ? '"' + v + '"' : v; }
function hueFor(email) {
  if (email.endsWith("@acme.com")) return "w";
  if (email.endsWith("@rivera.dev")) return "p";
  return email ? "o" : "n";
}

class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = this.fresh("global", "A");
  }
  fresh(from, opt) {
    const base = Object.assign({}, START[from]);
    return { from, opt, base, draft: Object.assign({}, base), scope: "local", unset: false, log: [] };
  }
  edit(patch) { this.setState({ draft: Object.assign({}, this.state.draft, patch), unset: false }); }

  commands() {
    const s = this.state, b = s.base, d = s.draft, out = [];
    const line = (key, value) => {
      const toks = [["t-p", "$"], ["t-g", "git"], ["t-g", "config"], ["t-f", "--" + s.scope]];
      if (value === null) { toks.push(["t-f", "--unset"], ["t-r", key]); }
      else { toks.push(["t-r", key], ["t-s", quote(value)]); }
      out.push({ toks: toks.map(([c, x]) => ({ c: "tk " + c, x })) });
    };
    if (s.unset) { line("user.email", null); return out; }
    if (d.name !== b.name) line("user.name", d.name);
    if (d.email !== b.email) line("user.email", d.email);
    if (d.sign !== b.sign) line("commit.gpgsign", d.sign ? "true" : "false");
    if (d.sign && d.format !== b.format) line("gpg.format", d.format);
    if (d.sign && d.key !== b.key) line("user.signingkey", d.key);
    return out;
  }

  renderVals() {
    const s = this.state, b = s.base, d = s.draft;
    const cmds = this.commands();
    const changed = cmds.length > 0;
    // A value the repository sets, or a file included after ~/.gitconfig
    // sets, hides a global one, so saving the email globally wouldn't show.
    const shadowed = s.scope === "global" && b.origin !== "global" && d.email !== b.email && !s.unset;
    const shown = b;   // what the window shows is what was last saved
    const signed = shown.sign && !!shown.key;
    const opt = s.opt;
    const hue = hueFor(shown.email);
    const own = shown.origin !== "global";
    const seg = (key, options, extra) => options.map(([v, t]) => ({
      t, cls: "sga" + (s[key] === v ? " on" : ""),
      pick: () => this.setState(Object.assign({ [key]: v }, extra ? extra(v) : {})),
    }));
    const fmtSeg = FORMATS.map(([v, t]) => ({ t, cls: d.format === v ? "on" : "", pick: () => this.edit({ format: v }) }));
    const scopeSeg = [["local", "This repository"], ["global", "Every repository"]].map(([v, t]) => ({
      t, cls: s.scope === v ? "on" : "", pick: () => this.setState({ scope: v }),
    }));
    const originOf = (field) => {
      if (s.unset && field === "email") return "from ~/.gitconfig after Save";
      if (d[field] !== b[field]) return s.scope === "local" ? "this repository's own after Save" : "~/.gitconfig after Save";
      return ORIGIN[b.origin];
    };
    let note = s.scope === "local"
      ? "Every worktree of " + b.repo + " commits with it."
      : "Every repository that doesn't set its own commits with it.";
    if (shadowed && b.origin === "include") note = "~/.gitconfig-work sets the email after ~/.gitconfig, so " + b.repo + " would go on committing as " + b.email + ". Save to this repository, or change the email in that file.";
    if (shadowed && b.origin === "local") note = b.repo + " sets its own email, so it would go on committing as " + b.email + ". Save to this repository, or use Use Global first.";
    const save = () => {
      if (!changed || shadowed) return;
      const text = cmds.map((c) => c.toks.map((t) => t.x).join(" ")).join("\n");
      const next = Object.assign({}, s.unset ? Object.assign({}, d, { email: GLOBAL.email }) : d);
      next.origin = s.unset ? "global" : s.scope === "local" ? "local" : b.origin;
      next.repo = b.repo;
      this.setState({ base: next, draft: Object.assign({}, next), unset: false,
        log: text.split("\n").map((x) => ({ text: x, cls: "new" })).concat(s.log.map((l) => ({ text: l.text, cls: "" }))).slice(0, 8) });
    };
    const tipLines = [shown.name + (shown.email ? " <" + shown.email + ">" : ", with no email"),
      shown.origin === "global" ? "From ~/.gitconfig" : shown.origin === "include" ? "From ~/.gitconfig-work, which ~/.gitconfig includes for ~/work/" : "This repository's own, in .git/config",
      signed ? "Signed with " + (shown.format === "ssh" ? "SSH" : shown.format === "x509" ? "X.509" : "OpenPGP") + " · " + shown.key : "Not signed"];
    return {
      fromSeg: seg("from", [["global", "~/.gitconfig"], ["include", "Included for ~/work/"], ["local", "The repository's own"]],
        (v) => { const f = this.fresh(v, s.opt); return f; }),
      optSeg: seg("opt", [["A", "A · Initials"], ["B", "B · The email"], ["C", "C · Only when it isn't the global one"]]),
      reset: () => this.setState(this.fresh(s.from, s.opt)),
      repo: b.repo,
      tip: tipLines.join("\n"),
      showA: opt === "A", showB: opt === "B" || (opt === "C" && own),
      initials: initials(shown.name), avCls: "av " + hue, signed, unsignedB: !signed,
      email: shown.email, whose: shown.name, lineEmail: "<" + shown.email + ">",
      showLine: opt === "B" || (opt === "C" && own),
      name: d.name, email2: d.email, key: d.key, sign: d.sign, tgCls: d.sign ? "tg on" : "tg", tgPressed: d.sign ? "true" : "false",
      onName: (e) => this.edit({ name: e.target.value }),
      onEmail: (e) => this.edit({ email: e.target.value }),
      onKey: (e) => this.edit({ key: e.target.value }),
      flipSign: () => this.edit({ sign: !d.sign, key: !d.sign && !d.key ? "~/.ssh/id_ed25519.pub" : d.key }),
      fmtSeg, scopeSeg,
      nameOrigin: originOf("name"), emailOrigin: originOf("email"), keyOrigin: originOf("key"),
      nameOCls: d.name !== b.name ? "o new" : "o", emailOCls: d.email !== b.email || s.unset ? "o new" : "o", keyOCls: d.key !== b.key ? "o new" : "o",
      useGlobal: b.origin === "local" && !s.unset && d.email === b.email,
      doUseGlobal: () => this.setState({ unset: true, draft: Object.assign({}, d, { email: GLOBAL.email }) }),
      note, noteCls: shadowed ? "pnote warn" : "pnote",
      cmds, hasCmds: changed, noCmds: !changed,
      saveOff: !changed || shadowed,
      save,
      cancel: () => this.setState({ draft: Object.assign({}, b), unset: false }),
      log: s.log, hasLog: s.log.length > 0,
    };
  }
"""


def sc_if(cond: str, body: str, placeholder: str = "false") -> str:
    return f'<sc-if value="{{{{{cond}}}}}" hint-placeholder-val="{{{{{placeholder}}}}}">{body}</sc-if>'


def board_try() -> Board:
    av_badge = sc_if("signed", badge(P_SHIELD), "true")
    av = '<span class="{{avCls}}" aria-hidden="true">{{initials}}' + av_badge + "</span>"
    sign_b = sc_if("signed", SHIELD, "true") + sc_if("unsignedB", f'<span class="off" style="display:flex">{SH_OFF}</span>')
    ident_row = (sc_if("showA", f'<button class="ib" type="button" aria-label="Commit identity" title="{{{{tip}}}}">{av}</button>', "true")
                 + sc_if("showB", '<button class="idw" type="button" title="{{tip}}"><span class="e">{{email}}</span>' + sign_b + "</button>"))
    brow = (f'<div class="brow alone" style="width:{WIDE}px"><button class="chip" type="button">{BRANCH}<span class="nm">agent/fix-login</span>{CHEV}</button>'
            f'<span class="cnt">{PUSH}2</span><span class="sp"></span><span class="rg">{ident_row}<span class="ib">{FETCH}</span>'
            f'<span class="ib">{NEWBRANCH}</span><i class="vs"></i><span class="nc">128 commits</span><span class="ib">{ORDER}</span></span></div>')
    line_right = (sc_if("signed", f'<span class="r">{SHIELD}Signed</span>', "true")
                  + sc_if("unsignedB", f'<span class="r off">{SH_OFF}Not signed</span>'))
    box_top = sc_if("showLine", f'<div class="btop"><button class="idl" type="button" title="{{{{tip}}}}">{USER}<span class="e"><b>{{{{whose}}}}</b> {{{{lineEmail}}}}</span>{line_right}</button></div>')
    box_av = sc_if("showA", f'<button class="avb" type="button" aria-label="Commit identity" title="{{{{tip}}}}">{av}</button>', "true")
    box = (f'<div class="box alone" style="width:{PANEL}px">{box_top}<div class="btx" style="padding-top:10px;height:58px"><div class="ln ph">Message</div></div>'
           f'<div style="height:2px"></div><div class="brw"><span class="gs"><button class="m" type="button">Generate with Claude</button>'
           f'<button class="chv" type="button" aria-label="Choose an agent">{CHEV}</button></span><span class="gap"></span>{box_av}'
           f'<span class="cb"><button class="m" type="button">Commit 2 Files</button><button class="chv" type="button" aria-label="More ways to commit">{CHEV}</button></span></div></div>')
    fmt = ('<div class="seg" role="group" aria-label="Format"><sc-for list="{{fmtSeg}}" as="f" hint-placeholder-count="3">'
           '<button type="button" class="{{f.cls}}" onClick="{{f.pick}}">{{f.t}}</button></sc-for></div>')
    scope = ('<div class="seg" role="group" aria-label="Save to"><sc-for list="{{scopeSeg}}" as="f" hint-placeholder-count="2">'
             '<button type="button" class="{{f.cls}}" onClick="{{f.pick}}">{{f.t}}</button></sc-for></div>')
    pop = (
        '<div class="pop"><div class="pin">'
        '<div class="phd"><b>Commit identity</b><span>For {{repo}} and every worktree of it</span></div>'
        '<div class="pfd"><div class="pl"><label for="idt-name">Name</label><span class="{{nameOCls}}">{{nameOrigin}}</span></div>'
        '<input id="idt-name" class="tf" type="text" value="{{name}}" onChange="{{onName}}"></div>'
        '<div class="pfd"><div class="pl"><label for="idt-email">Email</label><span class="{{emailOCls}}">{{emailOrigin}}</span>'
        + sc_if("useGlobal", '<button class="ug" type="button" onClick="{{doUseGlobal}}">Use Global</button>') +
        '</div><input id="idt-email" class="tf" type="text" value="{{email2}}" onChange="{{onEmail}}"></div>'
        '<div class="psw"><span class="l">Sign commits</span><button class="{{tgCls}}" type="button" aria-pressed="{{tgPressed}}" aria-label="Sign commits" onClick="{{flipSign}}"><i></i></button></div>'
        + sc_if("sign", f'<div class="pfd">{fmt}</div><div class="pfd"><div class="pl"><label for="idt-key">Key</label><span class="{{{{keyOCls}}}}">{{{{keyOrigin}}}}</span></div>'
                '<input id="idt-key" class="tf mono" type="text" value="{{key}}" onChange="{{onKey}}"></div>', "true")
        + f'<div class="pfd" style="padding-top:14px"><div class="pl"><label>Save to</label></div>{scope}</div>'
        '<div class="{{noteCls}}">{{note}}</div>'
        '<div class="pbtn"><button class="b sec" type="button" onClick="{{cancel}}">Cancel</button>'
        '<button class="b pri" type="button" onClick="{{save}}" disabled="{{saveOff}}">Save</button></div>'
        f'<div class="cmd"><button class="cp" type="button" aria-label="Copy the command">{COPY}</button>'
        + sc_if("noCmds", '<div class="cl cm"># Nothing to change yet</div>', "true")
        + '<sc-for list="{{cmds}}" as="ln" hint-placeholder-count="1"><div class="cl"><sc-for list="{{ln.toks}}" as="t" hint-placeholder-count="6">'
        '<span class="{{t.c}}">{{t.x}}</span></sc-for></div></sc-for></div>'
        '</div></div>'
    )
    bar = ('<div class="bar"><div class="grp"><span>Start from</span><div class="sega"><sc-for list="{{fromSeg}}" as="b" hint-placeholder-count="3">'
           '<button class="{{b.cls}}" type="button" onClick="{{b.pick}}">{{b.t}}</button></sc-for></div></div>'
           '<div class="grp"><span>Show it as</span><div class="sega"><sc-for list="{{optSeg}}" as="b" hint-placeholder-count="3">'
           '<button class="{{b.cls}}" type="button" onClick="{{b.pick}}">{{b.t}}</button></sc-for></div></div>'
           '<div class="grp"><div class="sega"><button class="sga" type="button" onClick="{{reset}}">Start over</button></div></div></div>')
    left = (f'<div class="tleft" style="width:{WIDE}px">{brow}{box}'
            '<div class="meta" style="max-width:680px">The branch row and the box show what was last saved. Hover the initials, the email or the line for the tooltip.</div>'
            + sc_if("hasLog", '<ul class="log"><sc-for list="{{log}}" as="l" hint-placeholder-count="2"><li class="{{l.cls}}">{{l.text}}</li></sc-for></ul>')
            + "</div>")
    w = 80 + WIDE + 40 + 344
    h = 26 + 30 + 18 + 640 + 40
    body = f'<div class="try th-l" style="width:{w}px;height:{h}px">{bar}<div class="tmain">{left}{pop}</div></div>'
    script = TRY_JS.replace("__START__", json.dumps(TRY_START))
    head, _, body_js = script.partition("class Component extends DCLogic {")
    return Board("Id-Try.dc.html", "Try it", w, h, page("Try it", body, w, h, body_js, head), interactive=True)


# ---------------------------------------------------------------- the sidebar


@dataclass
class SRow:
    name: str
    ident: Ident
    count: int = 0
    detail: str = ""
    on: bool = False


SIDEBAR_GROUPS: list[tuple[str, list[SRow]]] = [
    ("acme", [SRow("api-gateway", WORK, 3), SRow("billing", WORK), SRow("dashboard", WORK, 1)]),
    ("samrivera", [SRow("dotfiles", GLOBAL), SRow("roga", GLOBAL, 3, on=True)]),
    ("Other", [SRow("legacy-site", NO_EMAIL), SRow("oss-tools", OWN, 2, detail="release/0.9"), SRow("scratch", GLOBAL)]),
]


def sidebar(variant: str, *, tip: str = "", tip_row: str = "", selected: str = "") -> tuple[str, int]:
    """Today's sidebar, grouped by organization, marking only the repositories
    whose identity isn't the global one, or would go wrong."""
    out = ['<div class="tl"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>',
           f'<div class="tr2">{FOLDER_PLUS}<span>Add Repositories</span></div>',
           f'<div class="tr2">{SETTINGS}<span>Settings</span></div>',
           '<div class="nsep"></div>',
           f'<div class="shd"><b>Repositories</b>{FILTER}</div>']
    h = 52 + 34 * 2 + 15 + 32
    for group, rows in SIDEBAR_GROUPS:
        shared = {r.ident for r in rows}
        group_ident = next(iter(shared)) if len(shared) == 1 and next(iter(shared)).own else None
        label = esc(group)
        if variant == "C" and group_ident:
            label += f'<span class="e">· {esc(group_ident.email)}</span>'
        out.append(f'<div class="glb">{label}</div>')
        h += 30
        for r in rows:
            i = r.ident
            different = i.own and not (variant == "C" and group_ident)
            two = bool(i.problem)
            on = r.name == selected if selected else r.on
            cls = "sr" + (" two" if two else "") + (" on" if on else "")
            detail = f'<span class="dt">{esc(r.detail)}</span>' if r.detail else ""
            if variant == "B" and different:
                detail += f'<span class="dt">{esc(i.domain)}</span>'
            second = ""
            if i.problem == "noemail":
                second = f'<span class="l2 warn">{TRI}<span>No email for commits</span></span>'
            elif i.problem == "nokey":
                second = f'<span class="l2 warn">{TRI}<span>Signing needs a key</span></span>'
            trail = ""
            if variant in ("A", "C", "G") and different:
                extra = tip if r.name == tip_row else ""
                mark = bare_person(i) if variant == "G" else avatar(i, "sm")
                trail += f'<span class="rel">{mark}{extra}</span>'
            if r.count:
                trail += f'<span class="ct">{r.count}</span>'
            trail += '<span class="mkp"></span>'
            out.append(f'<div class="{cls}"><span class="tx"><span class="l1"><span class="nm">{esc(r.name)}</span>{detail}</span>{second}</span>'
                       f'<span class="trail">{trail}</span></div>')
            h += (52 if two else 32) + 2
    h += 16
    return f'<div class="sbw" style="height:{h}px">{"".join(out)}</div>', h


def board_sidebar() -> Board:
    tip = tip_box(OWN.tip, -200, 26)
    variants = [
        ("A · Initials at the right", "where a count goes", sidebar("A", tip=tip, tip_row="oss-tools")),
        ("B · The domain after the name", "where a branch goes", sidebar("B")),
        ("C · On the organization's label", "when every repository under it shares one", sidebar("C")),
    ]
    sb_h = max(h for _, _, (_, h) in variants)
    w = 80 + 3 * 312 + 2 * 48
    h = 34 + 36 + 12 + sb_h + 40
    cells = "".join(cell(c, s, f'<div class="stage" style="width:312px;height:{sb_h}px">{html_}</div>') for c, s, (html_, _) in variants)
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="cells">{cells}</div></div>'
    return Board("Id-Sidebar.dc.html", "The sidebar, only for exceptions", w, h, page("The sidebar, only for exceptions", body, w, h))


# ---------------------------------------------------------------- Settings › Git


def identity_git_page(ctx) -> tuple[str, int]:
    row, section, toggle, field_ = st.row, st.section, st.toggle, st.field_
    v = asb.fr.View(asb.fr.derive(asb.fr.state()))
    git = st.block(asb.fr.fcard(asb.fr.git_row(v, with_menu=False)), 68)
    fmt = st.seg(ctx, "fmt", ["OpenPGP", "SSH", "X.509"], "SSH", "Format")
    identity = section("Identity", [
        row("Name", field_("Sam Rivera", "Name"), key="user.name", cw=240),
        row("Email", field_("sam@rivera.dev", "Email"), key="user.email", cw=240),
        row("Sign commits", toggle(ctx, "sign", True, "Sign commits"), "With the key below.", key="commit.gpgsign"),
        row("Format", fmt, key="gpg.format", cw=220),
        row("Key", field_("~/.ssh/id_ed25519.pub", "Signing key", mono=True), key="user.signingkey", cw=240),
    ], desc="These are in ~/.gitconfig, which every repository uses unless it sets its own. Changing one runs git config --global.")

    def repo_row(name: str, line: str, button: str, warn: bool = False) -> str:
        cls = "ap warn" if warn else "ap"
        btn = f'<button class="b sec sm">{esc(button)}</button>' if button else f'<button class="chev" aria-label="Show">{st.ic("right", "ic s")}</button>'
        return f'<div class="ar"><div class="an"><b>{esc(name)}</b><span class="{cls}">{esc(line)}</span></div><div class="rc">{btn}</div></div>'

    rows = (repo_row("api-gateway, billing and dashboard", f"sam.rivera@acme.com · from {WORK_FILE}, which {GLOBAL_FILE} includes for ~/work/", "")
            + repo_row("oss-tools", "sam@oss.example · its own, in .git/config", "Use Global")
            + repo_row("legacy-site", "No email. git would refuse to commit, or make one up.", "Set…", warn=True))
    others = section("Repositories that commit as someone else",
                     [st.block(f'<div class="lst">{rows}</div>', 3 * 58)],
                     desc="The repositories in the sidebar whose name, email or signing isn't the global one, and the ones that couldn't commit.")
    # Installation stays first, as on today's Git page, and the identity
    # follows it, ahead of fetching.
    installation = section("Installation", [git], aside=asb.rescan(), desc="Requires Git 2.44 or later.")
    fetching = section("Fetching", [
        row("Fetch when Roga becomes active", toggle(ctx, "fetch", True, "Fetch when Roga becomes active"), "At most once a minute. Only remote-tracking branches are updated."),
    ])
    return st.join_sections([installation, identity, others, fetching])


def board_settings() -> Board:
    return asb.settings_board("Id-Settings.dc.html", "Settings › Git, with the identity", "git", "git", identity_git_page(st.Ctx()))


# ---------------------------------------------------------------- signed commits


SIG_STATES = [
    ("Checking", "while git log --format=%G? runs",
     '<div class="sgl"><span class="lb">Signature</span><span class="w"><span class="h"><i class="spin"></i>Checking…</span></span></div>'),
    ("Good", "the key is one this Mac trusts",
     f'<div class="sgl good"><span class="lb">Signature</span><span class="w"><span class="h">{SH_CHECK}Good SSH signature</span>'
     '<span class="g">sam@rivera.dev · SHA256:mR3tK0…Xq9w</span></span></div>'),
    ("Signed, but this Mac can't check it", "the most common answer for SSH",
     f'<div class="sgl"><span class="lb">Signature</span><span class="w"><span class="h">{SH_Q}Signed with SSH, not checked</span>'
     '<span class="g">git needs gpg.ssh.allowedSignersFile to know whose keys to trust.</span></span></div>'),
    ("A key this Mac doesn't have", "OpenPGP",
     f'<div class="sgl"><span class="lb">Signature</span><span class="w"><span class="h">{SH_Q}Signed with a key this Mac doesn\'t have</span>'
     '<span class="g">OpenPGP key 3AA5C34371567BD2</span></span></div>'),
    ("Bad", "the commit changed after it was signed",
     f'<div class="sgl bad"><span class="lb">Signature</span><span class="w"><span class="h">{SH_ALERT}The signature doesn\'t match this commit</span>'
     '<span class="g">It was made for other contents, or with another key than it names.</span></span></div>'),
    ("Not signed", "no line at all", ""),
]


def commit_details(sig: str, *, signed_by: str = "Sam Rivera", email: str = "sam@rivera.dev") -> str:
    return (f'<div class="cpanel" style="width:{PANEL}px;height:218px"><div class="clip">'
            f'<div class="cph">Commit <span class="hs2">5405371</span><span class="sp"></span><span class="ib">{COPY}</span></div>'
            '<div class="cpb"><div class="sj">Lock the login after five failed attempts</div>'
            f'<div class="ppl"><div><span class="lb">Author</span>{esc(signed_by)} <span class="g">&lt;{esc(email)}&gt;  Nov 24, 2026 at 10:12</span></div></div>'
            f'{sig}<div class="ppl"><div><span class="lb">Parent</span><span class="lk">2f1c9d0</span></div></div></div></div></div>')


def board_history() -> Board:
    tip = tip_box("Signed. Select the commit to check the signature.", -300, 22)
    hist_marks = (f'<div class="mid" style="width:{WIDE}px;height:330px"><div class="clip">'
                  f'{branch_row(GLOBAL, "A")}{history(10, marks=True, selected=1, tip=tip)}</div></div>')
    left = cell("History", "a shield by the hash of every commit with a signature", hist_marks)
    sig_cells = "".join(cell(c, s, commit_details(html_)) for c, s, html_ in SIG_STATES[:3])
    sig_cells2 = "".join(cell(c, s, commit_details(html_)) for c, s, html_ in SIG_STATES[3:])
    w = 80 + WIDE + 48 + 3 * PANEL + 2 * 40
    h = 34 + 2 * (36 + 12 + 218) + 36 + 40
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="cells">{left}'
            f'<div style="display:flex;flex-direction:column;gap:36px"><div class="cells" style="gap:40px">{sig_cells}</div>'
            f'<div class="cells" style="gap:40px">{sig_cells2}</div></div></div></div>')
    return Board("Id-History.dc.html", "Signed commits in history and the commit panel", w, h,
                 page("Signed commits in history and the commit panel", body, w, h))


# ---------------------------------------------------------------- after building it


def rows_board(file: str, title: str, rows: list[list[str]], *, w: int, stage_h: int) -> Board:
    h = 34 + len(rows) * (36 + 12 + stage_h) + (len(rows) - 1) * 36 + 40
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px">'
            + "".join(f'<div class="cells">{"".join(r)}</div>' for r in rows) + "</div>")
    return Board(file, title, w, h, page(title, body, w, h))


def board_d() -> Board:
    """D: the line at the top of the box all the time, and nothing in the
    branch row."""
    _, h = commit_box(GLOBAL, "D")
    line_top = PANEL_H - h + 8
    hover = tip_box(GLOBAL.tip, 14, line_top + 28) + pointer(150, line_top + 9)
    rows = [
        [cell("D · Nothing in the branch row", "it's the branch's row again", middle(GLOBAL, "D")),
         cell("D · The global identity, in gray", "always there, 27 points of its own", panel(GLOBAL, "D"))],
        [cell("D · From ~/work/", "the email's tint, and the name in ink", panel(WORK, "D")),
         cell("D · The repository's own", "and not signed", panel(OWN, "D")),
         cell("D · The pointer over the line", "a click opens the popover under it", panel(GLOBAL, "D", hover="line", overlay=hover, ruler=False))],
    ]
    w = 80 + 3 * (PANEL + 78) + 2 * 48
    return rows_board("Id-D.dc.html", "D · The box always says who", rows, w=w, stage_h=PANEL_H)


def board_where() -> Board:
    """Where the initials could go, besides the box's line: nowhere, the end
    of the tabs row, or beside the number of commits."""
    rows = [
        [cell("D · Nowhere in the header", "the box's line is the only place", middle(WORK, "D")),
         cell("E · The end of the tabs row", "for the repository and all its worktrees", middle(WORK, "E")),
         cell("F · Beside the number of commits", "with history's count and its commands", middle(WORK, "F"))],
        [cell("D · The global identity", "nothing, as for most repositories", middle(GLOBAL, "D")),
         cell("E · If it always showed", "a gray circle for the global identity", middle(GLOBAL, "E+")),
         cell("F · If it always showed", "", middle(GLOBAL, "F+"))],
    ]
    w = 80 + 3 * WIDE + 2 * 48
    return rows_board("Id-Where.dc.html", "Where the initials could go", rows, w=w, stage_h=MID_H)


def stacked_board(file: str, title: str, rows: list[tuple[list[str], int]], *, w: int) -> Board:
    """Rows of cells, each row with a height of its own."""
    h = 34 + sum(36 + 12 + rh for _, rh in rows) + (len(rows) - 1) * 36 + 40
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px">'
            + "".join(f'<div class="cells">{"".join(r)}</div>' for r, _ in rows) + "</div>")
    return Board(file, title, w, h, page(title, body, w, h))


def board_g() -> Board:
    """G: a person icon at the end of the tabs row, the box's line all the
    time with the same icon, and nothing in the branch row."""
    rows = [
        [cell("G · The global identity", "a plain person icon at the end of the tabs row", middle(GLOBAL, "G")),
         cell("G · The box's line, always", "in gray, 27 points of its own", panel(GLOBAL, "G"))],
        [cell("G · From ~/work/", "the person in the email's tint", middle(WORK, "G")),
         cell("G · The same, in the box", "the icon in the tint, the name in ink", panel(WORK, "G"))],
        [cell("G · Signing on, with no key", "amber, with a triangle", middle(NO_KEY, "G")),
         cell("G · The box warns", "in the line's place, as now", panel(NO_KEY, "G"))],
    ]
    return two_rows_board("Id-G.dc.html", "G · Who, at the end of the tabs row and in the box", rows, stage_h=PANEL_H)


# The popover under G's icon, as tall as it's drawn (476 points measured).
G_POP_H = 484


def board_g_change() -> Board:
    """G where the box isn't: the tooltip, a clean worktree, the popover
    opened from the tabs row, and the sidebar. It draws api-gateway, which
    the sidebar has under acme with the work email."""
    i = WORK
    repo = "api-gateway"
    # The icon's middle: the row's 8-point inset and half the 32-point button.
    icon_x = WIDE - 8 - 16
    hover = tip_box(i.tip, 8, 40, right=True) + pointer(icon_x - 2, 20)
    pointed = middle(i, "G", hover=True, overlay=hover, repo=repo)
    clean = (f'<div class="panes">'
             f'<div class="mid" style="width:{WIDE}px;height:{MID_H}px">'
             f'{branch_overlay_wrap(title_row(i, "G", repo=repo) + branch_row(i, "G") + history(selected=1))}</div>'
             f'{commit_details(SIG_STATES[2][2], email=i.email)}</div>')
    pop = popover(repo=repo, fields=[name_field(i), Field("Email", i.email, origin_short("include"))],
                  sign=True, key=Field("Key", i.key, origin_short("include"), mono=True),
                  note=f"Commits, merges and rebases in every worktree of {repo} go out as this, an agent's too.",
                  save=False, comment="Nothing to change yet", arrow=icon_x - (WIDE - 344) - 6,
                  style=f"position:absolute;z-index:8;left:{WIDE - 344}px;top:42px")
    opened = (f'<div class="mid" style="width:{WIDE}px;height:{MID_H}px">'
              f'{branch_overlay_wrap(title_row(i, "G", hover=True, repo=repo) + branch_row(i, "G") + history())}{pop}</div>')
    side, side_h = sidebar("G", selected=repo)
    pop_h = 42 + G_POP_H
    rows = [
        ([cell("G · The pointer over it", "the tooltip decision 103 gave the initials", pointed),
          cell("G · A clean worktree", "no box, and the tabs row still says who", clean)], MID_H),
        ([cell("G · A click opens the popover", "under the icon, for the repository and its agents",
               f'<div class="stage" style="width:{WIDE}px;height:{pop_h}px">{opened}</div>'),
          cell("G · The sidebar", "the same person in the email's tint, for the exceptions",
               f'<div class="stage" style="width:312px;height:{side_h}px">{side}</div>')], max(pop_h, side_h)),
    ]
    w = 80 + WIDE + 48 + WIDE + 24 + PANEL
    return stacked_board("Id-G-Change.dc.html", "G · Seeing and changing it without a commit", rows, w=w)


PIECE_W = 260


def tabs_piece(i: Ident | None) -> str:
    """The end of the tabs row, faded on the left where it's cut."""
    return (f'<div class="trow piece" style="width:{PIECE_W}px">{tab(WORKTREE, "agent/", "add-tests", "4", "org")}'
            f'<span class="tplus">{PLUS}</span><span class="sp"></span>{tabs_mark(i)}</div>')


def board_g_states() -> Board:
    """G in every moment, in both appearances: the end of the tabs row and
    the box at the panel's default 320."""
    label_w = 230
    heights = [commit_box(i, "G", lines=[], alone=True)[1] for _, _, i in MOMENTS]
    grid_h = 24 + 20 + sum(heights) + 20 * (len(heights) - 1)
    pane_h = 34 + grid_h + 40

    def pane(theme: str, suffix: str, labels: bool) -> tuple[str, int]:
        cells = []
        if labels:
            cells.append('<span class="cap" style="height:auto"></span>')
        for caption in ("The end of the tabs row", "The box, 320 points"):
            cells.append(f'<span class="cap" style="height:auto;font-weight:600">{esc(caption + suffix)}</span>')
        for label, sub, i in MOMENTS:
            if labels:
                cells.append(f'<div class="cap" style="height:auto;padding-top:10px">{esc(label)}'
                             f'<i style="display:block;margin-top:2px">{esc(sub)}</i></div>')
            cells.append(tabs_piece(i))
            box, _ = commit_box(i, "G", lines=[], alone=True)
            cells.append(f'<div style="width:{PANEL}px">{box}</div>')
        cols = (f"{label_w}px " if labels else "") + f"{PIECE_W}px {PANEL}px"
        w = 80 + (label_w + 32 if labels else 0) + PIECE_W + 32 + PANEL
        return (f'<div class="board {theme}" style="display:block;width:{w}px;height:{pane_h}px">'
                f'<div style="display:grid;grid-template-columns:{cols};column-gap:32px;row-gap:20px;align-items:start">'
                f'{"".join(cells)}</div></div>'), w

    light, lw = pane("th-l", "", True)
    dark, dw = pane("th-d", ", dark", False)
    w = lw + 24 + dw
    body = f'<div class="panes" style="width:{w}px;height:{pane_h}px">{light}{dark}</div>'
    title = "G, moment by moment"
    return Board("Id-G-States.dc.html", title, w, pane_h, page(title, body, w, pane_h))


# ---------------------------------------------------------------- the page


def all_boards() -> list[list[Board]]:
    return [
        [board_g(), board_g_change()],
        [board_g_states()],
        [board_d(), board_where()],
        [board_today(), board_a(), board_b(), board_c()],
        [board_states(False)],
        [board_states(True)],
        [board_popover(), board_try()],
        [board_sidebar(), board_settings()],
        [board_history()],
    ]


TITLES = [
    "G: who, at the end of the tabs row and in the box",
    "G, moment by moment",
    "Before G: D, and where the initials could go",
    "Where the identity could show",
    "Every option, moment by moment",
    "The same, dark",
    "Changing it",
    "The sidebar and Settings",
    "Signed commits",
]

INTROS = [
    "Commits aren't the only thing that use the identity. A merge that isn't a fast-forward makes a commit, a rebase or a "
    "cherry-pick makes you the committer of every commit it moves, and a revert, or a pull that merges or rebases, does the same. "
    "Agents run git in their worktrees with the same config, so what they commit and merge goes out as the same person, usually "
    "while nobody is looking at the commit box, which shows only while a worktree has uncommitted files. So G puts a person icon "
    "at the end of the tabs row, which holds every worktree of the repository, the identity's scope. It keeps the box's line all "
    "the time with the person icon it has now, takes the initials out of the branch row, and marks the sidebar's exceptions with "
    "the same icon. The initials are gone everywhere, since a name rarely changes, and the email, which does, gives the tint.",
    "Each moment from decision 103's boards, with the end of the tabs row beside the box, in both appearances at the panel's "
    "default 320 points. The tabs row is cut on the left.",
    "Once decision 103 was built, the initials in the branch row looked out of place, since the row is about the branch and the "
    "identity belongs to the whole repository. D showed the box's line all the time, with the initials at its start, and nothing "
    "in the header. The second board compared D with the initials at the end of the tabs row (E) and beside history's number of "
    "commits (F). G takes E's place, always shown and with a person icon, and keeps D's line.",
    "Roga doesn't say which name and email a commit will carry, or whether it will be signed, until the commit is made (issue 115). "
    "Each board draws the middle column of the default window, 680 points wide, next to the commit panel at its default 320. "
    "Sam Rivera's ~/.gitconfig commits as sam@rivera.dev and signs with an SSH key, and ~/.gitconfig-work, which it includes for ~/work/, "
    "commits as sam.rivera@acme.com. Every option reads the same keys with one git config call and writes them with git config. "
    "They differ only in how much they show while nothing is wrong.",
    "Each option in seven moments, from the global identity to a repository with no email and signing with no key. Only the branch row "
    "and the message box are drawn. Every option warns the same way, at the top of the box where decision 98 puts what's wrong, and "
    "every option shows nothing until git config has answered, about 10 ms after the sidebar's first look at the repository.",
    "The same moments in the dark appearance. The initials' tint comes from the email, so a work identity and a personal one look "
    "different at a glance, and the tints are lighter in the dark.",
    "One popover for every place that opens it: the initials or the email in the branch row, the line or the initials in the box, a "
    "repository's row in the sidebar, and Settings. It writes to the repository's own config by default, and its command block shows "
    "exactly what Save runs (decision 29). Try it edits a copy and shows the commands as you type.",
    "The sidebar marks only the repositories whose identity isn't the global one, and the ones that couldn't commit. Settings › Git has "
    "the global identity, with the keys it writes, and lists the repositories that commit as someone else.",
    "A signed commit has a gpgsig header, which CommitParser already reads past for every commit history shows, so marking it costs "
    "nothing. Checking the signature runs gpg or ssh-keygen, so Roga checks only the selected commit, and the commit panel says what it found.",
]

NOTES = {
    "Id-D.dc.html": "The line is always at the top of the box, so the place to see who a commit goes out as, and to change it, is where the commit is made, much as GitHub Desktop puts the author's picture beside the summary. It costs 27 points of the text's height in every repository, where decision 103 spent them only on the exceptions. The circle loses its shield, since the end of the line says Signed or Not signed, and a click opens the same popover under the line.",
    "Id-G.dc.html": "The person icon at the end of the tabs row is gray for the global identity, like the row's other icon buttons, and in the email's tint for anyone else, as in the sidebar and the box's line. It has no circle, whose faint fill would turn muddy on the button's gray under the pointer. It turns amber with a triangle when a commit would go wrong, which matters most for agents, whose commits would stop at signing while nobody watches the box, and it has a small shield while commits are signed, since the box isn't there in a clean worktree, and a rebase or a cherry-pick signs each commit again. Not signing gets no mark, as on decision 103's initials. The box's line keeps the person icon it has now, gray for the global identity, and in the email's tint with the name in ink for anyone else. The branch row has nothing.",
    "Id-G-Change.dc.html": "The tabs row is there whatever the panels show, so the identity can be seen and changed in a clean worktree, before a merge or a rebase, or while an agent works. A click opens the same popover under the icon, and its note says that merges, rebases and agents use the identity too. Making a branch or a worktree doesn't use it, and a push goes out as the account the SSH key or the credential helper belongs to, which this doesn't show. The sidebar marks the same exceptions with the same person in the email's tint, in place of the initials.",
    "Id-G-States.dc.html": "Before git config has answered, the end of the tabs row is empty and the box keeps the line's room, so nothing moves when they arrive. The warnings take the line's place in the box, and the icon in the tabs row turns amber. At 320 points the work email is long enough that the words Signed and Not signed go first, and the shield stays.",
    "Id-Where.dc.html": "E is the better place in the header. The tabs row belongs to the repository, which is the identity's scope, and the end of a top row is where apps put the person who's signed in. That's also its risk, since Roga has no account, and it takes room the tabs need when there are many worktrees. F sits with history's count and its commands, so the initials would read as a filter for whose commits history shows, and they'd go first when the row is short of room. With the line in the box always there, D draws nothing in the header. If the header should still say something, E for the exceptions only would match the sidebar.",
    "Id-Today.dc.html": "On main. Nothing in the window says who a commit goes out as. The commit panel's author line shows it once the commit exists, and git commit says nothing when it makes an email up from the login and the Mac's name.",
    "Id-A.dc.html": "A draws the identity as initials in a circle, before Fetch in the branch row and before Commit in the box, the way history's author column already shows people. The tint comes from the email, so a work identity and a personal one look different, and a small shield on the circle says commits are signed. It costs no height, but the initials alone don't say which email it is until the tooltip does, and at 320 points they cost Generate the agent's name, which is the first step decision 98's row already takes when it's short of room.",
    "Id-B.dc.html": "B writes the email before Fetch, and puts a line at the top of the box with the name, the email and whether commits are signed. It's the clearest, but the line costs 27 points of the height decision 98 gave back, and the branch row's email is the first thing cut when the row is short of room.",
    "Id-C.dc.html": "C shows nothing while the identity is the global one and nothing is wrong, and says it in the branch chip's menu and Commit's tooltip. A repository that commits as someone else shows its email in the same places as B. It's the quietest, and closest to decision 48's rule of saying something only while there's something to say, but most people would never see their identity at all.",
    "Id-States.dc.html": "A shows a shield only on signed identities, since a mark for not signed on every repository would be noise for the many people who don't sign. B says Not signed in words. In C, the global identity shows nothing either way. Every option warns in the box the same way, and none shows anything before git config has answered.",
    "Id-States-Dark.dc.html": "The amber of a warning is the sidebar's, so it reads the same in the branch row, the box and the sidebar.",
    "Id-Popover.dc.html": "Each field says where its value comes from, and the switch at the bottom says where Save writes. Writing every repository's config from one repository's popover is never the default. A value from an included file can't be changed for every repository from here, because that file sets it after ~/.gitconfig, so the popover says so rather than writing something that wouldn't show. The Email field suggests the emails Roga has already read from other repositories' config, which it doesn't store.",
    "Id-Try.dc.html": "Pick where the identity comes from and how the window shows it, then edit the fields and switch where Save writes. The command block changes as you type, and Save puts the result in the branch row and the box.",
    "Id-Sidebar.dc.html": "A puts the initials at a row's right, before the count. B writes the email's domain after the name, where a branch goes. C puts the email on an organization's label when every repository under it shares one that isn't the global identity, which suits an includeIf for each employer's folder, and marks the rest as A does. A repository with no email gets decision 48's second line in amber in all three.",
    "Id-Settings.dc.html": "The Identity section writes ~/.gitconfig, as the settings boards first drew it, with signing beside the name and email. Under it are the repositories in the sidebar that commit as someone else, with where that comes from. One that sets its own value can go back to the global one, and the ones a file includes for a folder can only change in that file.",
    "Id-History.dc.html": "The shield by the hash says a commit carries a signature, not that it's good. Selecting the commit checks it with git log --format=%G? in the background, and the commit panel says what it found. git can only check an SSH signature when gpg.ssh.allowedSignersFile lists whose keys to trust, so Signed, not checked will be common, and the panel says why. An unsigned commit has no line.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tId{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nId{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Commit identity page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Commit identity boards, and optionally merge them into a canvas.json."""
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
