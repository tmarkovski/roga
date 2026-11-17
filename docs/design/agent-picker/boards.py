# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Agent picker boards for the design canvas "yaga layout options".

How the default agent is marked in Generate's popover, where each agent's
model and effort are changed, and how Resolve and Fix open the same popover
from a chevron where they run. It builds on decision 89, one default agent for Generate, Resolve
and Fix, with custom agents beside Claude Code and Codex.

    uv run docs/design/agent-picker/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Boards that an earlier run put on the page and this one doesn't are listed at
the end, so they can be removed from the canvas when it's published.
"""

from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass
from pathlib import Path

import click

PAGE_ID = "agentpicker"
PAGE_NAME = "Agent picker"


def esc(text: str) -> str:
    return html.escape(text, quote=True)


# ---------------------------------------------------------------- styles

CSS = r"""
body{margin:0}
*{box-sizing:border-box}
.th-l{--bg:#deded9;--wtx:#1f1f1e;--wtx2:#5c5c58;--sheet:#fff;--surface:#fafaf9;--tx:#1c1c1a;--tx2:#696964;--tx3:#a3a39e;--card:#f2f2f0;--line:#d6d6d3;--hair:#e6e6e3;--sec:#efefed;--ink:#1a1a18;--onink:#fff;--term:#272822;--hover:rgba(0,0,0,.05);--mbg:#f6f6f5;--accent:#2f6de1;--red:#c4123f;--sa:#2559b0;--sab:#e9f0fb;--sb:#7136b8;--sbb:#f4edfb;--edge:rgba(201,68,2,.42);--edgeh:rgba(201,68,2,.85);--org:#c94402;--sh:0 18px 50px rgba(0,0,0,.2),0 0 0 .5px rgba(0,0,0,.14);--msh:0 10px 30px rgba(0,0,0,.16),0 0 0 .5px rgba(0,0,0,.2)}
.th-d{--bg:#141413;--wtx:#ececea;--wtx2:#b3b3ae;--sheet:#2a2a29;--surface:#252524;--tx:#ececea;--tx2:#a9a9a3;--tx3:#6e6e6a;--card:#353534;--line:#4a4a47;--hair:#393938;--sec:#3b3b3a;--ink:#ececea;--onink:#16150e;--term:#1a1b17;--hover:rgba(255,255,255,.07);--mbg:#2e2e2d;--accent:#2f6de1;--red:#ff6b8f;--sa:#8fb4f7;--sab:#1c2536;--sb:#c4a2ff;--sbb:#2a2136;--edge:rgba(240,129,63,.45);--edgeh:rgba(240,129,63,.9);--org:#c94402;--sh:0 18px 50px rgba(0,0,0,.55),0 0 0 .5px rgba(255,255,255,.12);--msh:0 10px 30px rgba(0,0,0,.5),0 0 0 .5px rgba(255,255,255,.16)}
.board{display:flex;flex-direction:column;gap:20px;padding:34px 40px 40px;background:var(--bg);color:var(--wtx);font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.cells{display:flex;gap:48px;align-items:flex-start}
.cell{display:flex;flex-direction:column;gap:14px;flex:none}
.cell.th-d,.cell.th-l{background:var(--bg);color:var(--wtx);border-radius:12px;padding:18px;margin:-18px}
.cap{font-size:13px;font-weight:500;color:var(--wtx)}
.cap i{font-style:normal;font-weight:400;color:var(--wtx2)}
.stage{position:relative;flex:none}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.s{width:13px;height:13px;stroke-width:2}
.ic.xs{width:11px;height:11px;stroke-width:2.2}
.mono{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}

.pop{position:absolute;left:0;width:400px;color:var(--tx);z-index:20;text-align:left;font-weight:400;font-size:13px}
.popin{position:relative;background:var(--sheet);border-radius:14px;box-shadow:var(--sh);display:flex;flex-direction:column}
.pt{height:40px;padding:13px 16px 0;font-weight:600}
.rows{display:flex;flex-direction:column;gap:2px;padding:0 6px}
.row{position:relative;display:flex;align-items:flex-start;gap:10px;height:52px;padding:7px 10px;border-radius:9px}
.row.on{background:var(--card)}
.row.hv{background:var(--hover)}
.pick{position:absolute;inset:0;border:0;background:none;border-radius:inherit;padding:0;cursor:default}
.rd{position:relative;width:14px;height:14px;border-radius:50%;border:1px solid var(--tx2);margin-top:2px;flex:none;pointer-events:none}
.rd.on{border:4.5px solid var(--ink)}
.rd.dim{opacity:.45}
.nm{position:relative;display:flex;flex-direction:column;gap:2px;flex:1 1 0;min-width:0;pointer-events:none}
.nm .n{white-space:nowrap}
.nm .n.dim{color:var(--tx2)}
.l2{font-size:12px;line-height:17px;color:var(--tx2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.l2.mono{font-size:11.5px}
.mw{position:relative;flex:none}
.more{position:relative;width:24px;height:24px;margin:-3px -4px 0 0;border:0;border-radius:6px;background:none;color:var(--tx2);display:grid;place-items:center;padding:0;cursor:default}
.more.open{background:var(--hover);color:var(--tx)}
.lw{position:relative;align-self:flex-start;pointer-events:auto}
.l2b{display:inline-flex;align-items:center;gap:3px;height:18px;margin-left:-5px;padding:0 4px 0 5px;border:0;border-radius:5px;background:none;font:inherit;font-size:12px;color:var(--tx2);cursor:default;white-space:nowrap}
.l2b .ic{color:var(--tx2)}
.l2b.mono{font:11.5px ui-monospace,"SF Mono",Menlo,monospace}
.l2b.open{background:var(--hover);color:var(--tx)}
.vB .rows{gap:6px;padding:0 10px}
.vB .row{box-shadow:inset 0 0 0 1px var(--line);border-radius:10px}
.vB .row.on{background:none;box-shadow:inset 0 0 0 2px var(--ink)}
.vT .row{gap:6px;padding:7px 10px 7px 6px;height:58px}
.vT .nm{gap:4px}
.ck0{width:16px;height:18px;display:grid;place-items:center;flex:none}
.mbx{display:inline-flex;align-items:center;gap:4px;height:22px;padding:0 5px 0 7px;border-radius:6px;background:var(--sheet);box-shadow:inset 0 0 0 1px var(--line);font-size:12px;color:var(--tx)}
.mbx .ic{color:var(--tx2)}
.two{display:flex;align-items:center;gap:5px;font-size:12px;color:var(--tx2)}
.vT .l2{line-height:22px}
.pnote{padding:10px 16px 12px;font-size:12.5px;color:var(--tx2)}
.cmd{position:relative;background:var(--term);color:#f8f8f2;font:11.5px/1.55 ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;padding:9px 38px 10px 14px;border-radius:0 0 14px 14px}
.cmd .ln{padding-left:1.2em;text-indent:-1.2em;white-space:pre-wrap;overflow-wrap:anywhere}
.cmd .cm{color:#a59f85}
.cmd .fl{color:#e6db74}
.cmd .sv{color:#ae81ff}
.cmd .cp{position:absolute;top:6px;right:6px;width:24px;height:24px;display:grid;place-items:center;color:#a59f85}
.pva{position:absolute;bottom:-6px;right:20px;width:13px;height:13px;background:var(--term);transform:rotate(45deg);border-radius:0 0 3px 0}
.pva.up{top:-6px;bottom:auto;right:auto;left:193.5px;background:var(--sheet);border-radius:3px 0 0 0}

.menu{position:absolute;z-index:10;min-width:196px;padding:5px;background:var(--mbg);color:var(--tx);border-radius:10px;box-shadow:var(--msh);font-size:13px;display:flex;flex-direction:column;text-align:left}
.mh{height:22px;padding:5px 10px 0 26px;font-size:11px;font-weight:600;color:var(--tx2);white-space:nowrap}
.mi{display:flex;align-items:center;width:100%;height:22px;padding:0 10px 0 4px;border:0;border-radius:5px;background:none;color:inherit;font:inherit;white-space:nowrap;text-align:left;cursor:default}
.mi .ck{width:22px;flex:none;display:grid;place-items:center}
.mi .tr{margin-left:auto;padding-left:22px;display:inline-flex;align-items:center;gap:4px;color:var(--tx2);font-size:12.5px}
.mi .tr .ic{color:var(--tx2)}
.mi.hl{background:var(--accent);color:#fff}
.mi.hl .tr,.mi.hl .tr .ic{color:rgba(255,255,255,.85)}
.mi.dis{color:var(--tx3)}
.mi.dis .tr{color:var(--tx3)}
.ms{height:1px;background:var(--hair);margin:5px 10px;flex:none}

.spw{position:relative;display:inline-flex;flex:none}
.sp{position:relative;display:inline-flex;align-items:stretch;flex:none;font-weight:500;color:var(--tx)}
.sp::after{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;box-shadow:inset 0 0 0 1px var(--edge)}
.sp button{border:0;background:none;color:inherit;font:inherit;display:inline-flex;align-items:center;padding:0 8px;white-space:nowrap;cursor:default;border-radius:inherit}
.sp .chv{padding:0 5px;color:var(--tx2);border-left:1px solid var(--line);border-radius:0}
.sp.box{height:24px;border-radius:7px;background:var(--card);font-size:12px}
.sp.hdr{height:24px;border-radius:6px;font-size:12px;font-weight:400}
.sp.dg{height:28px;border-radius:9px;background:var(--sec);font-size:13px}
.sp.dg .m{padding:0 10px 0 12px}
.sp.dg .chv{padding:0 7px}
.sp.open::after{box-shadow:inset 0 0 0 1px var(--edgeh)}
.sp.open .chv{background:var(--hover);color:var(--tx)}

.cbox{position:absolute;left:0;bottom:0;width:400px;background:var(--surface);color:var(--tx);border-radius:12px;box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 2px 8px rgba(0,0,0,.06);padding:10px}
.ed{position:relative;height:96px;border:1px solid var(--line);border-radius:8px;background:var(--sheet);padding:7px 9px}
.ed .ph{color:var(--tx2)}
.ed .gpos{position:absolute;right:6px;bottom:6px}
.cft{display:flex;align-items:center;gap:8px;padding:10px 2px 0}
.kb{font-size:12px;color:var(--tx2)}
.cbtn{margin-left:auto;height:26px;padding:0 12px;border-radius:7px;border:0;background:var(--card);color:var(--tx2);font:inherit;font-size:12.5px;font-weight:500}

.df{position:absolute;left:0;top:0;width:700px;background:var(--sheet);color:var(--tx);border-radius:12px;box-shadow:0 0 0 .5px rgba(0,0,0,.12),0 2px 8px rgba(0,0,0,.06)}
.dh{display:flex;align-items:center;gap:6px;height:40px;padding:0 8px 0 14px;border-bottom:1px solid var(--hair)}
.dh .fn{font-weight:500;white-space:nowrap}
.dh .fs{color:var(--tx2);font-size:12px;white-space:nowrap}
.dh .gap{flex:1 1 0}
.ib{width:24px;height:24px;display:grid;place-items:center;color:var(--tx2);border:0;background:none;border-radius:6px;padding:0;flex:none;cursor:default}
.hb{height:24px;padding:0 8px;border-radius:6px;border:0;background:none;box-shadow:inset 0 0 0 1px var(--line);font:inherit;font-size:12px;color:var(--tx);white-space:nowrap;flex:none;cursor:default}
.cfx{margin:10px 12px 12px;border-radius:8px;box-shadow:0 0 0 1px var(--hair);overflow:hidden;font:12px/19px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none}
.cbd{display:flex;align-items:center;height:26px;padding:0 10px;font:600 12px -apple-system,system-ui,sans-serif;color:var(--red);background:var(--card)}
.csh{padding:3px 10px;font:12px -apple-system,system-ui,sans-serif}
.csh.a{color:var(--sa);background:var(--sab)}
.csh.b{color:var(--sb);background:var(--sbb)}
.cl{padding:0 10px;white-space:pre}
.cl.a{background:var(--sab)}
.cl.b{background:var(--sbb)}

.dlg{position:absolute;left:0;top:0;width:520px;background:var(--sheet);color:var(--tx);border-radius:18px;box-shadow:var(--sh);display:flex;flex-direction:column}
.dtop{padding:18px 20px 14px;display:flex;flex-direction:column;gap:8px}
.dti{margin:0;font-size:15px;font-weight:600;line-height:1.35}
.dmsg{margin:0;line-height:1.45}
.dbt{display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:0 20px 16px}
.bt{height:28px;padding:0 12px;border-radius:9px;border:0;font:inherit;font-weight:500;background:var(--sec);color:var(--tx);white-space:nowrap;cursor:default}
.bt.pri{background:var(--ink);color:var(--onink)}
.dlg .cmd{font-size:12px;padding:11px 44px 13px 20px;border-radius:0 0 18px 18px}

.try{width:2460px;height:800px;padding:26px 40px 40px;background:var(--bg);color:var(--wtx);display:flex;flex-direction:column;gap:26px;font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden;position:relative}
.bar{position:relative;z-index:2;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.bar .gl{font-size:12px;color:var(--wtx2);margin:0 4px 0 14px}
.bar .gl:first-child{margin-left:0}
.pill{height:28px;padding:0 12px;border:0;border-radius:8px;background:var(--hover);color:var(--wtx);font:inherit;font-size:12.5px;cursor:pointer}
.pill.on{background:var(--ink);color:var(--onink);font-weight:500}
.tcols{display:flex;gap:56px;align-items:flex-start}
.scrim{position:absolute;inset:0;border:0;background:none;padding:0;z-index:1;cursor:default}
.try .stage{z-index:2}
.try button{cursor:pointer}
.runs{font-size:12px;color:var(--wtx2);margin-top:2px}
"""

# ---------------------------------------------------------------- icons

CHEV = '<svg class="ic xs" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"></path></svg>'
CHEVR = '<svg class="ic xs" viewBox="0 0 24 24" aria-hidden="true"><path d="m9 18 6-6-6-6"></path></svg>'
CHECK = '<svg class="ic xs" viewBox="0 0 24 24" aria-hidden="true"><path d="M20 6 9 17l-5-5"></path></svg>'
DOTS = '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle><circle cx="5" cy="12" r="1"></circle></svg>'
GEAR = ('<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"></path>'
        '<circle cx="12" cy="12" r="3"></circle></svg>')
COPY = '<svg class="ic s" viewBox="0 0 24 24" aria-hidden="true"><rect width="14" height="14" x="8" y="8" rx="2" ry="2"></rect><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path></svg>'
DIFF = '<svg class="ic s" viewBox="0 0 24 24" aria-hidden="true"><path d="M3 5h18M3 12h18M3 19h18"></path></svg>'
FIND = '<svg class="ic s" viewBox="0 0 24 24" aria-hidden="true"><circle cx="11" cy="11" r="7"></circle><path d="m20 20-3.5-3.5"></path></svg>'
GROW = '<svg class="ic s" viewBox="0 0 24 24" aria-hidden="true"><path d="m18 15-6-6-6 6"></path></svg>'

# ---------------------------------------------------------------- agents


@dataclass
class Agent:
    key: str
    name: str
    short: str
    models: list[str]
    model: str = ""
    effort: str = ""
    command: str = ""

    @property
    def custom(self) -> bool:
        return bool(self.command)


CODEX_DEFAULT = "gpt-6-astra"
EFFORTS = ["", "low", "medium", "high"]


def agents() -> dict[str, Agent]:
    return {
        "claude": Agent("claude", "Claude Code", "Claude", ["", "haiku", "sonnet", "opus"], "haiku", "low"),
        "codex": Agent("codex", "Codex", "Codex", [""]),
        "ollama": Agent("ollama", "Ollama", "Ollama", [], command="ollama run qwen2.5-coder:7b"),
    }


def model_word(a: Agent) -> str:
    if a.model:
        return a.model
    return CODEX_DEFAULT if a.key == "codex" else "default model"


def effort_word(a: Agent) -> str:
    return f"{a.effort} effort" if a.effort else "default effort"


def effort_title(e: str) -> str:
    return e.capitalize() if e else "Default"


def model_title(a: Agent, m: str) -> str:
    if not m:
        return f"Default · {CODEX_DEFAULT}" if a.key == "codex" else "Default"
    return m


def detail(a: Agent) -> str:
    return a.command if a.custom else f"{model_word(a)} · {effort_word(a)}"


def short_detail(a: Agent) -> str:
    if a.custom:
        return "custom"
    return f"{model_word(a)} · {effort_title(a.effort).lower() if a.effort else 'default'}"


# ---------------------------------------------------------------- menus


def menu(items: list[tuple], style: str = "", cls: str = "", label: str = "Menu", extra: str = "") -> str:
    out = []
    for it in items:
        kind = it[0]
        if kind == "h":
            out.append(f'<div class="mh">{esc(it[1])}</div>')
        elif kind == "-":
            out.append('<div class="ms"></div>')
        else:
            _, title, checked, trailing, flags = (list(it) + [False, "", ""])[:5]
            ck = CHECK if checked else ""
            arrow = CHEVR if "sub" in flags else ""
            tr = f'<span class="tr">{esc(trailing)}{arrow}</span>' if trailing or arrow else ""
            out.append(f'<button class="mi {flags}" type="button" role="menuitem"><span class="ck">{ck}</span><span>{esc(title)}</span>{tr}</button>')
    return f'<div class="menu {cls}" role="menu" aria-label="{esc(label)}" style="{style}">{"".join(out)}{extra}</div>'


def row_menu_items(a: Agent, hl: str | None = None) -> list[tuple]:
    if a.custom:
        return [("i", f"{a.name} Settings…", False, "", "hl" if hl == "settings" else "")]
    items: list[tuple] = [("h", "Model")]
    for m in a.models:
        items.append(("i", model_title(a, m), m == a.model, "", "hl" if hl == f"m:{m}" else ""))
    if a.key == "codex":
        items.append(("i", "Another Model…", False, "", ""))
    items += [("-",), ("h", "Effort")]
    for e in EFFORTS:
        items.append(("i", effort_title(e), e == a.effort, "", "hl" if hl == f"e:{e}" else ""))
    items += [("-",), ("i", f"{a.name} Settings…", False, "", "")]
    return items


# What each job sends and says. The three run the same flags, with their own
# prompt and their own data on standard input.
JOBS = {
    "generate": {
        "input": "Staged diff",
        "prompt": "Write a commit message…",
        "task": "Describe the staged changes…",
        "note": "Saved as you pick. Resolve and Fix use it too.",
    },
    "resolve": {
        "input": "Conflicts",
        "prompt": "Resolve merge conflicts…",
        "task": "Resolve each conflict below…",
        "note": "Saved as you pick. Generate and Fix use it too.",
    },
    "fix": {
        "input": "Git output and diagnostics",
        "prompt": "Suggest a fix for what git refused…",
        "task": "Explain what went wrong…",
        "note": "Saved as you pick. Generate and Resolve use it too.",
    },
}


def command_lines(a: Agent, job: str = "generate") -> str:
    j = JOBS[job]
    if a.custom:
        lines = [
            f'<div class="ln cm"># Instructions and {esc(j["input"].lower())} supplied via standard input</div>',
            f'<div class="ln">/bin/sh <span class="fl">-c</span> <span class="sv">\'{esc(a.command)}\'</span></div>',
        ]
    elif a.key == "claude":
        flags = ['-p', '--safe-mode', '--setting-sources', 'user']
        if a.model:
            flags += ['--model', a.model]
        if a.effort:
            flags += ['--effort', a.effort]
        flags += ['--tools=', '--no-session-persistence', '--output-format', 'json', '--system-prompt']
        body = " ".join(f'<span class="fl">{esc(f)}</span>' if f.startswith("-") else esc(f) for f in flags)
        lines = [
            f'<div class="ln cm"># {esc(j["input"])} supplied via standard input</div>',
            f'<div class="ln">claude {body} <span class="sv">\'{esc(j["prompt"])}\'</span> <span class="fl">--</span> <span class="sv">\'{esc(j["task"])}\'</span></div>',
        ]
    else:
        flags = ['exec', '--ephemeral', '--sandbox', 'read-only', '--color', 'never', '--skip-git-repo-check',
                 '--disable', 'hooks', '--disable', 'plugins', '--disable', 'apps', '--disable', 'shell_tool']
        if a.model:
            flags += ['-m', a.model]
        if a.effort:
            flags += ['-c', f'model_reasoning_effort={a.effort}']
        body = " ".join(f'<span class="fl">{esc(f)}</span>' if f.startswith("-") else esc(f) for f in flags)
        lines = [
            f'<div class="ln cm"># {esc(j["input"])} supplied via standard input</div>',
            f'<div class="ln">codex {body} <span class="sv">\'{esc(j["prompt"])}\'</span></div>',
        ]
    return f'<div class="cmd">{"".join(lines)}<span class="cp">{COPY}</span></div>'


# Where a popover that hangs under a split button starts, so that its arrow,
# in its middle, points at the chevron: half the popover plus half the chevron.
UNDER = {"hdr": 211, "dg": 213}


def popover(variant: str, ags: dict[str, Agent], default: str, *, job: str = "generate", menu_for: str | None = None,
            menu_hl: str | None = None, glyph: str = "dots", hover: str | None = None, bottom: int = 86, under: str | None = None) -> str:
    """The agent popover. `variant` is T for today's, or A, B or C. It hangs
    over Generate's chevron, or under the chevron of the split button of kind
    `under`, with `job`'s command along its bottom."""
    rows = []
    shown = {k: a for k, a in ags.items() if variant != "T" or not a.custom}
    for k, a in shown.items():
        on = k == default
        cls = "row" + (" on" if on else "") + (" hv" if hover == k and not on else "")
        open_menu = ""
        if menu_for == k:
            open_menu = menu(row_menu_items(a, menu_hl), style="top:30px;left:0", label=f"Options for {a.name}")
        if variant == "T":
            if on:
                second = (f'<div class="two"><span class="mbx">{esc(model_word(a))}{CHEV}</span>·'
                          f'<span class="mbx">{esc(effort_word(a))}{CHEV}</span></div>')
            else:
                second = f'<div class="l2">{esc(detail(a))}</div>'
            rows.append(
                f'<div class="{cls}"><span class="ck0">{CHECK if on else ""}</span>'
                f'<div class="nm"><span class="n">{esc(a.name)}</span>{second}</div></div>'
            )
            continue
        mono = " mono" if a.custom else ""
        if variant == "C":
            sub_menu = menu(row_menu_items(a, menu_hl), style="top:22px;left:-5px", label=f"Options for {a.name}") if menu_for == k else ""
            second = (f'<span class="lw"><button class="l2b{mono}{" open" if menu_for == k else ""}" type="button" aria-label="Options for {esc(a.name)}">'
                      f'{esc(detail(a))}{CHEV}</button>{sub_menu}</span>')
            trailing = ""
        else:
            second = f'<span class="l2{mono}">{esc(detail(a))}</span>'
            icon = GEAR if glyph == "gear" else DOTS
            trailing = (f'<span class="mw"><button class="more{" open" if menu_for == k else ""}" type="button" aria-label="Options for {esc(a.name)}">{icon}</button>'
                        f'{open_menu}</span>')
        rows.append(
            f'<div class="{cls}"><button class="pick" type="button" aria-label="Make {esc(a.name)} the default agent"></button>'
            f'<span class="rd{" on" if on else ""}"></span>'
            f'<div class="nm"><span class="n">{esc(a.name)}</span>{second}</div>{trailing}</div>'
        )
    title = "Agent" if variant == "T" else "Default agent"
    note = "Selection saved automatically" if variant == "T" else JOBS[job]["note"]
    if under:
        place, arrow = f"top:calc(100% + 10px);left:calc(100% - {UNDER[under]}px)", "pva up"
    else:
        place, arrow = f"bottom:{bottom}px", "pva"
    return (
        f'<div class="pop v{variant}" role="dialog" aria-label="{title}" style="{place}"><div class="popin">'
        f'<div class="pt">{title}</div><div class="rows">{"".join(rows)}</div>'
        f'<div class="pnote">{note}</div>{command_lines(ags[default], job)}<span class="{arrow}"></span></div></div>'
    )


def split(ctx: str, label: str, *, chevron: bool = True, open_: bool = False, menu_html: str = "", aria: str = "Choose an agent") -> str:
    chev = f'<button class="chv" type="button" aria-label="{esc(aria)}">{CHEV}</button>' if chevron else ""
    return (f'<span class="spw"><span class="sp {ctx}{" open" if open_ else ""}"><button class="m" type="button">{esc(label)}</button>{chev}</span>'
            f'{menu_html}</span>')


def commit_box(label: str, open_: bool = True) -> str:
    return (
        '<div class="cbox"><div class="ed"><span class="ph">Message</span>'
        f'<span class="gpos">{split("box", label, open_=open_)}</span></div>'
        '<div class="cft"><span class="kb">⌘↩</span><button class="cbtn" type="button">Commit 2 Files</button></div></div>'
    )


def generate_stage(variant: str, ags: dict[str, Agent], default: str, *, width: int = 580, **kw) -> str:
    height = 470 if variant != "B" else 482
    return (f'<div class="stage" style="width:{width}px;height:{height}px">'
            f'{commit_box("Generate with " + ags[default].short)}{popover(variant, ags, default, **kw)}</div>')


# ---------------------------------------------------------------- the diff panel


def diff_stage(resolve: str, width: int = 780, height: int = 330) -> str:
    conflict = (
        '<div class="cfx"><div class="cbd">Conflict 1 of 2</div>'
        '<div class="csh a">main · 4f2a91c Retry the login once after the token expires</div>'
        '<div class="cl a">    if token.isExpired {</div><div class="cl a">        try await session.refresh()</div><div class="cl a">    }</div>'
        '<div class="csh b">origin/main · b81e0d3 Sign out when the token can\'t be refreshed</div>'
        '<div class="cl b">    guard let token = try? await session.refresh() else {</div><div class="cl b">        return signOut()</div><div class="cl b">    }</div></div>'
    )
    return (
        f'<div class="stage" style="width:{width}px;height:{height}px"><div class="df">'
        '<div class="dh"><span class="fn">LoginView.swift</span><span class="fs">Conflicts · 2 of 2 left</span><span class="gap"></span>'
        f'{resolve}<button class="ib" type="button" aria-label="More">{DOTS}</button>'
        '<button class="hb" type="button">Mark Resolved</button>'
        f'<button class="ib" type="button" aria-label="Show whole file">{DIFF}</button><button class="ib" type="button" aria-label="Find in Diff">{FIND}</button>'
        f'<button class="ib" type="button" aria-label="Maximize">{GROW}</button></div>'
        f'{conflict}</div></div>'
    )


# ---------------------------------------------------------------- dialogs

PULL = "git pull --ff-only origin main"
REFUSED = "fatal: bad object HEAD\nerror: git status --porcelain=2 failed in submodule prototypes/git-access/.build"


def dialog_stage(title: str, message: str, buttons: str, command: str, width: int = 580, height: int = 320) -> str:
    return (
        f'<div class="stage" style="width:{width}px;height:{height}px"><div class="dlg">'
        f'<div class="dtop"><p class="dti">{esc(title)}</p><p class="dmsg">{message}</p></div>'
        f'<div class="dbt">{buttons}</div>'
        f'<div class="cmd">{command}<span class="cp">{COPY}</span></div></div></div>'
    )


def pull_command() -> str:
    lines = [f'<div class="ln">git pull <span class="fl">--ff-only</span> origin main</div>']
    lines += [f'<div class="ln cm">{esc(line)}</div>' for line in REFUSED.split("\n")]
    return "".join(lines)


def refused_fix_command() -> str:
    return ('<div class="ln">git rm <span class="fl">--cached</span> prototypes/git-access/.build</div>'
            '<div class="ln cm">fatal: Unable to remove prototypes/git-access/.build: use -f to force removal</div>')


def ok() -> str:
    return '<button class="bt pri" type="button">OK</button>'


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


def cell(caption: str, sub: str, stage: str, theme: str = "") -> str:
    cls = f"cell {theme}" if theme else "cell"
    return f'<div class="{cls}"><div class="cap">{esc(caption)} <i>· {esc(sub)}</i></div>{stage}</div>'


def static_board(file: str, title: str, cells: list[str], w: int, h: int) -> Board:
    body = f'<div class="board th-l" style="width:{w}px;height:{h}px"><div class="cells">{"".join(cells)}</div></div>'
    return Board(file, title, w, h, page(title, body, w, h))


def width_of(stages: list[int]) -> int:
    return 80 + sum(stages) + 48 * (len(stages) - 1)


def board_today() -> Board:
    ags = agents()
    stages = [580, 780, 580]
    cells = [
        cell("Generate's popover", "a check, and menus on the picked row only",
             generate_stage("T", ags, "claude", bottom=86)),
        cell("Resolve in the diff's header", "runs the default, with no way to switch",
             diff_stage(split("hdr", "Resolve with Claude", chevron=False))),
        cell("Fix in the refusal", "the same",
             dialog_stage("git pull didn't run", "git stopped before changing anything. What git said is below.",
                          split("dg", "Fix with Claude", chevron=False) + ok(), pull_command())),
    ]
    return static_board("Ap-Today.dc.html", "Today", cells, width_of(stages), 600)


def board_pop_a() -> Board:
    ags = agents()
    dark = agents()
    stages = [580, 580, 580, 580]
    cells = [
        cell("At rest", "a radio, and ⋯ on every row", generate_stage("A", ags, "claude")),
        cell("Claude Code's ⋯", "models and efforts, then its page", generate_stage("A", ags, "claude", menu_for="claude", menu_hl="m:sonnet")),
        cell("Codex's ⋯, dark", "without picking Codex", generate_stage("A", dark, "claude", menu_for="codex", menu_hl="m:"), theme="th-d"),
        cell("A gear instead", "for comparing the two", generate_stage("A", ags, "claude", glyph="gear")),
    ]
    return static_board("Ap-Pop-A.dc.html", "A · A radio, and ⋯ for model and effort", cells, width_of(stages), 600)


def board_pop_b() -> Board:
    ags = agents()
    stages = [580, 580, 580]
    cells = [
        cell("At rest", "the default's card has an ink edge", generate_stage("B", ags, "claude")),
        cell("Claude Code's ⋯, dark", "models and efforts, then its page", generate_stage("B", agents(), "claude", menu_for="claude", menu_hl="e:medium"), theme="th-d"),
        cell("Ollama picked", "a custom agent's ⋯ has only its page", generate_stage("B", ags, "ollama", menu_for="ollama", menu_hl="settings")),
    ]
    return static_board("Ap-Pop-B.dc.html", "B · Cards with an ink edge · chosen", cells, width_of(stages), 612)


def board_pop_c() -> Board:
    ags = agents()
    stages = [580, 580]
    cells = [
        cell("At rest", "the second line is a button on every row", generate_stage("C", ags, "claude")),
        cell("Codex's second line", "opens the same menu as A's ⋯", generate_stage("C", ags, "claude", menu_for="codex", menu_hl="e:medium")),
    ]
    return static_board("Ap-Pop-C.dc.html", "C · The second line is the button", cells, width_of(stages), 600)


def board_resolve() -> Board:
    ags = agents()
    stages = [780, 840, 840, 780]
    pop = popover("B", ags, "claude", job="resolve", under="hdr")
    pop_menu = popover("B", ags, "claude", job="resolve", under="hdr", menu_for="codex", menu_hl="m:")
    cells = [
        cell("At rest", "a chevron beside Resolve", diff_stage(split("hdr", "Resolve with Claude"))),
        cell("The chevron", "opens the same popover, with Resolve's command",
             diff_stage(split("hdr", "Resolve with Claude", open_=True, menu_html=pop), width=840, height=480)),
        cell("Codex's ⋯", "as it is under Generate",
             diff_stage(split("hdr", "Resolve with Claude", open_=True, menu_html=pop_menu), width=840, height=480)),
        cell("After picking Codex", "the button names it, and so does Generate",
             diff_stage(split("hdr", "Resolve with " + ags["codex"].short))),
    ]
    return static_board("Ap-Resolve.dc.html", "Resolve with a chevron", cells, width_of(stages), 600)


REFUSAL = ("git pull didn't run", "git stopped before changing anything. What git said is below.")


def board_fix() -> Board:
    ags = agents()
    stages = [580, 680, 580, 820]
    pop = popover("B", ags, "claude", job="fix", under="dg")
    again = popover("B", agents(), "claude", job="fix", under="dg", menu_for="claude", menu_hl="m:sonnet")
    cells = [
        cell("In the refusal", "Fix gets the chevron",
             dialog_stage(*REFUSAL, split("dg", "Fix with Claude") + ok(), pull_command())),
        cell("The chevron", "opens the same popover, with Fix's command",
             dialog_stage(*REFUSAL, split("dg", "Fix with Claude", open_=True, menu_html=pop) + ok(), pull_command(), width=680, height=540)),
        cell("When git refuses the fix", "ask again, or pick another agent first",
             dialog_stage("git refused the command", "git refused <code class=\"mono\">git rm --cached prototypes/git-access/.build</code>. Git output is shown below.",
                          split("dg", "Fix with Claude") + ok(), refused_fix_command())),
        cell("When the agent can't answer", "Try Again's chevron opens it too",
             dialog_stage("Claude Code couldn't suggest a fix", "Claude Code stopped after 3 minutes without an answer.",
                          split("dg", "Try Again", open_=True, menu_html=again, aria="Choose an agent") + ok(),
                          '<div class="ln cm">Timed out after 180 s</div>', width=820, height=540)),
    ]
    return static_board("Ap-Fix.dc.html", "Fix with a chevron", cells, width_of(stages), 660)


# ---------------------------------------------------------------- try it

TRY_HEAD = r"""
const AG = {
  claude: { name: 'Claude Code', short: 'Claude', models: ['', 'haiku', 'sonnet', 'opus'] },
  codex: { name: 'Codex', short: 'Codex', models: [''] },
  ollama: { name: 'Ollama', short: 'Ollama', command: 'ollama run qwen2.5-coder:7b' }
};
const ORDER = ['claude', 'codex', 'ollama'];
const EFFORTS = ['', 'low', 'medium', 'high'];
const CODEX_DEFAULT = 'gpt-6-astra';
const cap = (s) => s ? s.charAt(0).toUpperCase() + s.slice(1) : 'Default';
""" + "const JOBS = " + json.dumps(JOBS, ensure_ascii=False) + ";\n"

TRY_SCRIPT = r"""
  constructor(props) {
    super(props);
    this.state = { def: 'claude', model: { claude: 'haiku', codex: '' }, effort: { claude: 'low', codex: '' },
      theme: 'light', pop: 'generate', rowMenu: null };
  }
  modelWord(k) { const m = this.state.model[k]; return m || (k === 'codex' ? CODEX_DEFAULT : 'default model'); }
  effortWord(k) { const e = this.state.effort[k]; return e ? e + ' effort' : 'default effort'; }
  detail(k) { return AG[k].command ? AG[k].command : this.modelWord(k) + ' · ' + this.effortWord(k); }
  modelTitle(k, m) { if (!m) return k === 'codex' ? 'Default · ' + CODEX_DEFAULT : 'Default'; return m; }
  item(label, checked, act) {
    return { isItem: true, isHeader: false, isSep: false, label, ck: checked, tr: '', cls: 'mi', act: () => { act(); } };
  }
  header(label) { return { isItem: false, isHeader: true, isSep: false, label }; }
  sep() { return { isItem: false, isHeader: false, isSep: true }; }
  closeMenu() { this.setState({ rowMenu: null }); }
  setModel(k, m) { this.setState({ model: Object.assign({}, this.state.model, { [k]: m }), rowMenu: null }); }
  setEffort(k, e) { this.setState({ effort: Object.assign({}, this.state.effort, { [k]: e }), rowMenu: null }); }
  rowMenuItems(k) {
    const a = AG[k];
    if (a.command) return [this.item(a.name + ' Settings…', false, () => this.closeMenu())];
    const items = [this.header('Model')];
    a.models.forEach((m) => items.push(this.item(this.modelTitle(k, m), this.state.model[k] === m, () => this.setModel(k, m))));
    if (k === 'codex') items.push(this.item('Another Model…', false, () => this.closeMenu()));
    items.push(this.sep(), this.header('Effort'));
    EFFORTS.forEach((e) => items.push(this.item(cap(e), this.state.effort[k] === e, () => this.setEffort(k, e))));
    items.push(this.sep(), this.item(a.name + ' Settings…', false, () => this.closeMenu()));
    return items;
  }
  comment(k, job) {
    const j = JOBS[job];
    return AG[k].command ? '# Instructions and ' + j.input.toLowerCase() + ' supplied via standard input' : '# ' + j.input + ' supplied via standard input';
  }
  command(k, job) {
    const a = AG[k], j = JOBS[job];
    if (a.command) return "/bin/sh -c '" + a.command + "'";
    const m = this.state.model[k], e = this.state.effort[k];
    if (k === 'claude') return 'claude -p --safe-mode --setting-sources user' + (m ? ' --model ' + m : '') + (e ? ' --effort ' + e : '') + " --tools= --no-session-persistence --output-format json --system-prompt '" + j.prompt + "' -- '" + j.task + "'";
    return 'codex exec --ephemeral --sandbox read-only --color never --skip-git-repo-check --disable hooks --disable plugins --disable apps --disable shell_tool' + (m ? ' -m ' + m : '') + (e ? ' -c model_reasoning_effort=' + e : '') + " '" + j.prompt + "'";
  }
  renderVals() {
    const s = this.state;
    const d = s.def;
    const rows = ORDER.map((k) => {
      const on = d === k;
      return {
        name: AG[k].name,
        sub: this.detail(k),
        subCls: 'l2' + (AG[k].command ? ' mono' : ''),
        rowCls: 'row' + (on ? ' on' : ''),
        rdCls: 'rd' + (on ? ' on' : ''),
        pickLabel: 'Make ' + AG[k].name + ' the default agent',
        pick: () => this.setState({ def: k, rowMenu: null }),
        moreCls: 'more' + (s.rowMenu === k ? ' open' : ''),
        moreLabel: 'Options for ' + AG[k].name,
        toggleMenu: () => this.setState({ rowMenu: s.rowMenu === k ? null : k }),
        menuOpen: s.rowMenu === k,
        menuItems: s.rowMenu === k ? this.rowMenuItems(k) : []
      };
    });
    const toggle = (job) => () => this.setState({ pop: s.pop === job ? null : job, rowMenu: null });
    const vals = {
      themeCls: 'try ' + (s.theme === 'dark' ? 'th-d' : 'th-l'),
      themes: [['light', 'Light'], ['dark', 'Dark']].map(([value, label]) => ({ label, cls: 'pill' + (s.theme === value ? ' on' : ''), pick: () => this.setState({ theme: value }) })),
      rows,
      anyOpen: !!s.pop,
      closeAll: () => this.setState({ pop: null, rowMenu: null }),
      runs: 'Runs ' + AG[d].name + (AG[d].command ? ', a custom command' : ', ' + this.detail(d))
    };
    const verbs = { generate: 'Generate', resolve: 'Resolve', fix: 'Fix' };
    const kinds = { generate: 'sp box', resolve: 'sp hdr', fix: 'sp dg' };
    Object.keys(JOBS).forEach((job) => {
      vals[job + 'Open'] = s.pop === job;
      vals[job + 'Toggle'] = toggle(job);
      vals[job + 'Cls'] = kinds[job] + (s.pop === job ? ' open' : '');
      vals[job + 'Label'] = verbs[job] + ' with ' + AG[d].short;
      vals[job + 'Note'] = JOBS[job].note;
      vals[job + 'Comment'] = this.comment(d, job);
      vals[job + 'Command'] = this.command(d, job);
    });
    return vals;
  }
"""

MENU_TEMPLATE = """<div class="menu" role="menu" aria-label="{label}" style="{style}">
<sc-for list="{{{{{items}}}}}" as="it" hint-placeholder-count="6">
<sc-if value="{{{{it.isHeader}}}}" hint-placeholder-val="{{{{false}}}}"><div class="mh">{{{{it.label}}}}</div></sc-if>
<sc-if value="{{{{it.isSep}}}}" hint-placeholder-val="{{{{false}}}}"><div class="ms"></div></sc-if>
<sc-if value="{{{{it.isItem}}}}" hint-placeholder-val="{{{{true}}}}"><button class="{{{{it.cls}}}}" type="button" role="menuitem" onClick="{{{{it.act}}}}"><span class="ck"><sc-if value="{{{{it.ck}}}}" hint-placeholder-val="{{{{false}}}}">{check}</sc-if></span><span>{{{{it.label}}}}</span></button></sc-if>
</sc-for></div>"""


def live_menu(items: str, style: str, label: str) -> str:
    return MENU_TEMPLATE.format(items=items, style=style, label=label, check=CHECK)


def live_popover(job: str, place: str, arrow: str) -> str:
    """B's popover with holes, the same markup under every chevron."""
    row_menu = live_menu("r.menuItems", "top:30px;left:0", "Options")
    rows = (
        '<sc-for list="{{rows}}" as="r" hint-placeholder-count="3"><div class="{{r.rowCls}}">'
        '<button class="pick" type="button" aria-label="{{r.pickLabel}}" onClick="{{r.pick}}"></button>'
        '<span class="{{r.rdCls}}"></span>'
        '<div class="nm"><span class="n">{{r.name}}</span><span class="{{r.subCls}}">{{r.sub}}</span></div>'
        '<span class="mw"><button class="{{r.moreCls}}" type="button" aria-label="{{r.moreLabel}}" onClick="{{r.toggleMenu}}">' + DOTS + '</button>'
        '<sc-if value="{{r.menuOpen}}" hint-placeholder-val="{{false}}">' + row_menu + '</sc-if></span>'
        '</div></sc-for>'
    )
    return (
        f'<sc-if value="{{{{{job}Open}}}}" hint-placeholder-val="{{{{false}}}}">'
        f'<div class="pop vB" role="dialog" aria-label="Default agent" style="{place}"><div class="popin">'
        f'<div class="pt">Default agent</div><div class="rows">{rows}</div>'
        f'<div class="pnote">{{{{{job}Note}}}}</div>'
        f'<div class="cmd"><div class="ln cm">{{{{{job}Comment}}}}</div><div class="ln">{{{{{job}Command}}}}</div><span class="cp">{COPY}</span></div>'
        f'<span class="{arrow}"></span></div></div></sc-if>'
    )


def live_split(job: str, under: str | None) -> str:
    """A split button with holes whose chevron opens the popover, under it
    when `under` names its kind, and otherwise in the stage above it."""
    pop = live_popover(job, f"top:calc(100% + 10px);left:calc(100% - {UNDER[under]}px)", "pva up") if under else ""
    return (
        f'<span class="spw"><span class="{{{{{job}Cls}}}}"><button class="m" type="button">{{{{{job}Label}}}}</button>'
        f'<button class="chv" type="button" aria-label="Choose an agent" onClick="{{{{{job}Toggle}}}}">{CHEV}</button></span>{pop}</span>'
    )


def board_try() -> Board:
    w, h = 2460, 800
    gen = (
        f'<div class="cbox"><div class="ed"><span class="ph">Message</span><span class="gpos">{live_split("generate", None)}</span></div>'
        '<div class="cft"><span class="kb">⌘↩</span><button class="cbtn" type="button">Commit 2 Files</button></div></div>'
    )
    diff = diff_stage(live_split("resolve", "hdr"), width=840, height=560)
    dlg = dialog_stage(*REFUSAL, live_split("fix", "dg") + ok(), pull_command(), width=820, height=560)
    col = lambda title, sub, stage: f'<div class="cell"><div class="cap">{title} <i>· {sub}</i></div>{stage}</div>'
    body = (
        f'<div class="{{{{themeCls}}}}" style="width:{w}px;height:{h}px">'
        '<sc-if value="{{anyOpen}}" hint-placeholder-val="{{false}}"><button class="scrim" type="button" aria-label="Close the popover" onClick="{{closeAll}}"></button></sc-if>'
        '<div class="bar"><span class="gl">Appearance</span>'
        '<sc-for list="{{themes}}" as="p" hint-placeholder-count="2"><button class="{{p.cls}}" type="button" onClick="{{p.pick}}">{{p.label}}</button></sc-for>'
        '</div>'
        '<div class="tcols">'
        + col("Commit message", "the chevron opens the popover",
              f'<div class="stage" style="width:600px;height:560px">{gen}{live_popover("generate", "bottom:86px", "pva")}</div><div class="runs">{{{{runs}}}}</div>')
        + col("Resolving a conflict", "the same popover, under the button", diff)
        + col("Fixing what git refused", "the same popover again", dlg)
        + '</div></div>'
    )
    return Board("Ap-Try.dc.html", "Try it", w, h, page("Try it", body, w, h, TRY_SCRIPT, TRY_HEAD), interactive=True)


def all_boards() -> list[list[Board]]:
    return [
        [board_today()],
        [board_pop_a(), board_pop_b(), board_pop_c()],
        [board_resolve(), board_fix()],
        [board_try()],
    ]


TITLES = [
    "Choosing the agent today",
    "The Generate popover",
    "Resolve and Fix, where they run",
    "Try it",
]

INTROS = [
    "Generate's popover marks the default agent with a small check, the way a menu marks a choice, and only the picked agent's model and effort are menus. The other rows say theirs in gray, and picking a row moves the menus to it. Resolve with Claude and Fix with Claude name the agent they run but can't change it, so trying another agent on a conflict or a refusal means going to Generate's popover or Settings first. Since decision 89, Generate, Resolve and Fix all run one default agent.",
    "Three ways to mark the default agent and to reach each agent's model and effort. In all three, a row looks the same whether or not it's picked, so picking another agent moves nothing and no words turn into controls. The title says Default agent, the name Settings › Agents uses, and the line under the rows says what else uses it, which nothing on screen says today. B is the one chosen.",
    "Resolve and Fix become split buttons like Generate's, and their chevron opens the same popover as Generate's, so choosing an agent looks and works the same everywhere. It hangs under the button, and the command along its bottom is the one that job runs, with the same flags and its own prompt. A pick changes the one default from decision 89, so the button's name changes and Generate follows. Each job doesn't keep an agent of its own, which decision 89 looked at and turned down.",
    "Press Play. Every chevron opens the same popover, and every pick changes the same default, so pick Codex under Resolve and Generate and Fix follow. Change a model from a row's ⋯ and the command at the bottom follows. The bar switches the appearance.",
]

EXTRA_NOTES = {
    "nApPick": {
        "x": 1080, "row": 0, "w": 900,
        "text": "You chose B on 17 November, with one popover for every agent's chevron. Generate, Resolve, Fix, and Try Again after a fix that failed all open it: B's cards with the radio, each agent's ⋯ for its model and effort and its page in Settings, a line naming what else uses the default, and the exact command that job runs along the bottom. Picking an agent in it changes the one default, as it does from Generate today. A native menu under Resolve and Fix was drawn first and is gone. The row keeps the ⋯ rather than a gear, since Roga uses ⋯ for a row's menu, and a gear has meant Settings.",
    },
    "nApOpen": {
        "x": 2060, "row": 0, "w": 900,
        "text": "Still open: model and effort stay with the agent, so raising Claude Code to sonnet for a hard conflict also slows commit messages, which decision 89 lists as a consequence. A job could ask for a stronger model than the default's, but that's a setting for each job again, so it can wait until someone needs it.",
    },
}

NOTES = {
    "Ap-Today.dc.html": "On main: a check before the picked agent, its model and effort as two boxed menus, and gray words on the other rows. Resolve and Fix run the default, with nothing beside them to switch it.",
    "Ap-Pop-A.dc.html": "A brings back the radio, keeps the picked row's gray card, and puts a ⋯ at the right of every row, on the name's line, where Roga's rows put their controls. Its menu lists the agent's models and efforts as two sections with checks, then the agent's page in Settings. Codex's ends with Another Model…, and a custom agent's has only its page. The menu doesn't pick the row, so another agent's model can change without making it the default. The last frame swaps the ⋯ for a gear, to compare them.",
    "Ap-Pop-B.dc.html": "Chosen. B draws each agent as a card with a line around it, and the default's line in ink and twice as thick, with the radio too. Each card's ⋯ works as A's does: the agent's models and efforts, then its page in Settings, and only the page for a custom agent. It's 12 points taller than A, which a popover hanging over the message box can spare.",
    "Ap-Pop-C.dc.html": "C adds no buttons and makes the gray second line itself the button, on every row, with a chevron. It's closest to today, but the words you click to change a setting sit inside the row you click to pick an agent, which is the mix-up today's design has.",
    "Ap-Resolve.dc.html": "The header's Resolve becomes a split button, with the agent's orange line around both parts. The chevron opens the popover under it, with Resolve's command along the bottom and a line saying Generate and Fix use the same agent. A row's ⋯ works as it does under Generate. Picking Codex renames the button, and the conflicted file's ⋯ menu says Resolve with Codex too.",
    "Ap-Fix.dc.html": "The refusal's Fix with Claude gets the same chevron and popover, with Fix's command. When git refuses the agent's fix, Fix with Claude asks again with what git said, and the popover can switch agents first. When the agent couldn't answer, the dialog gains Try Again, whose chevron opens the popover too, here with Claude Code's ⋯ open to try a bigger model.",
    "Ap-Try.dc.html": "One popover behind every chevron, and one default behind every popover, with each agent's own model and effort.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    row_y: list[int] = []
    y = 0
    for index, row_boards in enumerate(rows):
        row_y.append(y)
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tAp{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": max(width, 2000), "page": PAGE_ID}
        notes[f"nAp{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Agent picker page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Agent picker boards, and optionally merge them into a canvas.json."""
    rows = all_boards()
    project = out / "project"
    project.mkdir(parents=True, exist_ok=True)
    for b in (b for r in rows for b in r):
        (project / b.file).write_text(b.html)
        click.echo(f"{b.file}  {b.w}×{b.h}  {len(b.html) // 1024} KB")
    if canvas:
        data = json.loads(canvas.read_text())
        boards, notes = layout(rows)
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
