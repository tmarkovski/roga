# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Settings boards for the design canvas "yaga layout options".

Every board is written as a `.dc.html` file under `<out>/project/`, and
`--canvas` merges their frames and notes into a copy of the canvas's
`canvas.json`, on a page of its own. Nothing here talks to the network.

    uv run docs/design/settings/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json
"""

from __future__ import annotations

import html
import json
import math
import re
from dataclasses import dataclass, field
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
MARK = HERE.parent / "branding" / "roga-mark.svg"
PAGE_ID = "settings"
PAGE_NAME = "Settings"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------------------
# Icons, Lucide's 24-point strokes (decision 24 draws the app's icons from it).

ICONS = {
    "x": '<path d="M18 6 6 18M6 6l12 12"></path>',
    "search": '<circle cx="11" cy="11" r="8"></circle><path d="m21 21-4.3-4.3"></path>',
    "down": '<path d="m6 9 6 6 6-6"></path>',
    "right": '<path d="m9 18 6-6-6-6"></path>',
    "left": '<path d="m15 18-6-6 6-6"></path>',
    "ext": '<path d="M7 7h10v10M7 17 17 7"></path>',
    "check": '<path d="M20 6 9 17l-5-5"></path>',
    "plus": '<path d="M5 12h14M12 5v14"></path>',
    "general": '<path d="M21 4h-7M10 4H3M21 12h-9M8 12H3M21 20h-5M12 20H3M14 2v4M8 10v4M16 18v4"></path>',
    "appearance": '<circle cx="13.5" cy="6.5" r="1"></circle><circle cx="17.5" cy="10.5" r="1"></circle><circle cx="8.5" cy="7.5" r="1"></circle><circle cx="6.5" cy="12.5" r="1"></circle><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.93 0 1.65-.75 1.65-1.69 0-.44-.18-.84-.44-1.13-.29-.29-.44-.65-.44-1.13a1.64 1.64 0 0 1 1.67-1.67h2c3.05 0 5.55-2.5 5.55-5.55C21.97 6.01 17.46 2 12 2z"></path>',
    "git": '<path d="M6 3v12"></path><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path>',
    "commit": '<circle cx="12" cy="12" r="3"></circle><path d="M3 12h6M15 12h6"></path>',
    "agents": '<path d="m7 11 2-2-2-2"></path><path d="M11 13h4"></path><rect width="18" height="18" x="3" y="3" rx="2"></rect>',
    "advanced": '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.76 3.76z"></path>',
    "refresh": '<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8"></path><path d="M21 3v5h-5"></path>',
    "undo": '<path d="M9 14 4 9l5-5"></path><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"></path>',
    "alert": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"></path><path d="M12 9v4M12 17h.01"></path>',
    "copy": '<rect x="9" y="9" width="13" height="13" rx="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>',
    "monitor": '<rect width="20" height="14" x="2" y="3" rx="2"></rect><path d="M8 21h8M12 17v4"></path>',
    "sun": '<circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41"></path>',
    "moon": '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z"></path>',
    "sparkles": '<path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"></path><path d="M20 3v4M22 5h-4"></path>',
}


def ic(name: str, cls: str = "ic") -> str:
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{ICONS[name]}</svg>'


def house_path() -> str:
    text = MARK.read_text()
    match = re.search(r'<path id="mark"[^>]* d="([^"]+)"', text)
    assert match, "The mark's path wasn't where it used to be"
    return match.group(1)


# ---------------------------------------------------------------------------
# Styles. The tokens are the Dialogs page's (decision 29), so a settings window
# and a dialog look like one family.

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.board{position:relative;display:flex;align-items:flex-start;justify-content:center;padding:40px;font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.th-l{--sheet:#fff;--tx:#1c1c1a;--tx2:#696964;--card:#f2f2f0;--line:#d6d6d3;--hair:#eaeae7;--sec:#efefed;--nav:#ececea;--ink:#1a1a18;--onink:#fff;--dng:#cd1755;--org:#c94402;--onorg:#fff;--act:#b83e02;--term:#272822;--warn:#9a5200;--ok:#3f7d00;--red:#c4123f;--add:#e6f4e1;--addh:#c9e8bd;--del:#fde8ec;--delh:#f7c4cf;--surface:#fafaf9;--scrim:rgba(20,20,18,.36);--hover:rgba(0,0,0,.05);--sh:0 18px 50px rgba(0,0,0,.22),0 0 0 .5px rgba(0,0,0,.14);--bg:#deded9;--tip:#1c1c1a;--ontip:#fff}
.th-d{--sheet:#2a2a29;--tx:#ececea;--tx2:#a9a9a3;--card:#353534;--line:#4a4a47;--hair:#393938;--sec:#3b3b3a;--nav:#3a3a39;--ink:#ececea;--onink:#16150e;--dng:#fc5884;--org:#f0813f;--onorg:#272822;--act:#f0813f;--term:#1a1b17;--warn:#f0a54a;--ok:#a6e22e;--red:#ff6b8f;--add:#26331c;--addh:#3b5226;--del:#3d2028;--delh:#5c2a37;--surface:#252524;--scrim:rgba(0,0,0,.5);--hover:rgba(255,255,255,.07);--sh:0 18px 50px rgba(0,0,0,.55),0 0 0 .5px rgba(255,255,255,.12);--bg:#141413;--tip:#ececea;--ontip:#1c1c1a}
.board{background:var(--bg);color:var(--tx)}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:13px;height:13px}
.ic.xs{width:11px;height:11px;stroke-width:2}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}

.sw{position:relative;width:880px;background:var(--sheet);color:var(--tx);border-radius:20px;box-shadow:var(--sh);display:flex;flex-direction:column;overflow:hidden;flex:none}
.swh{height:52px;flex:none;display:flex;align-items:center;gap:12px;padding:0 14px 0 20px;border-bottom:1px solid var(--hair)}
.swh h2{margin:0;flex:1 1 0;font-size:15px;font-weight:600}
.x{width:26px;height:26px;border:0;background:none;color:var(--tx2);display:grid;place-items:center;padding:0;border-radius:7px;flex:none;cursor:default}
.swb{display:flex;flex:1 1 auto;min-height:0}
.nav{width:216px;flex:none;border-right:1px solid var(--hair);padding:14px 12px 12px;display:flex;flex-direction:column;gap:2px}
.srch{display:flex;align-items:center;gap:8px;height:30px;padding:0 10px;border:1px solid var(--line);border-radius:9px;color:var(--tx2);margin-bottom:12px;flex:none}
.srch input{border:0;background:none;font:inherit;color:var(--tx);outline:none;min-width:0;flex:1 1 0;padding:0}
.ni{display:flex;align-items:center;gap:10px;height:30px;padding:0 10px;border-radius:8px;border:0;background:none;color:var(--tx);font:inherit;text-align:left;width:100%;flex:none;cursor:default}
.ni .ic{color:var(--tx2)}
.ni.on{background:var(--nav);font-weight:500}
.ni.on .ic{color:var(--tx)}
.nsep{height:1px;background:var(--hair);margin:7px 10px;flex:none}
.nft{margin-top:auto;padding:12px 10px 2px;display:flex;align-items:center;justify-content:space-between;color:var(--tx2);font-size:12px;flex:none}
.lnk{border:0;background:none;padding:0;font:inherit;color:var(--tx2);display:inline-flex;align-items:center;gap:3px;cursor:default}
.ct{position:relative;flex:1 1 0;min-width:0;padding:22px 28px 28px;display:flex;flex-direction:column;gap:30px;overflow:hidden}
.back{align-self:flex-start;margin:-8px 0 -22px -6px;height:24px;padding:0 6px 0 2px;border:0;background:none;color:var(--tx2);font:inherit;display:inline-flex;align-items:center;gap:2px;border-radius:6px;cursor:default}
.sec{display:flex;flex-direction:column}
.sh{display:flex;align-items:center;gap:10px;min-height:26px;margin-bottom:4px}
.sh h3{margin:0;flex:1 1 0;font-size:15px;font-weight:600}
.sd{margin:0 0 8px;color:var(--tx2);font-size:12.5px;line-height:18px}
.r{display:flex;align-items:center;gap:16px;min-height:56px;padding:10px 0}
.r.nh{min-height:46px}
.r+.r,.r+.blk,.blk+.r,.blk+.blk{border-top:1px solid var(--hair)}
.blk{padding:12px 0}
.rl{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px}
.rt{font-size:13px;display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.rh{font-size:12.5px;line-height:18px;color:var(--tx2)}
.rc{flex:none;display:flex;align-items:center;gap:8px}
.key{font:11.5px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;color:var(--tx2);background:var(--card);border-radius:5px;padding:1px 5px;white-space:nowrap}
.tdy{font-size:10.5px;font-weight:500;letter-spacing:.01em;color:var(--act);border:1px solid var(--act);border-radius:999px;padding:0 6px;line-height:15px;white-space:nowrap}
.tag{font-size:11px;color:var(--tx2);border:1px solid var(--line);border-radius:999px;padding:0 7px;line-height:17px;white-space:nowrap}

.tg{width:34px;height:20px;border-radius:10px;border:0;background:var(--line);position:relative;padding:0;flex:none;cursor:default}
.tg i{position:absolute;left:2px;top:2px;width:16px;height:16px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25)}
.tg.on{background:var(--ink)}
.tg.on i{left:16px;background:var(--sheet)}
.pu{display:inline-flex;align-items:center;gap:6px;height:28px;padding:0 6px 0 10px;border-radius:8px;border:0;background:none;color:var(--tx);font:inherit;white-space:nowrap;cursor:default}
.pu .v2{color:var(--tx2)}
.pu .ic{color:var(--tx2)}
.sel{display:inline-flex;align-items:center;gap:8px;height:32px;padding:0 10px 0 12px;border:1px solid var(--line);border-radius:9px;background:var(--sheet);color:var(--tx);font:inherit;text-align:left;cursor:default;white-space:nowrap}
.sel .sv{flex:1 1 0}
.sel .ic{color:var(--tx2)}
.tf{height:32px;border:1px solid var(--line);border-radius:9px;padding:0 11px;width:240px;font:inherit;background:var(--sheet);color:var(--tx);outline:none}
.tf.mono{font-size:12px}
.tf::placeholder{color:var(--tx2)}
.ta{width:100%;min-height:84px;border:1px solid var(--line);border-radius:10px;padding:9px 11px;font:inherit;line-height:1.45;background:var(--sheet);color:var(--tx);resize:none;outline:none;display:block}
.seg{display:inline-grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:2px;padding:2px;background:var(--card);border-radius:10px}
.seg button{height:26px;padding:0 11px;border:0;border-radius:8px;background:none;color:var(--tx);font:inherit;font-weight:500;white-space:nowrap;display:grid;place-items:center;cursor:default}
.seg button .ic{color:var(--tx2)}
.seg button.on{background:var(--sheet);box-shadow:0 0 0 .5px var(--line),0 1px 2px rgba(0,0,0,.08)}
.seg button.on .ic{color:var(--tx)}
.b{height:28px;padding:0 12px;border-radius:9px;border:0;font:inherit;font-weight:500;white-space:nowrap;display:inline-flex;align-items:center;gap:6px;cursor:default}
.b.sec{background:var(--sec);color:var(--tx)}
.b.pri{background:var(--ink);color:var(--onink)}
.b.dng{background:none;color:var(--red);box-shadow:inset 0 0 0 1px var(--line)}
.b.sm{height:24px;padding:0 9px;border-radius:7px;font-size:12px}
.sld{display:flex;align-items:center;gap:10px}
.trk{position:relative;width:180px;height:4px;border-radius:2px;background:var(--line)}
.trk b{position:absolute;left:0;top:0;bottom:0;border-radius:2px;background:var(--ink)}
.trk i{position:absolute;top:-7px;width:18px;height:18px;margin-left:-9px;border-radius:50%;background:#fff;box-shadow:0 0 0 .5px rgba(0,0,0,.2),0 1px 3px rgba(0,0,0,.3)}
.sv1{width:36px;text-align:right;color:var(--tx2);font-variant-numeric:tabular-nums}

.houses{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;background:var(--card);border-radius:12px;padding:12px 8px 10px}
.hs{display:flex;flex-direction:column;align-items:center;gap:6px;font-size:12px;color:var(--tx2)}
.hs svg{width:46px;height:46px;display:block}
.hs path{fill:#d54802;fill-rule:evenodd}
.diff{border:1px solid var(--hair);border-radius:12px;overflow:hidden;font:12px/20px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}
.dl{display:flex;white-space:pre}
.dl .n{width:38px;flex:none;text-align:right;padding-right:10px;color:var(--tx2)}
.dl .s{width:14px;flex:none;color:var(--tx2)}
.dl.a{background:var(--add)}
.dl.d{background:var(--del)}
.dl .ha{background:var(--addh);border-radius:3px}
.dl .hd{background:var(--delh);border-radius:3px}
.dl.hh{color:var(--tx2);background:var(--card)}

.lst{border:1px solid var(--hair);border-radius:12px;overflow:hidden}
.ar{display:flex;align-items:center;gap:12px;min-height:58px;padding:10px 12px 10px 14px}
.ar+.ar{border-top:1px solid var(--hair)}
.mg{width:30px;height:30px;border-radius:8px;display:grid;place-items:center;font-size:11.5px;font-weight:600;background:var(--card);color:var(--tx);flex:none;letter-spacing:-.01em}
.ar.off .mg{color:var(--tx2)}
.an{display:flex;flex-direction:column;gap:2px;flex:1 1 0;min-width:0;border:0;background:none;padding:0;font:inherit;color:var(--tx);text-align:left;cursor:default}
.an b{font-weight:500}
.ap{font:11.5px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ap.warn{color:var(--warn);font-family:inherit;font-size:12px;white-space:normal}
.ap.dim{font-family:inherit;font-size:12px}
.chev{width:24px;height:24px;border:0;background:none;color:var(--tx2);display:grid;place-items:center;padding:0;border-radius:6px;cursor:default}
.aradd{display:flex;align-items:center;gap:8px;height:44px;padding:0 14px;border:0;background:none;width:100%;font:inherit;color:var(--tx);border-top:1px solid var(--hair);cursor:default}
.aradd .ic{color:var(--tx2)}

.cmd{position:relative;font-variant-ligatures:none;background:var(--term);border-radius:10px;padding:10px 38px 11px 12px;color:#f8f8f2;font:12px/1.6 ui-monospace,"SF Mono",Menlo,monospace}
.cp{position:absolute;top:6px;right:6px;width:24px;height:24px;border:0;background:none;color:#a59f85;display:grid;place-items:center;padding:0;border-radius:6px;cursor:default}
.cp .ic{width:14px;height:14px}
.ln{padding-left:1.2em;text-indent:-1.2em;white-space:pre-wrap;overflow-wrap:anywhere}
.ln .tk::after{content:" "}
.ln.cm{padding-left:0;text-indent:0;color:#a59f85}
.t-p{color:#a59f85}
.t-g{color:#f8f8f2}
.t-f{color:#e6db74}
.t-r{color:#66d9ef}
.t-s{color:#ae81ff}
.card{background:var(--card);border-radius:12px;padding:10px 14px;display:flex;flex-direction:column;gap:7px}
.cr{display:flex;gap:12px;align-items:baseline}
.cr .h{font:11.5px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;color:var(--tx);flex:none;width:200px}
.cr .v{min-width:0;color:var(--tx2);font-size:12.5px}
.res{display:flex;align-items:center;gap:8px;font-size:12.5px;color:var(--tx2)}
.res .ok{color:var(--ok);display:inline-flex;align-items:center;gap:5px;font-weight:500}

.scrim{position:absolute;inset:0;background:var(--scrim)}
.dlg{position:relative;width:480px;background:var(--sheet);color:var(--tx);border-radius:20px;box-shadow:var(--sh);display:flex;flex-direction:column;overflow:hidden;flex:none}
.dtop{padding:16px 18px 14px;display:flex;flex-direction:column;gap:12px}
.dhd{display:flex;align-items:flex-start;gap:12px}
.dti{flex:1 1 0;min-width:0;margin:0;font-size:15px;font-weight:600;line-height:1.35}
.dlg .x{width:24px;height:24px;margin:-2px -4px 0 0}
.msg{margin:0}
.fld{display:flex;flex-direction:column;gap:5px}
.fld label{font-weight:500}
.fld .rh{margin-top:1px}
.fld .tf{width:100%}
.dft{display:flex;flex-direction:column-reverse;gap:14px}
.dft .cmd{border-radius:0;padding:11px 44px 13px 18px}
.dft .cp{top:8px;right:10px}
.btns{display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:0 18px}
.btns .lft{margin-right:auto}
.over{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}

.sheet{display:grid;grid-template-columns:repeat(4,340px);gap:44px 40px;align-items:start}
.cs{display:flex;flex-direction:column;gap:10px}
.cap{font-size:13px;font-weight:500}
.cap i{font-style:normal;font-weight:400;color:var(--tx2)}
.panel{position:relative;width:340px;height:440px;background:var(--sheet);border-radius:12px;box-shadow:0 0 0 .5px var(--line),0 2px 8px rgba(0,0,0,.06);display:flex;flex-direction:column;overflow:visible}
.files{flex:1 1 0;min-height:0;overflow:hidden;border-radius:12px 12px 0 0}
.fh{display:flex;align-items:center;gap:6px;height:30px;padding:0 14px;font-size:12px;font-weight:600;color:var(--tx2)}
.fh .n{font-weight:400}
.fr{display:flex;align-items:center;gap:8px;height:26px;padding:0 14px;font-size:12.5px;white-space:nowrap}
.fr .st{width:12px;font:600 11px ui-monospace,"SF Mono",Menlo,monospace;color:var(--act);text-align:center;flex:none}
.fr .st.a{color:var(--ok)}
.fr .fd{color:var(--tx2);overflow:hidden;text-overflow:ellipsis}
.box{flex:none;background:var(--surface);border-top:1px solid var(--line);border-radius:0 0 12px 12px;display:flex;flex-direction:column}
.bh{display:flex;align-items:center;gap:6px;height:32px;padding:0 14px;font-size:12px}
.bh .lead{color:var(--tx2)}
.bh .sub{font-weight:500}
.bh .amd{margin-left:auto;display:flex;align-items:center;gap:5px;color:var(--tx2)}
.cbx{width:13px;height:13px;border:1px solid var(--line);border-radius:3.5px;background:var(--sheet);flex:none}
.ed{position:relative;margin:0 10px;min-height:70px;padding:7px 9px 34px;border:1px solid var(--line);border-radius:8px;background:var(--sheet);font-size:13px;line-height:1.4}
.ed.ro{background:var(--surface);color:var(--tx2)}
.ed .ph{color:var(--tx2)}
.ed .sj{font-weight:600}
.ed .bd{margin-top:6px;color:var(--tx)}
.ed .cnt{position:absolute;top:7px;right:9px;font-size:11px;color:var(--tx2);font-variant-numeric:tabular-nums}
.ed textarea{width:100%;min-height:62px;border:0;padding:0;margin:0;background:none;font:inherit;color:var(--tx);resize:none;outline:none;display:block}
.bar{height:8px;border-radius:4px;background:var(--card);margin:6px 0}
.gen{position:absolute;right:6px;bottom:6px;display:inline-flex;align-items:stretch;height:24px;border-radius:7px;background:var(--card);overflow:hidden}
.gen button{border:0;background:none;color:var(--tx);font:inherit;font-size:12px;font-weight:500;display:inline-flex;align-items:center;gap:5px;padding:0 8px;cursor:default}
.gen button+button{border-left:1px solid var(--line);padding:0 5px}
.gen button .ic{color:var(--act)}
.gen button+button .ic{color:var(--tx2)}
.gen.dis button{color:var(--tx2)}
.gen.dis button .ic{color:var(--tx2)}
.gen.hv{box-shadow:0 0 0 1.5px var(--line)}
.note{padding:8px 12px 0;font-size:12px;color:var(--tx2);display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.note .ic{color:var(--act)}
.act{border:0;background:none;padding:0;font:inherit;font-weight:500;color:var(--act);cursor:default}
.wrk{padding:8px 12px 0;display:flex;align-items:center;gap:7px;font-size:12px;color:var(--tx2)}
.wrk .act{margin-left:auto}
.spin{width:12px;height:12px;border-radius:50%;border:1.5px solid var(--line);border-top-color:var(--tx2);flex:none}
.fail{margin:8px 10px 0;border:1px solid var(--red);border-radius:7px;padding:6px 8px;display:flex;flex-direction:column;gap:4px}
.fail b{font-size:12px;color:var(--red)}
.fail .o{font:11px ui-monospace,"SF Mono",Menlo,monospace;color:var(--tx2)}
.fail .fa{display:flex;gap:12px;font-size:12px}
.bf{display:flex;align-items:center;gap:8px;height:44px;padding:0 10px 0 14px}
.bf .kb{font-size:12px;color:var(--tx2)}
.cbtn{margin-left:auto;height:26px;padding:0 12px;border-radius:7px;border:0;background:#c94402;color:#fff;font:inherit;font-size:12.5px;font-weight:500;cursor:default}
.cbtn.dis{background:var(--card);color:var(--tx2)}
.tip{position:absolute;background:var(--tip);color:var(--ontip);font-size:11.5px;border-radius:6px;padding:4px 8px;white-space:nowrap;box-shadow:0 4px 12px rgba(0,0,0,.18)}
.pv{position:absolute;width:312px;background:var(--sheet);color:var(--tx);border-radius:16px;box-shadow:var(--sh);display:flex;flex-direction:column;z-index:2}
.pva{position:absolute;bottom:-6px;width:13px;height:13px;background:var(--term);transform:rotate(45deg);border-radius:0 0 3px 0}
.pvin{position:relative;display:flex;flex-direction:column;overflow:hidden;border-radius:16px}
.pvt{padding:13px 16px 8px;font-weight:600}
.ags{display:flex;flex-direction:column;gap:2px;padding:0 6px}
.ag{display:flex;gap:10px;align-items:flex-start;text-align:left;width:100%;padding:7px 10px;border:0;background:none;border-radius:9px;color:var(--tx);font:inherit;cursor:default}
.ag.on{background:var(--card)}
.rd{width:14px;height:14px;border-radius:50%;border:1px solid var(--tx2);margin-top:2px;flex:none}
.ag.on .rd{border:4.5px solid var(--ink)}
.ag .o2{color:var(--tx2);font-size:12px}
.ag .ot{display:flex;flex-direction:column;gap:1px}
.pvr{display:flex;align-items:center;gap:10px;padding:8px 16px 0}
.pvr .fl{width:52px;flex:none;color:var(--tx2);font-size:12.5px}
.chips{display:flex;flex-wrap:wrap;gap:4px}
.chip{height:24px;padding:0 9px;border-radius:7px;border:0;background:var(--card);color:var(--tx);font:inherit;font-size:12px;cursor:default}
.chip.on{background:var(--ink);color:var(--onink);font-weight:500}
.pv .seg button{height:22px;padding:0 8px;font-size:12px}
.pv .btns{padding:12px 16px 12px}
.pv .cmd{border-radius:0;padding:9px 38px 10px 14px;font-size:11.5px}
.menu{width:300px;background:var(--sheet);border-radius:10px;box-shadow:var(--sh);padding:5px;display:flex;flex-direction:column;font-size:13px}
.mi{display:flex;align-items:center;gap:8px;height:24px;padding:0 8px;border-radius:5px}
.mi .ck{width:12px;flex:none;display:grid;place-items:center}
.mi .kb{margin-left:auto;color:var(--tx2);font-size:12.5px}
.mi.on{background:#2f6de1;color:#fff}
.mi.on .kb{color:#fff}
.mi .dim{color:var(--tx2)}
.mi.on .dim{color:rgba(255,255,255,.8)}
.ms{height:1px;background:var(--hair);margin:5px 8px}
.sub2{position:absolute;width:250px}

.lg{display:flex;flex-direction:column;gap:2px;background:var(--card);border-radius:12px;padding:6px 8px}
.lgr{display:flex;align-items:center;gap:9px;height:26px;padding:0 6px;font-size:12.5px}
.lgr svg{width:14px;height:14px;flex:none;display:block}
.lgr .ref{font:12px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;width:150px;flex:none}
.lgr .lv{color:var(--tx2)}
.hk{display:flex;align-items:center;gap:12px;min-height:58px;padding:10px 12px 10px 14px}
.hk+.hk{border-top:1px solid var(--hair)}
.okt{color:var(--ok);font-weight:500}
.ntc{display:flex;gap:10px;align-items:flex-start;padding:10px 12px;border-radius:12px;background:var(--card);font-size:12.5px;color:var(--tx2)}
.ntc .ic{margin-top:1px;color:var(--tx2)}
.tgr{background:var(--card);border-radius:12px;padding:9px 14px;display:flex;align-items:center;gap:12px}
.tgr .rl .rt{font-weight:500}

.ctl{position:absolute;top:0;left:0;right:0;display:flex;flex-wrap:wrap;gap:8px 18px;align-items:center;padding:10px 16px;background:#1c1c1a;color:#e8e8e4}
.ctl .gl{font-size:11.5px;color:#a8a8a2}
.ctl .sb2{height:24px;padding:0 8px;border:0;border-radius:6px;background:#333331;color:#e8e8e4;font:inherit;font-size:12px;cursor:default;white-space:nowrap}
.ctl .sb2.on{background:#f0813f;color:#1c1c1a;font-weight:500}
"""


# ---------------------------------------------------------------------------
# Building blocks. Each returns markup and, where a board's size depends on it,
# an estimate of its height in points, so frames fit without measuring.


@dataclass
class Ctx:
    """What one board is being drawn as."""

    live: bool = False
    toggles: dict[str, bool] = field(default_factory=dict)
    segs: dict[str, tuple[list[str], str]] = field(default_factory=dict)


CONTENT_WIDTH = 880 - 216 - 56


def helper_lines(text: str, control_width: int) -> int:
    if not text:
        return 0
    avail = CONTENT_WIDTH - 16 - control_width
    return max(1, math.ceil(len(text) * 6.3 / avail))


def toggle(ctx: Ctx, key: str, on: bool, label: str) -> str:
    if ctx.live:
        ctx.toggles[key] = on
        return f'<button class="{{{{tg.{key}}}}}" aria-pressed="{{{{tp.{key}}}}}" aria-label="{esc(label)}" onClick="{{{{flip.{key}}}}}"><i></i></button>'
    cls = "tg on" if on else "tg"
    return f'<button class="{cls}" aria-pressed="{"true" if on else "false"}" aria-label="{esc(label)}"><i></i></button>'


def seg_key(key: str, option: str) -> str:
    return key + "__" + re.sub(r"[^a-z0-9]", "", option.lower())


def seg(ctx: Ctx, key: str, options: list[str], selected: str, label: str, icons: dict[str, str] | None = None) -> str:
    if ctx.live:
        ctx.segs[key] = (options, selected)
    parts = []
    for option in options:
        inner = ic(icons[option]) if icons else esc(option)
        aria = f' aria-label="{esc(option)}"' if icons else ""
        if ctx.live:
            k = seg_key(key, option)
            parts.append(f'<button class="{{{{sg.{k}}}}}"{aria} onClick="{{{{pick.{k}}}}}">{inner}</button>')
        else:
            cls = ' class="on"' if option == selected else ""
            pressed = "true" if option == selected else "false"
            parts.append(f'<button{cls} aria-pressed="{pressed}"{aria}>{inner}</button>')
    return f'<div class="seg" role="group" aria-label="{esc(label)}">{"".join(parts)}</div>'


def popup(value: str, detail: str = "") -> str:
    d = f' <span class="v2">{esc(detail)}</span>' if detail else ""
    return f'<button class="pu">{esc(value)}{d}{ic("down", "ic s")}</button>'


def select(value: str, width: int = 200) -> str:
    return f'<button class="sel" style="width:{width}px"><span class="sv">{esc(value)}</span>{ic("down", "ic s")}</button>'


def field_(value: str, label: str, mono: bool = False, width: int = 240, placeholder: str = "") -> str:
    cls = "tf mono" if mono else "tf"
    ph = f' placeholder="{esc(placeholder)}"' if placeholder else ""
    return f'<input class="{cls}" style="width:{width}px" type="text" value="{esc(value)}"{ph} aria-label="{esc(label)}">'


def today_tag() -> str:
    return '<sc-if value="{{today}}" hint-placeholder-val="{{true}}"><span class="tdy">In the app</span></sc-if>'


def row(label: str, control: str, help: str = "", key: str = "", today: bool = False, cw: int = 40, help_html: str = "", extra: int = 0) -> tuple[str, int]:
    """A setting: its name and gray help on the left, its control on the right."""
    tag = today_tag() if today else ""
    key_html = f' <span class="key">{esc(key)}</span>' if key else ""
    body = help_html or esc(help)
    lines = helper_lines(help + (" " + key + "   " if key else ""), cw) + extra
    helper = f'<span class="rh">{body}{key_html}</span>' if (help or help_html or key) else ""
    cls = "r" if helper else "r nh"
    height = max(56 if helper else 46, 20 + 18 + (2 + 18 * lines if lines else 0)) + 1
    return (
        f'<div class="{cls}"><div class="rl"><span class="rt">{esc(label)}{tag}</span>{helper}</div>'
        f'<div class="rc">{control}</div></div>',
        height,
    )


def block(markup: str, height: int) -> tuple[str, int]:
    return f'<div class="blk">{markup}</div>', height + 24 + 1


def section(title: str, rows: list[tuple[str, int]], desc: str = "", aside: str = "") -> tuple[str, int]:
    head = f'<div class="sh"><h3>{esc(title)}</h3>{aside}</div>'
    d = f'<p class="sd">{desc}</p>' if desc else ""
    dh = (8 + 18 * helper_lines(re.sub("<[^>]+>", "", desc), -16)) if desc else 0
    return (
        f'<section class="sec" aria-label="{esc(title)}">{head}{d}{"".join(r for r, _ in rows)}</section>',
        30 + dh + sum(h for _, h in rows),
    )


def tokens_html(line: list[tuple[str, str]], cls: str = "ln") -> str:
    return f'<div class="{cls}">' + "".join(f'<span class="tk {c}">{esc(t)}</span>' for c, t in line) + "</div>"


def command(lines: list[list[tuple[str, str]]], comment: str = "", live: str = "") -> str:
    """The dark block that shows what runs (decision 29)."""
    copy = f'<button class="cp" aria-label="Copy the command">{ic("copy")}</button>'
    if live:
        body = (
            f'<sc-for list="{{{{{live}}}}}" as="ln" hint-placeholder-count="1"><div class="ln">'
            '<sc-for list="{{ln.toks}}" as="t" hint-placeholder-count="6"><span class="{{t.c}}">{{t.x}}</span></sc-for></div></sc-for>'
        )
    else:
        body = "".join(tokens_html(line) for line in lines)
    cm = f'<div class="ln cm"># {esc(comment)}</div>' if comment else ""
    return f'<div class="cmd">{copy}{cm}{body}</div>'


P, G, F, R, S = "t-p", "t-g", "t-f", "t-r", "t-s"
PROMPT = '"Write a commit message for…"'


def claude_cmd(model: str = "haiku", effort: str = "low") -> list[list[tuple[str, str]]]:
    line = [(P, "$"), (G, "git"), (G, "diff"), (F, "--cached"), (P, "|"), (G, "claude"), (F, "-p")]
    if model != "Default":
        line += [(F, "--model"), (R, model)]
    if effort != "Default":
        line += [(F, "--effort"), (R, effort.lower())]
    line += [(F, "--tools"), (R, '""'), (F, "--no-session-persistence"), (S, PROMPT)]
    return [line]


def codex_cmd(effort: str = "low") -> list[list[tuple[str, str]]]:
    line = [(P, "$"), (G, "git"), (G, "diff"), (F, "--cached"), (P, "|"), (G, "codex"), (G, "exec"), (F, "--sandbox"), (R, "read-only"), (F, "--ephemeral")]
    if effort != "Default":
        line += [(F, "-c"), (R, f"model_reasoning_effort={effort.lower()}")]
    line += [(S, PROMPT)]
    return [line]


def ollama_cmd(model: str = "qwen2.5-coder:7b") -> list[list[tuple[str, str]]]:
    return [[(P, "$"), (G, "git"), (G, "diff"), (F, "--cached"), (P, "|"), (G, "ollama"), (G, "run"), (R, model), (S, PROMPT)]]


# ---------------------------------------------------------------------------
# The pages. The data is made up but true to this Mac: git 2.33.0 in
# /usr/local/bin is too old, so Roga passes over it for Apple's 2.54.0, and the
# Gemini CLI is installed but crashes before it can report a version.

NAV = [
    [("general", "General"), ("appearance", "Appearance")],
    [("git", "Git"), ("commit", "Commit")],
    [("agents", "Agents")],
    [("advanced", "Advanced")],
]


def page_general(ctx: Ctx) -> tuple[str, int]:
    s1 = section("Windows", [
        row("Reopen windows at launch", toggle(ctx, "reopen", True, "Reopen windows at launch"),
            "Roga brings back the repositories and worktrees that were open when it quit."),
        row("Show the rail of organizations", toggle(ctx, "rail", True, "Show the rail of organizations"),
            "The column of organizations beside the sidebar. It's in the View menu too, as ⌃⌘O.", today=True),
    ])
    s2 = section("Open in", [
        row("Editor", popup("Cursor"), "For Open in Editor on a file, a folder or a worktree.", cw=110),
        row("Terminal", popup("Ghostty"), "For Open in Terminal on a worktree.", cw=110),
    ], desc="Roga lists the editors and terminals it finds in /Applications.")
    s3 = section("Updates", [
        row("Check for updates automatically", toggle(ctx, "updates", True, "Check for updates automatically"),
            "Roga looks at roga.sh once a day, and asks before it installs anything."),
    ])
    return join_sections([s1, s2, s3])


def page_appearance(ctx: Ctx) -> tuple[str, int]:
    theme = seg(ctx, "theme", ["System", "Light", "Dark"], "System", "Theme", {"System": "monitor", "Light": "sun", "Dark": "moon"})
    s1 = section("Appearance", [
        row("Theme", theme, cw=110),
        row("Text size", popup("Medium"), "For the sidebar, history and file lists. Diffs have their own size below.", cw=110),
    ])
    path = house_path()
    poses = [("Push", "rotate(-9deg)"), ("Tug of War", "rotate(8deg)"), ("Heave", "translateY(-3px) scaleY(1.04)"), ("Waddle", "rotate(4deg)")]
    houses = "".join(
        f'<div class="hs"><svg viewBox="305.5 132 573 573" style="transform:{t}" role="img" aria-label="The house, as in {esc(n)}"><path d="{path}"></path></svg>{esc(n)}</div>'
        for n, t in poses
    )
    slider = '<div class="sld"><div class="trk" role="slider" aria-label="Animation speed" aria-valuemin="0.25" aria-valuemax="3" aria-valuenow="1"><b style="width:27%"></b><i style="left:27%"></i></div><span class="sv1">1×</span></div>'
    s2 = section("Motion", [
        block(f'<div class="houses">{houses}</div>', 92),
        row("Animation speed", slider, "How fast the house moves while git runs.", today=True, cw=230),
        row("Reduce motion", popup("Follow System Settings"), "When it's on, the house stays still and its words appear in place.", cw=190),
    ])
    diff = (
        '<div class="diff" role="img" aria-label="A sample diff in the code font">'
        '<div class="dl hh"><span class="n"></span><span class="s"></span>@@ -12,4 +12,5 @@ func signIn() async throws {</div>'
        '<div class="dl"><span class="n">12</span><span class="s"> </span>    let token = try await store.token()</div>'
        '<div class="dl d"><span class="n">13</span><span class="s">-</span>    <span class="hd">return try await api.login(token)</span></div>'
        '<div class="dl a"><span class="n">13</span><span class="s">+</span>    <span class="ha">do { return try await api.login(token) }</span></div>'
        '<div class="dl a"><span class="n">14</span><span class="s">+</span>    <span class="ha">catch APIError.expired { return try await retry() }</span></div>'
        '<div class="dl"><span class="n">15</span><span class="s"> </span>}</div></div>'
    )
    s3 = section("Diffs", [
        block(diff, 6 * 20 + 2),
        row("Code font", field_("SF Mono", "Code font", width=200), "A monospace font for diffs, commands and hashes.", cw=200),
        row("Code font size", popup("Default", "· 12 pt"), cw=130),
        row("Wrap long lines", toggle(ctx, "wrap", False, "Wrap long lines")),
        row("Ignore changes to whitespace", toggle(ctx, "ws", False, "Ignore changes to whitespace"),
            help_html='Hides lines whose only change is spacing, like <span class="key">git diff -w</span>.', help="Hides lines whose only change is spacing, like git diff -w."),
    ])
    s4 = section("Lists", [
        row("A commit's files", seg(ctx, "files", ["List", "Tree"], "List", "A commit's files"), "Also in the View menu.", today=True, cw=120),
        row("Sort branches by", seg(ctx, "sort", ["Name", "Date"], "Name", "Sort branches by"), "In the refs panel. Also in its menu.", today=True, cw=130),
        row("Fold long descriptions", toggle(ctx, "fold", False, "Fold long descriptions"),
            "A commit's description starts folded to its first lines in the commit panel.", today=True),
        row("Dates", popup("Relative", "· 3 hours ago"), "In history and the commit panel.", cw=170),
    ])
    return join_sections([s1, s2, s3, s4])


def page_git(ctx: Ctx) -> tuple[str, int]:
    git_help = (
        '<span class="mono" style="color:var(--tx)">/usr/bin/git</span> · git 2.54.0 (Apple Git-157)<br>'
        'Roga passed over <span class="mono">/usr/local/bin/git</span>, which is git 2.33.0, older than 2.44.'
    )
    s1 = section("Git", [
        row("Git", '<button class="b sec">Choose…</button>', help_html=git_help, help="x" * 60, cw=90, extra=1, today=True),
        row("Name", field_("Sam Rivera", "Name"), key="user.name", cw=240),
        row("Email", field_("sam@acme.dev", "Email"), key="user.email", cw=240),
    ], desc='Roga uses the first git 2.44 or newer in your login shell\'s <span class="mono">PATH</span>. A row with a key like <span class="key">user.name</span> reads and writes your global git config, so git does the same on the command line.')
    s2 = section("Fetching and pulling", [
        row("Fetch when Roga becomes active", toggle(ctx, "fetch", True, "Fetch when Roga becomes active"),
            "Roga runs git fetch for the repository on screen, at most once a minute, so that it can say how far your branch is from its upstream. It only moves remote branches, and it never asks for credentials.", today=True),
        row("Remove branches deleted on the remote", toggle(ctx, "prune", True, "Remove branches deleted on the remote"), "When fetching.", key="fetch.prune"),
        row("When a branch has moved apart from its upstream", popup("Ask each time"), "A repository's own setting wins, like the one Remember writes.", key="pull.rebase", cw=130),
    ])
    s3 = section("Pushing", [
        row("Set the upstream on a branch's first push", toggle(ctx, "autoremote", True, "Set the upstream on a branch's first push"),
            "A new branch pushes to a branch of the same name.", key="push.autoSetupRemote"),
    ])
    return join_sections([s1, s2, s3])


def page_commit(ctx: Ctx) -> tuple[str, int]:
    s1 = section("Message", [
        row("Mark a long first line", popup("Past 72 characters"), "The count beside the first line turns red.", today=True, cw=170),
    ])
    s2 = generate_section(ctx)
    s3 = section("Committing", [
        row("Commit button", seg(ctx, "cbtn", ["Commit", "Commit and Push"], "Commit", "Commit button"), "What ⌘↩ does. The other one is ⇧⌘↩.", cw=230),
        row("Sign commits", toggle(ctx, "sign", False, "Sign commits"), "With the key in your git config, through gpg or ssh.", key="commit.gpgsign"),
    ])
    s4 = section("Discarding", [
        row("Ask before discarding", popup("More than one file"), "A hunk or a single file goes straight away, with Undo for 8 seconds.", today=True, cw=170),
    ])
    return join_sections([s1, s2, s3, s4])


def generate_section(ctx: Ctx) -> tuple[str, int]:
    instructions = "Write a commit message for the staged changes below. Start with a summary under 72 characters, in the imperative. Then leave a blank line and say why the change was made, in a few sentences."
    effort = seg(ctx, "effort", ["Default", "Low", "Medium", "High"], "Low", "Effort")
    rows = [
        row("Show the Generate button", toggle(ctx, "genbtn", True, "Show the Generate button"), "In the message box. ⌥⌘L writes a message too."),
        row("Agent", select("Claude Code", 200), "Your staged diff goes to the agent, and from there to its provider. Ollama keeps it on this Mac.", cw=200),
        row("Model", popup("haiku"), "Something fast is plenty for a commit message.", cw=110),
        row("Effort", effort, cw=290),
        row("Match the repository's style", toggle(ctx, "style", True, "Match the repository's style"), "Sends the last 20 commit subjects along with the diff."),
        block(
            '<div style="display:flex;flex-direction:column;gap:6px"><div style="display:flex;align-items:baseline"><span class="rt" style="flex:1 1 0">Instructions</span><button class="lnk">Reset to Roga\'s</button></div>'
            f'<textarea class="ta" aria-label="Instructions">{esc(instructions)}</textarea></div>',
            23 + 6 + 84,
        ),
        block(
            '<div style="display:flex;flex-direction:column;gap:7px">'
            + command(claude_cmd(), live="cmdA" if ctx.live else "")
            + '<span class="rh">It runs in the worktree\'s folder, so the agent also reads the repository\'s CLAUDE.md or AGENTS.md. Agents are set up on the Agents page.</span></div>',
            21 + 19 * 2 + 7 + 36,
        ),
    ]
    return section("Generate messages with an agent", rows)


def page_advanced(ctx: Ctx) -> tuple[str, int]:
    s1 = section("Large repositories", [
        row("Keep commit-graph files up to date", toggle(ctx, "graph", True, "Keep commit-graph files up to date"),
            "Roga runs git commit-graph write in the background, so that large repositories open quickly. It writes to each repository's objects folder and never changes your git configuration.", today=True),
    ])
    s2 = section("Commands", [
        row("Command log", '<button class="b sec">Show Log</button>', "Every git command Roga ran, with what it printed and how long it took.", cw=100),
    ])
    s3 = section("Reset", [
        row("Reset all settings", '<button class="b dng">Reset…</button>', "Puts every setting back the way it was at first launch. Your repositories stay in the sidebar.", cw=90),
    ])
    return join_sections([s1, s2, s3])


AGENTS = [
    # key, monogram, name, detail, state
    ("claude", "Cl", "Claude Code", "~/.local/bin/claude · 2.1.286", "on"),
    ("codex", "Cx", "Codex", "/opt/homebrew/bin/codex · 0.137.0", "on"),
    ("cursor", "Cu", "Cursor Agent", "~/.local/bin/cursor-agent · 2025.08.08", "off"),
    ("ollama", "Ol", "Ollama", "ollama run {model} · your command", "on"),
    ("gemini", "Ge", "Gemini CLI", "Found at /opt/homebrew/bin/gemini, but it stopped before saying its version: Library not loaded: libsimdjson.29.dylib", "broken"),
    ("copilot", "Co", "GitHub Copilot CLI", "Not found. It installs with npm install -g @github/copilot.", "missing"),
]


def agent_rows(ctx: Ctx) -> tuple[str, int]:
    rows = []
    height = 0
    for key, mono, name, detail, state in AGENTS:
        drill = ' onClick="{{go.%s}}"' % key if ctx.live and key in ("claude", "codex") else ""
        if state in ("on", "off"):
            cls = "ap"
            right = toggle(ctx, "ag_" + key, state == "on", f"Use {name}") + f'<button class="chev" aria-label="{esc(name)} settings"{drill}>{ic("right")}</button>'
            h = 59
        elif state == "broken":
            cls = "ap warn"
            right = f'<button class="b sec sm">Details</button>'
            h = 77
        else:
            cls = "ap dim"
            right = f'<button class="lnk">Install {ic("ext", "ic xs")}</button>'
            h = 59
        rows.append(
            f'<div class="ar{" off" if state in ("off", "missing", "broken") else ""}"><span class="mg" aria-hidden="true">{mono}</span>'
            f'<button class="an"{drill}><b>{esc(name)}</b><span class="{cls}">{esc(detail)}</span></button>'
            f'<div class="rc">{right}</div></div>'
        )
        height += h
    add_click = ' onClick="{{openAdd}}"' if ctx.live else ""
    rows.append(f'<button class="aradd"{add_click}>{ic("plus")}Add a Command…</button>')
    return f'<div class="lst">{"".join(rows)}</div>', height + 45 + 2


RING = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5" fill="none" stroke="var(--line)" stroke-width="2"></circle><path d="M8 2.5a5.5 5.5 0 0 1 5.5 5.5" fill="none" stroke="var(--act)" stroke-width="2" stroke-linecap="round"></path></svg>'
DOT = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="4" fill="#2f6de1"></circle></svg>'
STUCK = '<svg viewBox="0 0 24 24" aria-hidden="true" style="fill:none;stroke:var(--warn);stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round">' + ICONS["alert"] + "</svg>"
PLUGINS = "~/Library/Application Support/sh.roga.app/plugins"


def hook_rows(ctx: Ctx) -> tuple[str, int]:
    install_click = ' onClick="{{openHooks}}"' if ctx.live else ""
    rows = [
        ('<span class="mg" aria-hidden="true">Cl</span>', "Claude Code",
         f'<span class="okt">Installed</span>, as the roga-hooks plugin. Last heard from 2 minutes ago, in acme/api.',
         '<button class="b sec sm">Remove</button>', ""),
        ('<span class="mg" aria-hidden="true">Cx</span>', "Codex",
         "Not installed. Codex asks you to trust a new hook the first time it runs.",
         f'<button class="b pri sm"{install_click}>Install…</button>', ""),
        ('<span class="mg" aria-hidden="true">Cu</span>', "Cursor Agent",
         "Roga doesn't know how to hear from it yet.", "", " off"),
    ]
    out = "".join(
        f'<div class="hk{off}">{mg}<div class="an"><b>{esc(name)}</b><span class="ap dim">{detail}</span></div><div class="rc">{btn}</div></div>'
        for mg, name, detail, btn, off in rows
    )
    return f'<div class="lst">{out}</div>', 59 + 59 + 59 + 2


def page_agents(ctx: Ctx) -> tuple[str, int]:
    lst, lh = agent_rows(ctx)
    look = f'<button class="b sec sm">{ic("refresh", "ic s")}Look Again</button>'
    s1 = section("Command-line agents", [block(lst, lh)], aside=look,
                 desc="Roga looks for these in your login shell's <span class=\"mono\">PATH</span>, the way it finds git. Generating a commit message runs one on this Mac with its tools off.")
    hooks, hh = hook_rows(ctx)
    legend = (
        '<div class="lg" role="img" aria-label="How the sidebar marks a worktree">'
        f'<div class="lgr">{RING}<span class="ref">agent/fix-login</span><span class="lv">Working</span></div>'
        f'<div class="lgr">{DOT}<span class="ref">agent/search-index</span><span class="lv">Finished, and you haven\'t looked yet</span></div>'
        f'<div class="lgr">{STUCK}<span class="ref">agent/billing</span><span class="lv">Waiting for you to answer it</span></div></div>'
    )
    gk = (
        f'<div class="ntc">{ic("alert", "ic s")}<span>GitKraken\'s hooks are installed in Claude Code and Codex too. Roga\'s run alongside them, and neither needs the other.</span></div>'
    )
    s2 = section("Working status", [
        block(hooks, hh),
        block(gk, 38),
        row("Show agents in the sidebar", toggle(ctx, "marks", True, "Show agents in the sidebar"), "Marks each worktree an agent is in, and puts the ones that need you first."),
        block(legend, 3 * 26 + 4 + 12),
        row("Notify me", popup("When an agent needs me"), "A macOS notification, which opens the worktree.", cw=200),
        row("Answer permission requests in Roga", toggle(ctx, "approve", False, "Answer permission requests in Roga"),
            "Roga shows what the agent wants to run, and you allow or deny it there. The agent waits on Roga until you do."),
    ], desc="Roga can show which worktrees have an agent working, finished or waiting for you. The agents tell it through their hooks, so Roga never guesses from file changes, and it ignores folders that aren't in its sidebar.")
    return join_sections([s1, s2])


def page_agent_detail(ctx: Ctx, which: str) -> tuple[str, int]:
    if which == "claude":
        name, path, version = "Claude Code", "~/.local/bin/claude", "Claude Code 2.1.286"
        model_help, effort_help = "Passed as --model. Default leaves it to Claude Code's own settings.", "Passed as --effort, from low to max."
        model, eff = popup("Default"), popup("Default")
        flags = [
            ('--tools ""', "No tools, so it can't run commands, read other files or change anything."),
            ("--no-session-persistence", "Leaves no session behind in Claude Code's history."),
            ("-p", "Prints its answer and exits, rather than starting a conversation."),
        ]
        cmd = claude_cmd("Default", "Default")
        result = "Replied in 2.4 s"
        extra_ph = "--append-system-prompt …"
    else:
        name, path, version = "Codex", "/opt/homebrew/bin/codex", "codex-cli 0.137.0"
        model_help, effort_help = "Passed as -m. Default is the model in ~/.codex/config.toml.", "Passed as -c model_reasoning_effort."
        model, eff = popup("Default", "· gpt-6-astra"), popup("Default", "· xhigh")
        flags = [
            ("--sandbox read-only", "It can read the worktree, but can't change files or reach the network."),
            ("--ephemeral", "Leaves no session behind in Codex's history."),
            ("exec", "Prints its answer and exits, rather than starting a conversation."),
        ]
        cmd = codex_cmd("Default")
        result = "Replied in 6.1 s"
        extra_ph = "-c model_verbosity=low"
    back_click = ' onClick="{{go.agents}}"' if ctx.live else ""
    back = f'<button class="back"{back_click}>{ic("left", "ic s")}Agents</button>'
    s1 = section(name, [
        row("Command", '<button class="b sec">Choose…</button>', help_html=f'<span class="mono" style="color:var(--tx)">{esc(path)}</span> · {esc(version)}<br>Found in your login shell\'s PATH.', help="x" * 40, extra=1, cw=90),
        row("Model", model, model_help, cw=170),
        row("Effort", eff, effort_help, cw=170),
        row("Extra arguments", field_("", "Extra arguments", mono=True, width=220, placeholder=extra_ph), "Added after Roga's own.", cw=220),
        row("Time limit", popup("60 seconds"), "Roga stops the agent after this long.", cw=130),
    ], aside=toggle(ctx, "ag_" + which, True, f"Use {name}"))
    card = '<div class="card">' + "".join(f'<div class="cr"><span class="h">{esc(f)}</span><span class="v">{esc(v)}</span></div>' for f, v in flags) + "</div>"
    test = (
        '<div style="display:flex;align-items:center;gap:12px"><button class="b sec">Run a Test</button>'
        f'<span class="res"><span class="ok">{ic("check", "ic s")}{esc(result)}</span>with a two-line message for a sample diff.</span></div>'
    )
    s2 = section("How Roga runs it", [
        block(card, 3 * 18 + 2 * 7 + 20),
        block('<div style="display:flex;flex-direction:column;gap:12px">' + command(cmd) + test + "</div>", 21 + 19 * 2 + 12 + 28),
    ], desc="Each flag is there to keep a small job small. Roga always adds these, before your extra arguments.")
    if which == "claude":
        events = [
            ("UserPromptSubmit, PreToolUse", RING, "Working"),
            ("Notification, PermissionRequest", STUCK, "Waiting for you"),
            ("Stop", DOT, "Finished"),
            ("SessionEnd", "", "Gone from the sidebar"),
        ]
        status = row("Hooks", '<button class="b sec">Remove</button>',
                     help_html='<span class="okt">Installed</span>, as the roga-hooks plugin. Last heard from 2 minutes ago.', help="x" * 60, cw=90)
    else:
        events = [
            ("UserPromptSubmit, PreToolUse", RING, "Working"),
            ("PermissionRequest", STUCK, "Waiting for you"),
            ("Stop", DOT, "Finished"),
            ("SessionEnd", "", "Gone from the sidebar"),
        ]
        click = ' onClick="{{openHooks}}"' if ctx.live else ""
        status = row("Hooks", f'<button class="b pri"{click}>Install…</button>', "Not installed. Codex asks you to trust a new hook the first time it runs.", cw=90)
    ev = '<div class="card">' + "".join(
        f'<div class="cr" style="align-items:center"><span class="h">{esc(e)}</span><span class="v" style="display:flex;align-items:center;gap:7px">'
        f'<span style="width:14px;height:14px;display:block">{m}</span>{esc(t)}</span></div>'
        for e, m, t in events
    ) + "</div>"
    s3 = section("Working status", [
        status,
        block(ev, 4 * 18 + 3 * 7 + 20),
    ], desc=f'Each hook runs <span class="key">roga hook --host {which}</span>, which tells Roga the event and the folder. It returns at once, and does nothing while Roga is closed.')
    sections = [s1, s2, s3]
    joined = join_sections(sections)
    return back + joined[0], joined[1] + 2


def join_sections(sections: list[tuple[str, int]]) -> tuple[str, int]:
    return "".join(s for s, _ in sections), 22 + sum(h for _, h in sections) + 30 * (len(sections) - 1) + 28


PAGES = {
    "general": page_general,
    "appearance": page_appearance,
    "git": page_git,
    "commit": page_commit,
    "agents": page_agents,
    "advanced": page_advanced,
}


def nav(ctx: Ctx, selected: str) -> str:
    groups = []
    for group in NAV:
        items = []
        for key, title in group:
            if ctx.live:
                items.append(f'<button class="{{{{nv.{key}}}}}" onClick="{{{{go.{key}}}}}">{ic(key)}{esc(title)}</button>')
            else:
                cls = "ni on" if key == selected else "ni"
                current = ' aria-current="page"' if key == selected else ""
                items.append(f'<button class="{cls}"{current}>{ic(key)}{esc(title)}</button>')
        groups.append("".join(items))
    seps = '<div class="nsep"></div>'.join(groups)
    search = f'<label class="srch">{ic("search")}<input type="text" placeholder="Search" aria-label="Search settings"></label>'
    foot = f'<div class="nft"><span>Roga 0.2</span><button class="lnk">Release Notes {ic("ext", "ic xs")}</button></div>'
    return f'<nav class="nav" aria-label="Settings pages">{search}{seps}{foot}</nav>'


NAV_HEIGHT = 14 + 42 + 6 * 32 + 3 * 17 + 40 + 12


def window(ctx: Ctx, selected: str, content: str, content_height: int, overlay: str = "", theme_hole: str = "") -> tuple[str, int]:
    height = max(content_height + 40, NAV_HEIGHT, 560)
    cls = f"sw {theme_hole}" if theme_hole else "sw"
    markup = (
        f'<div class="{cls}" role="dialog" aria-label="Settings" style="height:{height + 53}px">'
        f'<header class="swh"><h2>Settings</h2><button class="x" aria-label="Close">{ic("x")}</button></header>'
        f'<div class="swb">{nav(ctx, selected)}<div class="ct">{content}</div></div>{overlay}</div>'
    )
    return markup, height + 53


# ---------------------------------------------------------------------------
# The commit box with a Generate button, drawn from CommitBox.swift.

STAGED = [("M", "LoginView.swift", "Sources/App/Login"), ("M", "SessionStore.swift", "Sources/App/Session")]
UNSTAGED = [("M", "APIClient.swift", "Sources/Network"), ("A", "TokenRefreshTests.swift", "Tests/AppTests"), ("M", "Info.plist", "App"), ("M", "README.md", "")]
WRITTEN = {
    "claude": ("Retry sign-in once after the session token expires", "The token was only refreshed at launch, so signing in after it expired failed until the app restarted. Refresh it on a 401 and retry the request once."),
    "codex": ("Refresh an expired session token and retry sign-in", "A 401 from the login endpoint now refreshes the token and retries once, instead of failing until relaunch."),
    "ollama": ("fix: refresh expired session token on login", ""),
}


def file_list(staged: list = STAGED, unstaged: list = UNSTAGED) -> str:
    def rows(items):
        return "".join(
            f'<div class="fr"><span class="st{" a" if s == "A" else ""}">{s}</span><span>{esc(n)}</span><span class="fd">{esc(d)}</span></div>'
            for s, n, d in items
        )
    out = ""
    if staged:
        out += f'<div class="fh">Staged <span class="n">{len(staged)}</span></div>' + rows(staged)
    out += f'<div class="fh">Unstaged <span class="n">{len(unstaged)}</span></div>' + rows(unstaged)
    return f'<div class="files">{out}</div>'


def gen_button(label: bool = True, disabled: bool = False, hover: bool = False, live: bool = False) -> str:
    cls = "gen" + (" dis" if disabled else "") + (" hv" if hover else "")
    main_click = ' onClick="{{generate}}"' if live else ""
    chev_click = ' onClick="{{togglePop}}"' if live else ""
    text = "Generate" if label else ""
    aria = "" if label else ' aria-label="Rewrite with Claude Code"'
    if live:
        return (
            f'<div class="{cls}"><button{main_click}>{ic("sparkles", "ic s")}{{{{genLabel}}}}</button>'
            f'<button aria-label="Choose an agent"{chev_click}>{ic("down", "ic xs")}</button></div>'
        )
    return (
        f'<div class="{cls}"><button{aria}>{ic("sparkles", "ic s")}{text}</button>'
        f'<button aria-label="Choose an agent">{ic("down", "ic xs")}</button></div>'
    )


def commit_box(editor: str, below: str = "", button: str = "Commit 2 Files", enabled: bool = True) -> str:
    return (
        '<div class="box"><div class="bh"><span class="lead">Commit to</span><span class="sub">agent/fix-login</span>'
        '<span class="amd"><span class="cbx" aria-hidden="true"></span>Amend</span></div>'
        f'{editor}{below}'
        f'<div class="bf"><span class="kb">⌘↩</span><button class="cbtn{"" if enabled else " dis"}">{esc(button)}</button></div></div>'
    )


def editor(inner: str, gen: str = "", ro: bool = False, count: str = "") -> str:
    c = f'<span class="cnt">{count}</span>' if count else ""
    return f'<div class="ed{" ro" if ro else ""}">{inner}{c}{gen}</div>'


def written_text(agent: str = "claude") -> str:
    subject, body = WRITTEN[agent]
    b = f'<div class="bd">{esc(body)}</div>' if body else ""
    return f'<div class="sj">{esc(subject)}</div>{b}'


def popover(agent: str = "claude", style: str = "", live: bool = False) -> str:
    if live:
        ags = (
            '<sc-for list="{{agents}}" as="a" hint-placeholder-count="3"><button class="{{a.cls}}" onClick="{{a.pick}}"><span class="rd"></span>'
            '<span class="ot"><span>{{a.name}}</span><span class="o2">{{a.sub}}</span></span></button></sc-for>'
        )
        models = '<sc-for list="{{models}}" as="m" hint-placeholder-count="3"><button class="{{m.cls}}" onClick="{{m.pick}}">{{m.name}}</button></sc-for>'
        effort = (
            '<sc-if value="{{hasEffort}}" hint-placeholder-val="{{true}}"><div class="pvr"><span class="fl">Effort</span><div class="seg" role="group" aria-label="Effort">'
            '<sc-for list="{{efforts}}" as="e" hint-placeholder-count="4"><button class="{{e.cls}}" onClick="{{e.pick}}">{{e.name}}</button></sc-for></div></div></sc-if>'
        )
        cmd = command([], live="cmdG")
        gen_click = ' onClick="{{generate}}"'
    else:
        items = [("claude", "Claude Code", "haiku · low effort"), ("codex", "Codex", "gpt-6-astra · default effort"), ("ollama", "Ollama", "qwen2.5-coder:7b, on this Mac")]
        ags = "".join(
            f'<button class="ag{" on" if k == agent else ""}" aria-pressed="{"true" if k == agent else "false"}"><span class="rd"></span><span class="ot"><span>{n}</span><span class="o2">{esc(s)}</span></span></button>'
            for k, n, s in items
        )
        models = "".join(f'<button class="chip{" on" if m == "haiku" else ""}">{m}</button>' for m in ["Default", "haiku", "sonnet", "opus"])
        effort = '<div class="pvr"><span class="fl">Effort</span>' + seg(Ctx(), "pe", ["Default", "Low", "Medium", "High"], "Low", "Effort") + "</div>"
        cmd = command(claude_cmd())
        gen_click = ""
    return (
        f'<div class="pv" role="dialog" aria-label="Write the message with" style="{style}"><div class="pvin">'
        '<div class="pvt">Write the message with</div>'
        f'<div class="ags">{ags}</div>'
        f'<div class="pvr"><span class="fl">Model</span><div class="chips">{models}</div></div>{effort}'
        f'<div style="display:flex;flex-direction:column-reverse"><div>{cmd}</div><div class="btns"><span class="lft rh">Remembered for next time</span><button class="b pri"{gen_click}>Generate</button></div></div>'
        '</div><span class="pva" style="right:22px"></span></div>'
    )


def changes_menu() -> str:
    items = [
        ("", "Stage", "⌘S"), ("", "Stage All", "⌥⌘S"), ("", "Unstage All", "⇧⌥⌘S"), None,
        ("", "Write Message", "⌘L"), ("on", "Generate Message", "⌥⌘L"), ("sub", "Generate With", ""), None,
        ("", "Commit", "⌘↩"), ("", "Commit and Push", "⇧⌘↩"), ("", "Amend", "⌥⌘↩"),
    ]
    rows = []
    for item in items:
        if item is None:
            rows.append('<div class="ms"></div>')
            continue
        kind, title, keys = item
        cls = "mi on" if kind == "on" else "mi"
        arrow = ic("right", "ic xs") if kind == "sub" else ""
        rows.append(f'<div class="{cls}"><span class="ck"></span><span>{title}</span><span class="kb">{keys}{arrow}</span></div>')
    sub = (
        '<div class="menu sub2" style="left:290px;top:146px">'
        f'<div class="mi"><span class="ck">{ic("check", "ic xs")}</span><span>Claude Code</span><span class="kb dim">haiku</span></div>'
        '<div class="mi"><span class="ck"></span><span>Codex</span><span class="kb dim">gpt-6-astra</span></div>'
        '<div class="mi"><span class="ck"></span><span>Ollama</span><span class="kb dim">qwen2.5-coder</span></div>'
        '<div class="ms"></div><div class="mi"><span class="ck"></span><span>Agent Settings…</span></div></div>'
    )
    return f'<div style="position:relative;width:340px;height:440px"><div class="menu" role="menu" aria-label="Changes">{"".join(rows)}</div>{sub}</div>'


def generate_sheet() -> str:
    hint = "fix login after token expiry"
    cells = [
        ("Nothing written yet", "staged files, an empty message",
         file_list() + commit_box(editor('<span class="ph">Message</span>', gen_button()), enabled=False)),
        ("Picking an agent", "from the arrow, which remembers",
         file_list() + commit_box(editor('<span class="ph">Message</span>', gen_button(hover=True)), enabled=False)
         + popover(style="right:-2px;bottom:122px")),
        ("Writing", "the box waits, and Stop gives it back",
         file_list() + commit_box(editor('<div class="bar" style="width:78%"></div><div class="bar" style="width:92%;margin-top:12px"></div><div class="bar" style="width:60%"></div>', ro=True),
                                  '<div class="wrk"><span class="spin" aria-hidden="true"></span>Claude Code is writing… 3 s<button class="act">Stop</button></div>', enabled=False)),
        ("Written", "yours to edit, with Undo",
         file_list() + commit_box(editor(written_text(), gen_button(label=False), count="51"),
                                  f'<div class="note">{ic("sparkles", "ic s")}Claude Code · haiku wrote this in 4 s.<button class="act">Undo</button></div>')),
        ("Your words as a hint", "with text in the box, it rewrites from there",
         file_list() + commit_box(editor(f'<div class="sj">{esc(hint)}</div>', gen_button(label=False, hover=True), count=str(len(hint))))
         + '<div class="tip" style="right:-8px;bottom:142px">Rewrite with Claude Code, starting from your words  ⌥⌘L</div>'),
        ("It didn't work", "the message stays, and so does what the agent said",
         file_list() + commit_box(editor('<span class="ph">Message</span>', gen_button()),
                                  '<div class="fail"><b>Claude Code didn\'t write a message</b><span class="o">Invalid API key · Please run /login</span>'
                                  '<span class="fa"><button class="act">Try Again</button><button class="act">Agent Settings…</button></span></div>', enabled=False)),
        ("Nothing staged", "there's nothing to describe yet",
         file_list(staged=[]) + commit_box(editor('<span class="ph">Message</span>', gen_button(disabled=True, hover=True)), button="Commit", enabled=False)
         + '<div class="tip" style="right:-8px;bottom:122px">Stage files to write a message for them</div>'),
        ("In the Changes menu", "with the agent picked from a submenu", changes_menu()),
    ]
    out = []
    for title, sub, inner in cells:
        panel = inner if title == "In the Changes menu" else f'<div class="panel">{inner}</div>'
        out.append(f'<div class="cs"><div class="cap">{esc(title)} <i>· {esc(sub)}</i></div>{panel}</div>')
    return f'<div class="sheet">{"".join(out)}</div>'


# ---------------------------------------------------------------------------
# Boards.


def dc(title: str, w: int, h: int, body: str, props: dict, script: str) -> str:
    props = dict(props)
    props["$preview"] = {"width": w, "height": h}
    data = json.dumps(props, ensure_ascii=False).replace("'", "&#39;")
    return (
        '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        f"<title>{esc(title)}</title>\n<script src=\"./support.js\"></script>\n</head>\n<body>\n<x-dc>\n"
        f"<helmet>\n<style>{CSS}</style>\n</helmet>\n{body}\n</x-dc>\n"
        f"<script type=\"text/x-dc\" data-dc-script data-props='{data}'>\n{script}\n</script>\n</body>\n</html>\n"
    )


STATIC_PROPS = {
    "theme": {"editor": "enum", "options": ["light", "dark"], "default": "light", "section": "Settings"},
    "today": {"editor": "boolean", "default": True, "section": "Settings"},
}
STATIC_SCRIPT = """class Component extends DCLogic {
  renderVals() {
    return { th: (this.props.theme ?? "%s") === "dark" ? "th-d" : "th-l", today: this.props.today ?? true };
  }
}"""


@dataclass
class Board:
    file: str
    title: str
    w: int
    h: int
    html: str
    interactive: bool = False


def settings_board(file: str, title: str, page: str, theme: str = "light", overlay: str = "", selected: str | None = None) -> Board:
    ctx = Ctx()
    if page in ("claude", "codex"):
        content, ch = page_agent_detail(ctx, page)
    else:
        content, ch = PAGES[page](ctx)
    win, wh = window(ctx, selected or page, content, ch, overlay)
    w, h = 960, wh + 80
    body = f'<div class="board {{{{th}}}}" style="width:{w}px;height:{h}px">{win}</div>'
    return Board(file, title, w, h, dc(title, w, h, body, {**STATIC_PROPS, "theme": {**STATIC_PROPS["theme"], "default": theme}}, STATIC_SCRIPT % theme))


def add_dialog() -> str:
    return (
        '<div class="over"><div class="scrim"></div><div class="dlg" role="dialog" aria-label="Add a command"><div class="dtop">'
        f'<div class="dhd"><h3 class="dti">Add a command</h3><button class="x" aria-label="Close">{ic("x")}</button></div>'
        '<p class="msg">Any program that reads from standard input and prints a message will do. Roga writes the instructions and the diff to its input, and uses what it prints.</p>'
        '<div class="fld"><label for="an">Name</label><input id="an" class="tf" type="text" value="Ollama"></div>'
        '<div class="fld"><label for="ac">Command</label><input id="ac" class="tf mono" type="text" value="ollama run {model}">'
        '<span class="rh"><span class="key">{model}</span> and <span class="key">{effort}</span> are filled in from what\'s picked. Add <span class="key">{prompt}</span> for a program that wants the instructions as an argument.</span></div>'
        '<div class="fld"><label for="am">Models</label><input id="am" class="tf mono" type="text" value="qwen2.5-coder:7b, llama3.2">'
        '<span class="rh">Optional. They show in the model picker, and the first is the default.</span></div>'
        '</div><div class="dft">'
        + command(ollama_cmd())
        + f'<div class="btns"><span class="lft res"><button class="b sec">Test</button><span class="ok">{ic("check", "ic s")}3 lines in 3.1 s</span></span><button class="b sec">Cancel</button><button class="b pri">Add Command</button></div>'
        "</div></div></div>"
    )


def hooks_dialog(live: bool = False) -> str:
    def c(attr: str) -> str:
        return f' onClick="{{{{{attr}}}}}"' if live else ""
    lines = [
        [(P, "$"), (G, "claude"), (G, "plugin"), (G, "marketplace"), (G, "add"), (R, PLUGINS.replace(" ", "\\ "))],
        [(P, "$"), (G, "claude"), (G, "plugin"), (G, "install"), (R, "roga-hooks@roga")],
        [(P, "$"), (G, "codex"), (G, "plugin"), (G, "marketplace"), (G, "add"), (R, PLUGINS.replace(" ", "\\ "))],
        [(P, "$"), (G, "codex"), (G, "plugin"), (G, "add"), (R, "roga-hooks@roga")],
    ]
    also = toggle(Ctx(), "alsoCodex", True, "Install in Codex too")
    return (
        '<div class="over"><div class="scrim"></div><div class="dlg" role="dialog" aria-label="Install Roga\'s hooks"><div class="dtop">'
        f'<div class="dhd"><h3 class="dti">Install Roga\'s hooks in Claude Code</h3><button class="x" aria-label="Close"{c("closeHooks")}>{ic("x")}</button></div>'
        '<p class="msg">Claude Code will tell Roga when a session starts, works, asks you something and stops, and in which folder. The hooks only report, so they never change what Claude Code does.</p>'
        '<div class="card">'
        '<div class="cr"><span class="h" style="width:150px">roga-hooks</span><span class="v">A plugin, kept with Roga\'s files in Application Support.</span></div>'
        '<div class="cr"><span class="h" style="width:150px">~/.claude/settings.json</span><span class="v">Gets the plugin\'s folder and turns it on, through Claude Code\'s own commands.</span></div>'
        '<div class="cr"><span class="h" style="width:150px">Remove</span><span class="v">Runs claude plugin uninstall, and leaves nothing behind.</span></div></div>'
        f'<div class="tgr"><div class="rl"><span class="rt">Install in Codex too</span><span class="rh">Codex was found, and its hooks work the same way.</span></div>{also}</div>'
        '</div><div class="dft">'
        + command(lines)
        + f'<div class="btns"><button class="b sec"{c("closeHooks")}>Cancel</button><button class="b pri"{c("closeHooks")}>Install</button></div>'
        "</div></div></div>"
    )


def generate_board() -> Board:
    w, h = 4 * 340 + 3 * 40 + 88, 2 * (440 + 33) + 44 + 80
    body = f'<div class="board {{{{th}}}}" style="width:{w}px;height:{h}px;justify-content:flex-start;padding:40px 44px">{generate_sheet()}</div>'
    props = {"theme": STATIC_PROPS["theme"]}
    script = 'class Component extends DCLogic {\n  renderVals() {\n    return { th: (this.props.theme ?? "light") === "dark" ? "th-d" : "th-l" };\n  }\n}'
    return Board("St-Generate.dc.html", "The Generate button, state by state", w, h, dc("The Generate button, state by state", w, h, body, props, script))


def try_settings_board() -> Board:
    ctx = Ctx(live=True)
    pages_markup = []
    heights = []
    for key in list(PAGES) + ["claude", "codex"]:
        content, ch = page_agent_detail(ctx, key) if key in ("claude", "codex") else PAGES[key](ctx)
        heights.append(ch)
        hint = "{{true}}" if key == "general" else "{{false}}"
        pages_markup.append(f'<sc-if value="{{{{pg.{key}}}}}" hint-placeholder-val="{hint}">{content}</sc-if>')
    content_height = 640
    overlay = (
        f'<sc-if value="{{{{addOpen}}}}" hint-placeholder-val="{{{{false}}}}">{add_dialog_live()}</sc-if>'
        f'<sc-if value="{{{{hooksOpen}}}}" hint-placeholder-val="{{{{false}}}}">{hooks_dialog(live=True)}</sc-if>'
    )
    win, wh = window(ctx, "general", "".join(pages_markup), content_height, overlay, theme_hole="{{th}}")
    # The live window scrolls rather than growing, the way the real one would.
    win = win.replace('<div class="ct">', '<div class="ct" style="overflow:auto">', 1)
    w, h = 960, wh + 80
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px;background:#deded9">{win}</div>'
    script = live_settings_script(ctx)
    props = {"today": {"editor": "boolean", "default": True, "section": "Settings"}}
    return Board("St-Try.dc.html", "Try the settings", w, h, dc("Try the settings", w, h, body, props, script), interactive=True)


def add_dialog_live() -> str:
    markup = add_dialog()
    markup = markup.replace('<button class="x" aria-label="Close">', '<button class="x" aria-label="Close" onClick="{{closeAdd}}">', 1)
    markup = markup.replace('<button class="b sec">Cancel</button>', '<button class="b sec" onClick="{{closeAdd}}">Cancel</button>')
    markup = markup.replace('<button class="b pri">Add Command</button>', '<button class="b pri" onClick="{{closeAdd}}">Add Command</button>')
    return markup


def live_settings_script(ctx: Ctx) -> str:
    toggles = json.dumps(ctx.toggles)
    segs = json.dumps({k: {"options": o, "selected": s} for k, (o, s) in ctx.segs.items()})
    return """class Component extends DCLogic {
  constructor(props) {
    super(props);
    const segs = %s;
    const picked = {};
    Object.keys(segs).forEach((k) => { picked[k] = segs[k].selected; });
    this.segs = segs;
    this.state = { page: "general", on: %s, picked: picked, addOpen: false, hooksOpen: false };
  }
  key(k, o) { return k + "__" + o.toLowerCase().replace(/[^a-z0-9]/g, ""); }
  renderVals() {
    const s = this.state;
    const pages = ["general", "appearance", "git", "commit", "agents", "advanced", "claude", "codex"];
    const section = (p) => (p === "claude" || p === "codex") ? "agents" : p;
    const pg = {}, nv = {}, go = {};
    pages.forEach((p) => {
      pg[p] = s.page === p;
      nv[p] = section(s.page) === p ? "ni on" : "ni";
      go[p] = () => this.setState({ page: p });
    });
    const tg = {}, tp = {}, flip = {};
    Object.keys(s.on).forEach((k) => {
      tg[k] = s.on[k] ? "tg on" : "tg";
      tp[k] = s.on[k] ? "true" : "false";
      flip[k] = () => this.setState({ on: Object.assign({}, s.on, { [k]: !s.on[k] }) });
    });
    const sg = {}, pick = {};
    Object.keys(this.segs).forEach((k) => {
      this.segs[k].options.forEach((o) => {
        const id = this.key(k, o);
        sg[id] = s.picked[k] === o ? "on" : "";
        pick[id] = () => this.setState({ picked: Object.assign({}, s.picked, { [k]: o }) });
      });
    });
    const effort = s.picked.effort || "Low";
    const toks = [["t-p","$"],["t-g","git"],["t-g","diff"],["t-f","--cached"],["t-p","|"],["t-g","claude"],["t-f","-p"],["t-f","--model"],["t-r","haiku"]];
    if (effort !== "Default") { toks.push(["t-f","--effort"], ["t-r", effort.toLowerCase()]); }
    toks.push(["t-f","--tools"],["t-r","\\"\\""],["t-f","--no-session-persistence"],["t-s","\\"Write a commit message for…\\""]);
    const cmdA = [{ toks: toks.map((t) => ({ c: "tk " + t[0], x: t[1] })) }];
    return {
      pg, nv, go, tg, tp, flip, sg, pick, cmdA,
      th: s.picked.theme === "Dark" ? "th-d" : "th-l",
      today: this.props.today ?? true,
      addOpen: s.addOpen,
      openAdd: () => this.setState({ addOpen: true }),
      closeAdd: () => this.setState({ addOpen: false }),
      hooksOpen: s.hooksOpen,
      openHooks: () => this.setState({ hooksOpen: true }),
      closeHooks: () => this.setState({ hooksOpen: false }),
    };
  }
}""" % (segs, toggles)


def try_generate_board() -> Board:
    w, h = 960, 640
    ed = (
        '<div class="ed{{edCls}}"><sc-if value="{{busy}}" hint-placeholder-val="{{false}}">'
        '<div class="bar" style="width:78%"></div><div class="bar" style="width:92%;margin-top:12px"></div><div class="bar" style="width:60%"></div></sc-if>'
        '<sc-if value="{{notBusy}}" hint-placeholder-val="{{true}}"><textarea aria-label="Message" placeholder="Message" value="{{msg}}" onChange="{{type}}"></textarea></sc-if>'
        '<span class="cnt">{{count}}</span>'
        '<sc-if value="{{notBusy}}" hint-placeholder-val="{{true}}">' + gen_button(live=True) + "</sc-if></div>"
    )
    below = (
        '<sc-if value="{{busy}}" hint-placeholder-val="{{false}}"><div class="wrk"><span class="spin" aria-hidden="true"></span>{{agentName}} is writing…<button class="act" onClick="{{stop}}">Stop</button></div></sc-if>'
        f'<sc-if value="{{{{written}}}}" hint-placeholder-val="{{{{false}}}}"><div class="note">{ic("sparkles", "ic s")}{{{{writtenBy}}}}<button class="act" onClick="{{{{undo}}}}">Undo</button></div></sc-if>'
        '<sc-if value="{{failed}}" hint-placeholder-val="{{false}}"><div class="fail"><b>{{agentName}} didn\'t write a message</b><span class="o">Invalid API key · Please run /login</span>'
        '<span class="fa"><button class="act" onClick="{{generate}}">Try Again</button><button class="act">Agent Settings…</button></span></div></sc-if>'
    )
    box = (
        '<div class="box"><div class="bh"><span class="lead">Commit to</span><span class="sub">agent/fix-login</span>'
        '<span class="amd"><span class="cbx" aria-hidden="true"></span>Amend</span></div>'
        f"{ed}{below}"
        '<div class="bf"><span class="kb">⌘↩</span><button class="{{commitCls}}">Commit 2 Files</button></div></div>'
    )
    pop = f'<sc-if value="{{{{popOpen}}}}" hint-placeholder-val="{{{{false}}}}">{popover(live=True, style="right:-2px;bottom:122px")}</sc-if>'
    panel = f'<div class="panel" style="height:470px">{file_list()}{box}{pop}</div>'
    controls = (
        '<div class="ctl"><span class="gl">Next run</span>'
        '<button class="{{okCls}}" onClick="{{setOk}}">Works</button><button class="{{failCls}}" onClick="{{setFail}}">Fails</button>'
        '<span class="gl" style="margin-left:12px">Theme</span>'
        '<button class="{{lightCls}}" onClick="{{setLight}}">Light</button><button class="{{darkCls}}" onClick="{{setDark}}">Dark</button>'
        '<span class="gl" style="margin-left:auto">Press Generate, or the arrow beside it. Type a few words first to see a rewrite.</span></div>'
    )
    body = (
        f'<div class="board {{{{th}}}}" style="width:{w}px;height:{h}px;align-items:center;padding-top:60px">{controls}'
        f'<div style="display:flex;gap:48px;align-items:center"><div style="width:300px;display:flex;flex-direction:column;gap:10px">'
        '<div class="cap">The commit box, with Generate</div><p class="rh" style="margin:0">Generate uses the agent, model and effort picked last time. The arrow opens the picker, and the command at its bottom follows what you pick. A run takes about two seconds here.</p></div>'
        f"{panel}</div></div>"
    )
    script = """class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.agents = {
      claude: { name: "Claude Code", models: ["Default", "haiku", "sonnet", "opus"], effort: true },
      codex: { name: "Codex", models: ["Default", "gpt-6-astra"], effort: true },
      ollama: { name: "Ollama", models: ["qwen2.5-coder:7b", "llama3.2"], effort: false }
    };
    this.written = %s;
    this.state = { phase: "ready", agent: "claude", model: { claude: "haiku", codex: "Default", ollama: "qwen2.5-coder:7b" }, effort: { claude: "Low", codex: "Default" }, msg: "", prev: "", pop: false, fail: false, dark: false, secs: 0 };
  }
  componentWillUnmount() { clearTimeout(this.timer); }
  run() {
    clearTimeout(this.timer);
    const s = this.state;
    this.setState({ phase: "writing", pop: false, prev: s.msg });
    this.timer = setTimeout(() => {
      if (this.state.fail) { this.setState({ phase: "failed", msg: this.state.prev }); return; }
      const w = this.written[this.state.agent];
      this.setState({ phase: "written", msg: w[1] ? w[0] + "\\n\\n" + w[1] : w[0] });
    }, 2200);
  }
  tokens() {
    const s = this.state, a = s.agent, m = s.model[a], e = s.effort[a];
    const t = [["t-p","$"],["t-g","git"],["t-g","diff"],["t-f","--cached"],["t-p","|"]];
    if (a === "claude") {
      t.push(["t-g","claude"],["t-f","-p"]);
      if (m !== "Default") t.push(["t-f","--model"],["t-r",m]);
      if (e !== "Default") t.push(["t-f","--effort"],["t-r",e.toLowerCase()]);
      t.push(["t-f","--tools"],["t-r","\\"\\""],["t-f","--no-session-persistence"]);
    } else if (a === "codex") {
      t.push(["t-g","codex"],["t-g","exec"],["t-f","--sandbox"],["t-r","read-only"],["t-f","--ephemeral"]);
      if (m !== "Default") t.push(["t-f","-m"],["t-r",m]);
      if (e !== "Default") t.push(["t-f","-c"],["t-r","model_reasoning_effort=" + e.toLowerCase()]);
    } else {
      t.push(["t-g","ollama"],["t-g","run"],["t-r",m]);
    }
    t.push(["t-s", s.msg.trim() ? "\\"Rewrite this commit message…\\"" : "\\"Write a commit message for…\\""]);
    return [{ toks: t.map((x) => ({ c: "tk " + x[0], x: x[1] })) }];
  }
  renderVals() {
    const s = this.state, a = this.agents[s.agent];
    const busy = s.phase === "writing";
    const subject = s.msg.split("\\n")[0];
    const agentSub = (k) => {
      const ag = this.agents[k], m = s.model[k];
      if (!ag.effort) return m + ", on this Mac";
      const e = s.effort[k];
      return (m === "Default" ? "default model" : m) + " · " + (e === "Default" ? "default" : e.toLowerCase()) + " effort";
    };
    return {
      th: s.dark ? "th-d" : "th-l",
      busy, notBusy: !busy,
      written: s.phase === "written",
      failed: s.phase === "failed",
      popOpen: s.pop && !busy,
      edCls: busy ? " ro" : "",
      msg: s.msg,
      count: subject.length ? String(subject.length) : "",
      genLabel: s.msg.trim() ? "" : "Generate",
      agentName: a.name,
      writtenBy: a.name + (s.model[s.agent] === "Default" ? "" : " · " + s.model[s.agent]) + " wrote this in 2 s.",
      commitCls: s.msg.trim() && !busy ? "cbtn" : "cbtn dis",
      cmdG: this.tokens(),
      hasEffort: a.effort,
      agents: Object.keys(this.agents).map((k) => ({ name: this.agents[k].name, sub: agentSub(k), cls: k === s.agent ? "ag on" : "ag", pick: () => this.setState({ agent: k }) })),
      models: a.models.map((m) => ({ name: m, cls: m === s.model[s.agent] ? "chip on" : "chip", pick: () => this.setState({ model: Object.assign({}, s.model, { [s.agent]: m }) }) })),
      efforts: ["Default", "Low", "Medium", "High"].map((e) => ({ name: e, cls: e === s.effort[s.agent] ? "on" : "", pick: () => this.setState({ effort: Object.assign({}, s.effort, { [s.agent]: e }) }) })),
      type: (ev) => this.setState({ msg: ev.target.value, phase: s.phase === "written" || s.phase === "failed" ? "ready" : s.phase }),
      generate: () => this.run(),
      togglePop: () => this.setState({ pop: !s.pop }),
      stop: () => { clearTimeout(this.timer); this.setState({ phase: "ready", msg: s.prev }); },
      undo: () => this.setState({ phase: "ready", msg: s.prev }),
      okCls: s.fail ? "sb2" : "sb2 on", failCls: s.fail ? "sb2 on" : "sb2",
      setOk: () => this.setState({ fail: false }), setFail: () => this.setState({ fail: true }),
      lightCls: s.dark ? "sb2" : "sb2 on", darkCls: s.dark ? "sb2 on" : "sb2",
      setLight: () => this.setState({ dark: false }), setDark: () => this.setState({ dark: true })
    };
  }
}""" % json.dumps({k: list(v) for k, v in WRITTEN.items()})
    return Board("St-Generate-Try.dc.html", "Try Generate", w, h, dc("Try Generate", w, h, body, {}, script), interactive=True)


def all_boards() -> list[list[Board]]:
    row1 = [
        settings_board("St-General.dc.html", "General", "general"),
        settings_board("St-Appearance.dc.html", "Appearance", "appearance"),
        settings_board("St-Git.dc.html", "Git", "git"),
        settings_board("St-Commit.dc.html", "Commit", "commit"),
        settings_board("St-Advanced.dc.html", "Advanced", "advanced"),
    ]
    row2 = [
        settings_board("St-Agents.dc.html", "Agents", "agents"),
        settings_board("St-Agent-Claude.dc.html", "Agents › Claude Code", "claude", selected="agents"),
        settings_board("St-Agent-Codex-Dark.dc.html", "Agents › Codex, dark", "codex", theme="dark", selected="agents"),
        settings_board("St-Agent-Hooks.dc.html", "Agents › Install hooks…", "agents", overlay=hooks_dialog()),
        settings_board("St-Agent-Add.dc.html", "Agents › Add a Command…", "agents", overlay=add_dialog()),
        try_settings_board(),
    ]
    row3 = [generate_board(), try_generate_board()]
    return [row1, row2, row3]


# ---------------------------------------------------------------------------
# Notes that sit under the boards, in the canvas's voice.

TITLES = [
    "Settings, as a larger dialog with pages",
    "Agents: finding them, running them, and hearing from them",
    "Generate, in the commit box",
]

NOTES = {
    "St-General.dc.html": "Ordinary Mac app settings that Roga doesn't have yet. Editor and Terminal are for Open in Editor and Open in Terminal, which most Git clients have and Roga would need first. The rail switch is the View menu's ⌃⌘O, kept here too so it's findable.",
    "St-Appearance.dc.html": "The house's speed slider moves here from today's window, with the four animations above it. Diffs follow the Claude app's Code section, with a sample drawn in the code font. Lists gathers what's only in menus today, the file layout, the branch sort and folded descriptions, so every remembered choice has one home.",
    "St-Git.dc.html": "Which git Roga runs, and why it passed one over, which GitInstallation already records for Settings to show. Rows with a key like fetch.prune write your global git config, the same way Remember writes pull.rebase in the rebase or merge dialog (decision 29), so nothing Roga does is hidden from the command line.",
    "St-Commit.dc.html": "Generating messages lives here rather than on the Agents page, because this is where you'd look for it: one agent, model and effort, the repository's recent subjects for style, editable instructions, and the exact command at the bottom. Today the count turns red past 72 and discarding asks for more than one file (decision 39). Both become choices, with today's behavior as the default.",
    "St-Advanced.dc.html": "Keep commit-graph files up to date moves here from today's window, word for word. The command log is GitRunner's CommandLog, which has no window yet. Reset asks first, since it can't be undone.",
    "St-Agents.dc.html": "What's installed, and how agents tell Roga what they're doing. Roga finds agents the way it finds git, and says why one can't be used, the way Settings does for an old git. Gemini is a real case from this Mac: installed, but it crashes before saying its version. Working status is the hooks the Work view has been waiting for, installed the way GitKraken installs its own, which this Mac already has.",
    "St-Agent-Claude.dc.html": "Each agent has its own page, from the arrow on its row. Default leaves the model and effort to the agent's own settings. How Roga runs it lists the flags Roga always adds and why, so a commit message can't touch files. Working status lists which of the agent's hook events mean working, waiting for you, finished and gone.",
    "St-Agent-Codex-Dark.dc.html": "The same page for Codex, in dark. Its defaults come from ~/.codex/config.toml, so the popups say what Default means. Codex is sandboxed read-only rather than having its tools turned off, and its hooks aren't installed yet, so Install… is the main button.",
    "St-Agent-Hooks.dc.html": "Installing hooks is a dialog with the commands at the bottom, as every dialog is (decision 29). Roga ships a plugin and installs it with each agent's own plugin commands, which is how GitKraken does it, so it shows up in /plugin and comes out cleanly. Each hook is roga hook --host claude, a small helper that returns at once and does nothing while Roga is closed.",
    "St-Agent-Add.dc.html": "Add a Command takes anything that reads stdin and prints a message, like Ollama or llm, for people who'd rather keep diffs on their Mac. The placeholders fill in what's picked, and Test runs it on a sample diff before it's saved.",
    "St-Try.dc.html": "Press Play. Click through the pages, flip switches, pick Dark under Appearance, and open Claude Code or Codex from the Agents page. Install… and Add a Command open their dialogs. Rows tagged In the app are what's in today's settings window or menus.",
    "St-Generate.dc.html": "Generate sits inside the message box, at the bottom right, where VS Code and GitHub Desktop put theirs. With text in the box it shrinks to the sparkle and rewrites from your words. The arrow opens a popover for agent, model and effort, laid out as the dialogs are, with the command along the bottom edge. ⌥⌘L pairs with Write Message's ⌘L.",
    "St-Generate-Try.dc.html": "Press Play. Generate writes a message after about two seconds, Undo puts back what was there, and Stop gives the box back. Switch Next run to Fails to see the error, and pick an agent from the arrow to watch the command change.",
}

INTRO = (
    "Settings drawn the way the Claude app lays out its own, as you asked: a larger dialog with a sidebar of pages, rows with gray help, and switches on the right. "
    "The look is the Dialogs page's, so a settings window and a dialog read as one family. Every setting in today's window and every remembered menu choice has a home, "
    "and each is tagged In the app (turn the tag off under Tweaks). Everything else is a proposal from what Git clients commonly offer, for you to strike out."
)
AGENT_INTRO = (
    "One page for the command-line agents Roga can call and how they report back. Roga finds them in the login shell's PATH, runs one with its tools off to write a commit message, "
    "and, once its hooks are installed, hears when an agent starts, needs you and stops, so the sidebar can mark the worktree it's in."
)
GEN_INTRO = (
    "The button that writes a commit message. A click uses the agent, model and effort picked last time, and the arrow beside it changes them. "
    "Nothing is committed until you press Commit, and Undo puts back whatever was in the box."
)


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    intros = [INTRO, AGENT_INTRO, GEN_INTRO]
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tSt{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": width, "page": PAGE_ID}
        notes[f"nSt{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": intros[index], "page": PAGE_ID}
        x = 0
        tallest = 0
        for b in row_boards:
            entry = {"x": x, "y": y, "w": b.w, "h": b.h, "page": PAGE_ID, "title": b.title}
            if b.interactive:
                entry["is_interactive"] = True
            boards[b.file] = entry
            if b.file in NOTES:
                notes["n" + re.sub(r"[^A-Za-z0-9]", "", b.file.removesuffix(".dc.html"))] = {"x": x, "y": y + b.h + 40, "w": min(b.w, 720), "text": NOTES[b.file], "page": PAGE_ID}
            x += b.w + 80
            tallest = max(tallest, b.h)
        y += tallest + 40 + 300 + 640
    return boards, notes


@click.command()
@click.option("--out", "out", type=click.Path(file_okay=False, path_type=Path), required=True, help="The folder that holds project/.")
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Settings page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Settings boards, and optionally merge them into a canvas.json."""
    rows = all_boards()
    project = out / "project"
    project.mkdir(parents=True, exist_ok=True)
    for b in (b for r in rows for b in r):
        (project / b.file).write_text(b.html)
        click.echo(f"{b.file}  {b.w}×{b.h}  {len(b.html) // 1024} KB")
    if canvas:
        data = json.loads(canvas.read_text())
        boards, notes = layout(rows)
        data["boards"] = {k: v for k, v in data["boards"].items() if v.get("page") != PAGE_ID}
        data["notes"] = {k: v for k, v in data["notes"].items() if v.get("page") != PAGE_ID}
        data["boards"].update(boards)
        data["notes"].update(notes)
        data["order"] = [f for f in data["order"] if f in data["boards"]] + [f for f in boards if f not in data["order"]]
        if not any(p["id"] == PAGE_ID for p in data["pages"]):
            data["pages"].append({"id": PAGE_ID, "name": PAGE_NAME})
        # The page that opens first is the user's call, so launch stays as it was.
        canvas.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        click.echo(f"Merged {len(boards)} boards and {len(notes)} notes into {canvas}")


if __name__ == "__main__":
    main()
