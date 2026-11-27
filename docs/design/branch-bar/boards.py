# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Branch bar boards for the design canvas "yaga layout options".

The row under the tabs says which branch the worktree is on, pulls and
pushes, and says what its agent is doing (decisions 95 and 100). These
boards try three other ways to fill it: A gives the branch and the agent two
lines each, with the worktree's folder under the branch; B shrinks every part
to a short label and moves the words into tooltips and popovers; C uses the
second line under the branch to say how far it is from main. In each of them
the branch's menu, which repeats Pull, Push, Fetch and New Branch, becomes a
popover about the checkout.

    uv run docs/design/branch-bar/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Every part is drawn at its size in points: the title row and the branch row
are 44 points tall, a tab 32, a row of history 28. The middle column is 680
points wide in the default window of 1280 with the sidebar and the refs panel
showing, and 480 in a narrower one.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

import click

PAGE_ID = "branchbar"
PAGE_NAME = "Branch bar"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- measures

WIDE = 680         # the middle column in the default window
NARROW = 480       # and in a narrower one
ROW_H = 28         # a row of history (CommitCellView.height)
STAGE_H = 330      # a column on the option boards
CELL_H = 104       # a cell on the moments boards: the branch row and two rows of history
POP_H = 540        # a column on the popovers board, tall enough for the checkout popover
SHORT = 600        # under this width, today's row drops history's count while an agent speaks


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--surface:#fff;--title:#f3f3f2;--line:#e2e2e2;--tx:#1f1f1e;--tx2:#6b6b66;--tx3:#a3a39e;--hov:rgba(0,0,0,.075);--bhov:rgba(0,0,0,.10);--tabon:#fff;--tabedge:#dedede;--tabsh:rgba(0,0,0,.12);--cnt:#e57a00;--act:#c94402;--warn:#9a5200;--fin:#2f6de1;--red:#cd1755;--track:#d6d6d3;--pill:rgba(0,0,0,.055);--sheet:#fff;--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2);--l1:#db1c61;--cur:#547a02;--oncur:#fff;--edge:#c9c9c4;--tip:#f6f6f6;--tiptx:#1a1a1a;--seg:#ecebe8;--segon:#fff;--new:#2f6de1}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--surface:#222;--title:#1b1b1b;--line:#393939;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--hov:rgba(255,255,255,.075);--bhov:rgba(255,255,255,.15);--tabon:#3b3b3b;--tabedge:#4d4d4d;--tabsh:rgba(0,0,0,.4);--cnt:#ff9f0a;--act:#f0813f;--warn:#f0a54a;--fin:#4c8dff;--red:#fc5884;--track:#4a4a47;--pill:rgba(255,255,255,.08);--sheet:#2a2a29;--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16);--l1:#ff3478;--cur:#a6e22e;--oncur:#272822;--edge:#62625c;--tip:#3a3a39;--tiptx:#f0f0f0;--seg:#2c2c2b;--segon:#4a4a47;--new:#4c8dff}
.board{display:flex;flex-direction:column;gap:36px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cell{display:flex;flex-direction:column;gap:12px;flex:none}
.cap{font-size:13px;font-weight:500;color:var(--wtx);height:36px;line-height:18px;overflow:hidden}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:14px;height:14px;stroke-width:2}
.ic.xs{width:11px;height:11px;stroke-width:2.4}
.ic.xxs{width:10px;height:10px;stroke-width:2.4}

.mid{position:relative;flex:none;background:var(--surface);color:var(--tx);border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.14),0 2px 8px rgba(0,0,0,.06);overflow:hidden;display:flex;flex-direction:column;font:13px/1.3 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif}
.sp{flex:1 1 0;min-width:12px}

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
.tme{width:32px;height:32px;display:grid;place-items:center;color:var(--tx2);flex:none;margin-left:auto}

.brow{position:relative;height:44px;flex:none;display:flex;align-items:center;padding:0 6px;background:var(--surface);border-bottom:1px solid var(--line);white-space:nowrap;min-width:0}
.brow button{cursor:pointer}
.tw{position:relative;display:flex;align-items:center;min-width:0;flex:0 1 auto}
/* The branch keeps its width while the agent's words are cut, and gives way
   only in a narrow column, so that a fraction of a point never cuts it. */
.tw.cw{flex:none;min-width:110px}
.tw.bw{flex:none;min-width:96px}
.tw.fw{flex:none;min-width:70px}
.narrow .tw.cw,.narrow .tw.bw,.brow.tight .tw.cw,.brow.tight .tw.bw{flex:0 1 auto}
.narrow .tw.fw{flex:0 3 auto}
.tw.aw{flex:0 1000 auto;min-width:140px;margin-left:6px}
.tw.ow{flex:none}
.fill{position:absolute;left:0;right:0;top:50%;border-radius:8px;background:var(--bhov);pointer-events:none}
.tw.h32>.fill{height:32px;margin-top:-16px}
.tw.h36>.fill{height:36px;margin-top:-18px}
.tw.h28>.fill{height:28px;margin-top:-14px;border-radius:7px}
.tw.h36>.fill.even,.brow.even .tw.ow>.fill{height:36px;margin-top:-18px}
.tw:hover>.fill{display:none}
.chip{height:32px;display:flex;align-items:center;gap:5px;padding:0 7px 0 5px;border:0;border-radius:8px;background:none;color:var(--tx);font:inherit;min-width:0;max-width:100%}
.chip:hover{background:var(--bhov)}
.chip .ic{color:var(--tx2)}
.chip .nm{min-width:0;overflow:hidden;text-overflow:ellipsis}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:12.5px}
.g{color:var(--tx2)}
.cnts{display:flex;align-items:center;flex:none}
.cnt{height:32px;min-width:32px;justify-content:center;display:flex;align-items:center;gap:3px;padding:0 6px;border-radius:8px;color:var(--tx2);flex:none;font-variant-numeric:tabular-nums;border:0;background:none;font:inherit}
.cnt.act{color:var(--act)}
.cnt:hover{background:var(--bhov)}
.stk{height:32px;display:flex;align-items:center;gap:5px;padding:0 8px;border-radius:8px;color:var(--red);flex:none}
.say{color:var(--tx2);margin-left:8px;flex:none}
.undo{height:24px;padding:0 8px;margin-left:6px;border:0;border-radius:7px;background:none;color:var(--act);font:inherit;font-weight:500;flex:none}
.al{height:32px;display:flex;align-items:center;gap:6px;padding:0 8px;border:0;border-radius:8px;background:none;color:var(--tx2);font:inherit;min-width:0;max-width:100%}
.al:hover{background:var(--bhov)}
.al .w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.al .t{flex:none}
.al.warn{color:var(--warn)}
.al.fail{color:var(--red)}
.rg{display:flex;align-items:center;gap:6px;flex:none;margin-left:12px}
.ib{width:32px;height:32px;display:grid;place-items:center;border:0;border-radius:8px;background:none;color:var(--tx2);padding:0;flex:none}
.ib:hover{background:var(--bhov)}
.ib.sm{width:26px;height:26px;border-radius:6px}
.vs{width:1px;height:18px;background:var(--line);margin:0 6px;flex:none}
.nc{color:var(--tx2);font-size:12.5px}
.narrow .nc.drop{display:none}
/* D: every control in the row is as tall as C's two-line blocks. */
.brow.even .cnt,.brow.even .stk{height:36px;min-width:36px}
.brow.even .ib{width:36px;height:36px}
.brow.even .rg{gap:3px}
.brow.even .tw.ow>.pop,.brow.even .tw.ow>.cpop{top:calc(50% + 24px)}
/* Every control's fill at once, as if the pointer were over each. */
.brow.fills .chip,.brow.fills .cnt,.brow.fills .co,.brow.fills .ag,.brow.fills .al,.brow.fills .lb,.brow.fills .ib,.brow.fills .stk{background:var(--bhov)}

.co,.ag{height:36px;display:flex;align-items:center;gap:8px;padding:0 9px 0 6px;border:0;border-radius:8px;background:none;color:var(--tx);font:inherit;min-width:0;max-width:100%;text-align:left}
.co{max-width:300px}
.co:hover,.ag:hover{background:var(--bhov)}
.co>.ic{color:var(--tx2)}
.two{display:flex;flex-direction:column;justify-content:center;min-width:0;gap:1px}
.l1{display:flex;align-items:baseline;min-width:0;font-size:13px;line-height:16px;white-space:nowrap}
.l2{display:flex;align-items:center;gap:0;min-width:0;font-size:11px;line-height:14px;color:var(--tx2);white-space:nowrap}
.cut{min-width:0;overflow:hidden;text-overflow:ellipsis}
.keep{flex:none}
.l2 .o{color:var(--act)}
.l2 .lk{margin-right:3px;display:flex}
.ag .l1 .t{color:var(--tx2);flex:none}
.ag .short,.narrow .ag .long{display:none}
.narrow .ag .short{display:block}
.ag.warn .l1{color:var(--warn)}
.ag.fail .l1{color:var(--red)}
.shim{background:linear-gradient(90deg,var(--tx2) 0%,var(--tx2) 38%,var(--act) 50%,var(--tx2) 62%,var(--tx2) 100%);background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:bbshim 2.4s linear infinite}
@keyframes bbshim{from{background-position:100% 0}to{background-position:0 0}}
@media (prefers-reduced-motion:reduce){.shim{animation:none;background:none;color:var(--tx2)}}
.lb{height:32px;display:flex;align-items:center;gap:5px;padding:0 7px;border:0;border-radius:8px;background:none;color:var(--tx);font:inherit;min-width:0;max-width:100%}
.lb:hover{background:var(--bhov)}
.lb>.ic{color:var(--tx2)}
.lb .w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.lb .t{color:var(--tx2);flex:none}
.lb.warn{color:var(--warn)}
.lb.fail{color:var(--red)}
.lb.quiet{color:var(--tx2)}

.hist{position:relative;flex:1;min-height:0;overflow:hidden;padding-top:4px}
.lane{position:absolute;left:17px;width:2px;background:var(--l1);top:0;bottom:0}
.lane.wt{background:none;border-left:2px dotted var(--tx3);width:0}
.hr{position:relative;height:28px;display:flex;align-items:center;gap:8px;padding:0 12px 0 36px;white-space:nowrap;min-width:0}
.hr .dot{position:absolute;left:12px;top:9px;width:12px;height:12px;border-radius:50%;background:var(--l1);box-shadow:0 0 0 2px var(--surface)}
.hr .dot.wt{background:var(--surface);border:2px solid var(--tx3)}
.hr .msg{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}
.hr.wt .msg{color:var(--tx2);flex:none}
.hr .au{margin-left:auto;color:var(--tx2);font-size:12px;flex:none}
.hr .hs{color:var(--tx2);font:11.5px ui-monospace,"SF Mono",Menlo,monospace;flex:none;width:58px;text-align:right}
.bdg{display:inline-block;font-size:11.5px;line-height:16px;padding:0 6px;border-radius:5px;border:1px solid var(--edge);color:var(--tx);margin-right:6px}
.bdg.cur{background:var(--cur);border-color:var(--cur);color:var(--oncur)}

.mk{position:relative;width:14px;height:14px;flex:none;display:block}
.mk svg{position:absolute;left:0;top:0;width:14px;height:14px;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.mk .trk{stroke:var(--track)}
.mk .arc{stroke:var(--act);animation:bbspin 1s linear infinite;transform-origin:50% 50%}
.mk .alert{stroke:var(--warn)}
.mk .done{stroke:var(--tx2)}
.mk .fail{stroke:var(--red)}
.mk .tri{stroke:var(--red)}
@keyframes bbspin{to{transform:rotate(360deg)}}
@media (prefers-reduced-motion:reduce){.mk .arc{animation:none}}

.tip{position:absolute;z-index:6;left:4px;top:calc(100% + 8px);width:max-content;max-width:330px;padding:5px 9px;border-radius:6px;background:var(--tip);color:var(--tiptx);font-size:11.5px;line-height:15px;white-space:pre-line;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 6px 16px rgba(0,0,0,.16);visibility:hidden;opacity:0;transition:opacity .1s 0s;pointer-events:none;font-weight:400;text-align:left}
.tw:hover>.tip{visibility:visible;opacity:1;transition-delay:.8s}
.tw>.tip.show{visibility:visible;opacity:1}
.fill~.tip{display:none}
.ptr{position:absolute;z-index:7;width:12px;height:18px;pointer-events:none}

.pop,.cpop{position:absolute;z-index:5;left:-6px;top:calc(100% + 6px);background:var(--sheet);color:var(--tx);border-radius:10px;box-shadow:var(--msh);white-space:normal;text-align:left;font-size:13px;line-height:1.3}
.pop{width:340px}
.cpop{width:400px;left:-2px}
.pop::before,.cpop::before{content:"";position:absolute;left:24px;top:-6px;width:12px;height:12px;background:var(--sheet);transform:rotate(45deg);box-shadow:-.5px -.5px 0 0 rgba(0,0,0,.14)}
.tw.h36>.pop,.tw.h36>.cpop{top:calc(50% + 24px)}
.tw.h32>.pop,.tw.h32>.cpop{top:calc(50% + 22px)}
.tw.h28>.pop,.tw.h28>.cpop{top:calc(50% + 20px)}
.narrow .tw.aw>.pop,.tw.aw>.pop.right{left:auto;right:-6px}
.narrow .tw.aw>.pop::before,.tw.aw>.pop.right::before{left:auto;right:24px}
.ps{position:relative;display:flex;flex-direction:column;gap:3px;padding:11px 14px 11px}
.ps+.ps{border-top:1px solid var(--line)}
.p1{display:flex;align-items:center;gap:7px;height:18px}
.p1 b{font-weight:600}
.p1 .st{color:var(--tx2)}
.p1 .st.warn{color:var(--warn)}
.p1 .st.fail{color:var(--red)}
.p1 .t{margin-left:auto;color:var(--tx2);font-size:12px}
.p2{padding-left:21px;font-size:13px;line-height:17px;color:var(--tx)}
.p3{padding-left:21px;font-size:12px;line-height:16px;color:var(--tx2)}
.pf{display:flex;gap:4px;padding:6px;border-top:1px solid var(--line)}
.pb{height:28px;display:flex;align-items:center;gap:6px;padding:0 8px;border:0;border-radius:6px;background:none;color:var(--tx);font:inherit;font-size:13px}
.pb:hover{background:var(--bhov)}
.pb .ic{color:var(--tx2)}
.ch{display:flex;align-items:center;gap:9px;padding:12px 10px 11px 14px}
.ch>.ic{color:var(--tx2)}
.ch b{font-weight:600;font-size:13px;line-height:16px;overflow-wrap:anywhere}
.ch .sub{color:var(--tx2);font-size:12px;line-height:15px}
.kv{display:grid;grid-template-columns:64px 1fr;column-gap:10px;padding:10px 14px 11px;border-top:1px solid var(--line);font-size:12.5px;line-height:17px}
.kv .k{color:var(--tx2)}
.kv .v{min-width:0;overflow-wrap:anywhere}
.kv .v2{color:var(--tx2)}
.kv .v2 .o{color:var(--act)}
.kv .nw{display:inline-block;margin-left:6px;padding:0 5px;border-radius:4px;font-size:10.5px;line-height:15px;color:var(--new);box-shadow:inset 0 0 0 1px var(--new);vertical-align:1px}
.acts{display:flex;gap:6px;flex-wrap:wrap;margin-top:7px}
.btn{height:24px;padding:0 9px 0 7px;border-radius:6px;border:0;background:var(--pill);color:var(--tx);font:inherit;font-size:12px;display:flex;align-items:center;gap:5px;cursor:pointer}
.btn .ic{color:var(--tx2)}
.btn:hover{background:var(--bhov)}

.st-grid{display:grid;column-gap:32px;row-gap:16px;align-items:start}
.st-h{font-size:13px;font-weight:600;color:var(--wtx)}
.st-l{font-size:13px;font-weight:500;color:var(--wtx);padding-top:12px}
.st-l i{display:block;font-style:normal;font-weight:400;color:var(--wtx2);margin-top:2px}

.sheet{display:flex;flex-direction:column;gap:18px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden;padding:28px}
.bar{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center}
.grp{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--wtx2)}
.seg{display:flex;flex-wrap:wrap;background:var(--seg);border-radius:8px;padding:2px;gap:2px}
.sg{border:0;background:none;font:inherit;font-size:12.5px;color:var(--wtx2);height:26px;padding:0 10px;border-radius:6px;cursor:pointer}
.sg.on{background:var(--segon);color:var(--wtx);font-weight:500;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.main{display:flex;gap:28px;align-items:flex-start}
.side{display:flex;flex-direction:column;gap:12px;width:330px;flex:none}
.meta{font-size:12.5px;color:var(--wtx2);line-height:1.45}
.meta b{color:var(--wtx);font-weight:600}
"""


# ---------------------------------------------------------------- icons


def _ic(paths: str, cls: str = "ic") -> str:
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{paths}</svg>'


# Lucide's, as docs/design/icons/lucide has them, except Fetch, which is the
# arrow the earlier boards draw for the button the house drops through.
P_CHEV = '<path d="m6 9 6 6 6-6"></path>'
P_BRANCH = '<path d="M15 6a9 9 0 0 0-9 9V3"></path><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle>'
P_NEWBRANCH = '<path d="M6 3v12"></path><path d="M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path><path d="M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6z"></path><path d="M15 6a9 9 0 0 0-9 9"></path><path d="M18 15v6"></path><path d="M21 18h-6"></path>'
P_FETCH = '<path d="M12 2v9"></path><path d="m8 7 4 4 4-4"></path><circle cx="12" cy="18" r="3"></circle>'
P_PUSH = '<path d="m5 9 7-7 7 7"></path><path d="M12 16V2"></path><circle cx="12" cy="21" r="1"></circle>'
P_PULL = '<path d="M12 2v14"></path><path d="m19 9-7 7-7-7"></path><circle cx="12" cy="21" r="1"></circle>'
P_SORT = '<path d="m21 16-4 4-4-4"></path><path d="M17 20V4"></path><path d="m3 8 4-4 4 4"></path><path d="M7 4v16"></path>'
P_REPO = '<circle cx="12" cy="13" r="2"></circle><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"></path><path d="M14 13h3"></path><path d="M7 13h3"></path>'
P_WORKTREE = '<path d="M18 19a5 5 0 0 1-5-5v8"></path><path d="M9 20H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v5"></path><circle cx="13" cy="12" r="2"></circle><circle cx="20" cy="19" r="2"></circle>'
P_OPEN = '<path d="m6 14 1.5-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.54 6a2 2 0 0 1-1.95 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H18a2 2 0 0 1 2 2v2"></path>'
P_COPY = '<rect width="14" height="14" x="8" y="8" rx="2" ry="2"></rect><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path>'
P_TERM = '<path d="M12 19h8"></path><path d="m4 17 6-6-6-6"></path>'
P_LOCK = '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path>'
P_COMMIT = '<circle cx="12" cy="12" r="3"></circle><line x1="3" x2="9" y1="12" y2="12"></line><line x1="15" x2="21" y1="12" y2="12"></line>'
P_USER = '<path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle>'
P_PLUS = '<path d="M5 12h14"></path><path d="M12 5v14"></path>'
P_TRI = '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path>'
P_DIFF = '<path d="M12 3v14"></path><path d="M5 10h14"></path><path d="M5 21h14"></path>'
P_MERGE = '<circle cx="18" cy="18" r="3"></circle><circle cx="6" cy="6" r="3"></circle><path d="M6 21V9a9 9 0 0 0 9 9"></path>'

CHEV = _ic(P_CHEV, "ic xs")
BRANCH = _ic(P_BRANCH, "ic s")
BRANCH16 = _ic(P_BRANCH)
COMMIT = _ic(P_COMMIT, "ic s")
COMMIT16 = _ic(P_COMMIT)
NEWBRANCH = _ic(P_NEWBRANCH)
FETCH = _ic(P_FETCH)
PUSH = _ic(P_PUSH, "ic s")
PULL = _ic(P_PULL, "ic s")
SORT = _ic(P_SORT)
REPO = _ic(P_REPO, "ic s")
WORKTREE = _ic(P_WORKTREE, "ic s")
OPEN = _ic(P_OPEN, "ic s")
COPY = _ic(P_COPY, "ic s")
TERM = _ic(P_TERM, "ic s")
LOCK = _ic(P_LOCK, "ic s")
LOCK_XS = _ic(P_LOCK, "ic xxs")
USER = _ic(P_USER)
PLUS = _ic(P_PLUS, "ic s")
TRI = _ic(P_TRI, "ic s")
DIFF = _ic(P_DIFF, "ic s")
MERGE = _ic(P_MERGE, "ic s")

RING = ('<span class="mk"><svg class="trk" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5"></circle></svg>'
        '<svg class="arc" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5A5.5 5.5 0 0 1 13.5 8"></path></svg></span>')
WAIT = ('<span class="mk"><svg class="alert" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<line x1="12" x2="12" y1="8" y2="12"></line><line x1="12" x2="12.01" y1="16" y2="16"></line></svg></span>')
DONE = ('<span class="mk"><svg class="done" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<path d="m9 12 2 2 4-4"></path></svg></span>')
FAIL = ('<span class="mk"><svg class="fail" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<path d="m15 9-6 6"></path><path d="m9 9 6 6"></path></svg></span>')
CONFLICT = f'<span class="mk"><svg class="tri" viewBox="0 0 24 24" aria-hidden="true">{P_TRI}</svg></span>'
MARK = {"working": RING, "waiting": WAIT, "finished": DONE, "failed": FAIL}

POINTER = ('<svg class="ptr" style="{style}" viewBox="0 0 12 18" aria-hidden="true">'
           '<path d="M1 1v14l3.6-3.4 2.6 5.6 2.2-1-2.6-5.4H12z" fill="#000" stroke="#fff" stroke-width="1"></path></svg>')


# ---------------------------------------------------------------- what's drawn


@dataclass
class Agent:
    state: str               # working, waiting, finished or failed
    words: str               # the helper's line; the command it asks to run; or the reply's first line
    time: str = ""           # "6 min", or "3 min ago" once it has finished
    who: str = "Claude Code"
    asks: str = ""           # while waiting: "approval" for a tool, "answer" for a question
    subagents: int = 0


@dataclass
class Scene:
    branch: str | None = "agent/fix-login"     # None while HEAD is detached
    head: str = "48ba644"
    folder: str = "~/git/roga/.claude/worktrees/fix-login"
    main_wt: bool = False                       # the repository's own folder
    upstream: str | None = "origin/agent/fix-login"
    ahead: int = 2
    behind: int = 0
    first_push: bool = False                    # never pushed, so ↑ pushes it for the first time
    base_ahead: int = 4                         # commits on the branch that origin/main doesn't have
    base_behind: int = 12                       # commits on origin/main that the branch doesn't have
    # The files a merge of origin/main would conflict in, as
    # git merge-tree --write-tree origin/main HEAD lists them after a fetch.
    would_conflict: list[str] = field(default_factory=list)
    agents: list[Agent] = field(default_factory=list)
    files: int = 3
    roga: str = ""                              # what Roga says after the counts, as "Committed 9f2c1ab"
    stuck: str = ""                             # what replaces the counts, as "Rebasing · 2 conflicts"
    locked: str = ""                            # the lock's reason
    fetched: str = "4 min ago"
    fetch_failed: bool = False                  # the last fetch couldn't reach origin

    @property
    def name(self) -> str:
        return self.branch or self.head

    @property
    def lead(self) -> Agent | None:
        """The session one line speaks for: one waiting for you, then one
        working, then the rest, as the sidebar ranks them."""
        for state in ("waiting", "failed", "working", "finished"):
            for a in self.agents:
                if a.state == state:
                    return a
        return None

    @property
    def speaks(self) -> bool:
        """Whether the agent has the place after the counts, which Roga's own
        words take while they show (decision 100)."""
        return bool(self.agents) and not self.roga


def working(words: str, time: str = "6 min", **kw) -> Agent:
    return Agent("working", words, time, **kw)


RUN_TESTS = working("Run the test suite", subagents=2)
APPROVAL = Agent("waiting", "git push", "2 min", asks="approval")
FINISHED = Agent("finished", "Added the lockout tests and updated the changelog", "3 min ago")
CODEX_PUSH = Agent("waiting", "git push", "1 min", who="Codex", asks="approval")
EDITING = working("Editing LoginView.swift", "3 min")

MAIN_SCENE = Scene(branch="main", folder="~/git/roga", main_wt=True, upstream="origin/main", ahead=0, behind=0,
                   base_ahead=0, base_behind=0, files=0)
WORKING = Scene(agents=[RUN_TESTS])
TWO_AGENTS = Scene(agents=[CODEX_PUSH, RUN_TESTS])
WOULD_CONFLICT = Scene(agents=[FINISHED], base_behind=15, would_conflict=["LoginView.swift", "LoginStore.swift"])
LOCKED_NEW = Scene(branch="agent/rate-limits", folder="~/git/roga/.claude/worktrees/rate-limits", upstream=None,
                   first_push=True, ahead=0, base_ahead=3, base_behind=0, files=1, locked="In use by Claude Code",
                   agents=[working("Reading RateLimiter.swift", "1 min")])

# The moments every option is drawn in, with a short name for Try it.
STATES: list[tuple[str, str, str, Scene]] = [
    ("Main", "The main worktree, quiet", "Nothing running, up to date", MAIN_SCENE),
    ("Working", "An agent working", "The helper's line, and how long", WORKING),
    ("Approval", "Waiting for approval", "Amber, like the tab's mark", Scene(agents=[APPROVAL], files=0, ahead=3)),
    ("Finished", "Finished", "The reply's first line, until the next turn", Scene(agents=[FINISHED])),
    ("Would conflict", "Merging main would conflict", "C's line turns orange only now",
     WOULD_CONFLICT),
    ("Two agents", "Two agents, one waiting", "The waiting one speaks for both", TWO_AGENTS),
    ("Committed", "Roga says what just happened", "Its words take the agent's place for 8 seconds",
     Scene(agents=[FINISHED], files=0, ahead=3, roga="Committed 9f2c1ab")),
    ("Rebasing", "Stopped partway, with conflicts", "The conflicts replace the counts",
     Scene(agents=[EDITING], stuck="Rebasing · 2 conflicts", files=2)),
    ("Detached", "Detached HEAD", "A commit rather than a branch",
     Scene(branch=None, upstream=None, ahead=0, base_ahead=0, base_behind=0, files=0)),
    ("Not pushed", "Never pushed", "↑ pushes it for the first time",
     Scene(branch="agent/rate-limits", folder="~/git/roga/.claude/worktrees/rate-limits", upstream=None, first_push=True,
           ahead=0, base_ahead=3, base_behind=0, files=1, agents=[working("Reading RateLimiter.swift", "1 min")])),
    ("Offline", "The last fetch failed", "C says how old its numbers are",
     Scene(agents=[RUN_TESTS], fetch_failed=True, fetched="2 h ago")),
    ("Locked", "A locked worktree", "git worktree lock, with its reason",
     Scene(locked="In use by Claude Code", agents=[RUN_TESTS])),
]

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


# ---------------------------------------------------------------- words


def plural(n: int, word: str) -> str:
    return f"{n:,} {word}{'' if n == 1 else 's'}"


def summary(s: Scene) -> str:
    """The branch's first line today: its upstream, how far it is from it,
    and when Roga last fetched (BranchModel.summary)."""
    if s.fetch_failed:
        return f"couldn't reach origin · fetched {s.fetched}"
    if s.branch is None:
        return f"Detached at {s.head} · fetched {s.fetched}"
    if s.first_push:
        return f"Not pushed yet · fetched {s.fetched}"
    if s.ahead and s.behind:
        rel = f"{s.behind} behind, {s.ahead} ahead"
    elif s.behind:
        rel = f"{s.behind} behind"
    elif s.ahead:
        rel = f"{s.ahead} ahead"
    else:
        rel = "up to date"
    return f"{s.upstream} · {rel} · fetched {s.fetched}"


def state_words(a: Agent) -> str:
    """What the agent's first line, or the popover, says after its name."""
    if a.state == "working":
        return "is working"
    if a.state == "waiting":
        return "needs approval" if a.asks == "approval" else "is waiting for you"
    if a.state == "finished":
        return "finished"
    return "stopped with an error"


def today_words(s: Scene) -> str:
    """Today's single line (decision 100), with the app's words for approval
    from decision 72."""
    a = s.lead
    if a is None:
        return ""
    if len(s.agents) > 1 and all(x.state == "working" for x in s.agents):
        return f"{len(s.agents)} agents working"
    if a.state == "waiting" and a.asks == "approval":
        w = f"Approval required: {a.words}"
    elif a.state == "failed":
        w = f"{a.who} stopped with an error"
    else:
        w = a.words
    return f"{a.who}: {w}" if len(s.agents) > 1 else w


def two_lines(s: Scene) -> tuple[str, str, str, str]:
    """A's and C's agent block: what state it's in, what it's doing, how long,
    and its tone."""
    a = s.lead
    assert a is not None
    others = [x for x in s.agents if x is not a]
    if others and all(x.state == "working" for x in s.agents):
        first = f"{a.who} and {others[0].who} are working"
    else:
        first = f"{a.who} {state_words(a)}"
    line = "It stopped before the end of its turn" if a.state == "failed" else a.words
    if others and not first.endswith("are working"):
        o = others[0]
        line += f" · {o.who} {state_words(o)} too" if o.state == a.state else f" · {o.who} {state_words(o)}"
    tone = {"waiting": " warn", "failed": " fail"}.get(a.state, "")
    return first, line, a.time, tone


def tone_of(s: Scene) -> str:
    a = s.lead
    return {"waiting": " warn", "failed": " fail"}.get(a.state, "") if a else ""


def push_help(s: Scene) -> str:
    if s.first_push:
        return f"Push {s.name} to origin for the first time\ngit push -u origin {s.name}"
    return f"Push {plural(s.ahead, 'commit')} from {s.name} to {s.upstream}\ngit push"


def pull_help(s: Scene) -> str:
    return f"Pull {plural(s.behind, 'commit')} from {s.upstream} into {s.name}\ngit pull --ff-only"


def folder_parts(folder: str) -> tuple[str, str]:
    head, _, tail = folder.rpartition("/")
    return (head + "/", tail) if head else ("", tail)


def folder_html(s: Scene) -> str:
    """The folder on A's second line, cut in its middle as macOS cuts paths,
    so that its last part, which names the worktree, stays."""
    head, tail = folder_parts(s.folder)
    lock = f'<span class="keep lk">{LOCK_XS}</span>' if s.locked else ""
    return f'{lock}<span class="cut">{esc(head)}</span><span class="keep">{esc(tail)}</span>'


def relation_html(s: Scene) -> str:
    """C's second line: how far the branch is from origin/main, or for main
    itself, from its upstream.

    It compares with origin/main rather than the local main, which goes
    stale unless someone pulls it, while Roga's own fetches keep origin/main
    current. How far ahead always shows, since it's how much work the branch
    holds. How far behind shows only when it isn't zero, and in gray, since
    most branches that are behind still merge cleanly. Only a merge that
    would conflict is orange, and it's never cut. After a fetch that failed,
    the line says how old its numbers are."""
    lock = f'<span class="keep lk">{LOCK_XS}</span>' if s.locked else ""
    if s.branch is None:
        return '<span class="cut">Not on a branch</span>'
    if s.branch == "main":
        return f'{lock}<span class="cut">{esc(summary(s))}</span>'
    if s.would_conflict:
        # The line says the most pressing thing about main, and how far
        # ahead gives way to it. The popover still has both.
        text = f"{s.base_behind} behind origin/main"
    elif s.base_ahead and s.base_behind:
        text = f"{s.base_ahead} ahead, {s.base_behind} behind origin/main"
    elif s.base_behind:
        text = f"{s.base_behind} behind origin/main"
    elif s.base_ahead:
        text = f"{s.base_ahead} ahead of origin/main"
    else:
        text = "Same as origin/main"
    if s.first_push:
        text += " · not pushed yet"
    if s.fetch_failed:
        text += f" · as of {s.fetched}"
    n = len(s.would_conflict)
    clash = f'<span class="keep o">&nbsp;· {plural(n, "file")} would conflict</span>' if n else ""
    return f'{lock}<span class="cut">{esc(text)}</span>{clash}'


# ---------------------------------------------------------------- the middle column


def tab(icon_html: str, folder: str, name: str, badge: str = "", badge_cls: str = "", *, on: bool = False) -> str:
    fo = f'<span class="fo">{esc(folder)}</span>' if folder else ""
    return (f'<span class="tab{" on" if on else ""}">{icon_html}<span class="nm">{fo}{esc(name)}</span>'
            f'<span class="bd {badge_cls}">{esc(badge)}</span></span>')


def title_row(s: Scene) -> str:
    lead = s.lead
    if lead and lead.state == "waiting":
        m = WAIT
    elif s.stuck:
        m = CONFLICT
    elif lead and lead.state == "working":
        m = RING
    elif s.locked:
        m = LOCK
    else:
        m = WORKTREE
    if s.stuck:
        badge, cls = "2", "red"
    elif s.files:
        badge, cls = str(s.files), "org"
    elif s.ahead:
        badge, cls = f"↑{s.ahead}", ""
    else:
        badge, cls = "", ""
    if s.main_wt:
        here = [tab(REPO, "", "roga", on=True), '<i class="tsep"></i>', tab(WORKTREE, "agent/", "fix-login", "3", "org")]
    elif s.branch is None:
        here = [tab(REPO, "", "roga"), '<i class="tsep"></i>', tab(m, "", s.head, badge, cls, on=True)]
    else:
        folder, _, leaf = s.branch.rpartition("/")
        here = [tab(REPO, "", "roga"), '<i class="tsep"></i>', tab(m, folder + "/" if folder else "", leaf, badge, cls, on=True)]
    tabs = here + [tab(WORKTREE, "agent/", "add-tests", "4", "org"), f'<span class="tplus">{PLUS}</span>',
                   f'<span class="tme">{USER}</span>']
    return f'<div class="trow">{"".join(tabs)}</div>'


@dataclass
class Hooks:
    """What a bar hangs off its buttons: the popovers, open or wrapped in
    Try it's switches, the fills that show a button is open, and what a click
    does."""
    co_pop: str = ""      # under the branch, or C's and A's checkout block
    fl_pop: str = ""      # under B's folder
    ag_pop: str = ""      # under the agent
    co_fill: str = ""
    fl_fill: str = ""
    ag_fill: str = ""
    co_click: str = ""
    fl_click: str = ""
    ag_click: str = ""
    tip_on: str = ""      # "co", "fl", "ag", "cnt": a tooltip drawn open
    row: str = ""         # classes for the row, as " fills" to draw every control's fill

    @staticmethod
    def open(which: str, pop: str) -> "Hooks":
        fill = '<i class="fill"></i>'
        return Hooks(**{f"{which}_pop": pop, f"{which}_fill": fill})


def wrap(inner: str, cls: str, *, tip: str = "", tip_on: bool = False, pop: str = "", fill: str = "") -> str:
    t = f'<span class="tip{" show" if tip_on else ""}">{esc(tip)}</span>' if tip else ""
    return f'<span class="tw {cls}">{fill}{inner}{t}{pop}</span>'


def tight(s: Scene) -> str:
    """Conflicts and an agent together leave too little room for the
    branch, which then gives way too. A real row would measure."""
    return " tight" if s.stuck and s.speaks else ""


def counts(s: Scene, h: Hooks) -> str:
    if s.stuck:
        return f'<span class="stk">{TRI}<span>{esc(s.stuck)}</span>{CHEV}</span>'
    out = []
    if s.first_push:
        out.append(wrap(f'<button class="cnt act" type="button" aria-label="Push for the First Time">{PUSH}</button>', "ow h32",
                        tip=push_help(s), tip_on=h.tip_on == "cnt"))
    if s.behind:
        out.append(wrap(f'<button class="cnt act" type="button">{PULL}{s.behind}</button>', "ow h32", tip=pull_help(s)))
    if s.ahead and not s.first_push:
        out.append(wrap(f'<button class="cnt act" type="button">{PUSH}{s.ahead}</button>', "ow h32",
                        tip=push_help(s), tip_on=h.tip_on == "cnt"))
    return f'<span class="cnts">{"".join(out)}</span>' if out else ""


def roga_words(s: Scene) -> str:
    if not s.roga:
        return ""
    return f'<span class="say">{esc(s.roga)}</span><button class="undo" type="button">Undo</button>'


def right_end(s: Scene, *, count: bool) -> str:
    """Fetch, New Branch, a line, and history's order. Today's row has the
    number of commits before the order, and drops it in a narrow column while
    an agent speaks. The others move the number into the order's menu."""
    c = f'<span class="nc{" drop" if s.speaks else ""}">128 commits</span>' if count else ""
    return (f'<span class="rg"><span class="ib">{FETCH}</span><span class="ib">{NEWBRANCH}</span>'
            f'<i class="vs"></i>{c}<span class="ib">{SORT}</span></span>')


def name_html(s: Scene) -> str:
    if s.branch is None:
        return f'<span class="mono keep">{esc(s.head)}</span><span class="g keep">&nbsp;detached</span>'
    return f'<span class="cut">{esc(s.branch)}</span>'


def bar_today(s: Scene, h: Hooks, narrow: bool = False) -> str:
    icon = COMMIT if s.branch is None else BRANCH
    name = (f'<span class="mono">{esc(s.head)}</span><span class="g">detached</span>' if s.branch is None
            else f'<span class="nm">{esc(s.branch)}</span>')
    parts = [wrap(f'<button class="chip" type="button"{h.co_click}>{icon}{name}{CHEV}</button>', "bw h32",
                  tip=summary(s), tip_on=h.tip_on == "co", pop=h.co_pop, fill=h.co_fill),
             counts(s, h), roga_words(s)]
    if s.speaks:
        a = s.lead
        t = f'<span class="t">&nbsp;· {esc(a.time)}</span>' if a.time and a.state != "finished" else ""
        btn = (f'<button class="al{tone_of(s)}" type="button"{h.ag_click}>{MARK[a.state]}'
               f'<span class="w">{esc(today_words(s))}</span>{t}</button>')
        parts.append(wrap(btn, "aw h32", tip=f"{today_words(s)}" + (f" · {a.time}" if a.time else ""),
                          tip_on=h.tip_on == "ag", pop=h.ag_pop, fill=h.ag_fill))
    parts.append('<span class="sp"></span>')
    parts.append(right_end(s, count=True))
    return f'<div class="brow{tight(s)}{h.row}">{"".join(parts)}</div>'


def agent_block(s: Scene, h: Hooks) -> str:
    """A's and C's agent: its mark, then what state it's in over what it's doing."""
    a = s.lead
    first, line, time, tone = two_lines(s)
    t = f'<span class="t">&nbsp;· {esc(time)}</span>' if time else ""
    shim = " shim" if a.state == "working" else ""
    # In a narrow column the first line says only whose it is, as a
    # ViewThatFits would pick, and the mark and the color say the rest.
    short = a.who if len(s.agents) == 1 else f"{a.who} +{len(s.agents) - 1}"
    btn = (f'<button class="ag{tone}" type="button"{h.ag_click}>{MARK[a.state]}<span class="two">'
           f'<span class="l1"><span class="cut long">{esc(first)}</span><span class="cut short">{esc(short)}</span>{t}</span>'
           f'<span class="l2"><span class="cut{shim}">{esc(line)}</span></span></span></button>')
    return wrap(btn, "aw h36", tip=f"{first}: {line}" + (f" · {time}" if time else ""),
                tip_on=h.tip_on == "ag", pop=h.ag_pop, fill=h.ag_fill)


def bar_two(s: Scene, h: Hooks, option: str) -> str:
    """A: the branch over its folder. C: the branch over how far it is from
    main. D: C, with every control in the row as tall as its two-line blocks."""
    icon = COMMIT16 if s.branch is None else BRANCH16
    second = folder_html(s) if option == "A" else relation_html(s)
    tip = summary(s) if option == "A" else f"{s.folder}\n{summary(s)}"
    btn = (f'<button class="co" type="button"{h.co_click}>{icon}<span class="two">'
           f'<span class="l1">{name_html(s)}</span><span class="l2">{second}</span></span></button>')
    parts = [wrap(btn, "cw h36", tip=tip, tip_on=h.tip_on == "co", pop=h.co_pop, fill=h.co_fill),
             counts(s, h), roga_words(s)]
    if s.speaks:
        parts.append(agent_block(s, h))
    parts.append('<span class="sp"></span>')
    parts.append(right_end(s, count=False))
    even = " even" if option == "D" else ""
    return f'<div class="brow{tight(s)}{even}{h.row}">{"".join(parts)}</div>'


def bar_labels(s: Scene, h: Hooks) -> str:
    """B: a label for the folder, one for the branch, and one for the agent,
    each with a tooltip, each opening a popover."""
    head, leaf = folder_parts(s.folder)
    fl_icon = REPO if s.main_wt else (LOCK if s.locked else WORKTREE)
    fl = (f'<button class="lb quiet" type="button"{h.fl_click}>{fl_icon}<span class="w">{esc(leaf)}</span></button>')
    icon = COMMIT if s.branch is None else BRANCH
    br_name = (f'<span class="mono">{esc(s.head)}</span>' if s.branch is None else f'<span class="w">{esc(s.branch)}</span>')
    br = f'<button class="lb" type="button"{h.co_click}>{icon}{br_name}</button>'
    parts = [wrap(fl, "fw h32", tip=s.folder + (f"\nLocked: {s.locked}" if s.locked else ""), tip_on=h.tip_on == "fl",
                  pop=h.fl_pop, fill=h.fl_fill),
             wrap(br, "bw h32", tip=summary(s), tip_on=h.tip_on == "co", pop=h.co_pop, fill=h.co_fill),
             counts(s, h), roga_words(s)]
    if s.speaks:
        a = s.lead
        who = a.who if len(s.agents) == 1 else f"{a.who} +{len(s.agents) - 1}"
        t = f'<span class="t">&nbsp;· {esc(a.time)}</span>' if a.time and a.state != "finished" else ""
        first, line, time, _ = two_lines(s)
        btn = f'<button class="lb{tone_of(s)}" type="button"{h.ag_click}>{MARK[a.state]}<span class="w">{esc(who)}</span>{t}</button>'
        parts.append(wrap(btn, "aw h32", tip=f"{first}: {line}" + (f" · {time}" if time else ""),
                          tip_on=h.tip_on == "ag", pop=h.ag_pop, fill=h.ag_fill))
    parts.append('<span class="sp"></span>')
    parts.append(right_end(s, count=False))
    return f'<div class="brow{tight(s)}{h.row}">{"".join(parts)}</div>'


def bar(s: Scene, option: str, h: Hooks | None = None) -> str:
    h = h or Hooks()
    if option == "today":
        return bar_today(s, h)
    if option == "B":
        return bar_labels(s, h)
    return bar_two(s, h, option)


def history(s: Scene, rows: int = 8) -> str:
    out = ['<div class="hist">']
    wt = s.files > 0
    lane_top = 4 + ROW_H + 14 if wt else 18
    out.append(f'<i class="lane" style="top:{lane_top}px"></i>')
    if wt:
        out.append(f'<i class="lane wt" style="top:{4 + 21}px;height:{ROW_H - 12}px"></i>')
        out.append(f'<div class="hr wt"><span class="dot wt"></span><span class="msg">{esc(plural(s.files, "uncommitted file"))}</span></div>')
    commits = COMMITS[3:] if s.main_wt else COMMITS
    for n, (badges, msg, au, hs) in enumerate(commits[: rows - (1 if wt else 0)]):
        if s.main_wt and n == 0:
            badges = ["cur:main"]
        if s.branch is None and n == 0:
            badges = ["agent/fix-login"]
        b = "".join(f'<span class="bdg{" cur" if x.startswith("cur:") else ""}">{esc(x.removeprefix("cur:"))}</span>' for x in badges)
        out.append(f'<div class="hr"><span class="dot"></span><span class="msg">{b}{esc(msg)}</span>'
                   f'<span class="au">{au}</span><span class="hs">{hs}</span></div>')
    out.append("</div>")
    return "".join(out)


def middle(s: Scene, option: str, width: int, height: int, *, tabs: bool = True, h: Hooks | None = None,
           rows: int = 8, extra: str = "") -> str:
    narrow = " narrow" if width < SHORT else ""
    parts = [title_row(s)] if tabs else []
    parts.append(bar(s, option, h))
    parts.append(history(s, rows))
    return f'<div class="mid{narrow}" style="width:{width}px;height:{height}px">{"".join(parts)}{extra}</div>'


# ---------------------------------------------------------------- popovers


def kv(key: str, value: str, second: str = "", acts: list[tuple[str, str]] | None = None, *, new: bool = False) -> str:
    v2 = f'<div class="v2">{second}</div>' if second else ""
    nw = '<span class="nw">new</span>' if new else ""
    a = ""
    if acts:
        a = '<div class="acts">' + "".join(f'<button class="btn" type="button">{icon}{esc(t)}</button>' for icon, t in acts) + "</div>"
    return f'<div class="kv"><span class="k">{esc(key)}</span><div class="v">{value}{nw}{v2}{a}</div></div>'


def checkout_pop(s: Scene, *, right: bool = False) -> str:
    """What the branch's menu becomes: a popover about the checkout, with what
    the row has no room for, and only the actions the row doesn't have."""
    if s.branch is None:
        head = f'{COMMIT16}<div class="two"><b class="mono">{esc(s.head)}</b><span class="sub">Detached HEAD, not on a branch</span></div>'
    else:
        where = "The main worktree of roga" if s.main_wt else "A worktree of roga"
        head = f'{BRANCH16}<div class="two"><b>{esc(s.branch)}</b><span class="sub">{where}</span></div>'
    copy_label = "Copy Commit ID" if s.branch is None else "Copy Branch Name"
    secs = [f'<div class="ch">{head}<span class="sp"></span><button class="ib sm" type="button" aria-label="{copy_label}">{COPY}</button></div>']
    secs.append(kv("Folder", esc(s.folder), acts=[(OPEN, "Show in Finder"), (TERM, "Open in Terminal"), (COPY, "Copy Path")]))
    if s.locked:
        secs.append(kv("Locked", esc(s.locked), "git worktree remove refuses it until it's unlocked", acts=[("", "Unlock")]))
    if s.branch is not None:
        if s.first_push:
            secs.append(kv("Upstream", "Not pushed yet", "↑ pushes it to origin for the first time"))
        else:
            if s.fetch_failed:
                rel = "Couldn't reach origin"
            elif s.ahead and s.behind:
                rel = f"{s.behind} behind, {s.ahead} ahead"
            elif s.behind:
                rel = f"{s.behind} behind"
            elif s.ahead:
                rel = f"{s.ahead} ahead, not pushed"
            else:
                rel = "Up to date"
            secs.append(kv("Upstream", esc(s.upstream or ""), f"{esc(rel)} · fetched {esc(s.fetched)}"))
        if s.branch != "main":
            if s.would_conflict:
                files = " and ".join(s.would_conflict) if len(s.would_conflict) < 3 else plural(len(s.would_conflict), "file")
                second = f'<span class="o">Merging it would conflict in {esc(files)}</span>'
            elif s.base_behind:
                second = f"origin/main has {plural(s.base_behind, 'commit')} this branch doesn't"
            else:
                second = "Has every commit on origin/main"
            if s.fetch_failed:
                second += f"<br>As of the last fetch, {esc(s.fetched)}"
            acts = [("", "Rebase onto origin/main"), ("", "Merge origin/main")] if s.base_behind else None
            secs.append(kv("Main", f"{s.base_ahead} ahead, {s.base_behind} behind origin/main", second, acts, new=True))
    foot = ['<button class="pb" type="button">Switch Branch…</button>']
    if s.branch is not None:
        foot.append('<button class="pb" type="button">Rename Branch…</button>')
    else:
        foot.append(f'<button class="pb" type="button">{NEWBRANCH}New Branch Here…</button>')
    secs.append(f'<div class="pf">{"".join(foot)}</div>')
    return f'<div class="cpop{" right" if right else ""}">{"".join(secs)}</div>'


def agent_pop(s: Scene, *, right: bool = False) -> str:
    """Decision 100's popover: a section for each session, most urgent first,
    and Review Files while there are uncommitted files."""
    secs = []
    for a in sorted(s.agents, key=lambda x: ["waiting", "failed", "working", "finished"].index(x.state)):
        st_cls = {"waiting": " warn", "failed": " fail"}.get(a.state, "")
        t = f'<span class="t">{esc(a.time)}</span>' if a.time else ""
        words = "It stopped before the end of its turn." if a.state == "failed" else a.words
        if a.state == "waiting" and a.asks == "approval":
            words = f"Wants to run {a.words}"
        sub = f'<div class="p3">{a.subagents} subagents running</div>' if a.subagents else ""
        secs.append(f'<div class="ps"><div class="p1">{MARK[a.state]}<b>{esc(a.who)}</b><span class="st{st_cls}">{esc(state_words(a))}</span>{t}</div>'
                    f'<div class="p2">{esc(words)}</div>{sub}</div>')
    if s.files:
        secs.append(f'<div class="pf"><button class="pb" type="button">{DIFF}Review {plural(s.files, "File")}</button></div>')
    return f'<div class="pop{" right" if right else ""}">{"".join(secs)}</div>'


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


OPTIONS = [("today", "Today"), ("A", "A · Two lines"), ("B", "B · Labels"), ("C", "C · Against main"),
           ("D", "D · C at one height")]


def option_board(file: str, option: str, title: str) -> Board:
    cells = [
        cell(title, "680 points, Claude Code running the tests", middle(WORKING, option, WIDE, STAGE_H)),
        cell(title, "480 points", middle(WORKING, option, NARROW, STAGE_H)),
    ]
    w = 80 + WIDE + 48 + NARROW
    h = 34 + 36 + 12 + STAGE_H + 40
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="cells">{"".join(cells)}</div></div>'
    return Board(file, title, w, h, page(title, body, w, h))


def board_states(dark: bool) -> Board:
    label_w = 230
    cols = f"{label_w}px " + " ".join(f"{WIDE}px" for _ in OPTIONS)
    cells = ['<span class="st-h"></span>'] + [f'<span class="st-h">{esc(t)}</span>' for _, t in OPTIONS]
    for _, label, sub, scene in STATES:
        cells.append(f'<div class="st-l">{esc(label)}' + (f"<i>{esc(sub)}</i>" if sub else "") + "</div>")
        for option, _ in OPTIONS:
            cells.append(middle(scene, option, WIDE, CELL_H, tabs=False, rows=2))
    w = 80 + label_w + len(OPTIONS) * (WIDE + 32)
    h = 34 + 20 + 16 + len(STATES) * (CELL_H + 16) + 40
    theme = "th-d" if dark else "th-l"
    body = (f'<div class="board {theme}" style="width:{w}px;height:{h}px;display:block">'
            f'<div class="st-grid" style="grid-template-columns:{cols}">{"".join(cells)}</div></div>')
    title = "Every option, moment by moment" + (", dark" if dark else "")
    return Board("Bb-States-Dark.dc.html" if dark else "Bb-States.dc.html", title, w, h, page(title, body, w, h))


def board_heights() -> Board:
    """Today, C and D, as they look and with every control's fill showing at
    once, which is what the pointer finds as it slides along the row."""
    scene = Scene(agents=[RUN_TESTS], behind=3)
    rows = [("today", "Today", "Every control 32 points"),
            ("C", "C", "The two-line blocks 36, the rest 32"),
            ("D", "D", "Every control 36 points")]
    label_w = 270
    cols = f"{label_w}px {WIDE}px {WIDE}px"
    cells = ['<span class="st-h"></span>', '<span class="st-h">As it looks</span>',
             '<span class="st-h">Every control\'s fill, as the pointer finds it</span>']
    for option, label, sub in rows:
        cells.append(f'<div class="st-l">{esc(label)}<i>{esc(sub)}</i></div>')
        for row in ("", " fills"):
            cells.append(f'<div class="mid" style="width:{WIDE}px;height:45px">{bar(scene, option, Hooks(row=row))}</div>')
    w = 80 + label_w + 2 * (WIDE + 32)
    h = 34 + 20 + 16 + len(rows) * (52 + 16) + 40   # a label's two lines are a little taller than the row
    body = (f'<div class="board th-l" style="width:{w}px;height:{h}px;display:block">'
            f'<div class="st-grid" style="grid-template-columns:{cols}">{"".join(cells)}</div></div>')
    return Board("Bb-Heights.dc.html", "One height for the row", w, h, page("One height for the row", body, w, h))


def board_popovers() -> Board:
    fin = Scene(agents=[Agent("finished", "Added the lockout tests and updated the changelog. Both test suites pass, and the "
                              "lockout message now says how long to wait.", "3 min ago")])
    rows = [
        [
            ("The branch's popover", "C, when merging origin/main would conflict",
             middle(WOULD_CONFLICT, "C", WIDE, POP_H, h=Hooks.open("co", checkout_pop(WOULD_CONFLICT)))),
            ("The branch's popover", "C, in the main worktree",
             middle(MAIN_SCENE, "C", WIDE, POP_H, h=Hooks.open("co", checkout_pop(MAIN_SCENE)))),
            ("The branch's popover", "C, never pushed, and locked",
             middle(LOCKED_NEW, "C", WIDE, POP_H, h=Hooks.open("co", checkout_pop(LOCKED_NEW)))),
        ],
        [
            ("The agent's popover", "C, two sessions, one waiting",
             middle(TWO_AGENTS, "C", WIDE, POP_H, h=Hooks.open("ag", agent_pop(TWO_AGENTS)))),
            ("The agent's popover", "C, finished, with its whole reply",
             middle(fin, "C", WIDE, POP_H, h=Hooks.open("ag", agent_pop(fin)))),
            ("C's tooltip", "a hover over the branch, where the folder went",
             middle(WORKING, "C", WIDE, POP_H, h=Hooks(tip_on="co"),
                    extra=POINTER.format(style="left:150px;top:50px"))),
            ("B's tooltip", "a hover over the agent's label, the only place its words are",
             middle(WORKING, "B", WIDE, POP_H, h=Hooks(tip_on="ag"),
                    extra=POINTER.format(style="left:300px;top:60px"))),
        ],
    ]
    out = []
    for r in rows:
        out.append('<div class="cells">' + "".join(cell(t, sub, stage) for t, sub, stage in r) + "</div>")
    w = 80 + 4 * WIDE + 3 * 48
    h = 34 + 2 * (36 + 12 + POP_H) + 36 + 40
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px">{"".join(out)}</div>'
    return Board("Bb-Popovers.dc.html", "What the clicks open", w, h, page("What the clicks open", body, w, h))


# ---------------------------------------------------------------- try it


def sc_if(cond: str, body: str, placeholder: str = "false") -> str:
    return f'<sc-if value="{{{{{cond}}}}}" hint-placeholder-val="{{{{{placeholder}}}}}">{body}</sc-if>'


def try_hooks(s: Scene) -> Hooks:
    fill = '<i class="fill"></i>'
    return Hooks(
        co_pop=sc_if("coOpen", checkout_pop(s)), fl_pop=sc_if("flOpen", checkout_pop(s)),
        ag_pop=sc_if("agOpen", agent_pop(s)) if s.agents else "",
        co_fill=sc_if("coOpen", fill), fl_fill=sc_if("flOpen", fill), ag_fill=sc_if("agOpen", fill),
        co_click=' onClick="{{openCo}}"', fl_click=' onClick="{{openFl}}"', ag_click=' onClick="{{openAg}}"',
    )


def try_middle() -> str:
    tabs = "".join(sc_if(f"t{i}", title_row(scene), "true" if i == 1 else "false") for i, (_, _, _, scene) in enumerate(STATES))
    bars = "".join(
        sc_if(f"v{option}{i}", bar(scene, option, try_hooks(scene)), "true" if (option == "A" and i == 1) else "false")
        for option, _ in OPTIONS for i, (_, _, _, scene) in enumerate(STATES))
    hist = "".join(sc_if(f"t{i}", history(scene), "true" if i == 1 else "false") for i, (_, _, _, scene) in enumerate(STATES))
    return f'<div class="{{{{midCls}}}}" style="{{{{midStyle}}}}">{tabs}{bars}{hist}</div>'


TRY_JS = r"""
const OPTS = __OPTS__;
const N = __N__;

class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { opt: "A", st: 1, width: 680, look: "light", open: "" };
  }

  renderVals() {
    const s = this.state;
    const v = {};
    for (const o of OPTS) for (let i = 0; i < N; i++) v["v" + o[0] + i] = o[0] === s.opt && i === s.st;
    for (let i = 0; i < N; i++) v["t" + i] = i === s.st;
    const group = (name, key, options) => ({
      name,
      btns: options.map(([val, t]) => ({
        t, cls: "sg" + (s[key] === val ? " on" : ""), pressed: s[key] === val ? "true" : "false",
        pick: () => this.setState({ [key]: val, open: "" }),
      })),
    });
    const toggle = (k) => () => this.setState({ open: s.open === k ? "" : k });
    return Object.assign(v, {
      groups: [
        group("Option", "opt", OPTS),
        group("Moment", "st", __MOMENTS__),
        group("Width", "width", [[680, "680"], [480, "480"]]),
        group("Look", "look", [["light", "Light"], ["dark", "Dark"]]),
      ],
      sheetCls: "sheet " + (s.look === "dark" ? "th-d" : "th-l"),
      midCls: "mid" + (s.width < 600 ? " narrow" : ""),
      midStyle: "width:" + s.width + "px;height:460px",
      coOpen: s.open === "co", flOpen: s.open === "fl", agOpen: s.open === "ag",
      openCo: toggle("co"), openFl: toggle("fl"), openAg: toggle("ag"),
    });
  }
"""


def board_try() -> Board:
    w = 28 + WIDE + 28 + 330 + 28
    h = 28 + 4 * 34 + 18 + 460 + 28    # twelve moments wrap the controls onto a fourth line
    body = (
        f'<div class="{{{{sheetCls}}}}" style="width:{w}px;height:{h}px">'
        '<div class="bar"><sc-for list="{{groups}}" as="gp" hint-placeholder-count="4"><div class="grp"><span>{{gp.name}}</span>'
        '<div class="seg"><sc-for list="{{gp.btns}}" as="b" hint-placeholder-count="4">'
        '<button class="{{b.cls}}" type="button" aria-pressed="{{b.pressed}}" onClick="{{b.pick}}">{{b.t}}</button>'
        '</sc-for></div></div></sc-for></div>'
        f'<div class="main"><div style="width:{WIDE}px;flex:none">{try_middle()}</div>'
        '<div class="side">'
        '<div class="meta"><b>Click</b> the branch, the folder in B, or the agent to open its popover, and click it again to close it. '
        '<b>Hover</b> over any of them, or over a count, and wait for the tooltip, as macOS makes you wait for one.</div>'
        '<div class="meta">Things to look for: how much each option says before you click anything; whether C\'s line stays quiet '
        'until it matters, which <b>Would conflict</b> and <b>Offline</b> show; whether the arrows and C\'s words read as two '
        'different things; and what B loses when the agent\'s words are only in a tooltip.</div>'
        '<div class="meta">The right end is the same in A, B and C: Fetch, New Branch, a line and history\'s order. The number of '
        'commits moves into the order\'s menu, which gives the agent the room it used to share with it.</div>'
        "</div></div></div>"
    )
    moments = [[i, short] for i, (short, _, _, _) in enumerate(STATES)]
    script = (TRY_JS.replace("__OPTS__", json.dumps([[o, t.split(" ·")[0]] for o, t in OPTIONS]))
              .replace("__N__", str(len(STATES)))
              .replace("__MOMENTS__", json.dumps(moments, ensure_ascii=False)))
    head, _, body_js = script.partition("class Component extends DCLogic {")
    return Board("Bb-Try.dc.html", "Try it", w, h, page("Try it", body, w, h, body_js, head), interactive=True)


# ---------------------------------------------------------------- the page


def all_boards() -> list[list[Board]]:
    return [
        [option_board("Bb-Today.dc.html", "today", "Today"),
         option_board("Bb-A.dc.html", "A", "A · Two lines"),
         option_board("Bb-B.dc.html", "B", "B · Labels"),
         option_board("Bb-C.dc.html", "C", "C · Against main"),
         option_board("Bb-D.dc.html", "D", "D · C at one height")],
        [board_heights(), board_popovers(), board_try()],
        [board_states(False)],
        [board_states(True)],
    ]


TITLES = [
    "What the branch row could say",
    "What the clicks open, and trying it",
    "Every option, moment by moment",
    "The same, dark",
]

INTROS = [
    "The row under the tabs says which branch the worktree is on, pulls and pushes, and says what its agent is doing. "
    "It doesn't say how far the branch has drifted from main, which you only find out from history or a failed merge, "
    "and the branch's menu repeats Pull, Push, Fetch and New Branch, which are a click away on the same row. Each board "
    "draws the middle column at 680 points, as in the default window, and at 480, with Claude Code running the tests "
    "in agent/fix-login. A gives the branch and the agent two lines each in the row's 44 points, with the folder under "
    "the branch. B shrinks every part to a label and leaves the words to tooltips and popovers. C keeps A's two lines "
    "but puts how far the branch is from origin/main under it, and leaves the folder to the tooltip and the popover. "
    "D is C with every control in the row as tall as its two-line blocks.",
    "The first board shows how tall each control's fill is in today's row, in C and in D, as they look and with every "
    "fill showing at once. In A to D a click on the branch opens a popover about the checkout instead of the menu: the "
    "folder with Show in "
    "Finder, Open in Terminal and Copy Path, the upstream and when Roga last fetched, how far the branch is from "
    "origin/main and which files a merge of it would conflict in, with Rebase and Merge, the lock, and Switch Branch and "
    "Rename. Pull, Push, Fetch and New Branch stay on the row, and in the menu bar's Branch menu with their shortcuts. "
    "The agent's popover is decision 100's. Try it puts every option and moment under your pointer.",
    "Each option in the same twelve moments. Only the branch row and the first rows of history are drawn.",
    "The same moments in the dark appearance.",
]

EXTRA_NOTES = {
    "nBbPick": {
        "x": 1080, "row": 0, "w": 900,
        "text": "Suggested: C, with the branch's popover. The row's place is for two kinds of things: what you can do, "
                "like the counts that pull and push, and what changed without you, like the agent and main moving on. "
                "The folder never changes once you know it, and you mostly need it to do something there, so it belongs "
                "beside Open in Terminal in the popover. How far origin/main has moved is the opposite: nobody notices "
                "it until a merge goes wrong. C draws it in gray, since most branches that are behind still merge "
                "cleanly, says how far behind only when it isn't zero, and turns orange only when git merge-tree "
                "--write-tree says a merge would conflict. It compares with origin/main rather than the local main, "
                "which goes stale unless someone pulls it. Two lines still fit in the row's 44 points, so history "
                "doesn't move down. B is the quietest, but what the agent is doing would again take a hover. D is C "
                "with every control 36 points tall, so the fills under the pointer match from one end of the row to "
                "the other, as today's do at 32.",
    },
    "nBbHover": {
        "x": 1080, "row": 1, "w": 900,
        "text": "Why click and not hover for the detail: macOS has tooltips for hover, which wait about a second and can't "
                "hold a button, and popovers for clicks. A card that opens on hover would open as the pointer crosses "
                "the row to Fetch, couldn't be reached from the keyboard or VoiceOver, and would have to close itself "
                "when the pointer leaves, which makes it hard to click Open in Terminal inside it. Every part keeps a "
                "tooltip with its one-line summary for a quick look, and the click opens the rest on the press (decision 111).",
    },
    "nBbWatch": {
        "x": 1080, "row": 2, "w": 900,
        "text": "What to watch in C: the row now has two kinds of ahead and behind, the arrows against the upstream and "
                "the words against origin/main. They're meant to read apart because they look and behave differently. "
                "The arrows are buttons that pull and push and go away when there's nothing to do. The words are "
                "gray, and a click on them opens the branch's popover rather than doing anything to the branch. If "
                "people still mix them up, the words could say main's name only and leave origin/ to the popover.",
    },
}

NOTES = {
    "Bb-Today.dc.html": "Today's row: the branch's chip opens a menu with its upstream on the first line, then Pull, Push, "
                        "Fetch, New Branch and Switch Branch, most of which are buttons on the same row. The agent's line "
                        "follows the counts, and history's number of commits drops at 480 points while it speaks.",
    "Bb-A.dc.html": "A gives the branch block and the agent block two lines each. The folder sits under the branch, cut in "
                    "its middle so its last part stays, and the agent's state and time sit over what it's doing, with "
                    "the light running through those words. The number of commits moves into the order's menu. At 480 "
                    "points the agent's words are cut first, then the folder's middle, then the branch's name.",
    "Bb-B.dc.html": "B is a row of quiet labels: the folder's last part, the branch, the counts, and the agent's name and "
                    "time. Each label's tooltip has the whole of it, and a click opens its popover. It reads calmly and "
                    "fits anywhere, but what the agent is doing takes a hover and a wait, as it did before decision 100.",
    "Bb-C.dc.html": "C puts how far the branch is from origin/main under its name: always how far ahead, which is how much "
                    "work it holds, and how far behind once it's behind at all, both in gray. Only a merge that would "
                    "conflict is orange, and that part is never cut. The folder moves to the tooltip and the popover. For "
                    "main itself the line says how far it is from origin/main and when Roga fetched.",
    "Bb-D.dc.html": "D is C with every control in the row 36 points tall: the counts, Fetch, New Branch and the order "
                    "as well as the branch and the agent. Today's row draws every control at 32, so the fills under "
                    "the pointer match as it slides along the row. C's two-line blocks need 36, which leaves the counts "
                    "between them shorter than their neighbours. The icon button style already takes a size.",
    "Bb-Heights.dc.html": "The boards before this one drew the counts at 28 points, where the app draws them at 32, "
                          "and they're 32 now. In C the counts are still 4 points shorter than the blocks on either "
                          "side of them, which is easiest to see with every fill showing. D evens them out at 36, which "
                          "leaves 4 points above and below each fill in the 44-point row.",
    "Bb-Popovers.dc.html": "The branch's popover holds what the row has no room for and the actions the row doesn't have. "
                           "The Main section is marked new, since Roga doesn't work out how far a branch is from "
                           "origin/main, or whether merging it would conflict, today. The agent's popover is decision "
                           "100's, without Show Terminal. The last two cells show where C's folder went, and how B's "
                           "agent label gives its words only to a tooltip.",
    "Bb-Try.dc.html": "Pick an option and a moment. Click a part to open its popover, and hover to see its tooltip.",
    "Bb-States.dc.html": "Roga's own words, as in Committed 9f2c1ab, still take the agent's place while they show. "
                         "Would conflict is the one moment where C's line turns orange, and Offline is where it says how "
                         "old its numbers are. A detached HEAD shows its commit, and C says it isn't on a branch. A locked "
                         "worktree gets a small lock at the start of the second line in A and C, and its folder label "
                         "turns into the lock in B.",
    "Bb-States-Dark.dc.html": "The amber of a waiting agent and the red of conflicts are the sidebar's, so they read the "
                              "same in the tab, the row and the popovers. C's orange is the counts' color, since it "
                              "asks for something to be done rather than for an answer.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    row_y: list[int] = []
    y = 0
    for index, row_boards in enumerate(rows):
        row_y.append(y)
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tBb{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nBb{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Branch bar page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Branch bar boards, and optionally merge them into a canvas.json."""
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
