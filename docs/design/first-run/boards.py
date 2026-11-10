# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the First run boards for the design canvas "yaga layout options".

Every board is written as a `.dc.html` file under `<out>/project/`, and
`--canvas` merges their frames and notes into a copy of the canvas's
`canvas.json`, on a page of its own. It borrows the styles, the window and the
rows of `docs/design/settings/boards.py`, so the two pages stay one family.

    uv run docs/design/first-run/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Boards that an earlier run put on the page and this one doesn't are listed at
the end, so they can be removed from the canvas when it's published.
"""

from __future__ import annotations

import copy
import importlib.util
import json
import re
import sys
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
BRANDING = HERE.parent / "branding"
PAGE_ID = "firstrun"
PAGE_NAME = "First run"

_spec = importlib.util.spec_from_file_location("settings_boards", HERE.parent / "settings" / "boards.py")
s = importlib.util.module_from_spec(_spec)
sys.modules["settings_boards"] = s  # dataclasses look their module up here
_spec.loader.exec_module(s)

esc, ic, tokens_html, Board = s.esc, s.ic, s.tokens_html, s.Board
P, G, R, F = s.P, s.G, s.R, s.F

ICONS = {
    "git": '<path d="M6 3v12"></path><circle cx="18" cy="6" r="3"></circle><circle cx="6" cy="18" r="3"></circle><path d="M18 9a9 9 0 0 1-9 9"></path>',
    "github": '<path d="M15 22v-4a4.8 4.8 0 0 0-1-3.5c3 0 6-2 6-5.5.08-1.25-.27-2.48-1-3.5.28-1.15.28-2.35 0-3.5 0 0-1 0-3 1.5-2.64-.5-5.36-.5-8 0C6 2 5 2 5 2c-.3 1.15-.3 2.35 0 3.5A5.403 5.403 0 0 0 4 9c0 3.5 3 5.5 6 5.5-.39.49-.68 1.05-.85 1.65-.17.6-.22 1.23-.15 1.85v4"></path><path d="M9 18c-4.51 2-5-2-7-2"></path>',
    "alert": '<circle cx="12" cy="12" r="10"></circle><path d="M12 8v4M12 16h.01"></path>',
    "updown": '<path d="m7 15 5 5 5-5"></path><path d="m7 9 5-5 5 5"></path>',
    "minus": '<path d="M5 12h14"></path>',
}


def icon(name: str, cls: str = "ic") -> str:
    if name in ICONS:
        return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{ICONS[name]}</svg>'
    return ic(name, cls)


def house_svg(cls: str = "") -> str:
    c = f' class="{cls}"' if cls else ""
    return (
        f'<svg{c} viewBox="0 0 573 573" aria-hidden="true"><path transform="translate(-305.5 -132)" fill="#D54802" '
        f'fill-rule="evenodd" d="{s.house_path()}"></path></svg>'
    )


def wordmark_svg() -> str:
    text = (BRANDING / "roga-wordmark.svg").read_text()
    inner = text[text.index("</desc>") + len("</desc>"): text.rindex("</svg>")]
    inner = inner.replace('fill="#16150E"', 'fill="currentColor"')
    return f'<svg class="fr-wm" viewBox="0 0 685 261" role="img" aria-label="Roga">{inner}</svg>'


RING = (
    '<svg class="{cls}" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5" fill="none" stroke="var(--line)" stroke-width="2"></circle>'
    '<path d="M8 2.5a5.5 5.5 0 0 1 5.5 5.5" fill="none" stroke="#d54802" stroke-width="2" stroke-linecap="round"></path></svg>'
)

s.CSS += r"""
.fw{position:relative;width:1120px;height:800px;background:var(--sheet);border-radius:12px;box-shadow:var(--sh);display:flex;overflow:hidden;flex:none}
.fs{width:312px;flex:none;background:var(--side);border-right:1px solid var(--hair);display:flex;flex-direction:column;padding:0 8px}
.fs .tl{padding-left:12px}
.fi{display:flex;align-items:center;gap:10px;height:32px;padding:0 10px;font-size:14px}
.fi .ic{color:var(--tx2)}
.fm{flex:1 1 0;min-width:0;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;color:var(--tx2)}
.dlg.su{width:580px}
.su .dft.nc{padding-bottom:14px}
.su .dtop{gap:12px}
.pips{display:flex;gap:14px;font-size:12px}
.pips button{border:0;background:none;padding:0;font:inherit;color:var(--tx2);display:inline-flex;align-items:center;gap:4px;cursor:default}
.pips button.cur{color:var(--tx);font-weight:600}
.pips .ic{width:12px;height:12px;stroke-width:2.4}
.su .msg{color:var(--tx2)}
.oc{background:var(--card);border-radius:12px;display:flex;flex-direction:column;overflow:hidden}
.ah{display:flex;align-items:center;justify-content:space-between;gap:8px;min-height:36px;padding:8px 14px 4px;font-weight:500}
.oc .sub{padding:0 14px 10px;font-size:12px;color:var(--tx2)}
.opt{display:flex;gap:10px;width:100%;border:0;background:none;text-align:left;padding:8px 14px;align-items:flex-start;font:inherit;color:var(--tx);cursor:default}
.opt+.opt{border-top:1px solid var(--hair)}
.opt[disabled]{color:var(--tx2)}
.rad{width:14px;height:14px;border-radius:50%;box-shadow:inset 0 0 0 1px var(--line);margin-top:2px;flex:none;background:var(--sheet)}
.opt[aria-checked="true"] .rad{box-shadow:inset 0 0 0 4px var(--ink)}
.opt[disabled] .rad{background:none}
.ob{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px}
.ot{display:flex;gap:8px;align-items:baseline}
.ot b{font-weight:500}
.ver{color:var(--tx2);font-variant-numeric:tabular-nums}
.stt{margin-left:auto;font-size:12px;display:inline-flex;align-items:center;gap:4px;color:var(--tx2);white-space:nowrap}
.stt.ok{color:var(--ok);font-weight:500}
.stt.warn{color:var(--warn);font-weight:500}
.stt .ic{width:12px;height:12px;stroke-width:2.4}
.pth{font:11.5px ui-monospace,"SF Mono",Menlo,monospace;font-variant-ligatures:none;color:var(--tx2);overflow-wrap:anywhere}
.why{font-size:12px;color:var(--tx2)}
.why.warn{color:var(--warn)}
.help{font-size:12px;color:var(--tx2);margin:0}
.kv{display:flex;gap:12px;padding:9px 14px;align-items:baseline}
.kv+.kv{border-top:1px solid var(--hair)}
.kv .k{width:116px;flex:none;font-weight:500}
.kv .v{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px}
.kv .to{font-size:12px;color:var(--tx2);white-space:nowrap}
.kv.c{align-items:center}
.kv.c .v b{font-weight:500}
.kv.c .v b.off{color:var(--tx2)}

.th-l{--rule:#e1e1de}
.th-d{--rule:#464644}
.fr-win{position:relative;width:1120px;height:800px;background:var(--sheet);border-radius:12px;box-shadow:var(--sh);display:flex;flex-direction:column;overflow:hidden;flex:none}
.fr-top{position:relative;height:52px;flex:none;display:flex;align-items:center;padding-left:12px}
.fr-dots{position:absolute;left:50%;top:23px;transform:translateX(-50%);display:flex;gap:6px}
.fr-dots i{display:block;width:6px;height:6px;border-radius:3px;background:var(--line);transition:width .3s,background .3s}
.fr-dots i.done{background:var(--tx2)}
.fr-dots i.cur{width:20px;background:var(--ink)}
.fr-stage{flex:1 1 0;min-height:0;display:flex;flex-direction:column;align-items:center;padding:20px 40px 0}
.fr-col{width:620px;display:flex;flex-direction:column;gap:14px}
.fr-hd{display:flex;flex-direction:column;align-items:center;text-align:center;gap:8px;margin-bottom:6px}
.fr-eb{font-size:11.5px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:var(--act)}
.fr-h{margin:0;font-size:28px;line-height:1.2;font-weight:600;letter-spacing:-.015em;text-wrap:balance}
.fr-sub{margin:0;font-size:14px;line-height:1.5;color:var(--tx2);max-width:560px;text-wrap:pretty}
.fr-acts{display:flex;justify-content:center;align-items:center;gap:8px;margin-top:8px}
.fr-b{height:36px;padding:0 18px;border-radius:10px;border:0;font:inherit;font-size:13.5px;font-weight:500;white-space:nowrap;display:inline-flex;align-items:center;justify-content:center;gap:6px;cursor:default}
.fr-b.pri{background:var(--ink);color:var(--onink);min-width:168px}
.fr-b.sec{background:var(--sec);color:var(--tx)}
.fr-b.gh{background:none;color:var(--tx2);padding:0 12px}
.fr-b[disabled]{opacity:.45}
.fr-note{margin:0;font-size:12.5px;line-height:1.5;color:var(--tx2);text-align:center}
.fr-fine{margin:0;font-size:12.5px;color:var(--tx2);text-align:center}

.fr-card{background:var(--card);border-radius:14px;display:flex;flex-direction:column}
.fr-row{display:flex;align-items:center;gap:14px;min-height:68px;padding:13px 14px 13px 16px}
.fr-row+.fr-row{border-top:1px solid var(--rule)}
.fr-ri{width:38px;height:38px;border-radius:10px;background:var(--sheet);display:grid;place-items:center;color:var(--tx2);flex:none}
.fr-ri .ic{width:19px;height:19px}
.fr-rb{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:3px}
.fr-rt{display:flex;align-items:center;gap:8px;font-size:14.5px;line-height:20px;white-space:nowrap}
.fr-rt b{font-weight:600}
.fr-rt .ver{font-size:13.5px}
.fr-det{display:inline-flex;align-items:center;gap:3px;margin-left:2px;font-size:12px;font-weight:500;color:var(--ok)}
.fr-det .ic{width:12px;height:12px;stroke-width:2.6}
.fr-det.warn{color:var(--warn)}
.fr-row.off .fr-rt b{color:var(--tx2);font-weight:500}
.fr-row .pth{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.fr-pick{position:relative;flex:none}
.fr-sl{display:inline-flex;align-items:center;gap:8px;height:30px;padding:0 7px 0 12px;border-radius:9px;border:0;background:var(--sheet);box-shadow:0 0 0 1px var(--line);color:var(--tx);font:inherit;font-weight:500;white-space:nowrap;cursor:default}
.fr-sl .ic{width:14px;height:14px;color:var(--tx2)}
.fr-sl.plain{padding:0 12px}
.fr-sl.open{box-shadow:0 0 0 1px var(--ink),0 0 0 4px var(--hover)}
.fr-scrim{position:absolute;inset:0;z-index:5}
.fr-menu{position:absolute;top:36px;right:0;width:404px;background:var(--sheet);border-radius:12px;box-shadow:var(--sh);padding:6px;display:flex;flex-direction:column;z-index:6}
.fr-mi{display:flex;gap:8px;align-items:flex-start;width:100%;border:0;background:none;padding:8px 10px 8px 8px;border-radius:8px;font:inherit;color:var(--tx);text-align:left;cursor:default}
.fr-mi:hover{background:var(--hover)}
.fr-mi[disabled]{color:var(--tx2)}
.fr-mi[disabled] b,.fr-mi[disabled] .ver,.fr-mi[disabled] .pth{opacity:.5}
.fr-mi[disabled]:hover{background:none}
.fr-mi.one{padding-top:6px;padding-bottom:6px}
.fr-ck{width:16px;height:18px;flex:none;display:grid;place-items:center}
.fr-ck .ic{width:14px;height:14px;stroke-width:2.4}
.fr-mb{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px}
.fr-mt{display:flex;align-items:center;gap:8px}
.fr-mt b{font-weight:500}
.fr-mt .ver{margin-left:auto}
.fr-old{font-size:11px;font-weight:500;color:var(--warn)}
.fr-ms{height:1px;background:var(--hair);margin:5px 8px}

.fr-lk{display:flex;align-items:center;gap:12px;padding:0 16px;height:46px}
.fr-lk+.fr-lk{border-top:1px solid var(--hair)}
.fr-lk b{font-weight:500;width:120px;flex:none}
.fr-lv{flex:1 1 0;min-width:0;color:var(--tx2)}
.fr-ok{width:16px;height:16px;flex:none;color:var(--ok)}
.fr-ok .ic{width:16px;height:16px;stroke-width:2.4}
.fr-wait{width:16px;height:16px;flex:none;display:grid;place-items:center}
.fr-wait i{display:block;width:6px;height:6px;border-radius:3px;background:var(--line)}
.fr-ring{width:16px;height:16px;flex:none;display:block}
.fr-ring.go{animation:fr-spin 1s linear infinite}
@keyframes fr-spin{to{transform:rotate(360deg)}}
.fr-floor{position:absolute;left:0;right:0;bottom:30px;height:1px;background:var(--hair)}
.fr-hz{position:absolute;bottom:30px;width:46px;height:46px;transition:left .8s cubic-bezier(.3,.7,.3,1)}
.fr-hz svg{display:block;width:46px;height:46px;transform-origin:50% 100%}
.fr-hz.go svg{animation:fr-wd .42s ease-in-out infinite alternate}
@keyframes fr-wd{from{transform:rotate(-5deg)}to{transform:rotate(5deg)}}
.fr-wel{display:flex;flex-direction:column;align-items:center;text-align:center;gap:14px;margin-top:100px}
.fr-big{width:168px;height:168px;display:block}
.fr-wel.go .fr-big{transform-origin:50% 100%;animation:fr-wd .9s ease-in-out infinite alternate}
.fr-wm{width:132px;height:auto;color:var(--tx);display:block;margin-top:6px}
.fr-tag{font-size:11.5px;font-weight:500;letter-spacing:.16em;text-transform:uppercase;color:var(--tx2)}
.fr-lead{margin:10px 0 0;font-size:17px;line-height:1.45;max-width:440px;text-wrap:balance}

.fr-fig{display:flex;justify-content:center;align-items:flex-start}
.fr-sb{width:276px;flex:none;background:var(--side);box-shadow:0 0 0 1px var(--rule),0 2px 6px rgba(0,0,0,.05);border-radius:12px;padding:6px}
.fr-sr{display:grid;grid-template-columns:minmax(0,1fr) 24px 16px;grid-template-rows:30px 16px;height:52px;padding:0 8px 0 10px;border-radius:7px}
.fr-sr.cur{background:var(--nav)}
.fr-sn{align-self:center;font-size:13px;white-space:nowrap;overflow:hidden}
.fr-sm{align-self:center;justify-self:center;display:grid;place-items:center}
.fr-sm .ic{width:14px;height:14px;color:var(--warn);stroke-width:2}
.fr-sm .fr-ring{width:14px;height:14px}
.fr-dot{display:block;width:7px;height:7px;border-radius:50%;background:#2f6de1}
.fr-sc{align-self:center;justify-self:end;font-size:12px;color:var(--tx2);font-variant-numeric:tabular-nums}
.fr-s2{font-size:12px;line-height:16px;color:var(--tx2);white-space:nowrap;overflow:hidden}
.fr-s2.w{color:var(--warn)}
.fr-st{grid-column:2/4;justify-self:end;font-size:12px;line-height:16px;color:var(--tx2);font-variant-numeric:tabular-nums;white-space:nowrap}
.fr-co{display:flex;flex-direction:column;padding-top:6px}
.fr-cl{height:52px;display:flex;align-items:flex-start;gap:10px;padding-top:5px}
.fr-cl i{display:block;width:30px;height:1px;background:var(--tx2);opacity:.45;margin-top:10px;flex:none}
.fr-cl span{display:flex;flex-direction:column;gap:0}
.fr-cl b{font-weight:600;line-height:20px}
.fr-cl em{font-style:normal;font-size:12.5px;line-height:18px;color:var(--tx2)}
.fr-say{margin:0;font-size:13.5px;line-height:1.5;text-wrap:pretty}
.fr-say b{font-weight:600}
.fr-hr{display:flex;align-items:flex-start;gap:12px;padding:11px 14px 11px 16px}
.fr-hr+.fr-hr{border-top:1px solid var(--rule)}
.fr-hb{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px}
.fr-hn{display:flex;align-items:baseline;gap:8px;line-height:19px}
.fr-hn b{font-weight:600;font-size:13.5px}
.fr-hr.off .fr-hn b{color:var(--tx2);font-weight:500}
.fr-he{display:flex;flex-direction:column;align-items:flex-end;gap:7px;flex:none}
.fr-hs{display:inline-flex;align-items:center;gap:5px;font-size:12.5px;line-height:19px;color:var(--tx2);white-space:nowrap}
.fr-hs.ok{color:var(--ok);font-weight:500}
.fr-hs.warn{color:var(--warn);font-weight:500}
.fr-hs .ic{width:13px;height:13px;stroke-width:2.4}
.fr-hs .fr-ring{width:13px;height:13px}
.fr-card>.cmd{border-radius:0 0 14px 14px;font-size:11px;padding:10px 34px 11px 16px}
.fr-sm2{height:24px;padding:0 10px;border-radius:7px;border:0;background:var(--sheet);box-shadow:0 0 0 1px var(--line);font:inherit;font-size:12px;font-weight:500;color:var(--tx);white-space:nowrap;cursor:default;flex:none}
.fr-sec{display:flex;flex-direction:column;gap:7px}
.fr-lab{padding-left:4px;font-size:11px;font-weight:600;letter-spacing:.07em;text-transform:uppercase;color:var(--tx2)}
.fr-g{width:18px;height:19px;display:grid;place-items:center;flex:none}
.fr-g .ic{width:15px;height:15px;stroke-width:2.4}
.fr-g.ok{color:var(--ok)}
.fr-g.warn{color:var(--warn)}
.fr-g.off{color:var(--tx2)}
.fr-k{width:58px;flex:none;font-weight:600;line-height:19px}
.fr-v{flex:1 1 0;min-width:0;display:flex;flex-direction:column;gap:2px;line-height:19px}
.fr-hr.mid{align-items:center}
@media (prefers-reduced-motion:reduce){.fr-hz svg,.fr-ring.go,.fr-wel.go .fr-big{animation:none}}
"""

# ---------------------------------------------------------------------------
# What this Mac has, read on November 9, 2026 with each program's --version.
# `src` names a copy in its row's menu, and `label` in the first draft's rows.

GITS = [
    {"id": "xcode", "src": "Xcode", "from": "from Xcode", "label": "Git from Xcode", "ver": "2.54.0", "path": "/usr/bin/git", "why": "Apple Git-157. The first usable Git in your PATH.", "rec": True},
    {"id": "clt", "src": "Command Line Tools", "from": "from Command Line Tools", "label": "Git from Command Line Tools", "ver": "2.54.0", "path": "/Library/Developer/CommandLineTools/usr/bin/git", "why": "Apple Git-157."},
    {"id": "local", "src": "/usr/local/bin", "from": "in /usr/local/bin", "label": "Git in /usr/local/bin", "ver": "2.33.0", "path": "/usr/local/bin/git", "why": "Your terminal runs this one, but Roga needs 2.44 or later.", "old": True},
]
AGENTS = {
    "claude": {"name": "Claude Code", "copies": [
        {"id": "local", "src": "Your PATH", "label": "In your PATH", "ver": "2.1.318", "path": "~/.local/bin/claude", "why": "Your terminal runs this one.", "rec": True},
        {"id": "n25", "src": "nvm, Node 25", "label": "Through nvm, Node 25", "ver": "2.1.29", "path": "~/.nvm/versions/node/v25.5.0/bin/claude", "why": "Roga needs 2.1.169 or later.", "old": True},
        {"id": "n20", "src": "nvm, Node 20", "label": "Through nvm, Node 20", "ver": "2.0.15", "path": "~/.nvm/versions/node/v20.12.2/bin/claude", "why": "Roga needs 2.1.169 or later.", "old": True},
    ]},
    "codex": {"name": "Codex", "copies": [
        {"id": "chatgpt", "src": "ChatGPT app", "label": "Inside the ChatGPT app", "ver": "0.167.0-alpha.3.2", "path": "/Applications/ChatGPT.app/…/MacOS/codex", "why": "The newest copy, which new models need.", "rec": True},
        {"id": "brew", "src": "Homebrew", "label": "From Homebrew", "ver": "0.166.0", "path": "/opt/homebrew/bin/codex", "why": "Your terminal runs this one."},
    ]},
}
KINDS = ["claude", "codex"]
PICKS = ["git", "claude", "codex"]
LOOKS = [
    ("path", "Your PATH", "Read from your login shell, zsh"),
    ("git", "Git", "3 found · 2.54.0 from Xcode"),
    ("claude", "Claude Code", "3 found · 2.1.318"),
    ("codex", "Codex", "2 found · 0.167.0-alpha.3.2"),
]
STEP_LABELS = {"git": "Git", "agents": "Agents", "hooks": "Hooks", "github": "GitHub", "finish": "Finish"}
PLUGINS = r"~/Library/Application\ Support/sh.roga.app/plugins"
WIN_W, WIN_H, FLOOR_PAD, HOUSE = 1120, 800, 64, 46

BASE = {
    "step": "git", "git": "xcode", "use": True, "menu": None,
    "found": {"claude": True, "codex": True},
    "on": {"claude": True, "codex": True},
    "copy": {"claude": "local", "codex": "chatgpt"},
    "hook": {"claude": "no", "codex": "no"},
    "skipped": False, "check": True, "dl": False, "later": False, "looked": 4,
}
HOOK_STATES = {
    "no": ("stt", "Not installed"),
    "busy": ("stt", "Installing…"),
    "ok": ("stt ok", "Installed"),
    "trust": ("stt warn", "Needs your OK in Codex"),
}
TRUST_HELP = "Run /hooks in Codex and trust Roga's, or use Review hooks in the Codex app."
HOOK_OK = {"claude": "It works in the sessions you start from now on.", "codex": "Codex trusts Roga's hooks."}
HOOK_TRUST = "Codex won't run a new hook until you trust it. Run /hooks in Codex, or use Review hooks in the Codex app."
UNUSED_LINE = "Roga won't use it. Pick a copy from the menu to use it after all."
OFF_LINE = "Roga hides its agent commands and the Generate button."
NO_HOOKS_LINE = "The sidebar won't show what your agents are doing."
AGENTS_SUB = "Roga can ask an agent to write a commit message, resolve a conflict or fix what Git refused. It only runs one when you press a button for it."
NO_AGENTS_SUB = "Roga looked for Claude Code and Codex in your PATH and where their installers put them. It works without one, and you can add one later in Settings › Agents."


def state(**changes) -> dict:
    out = copy.deepcopy(BASE)
    for key, value in changes.items():
        if isinstance(value, dict):
            out[key].update(value)
        else:
            out[key] = value
    return out


def copy_of(st: dict, kind: str) -> dict:
    return next(c for c in AGENTS[kind]["copies"] if c["id"] == st["copy"][kind])


def and_(names: list[str]) -> str:
    return names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]


def window_steps(st: dict, any_usable: bool) -> list[str]:
    return ["looking", "git", "agents"] + (["hooks"] if any_usable else []) + (["github"] if st["later"] else []) + ["ready"]


def house_x(index: int, count: int) -> int:
    return round(FLOOR_PAD + index / (count - 1) * (WIN_W - 2 * FLOOR_PAD - HOUSE))


def copies_hint(found: dict) -> str:
    counts = [(len(AGENTS[k]["copies"]), AGENTS[k]["name"]) for k in KINDS if found[k]]
    if not counts:
        return ""
    words = [f"{n} {'copy' if n == 1 else 'copies'} of {name}" if i == 0 else f"{n} of {name}" for i, (n, name) in enumerate(counts)]
    return f"Roga found {and_(words)}. {'Each menu lists them all' if len(counts) > 1 else 'The menu lists them all'}."


def hooks_summary(names_ok: list[str], names_waiting: list[str]) -> tuple[str, str, str]:
    """What the Ready screen says about hooks, and which mark it gets."""
    if names_ok and names_waiting:
        return f"Installed in {and_(names_ok)}", f"{and_(names_waiting)} is waiting for you to trust them.", "warn"
    if names_waiting:
        return f"Installed in {and_(names_waiting)}", "It's waiting for you to trust them.", "warn"
    if names_ok:
        return f"Installed in {and_(names_ok)}", "", "ok"
    return "Not installed", NO_HOOKS_LINE, "off"


def derive(st: dict) -> dict:
    """What a static board shows for a state. The Try board's script works out
    the same values in JavaScript."""
    found, on, menu = st["found"], st["on"], st["menu"]
    used = {k: found[k] and on[k] for k in KINDS}
    usable = {k: st["use"] and used[k] for k in KINDS}
    any_usable = any(usable.values())
    pending = any(usable[k] and st["hook"][k] == "no" for k in KINDS)
    busy = any(usable[k] and st["hook"][k] == "busy" for k in KINDS)
    found_names = [AGENTS[k]["name"] for k in KINDS if found[k]]
    asked_names = [AGENTS[k]["name"] for k in KINDS if used[k]] or found_names
    g = next(x for x in GITS if x["id"] == st["git"])
    vals = {
        "found": found, "missing": {k: not found[k] for k in KINDS},
        "used": {"git": True, **used}, "usable": usable,
        "anyFound": bool(found_names), "noneFound": not found_names,
        "canUse": any(used.values()), "cantUse": bool(found_names) and not any(used.values()),
        "agentsHead": f"Use {and_(asked_names)} in Roga?" if found_names else "Roga didn't find a coding agent",
        "agentsSub": AGENTS_SUB if found_names else NO_AGENTS_SUB,
        "agentsHint": copies_hint(found),
        "menuOpen": {k: menu == k for k in PICKS}, "anyMenu": menu is not None,
        "slCls": {k: "fr-sl open" if menu == k else "fr-sl" for k in PICKS},
        "rowCls": {"git": "fr-row", **{k: "fr-row" if used[k] else "fr-row off" for k in KINDS}},
        "pk": {"git": {"ver": g["ver"], "line": g["path"], "lineCls": "pth", "src": g["src"]}},
        "pending": pending, "busy": busy, "ready": not pending and not busy,
        "hooksBefore": pending or busy, "hooksAfter": not pending and not busy,
        "gitHead": f"Roga will use Git {g['ver']} {g['from']}",
        "chk": {"use_yes": st["use"], "use_no": not st["use"]}, "hk": {}, "tgc": {},
        "ringCls": "fr-ring", "welCls": "",
        "lk": {}, "lkSpin": {}, "lkWait": {},
        "lookDone": st["looked"] >= len(LOOKS), "lookBusy": st["looked"] < len(LOOKS),
        # The first draft's sheets read these.
        "off": {k: found[k] and not usable[k] for k in KINDS},
        "hookLabel": {}, "hookCls": {}, "hookOk": {}, "hookTrust": {}, "hookSub": {}, "hookSubCls": {},
    }
    for n, (key, _, _) in enumerate(LOOKS):
        vals["lk"][key] = st["looked"] > n
        vals["lkSpin"][key] = st["looked"] == n
        vals["lkWait"][key] = st["looked"] < n
    for x in GITS:
        vals["chk"]["git_" + x["id"]] = st["git"] == x["id"]
    for k in KINDS:
        c = copy_of(st, k)
        vals["pk"][k] = (
            {"ver": c["ver"], "line": c["path"], "lineCls": "pth", "src": c["src"]} if used[k]
            else {"ver": "", "line": UNUSED_LINE, "lineCls": "why", "src": "Not used"}
        )
        for c2 in AGENTS[k]["copies"]:
            vals["chk"][f"copy_{k}_{c2['id']}"] = on[k] and st["copy"][k] == c2["id"]
        vals["chk"]["off_" + k] = not on[k]
        h = st["hook"][k]
        vals["hk"][k] = {"no": h == "no", "busy": h == "busy", "ok": h == "ok", "trust": h == "trust"}
        vals["hookCls"][k], vals["hookLabel"][k] = HOOK_STATES[h]
        vals["hookOk"][k], vals["hookTrust"][k] = h == "ok", h == "trust"
        vals["hookSubCls"][k] = "why warn" if h == "trust" else "why"
        vals["hookSub"][k] = (
            TRUST_HELP if h == "trust"
            else ("Works in sessions you start from now on." if k == "claude" else "Codex trusts Roga's hooks.") if h == "ok"
            else "Detected, " + c["ver"] if found[k] else ""
        )
    vals["tgc"]["check"] = "tg on" if st["check"] else "tg"
    vals["tgc"]["dl"] = "tg on" if st["dl"] and st["check"] else "tg"

    # What the Ready screen says.
    names = [f"{AGENTS[k]['name']} {copy_of(st, k)['ver']}" for k in KINDS if usable[k]]
    left_out = [AGENTS[k]["name"] for k in KINDS if st["use"] and found[k] and not on[k]]
    hooks, hooks_detail, hooks_mark = hooks_summary(
        [AGENTS[k]["name"] for k in KINDS if usable[k] and st["hook"][k] == "ok"],
        [AGENTS[k]["name"] for k in KINDS if usable[k] and st["hook"][k] == "trust"],
    )
    agents_detail = (and_(left_out) + " isn't used.") if any_usable and left_out else "" if any_usable else OFF_LINE if found_names else "Roga looked for Claude Code and Codex."
    vals["sum"] = {
        "git": f"Git {g['ver']} {g['from']}", "gitPath": g["path"],
        "agents": and_(names) if any_usable else "Not used" if found_names else "None found",
        "agentsDetail": agents_detail, "hooks": hooks, "hooksDetail": hooks_detail,
    }
    vals["sumHas"] = {"agentsDetail": bool(agents_detail), "hooksDetail": bool(hooks_detail)}
    vals["sumG"] = {
        "agentsOk": any_usable, "agentsOff": not any_usable, "hooksShown": any_usable,
        "hooksOk": hooks_mark == "ok", "hooksWarn": hooks_mark == "warn", "hooksOff": hooks_mark == "off",
    }
    hook_words = {"ok": "installed", "trust": "waiting for your OK", "no": "not installed", "busy": "not installed"}
    vals["old"] = {
        "git": f"{g['label']} {g['ver']}", "gitPath": g["path"],
        "agents": "Off" if not st["use"] else ", ".join(names) if names else "None found yet",
        "hooks": "None" if not any_usable else "Skipped" if st["skipped"]
        else "; ".join(f"{AGENTS[k]['name']}: {hook_words[st['hook'][k]]}" for k in KINDS if usable[k]),
    }

    # The first draft's row of steps, for the sheet boards.
    sheet = ["git", "agents"] + (["hooks"] if any_usable else []) + (["github"] if st["later"] else []) + ["finish"]
    if st["step"] in sheet:
        at = sheet.index(st["step"])
        vals["pips"] = [{"label": STEP_LABELS[k], "cur": n == at, "done": n < at} for n, k in enumerate(sheet)]
    # The window's dots and where the house stands on its floor.
    steps = window_steps(st, any_usable)
    welcome = st["step"] == "welcome"
    at = steps.index(st["step"]) if st["step"] in steps else -1
    vals["dots"] = [{"cls": "cur" if n == at else "done" if n < at else ""} for n in range(len(steps))]
    vals["showDots"] = not welcome
    vals["showHouse"] = not welcome
    vals["houseX"] = house_x(max(at, 0), len(steps))
    vals["hzCls"] = "fr-hz"
    return vals


# ---------------------------------------------------------------------------
# One set of screens draws both kinds of board. A static board reads values
# now, and the Try board leaves holes for its script to fill.


class View:
    def __init__(self, vals: dict | None = None):
        self.vals = vals

    @property
    def live(self) -> bool:
        return self.vals is None

    def get(self, path: str):
        value = self.vals
        for part in path.split("."):
            value = value[part]
        return value

    def when(self, path: str, markup: str) -> str:
        if self.live:
            return f'<sc-if value="{{{{{path}}}}}" hint-placeholder-val="{{{{true}}}}">{markup}</sc-if>'
        return markup if self.get(path) else ""

    def text(self, path: str) -> str:
        if self.live:
            return "{{" + path + "}}"
        value = self.get(path)
        if isinstance(value, bool):
            return "true" if value else "false"
        return esc(str(value))

    def click(self, path: str) -> str:
        return f' onClick="{{{{{path}}}}}"' if self.live else ""

    def pips(self) -> str:
        check = ic("check")
        inner = "".join(
            f'<button class="{"cur" if p["cur"] else ""}">{check if p["done"] else ""}{esc(p["label"])}</button>'
            for p in self.vals["pips"]
        )
        return f'<nav class="pips" aria-label="Steps">{inner}</nav>'

    def dots(self) -> str:
        if self.live:
            inner = '<sc-for list="{{dots}}" as="d" hint-placeholder-count="5"><i class="{{d.cls}}"></i></sc-for>'
        else:
            inner = "".join(f'<i class="{d["cls"]}"></i>' for d in self.vals["dots"])
        return self.when("showDots", f'<div class="fr-dots" aria-hidden="true">{inner}</div>')


def btn(title: str, kind: str = "sec", click: str = "", extra: str = "") -> str:
    return f'<button class="b {kind}"{click}{extra}>{esc(title)}</button>'


def fbtn(title: str, kind: str = "pri", click: str = "", extra: str = "") -> str:
    return f'<button class="fr-b {kind}"{click}{extra}>{esc(title)}</button>'


def card(inner: str, role: str = "", label: str = "") -> str:
    r = f' role="{role}" aria-label="{esc(label)}"' if role else ""
    return f'<div class="oc"{r}>{inner}</div>'


def opt(v: View, o: dict, key: str) -> str:
    if o.get("old"):
        status = '<span class="stt warn">Too old</span>'
    elif o.get("rec"):
        status = f'<span class="stt ok">{ic("check")}Detected, recommended</span>'
    else:
        status = '<span class="stt">Detected</span>'
    disabled = " disabled" if o.get("old") else ""
    click = "" if o.get("old") else v.click(f"pick.{key}")
    checked = "false" if o.get("old") else v.text(f"chk.{key}")
    return (
        f'<button class="opt" role="radio" aria-checked="{checked}"{click}{disabled}><span class="rad"></span><span class="ob">'
        f'<span class="ot"><b>{esc(o["label"])}</b><span class="ver">{esc(o["ver"])}</span>{status}</span>'
        f'<span class="pth">{esc(o["path"])}</span><span class="why">{esc(o["why"])}</span></span></button>'
    )


def plain_opt(v: View, title: str, key: str) -> str:
    return (
        f'<button class="opt" role="radio" aria-checked="{v.text("chk." + key)}"{v.click("pick." + key)}>'
        f'<span class="rad"></span><span class="ob"><span class="ot"><b>{esc(title)}</b></span></span></button>'
    )


def cmd_block(lines: str) -> str:
    return f'<div class="cmd"><button class="cp" aria-label="Copy the commands">{ic("copy")}</button>{lines}</div>'


def line(*words: tuple[str, str]) -> str:
    return tokens_html([(P, "$"), *words])


def install_lines(kind: str) -> str:
    """The commands Install runs, as `HookInstaller.installCommands` has them."""
    if kind == "claude":
        return (
            line((G, "claude"), (G, "plugin"), (G, "marketplace"), (G, "add"), (R, PLUGINS))
            + line((G, "claude"), (G, "plugin"), (G, "install"), (R, "roga-hooks@roga"), (F, "--scope"), (R, "user"))
            + line((G, "claude"), (G, "plugin"), (G, "update"), (R, "roga-hooks@roga"), (F, "--scope"), (R, "user"))
        )
    return (
        line((G, "codex"), (G, "plugin"), (G, "marketplace"), (G, "add"), (R, PLUGINS))
        + line((G, "codex"), (G, "plugin"), (G, "add"), (R, "roga-hooks@roga"))
    )


def kv(key: str, value: str, where: str, path: str = "") -> str:
    p = f'<span class="pth">{path}</span>' if path else ""
    return f'<div class="kv"><span class="k">{key}</span><span class="v"><span>{value}</span>{p}</span><span class="to">{where}</span></div>'


# ---------------------------------------------------------------------------
# The first draft: a sheet on the empty first window.


def hook_rows(v: View) -> str:
    rows = ""
    for k in KINDS:
        name = esc(AGENTS[k]["name"])
        status = f'<span class="{v.text("hookCls." + k)}">{v.when("hookOk." + k, ic("check"))}{v.text("hookLabel." + k)}</span>'
        rows += v.when(
            "usable." + k,
            f'<div class="kv c"><div class="v"><b>{name}</b><span class="{v.text("hookSubCls." + k)}">{v.text("hookSub." + k)}</span></div>{status}</div>',
        )
        rows += v.when("off." + k, f'<div class="kv c"><div class="v"><b class="off">{name}</b><span class="why">Turned off in the last step.</span></div><span class="stt">Nothing to install</span></div>')
        rows += v.when("missing." + k, f'<div class="kv c"><div class="v"><b class="off">{name}</b><span class="why">Not detected on this Mac.</span></div><span class="stt">Nothing to install</span></div>')
    return card(rows)


def summary_cards(v: View) -> str:
    summary = card(
        kv("Git", v.text("old.git"), "Settings › Git", v.text("old.gitPath"))
        + kv("Agents", v.text("old.agents"), "Settings › Agents")
        + kv("Hooks", v.text("old.hooks"), "Settings › Agents")
    )
    updates = card(
        f'<div class="kv c"><div class="v"><b>Check for updates automatically</b><span class="why">A new version shows in the sidebar.</span></div><button class="{v.text("tgc.check")}" aria-label="Check for updates automatically"><i></i></button></div>'
        f'<div class="kv c"><div class="v"><b>Download updates automatically</b></div><button class="{v.text("tgc.dl")}" aria-label="Download updates automatically"><i></i></button></div>'
    )
    return summary + updates


def sheet(v: View, title: str, msg: str, body: str, buttons: str, cmd: str = "") -> str:
    footer = f'{cmd}<div class="btns">{buttons}</div>'
    cls = "dft" if cmd else "dft nc"
    return (
        f'<div class="dlg su" role="dialog" aria-label="{esc(title)}"><div class="dtop">{v.pips()}'
        f'<h3 class="dti">{esc(title)}</h3><p class="msg">{esc(msg)}</p>{body}</div>'
        f'<div class="{cls}">{footer}</div></div>'
    )


def sheet_git(v: View) -> str:
    rows = "".join(opt(v, g, "git_" + g["id"]) for g in GITS)
    return sheet(v, "Choose which Git Roga runs",
                 "Roga runs the Git already on your Mac, with its version and configuration. You can change this later in Settings.",
                 card(rows, "radiogroup", "Git"), btn("Choose Another…") + btn("Continue", "pri"))


def sheet_agents(v: View) -> str:
    use = card(plain_opt(v, "Use agents", "use_yes") + plain_opt(v, "Not now", "use_no"), "radiogroup", "Use agents")
    cards = ""
    for k in KINDS:
        a = AGENTS[k]
        rows = "".join(opt(v, c, f"copy_{k}_{c['id']}") for c in a["copies"])
        cards += card(f'<div class="ah">{esc(a["name"])}<button class="tg on" aria-label="Use {esc(a["name"])}"><i></i></button></div><div role="radiogroup">{rows}</div>')
    return sheet(v, "Do you work with coding agents?",
                 "Roga can run your agents' own command-line tools to write commit messages and fix what Git refused, and it can show which worktrees they're busy in.",
                 use + cards, btn("Back") + btn("Continue", "pri"))


def sheet_hooks(v: View) -> str:
    facts = card(
        '<div class="kv"><span class="k">Roga hears</span><span class="v why">Which event happened, and in which folder.</span></div>'
        '<div class="kv"><span class="k">When it\'s closed</span><span class="v why">The hooks do nothing.</span></div>'
    )
    return sheet(v, "Let your agents tell Roga what they're doing",
                 "Hooks are a small plugin that an agent runs at moments in its work. With them, the sidebar shows which worktrees have an agent working, waiting for you, or finished.",
                 facts + hook_rows(v), btn("Back") + btn("Skip for Now") + btn("Install Hooks", "pri"),
                 cmd=cmd_block(install_lines("claude") + install_lines("codex")))


def sheet_finish(v: View) -> str:
    return sheet(v, "That's everything Roga needs", "You can change any of this in Settings.", summary_cards(v), btn("Back") + btn("Open Roga", "pri"))


SIDEBAR = (
    '<div class="fs" aria-hidden="true"><div class="tl"><i></i><i></i><i></i></div>'
    f'<div class="fi">{ic("plus")}Add Repositories</div><div class="fi">{ic("general")}Settings</div></div>'
)
W, H = 1200, 880


def sheet_board(file: str, title: str, draw, st: dict) -> Board:
    body = (
        f'<div class="board {{{{th}}}}" style="width:{W}px;height:{H}px"><div class="fw">{SIDEBAR}<div class="fm"></div>'
        f'<div class="over"><div class="scrim"></div>{draw(View(derive(st)))}</div></div></div>'
    )
    return Board(file, title, W, H, s.dc(title, W, H, body, s.STATIC_PROPS, s.STATIC_SCRIPT % "light"))


# ---------------------------------------------------------------------------
# The setup in the whole window. Three things repeat on every screen: a row
# that says which program Roga will run, with a menu of every copy it found; a
# sentence that says what the dark button does; and the buttons as the answer.


def head(eyebrow: str, title: str, sub: str) -> str:
    return f'<div class="fr-hd"><span class="fr-eb">{esc(eyebrow)}</span><h2 class="fr-h">{title}</h2><p class="fr-sub">{sub}</p></div>'


def col(*parts: str) -> str:
    return f'<div class="fr-col">{"".join(parts)}</div>'


def fcard(inner: str) -> str:
    return f'<div class="fr-card">{inner}</div>'


def acts(*buttons: str) -> str:
    return f'<div class="fr-acts">{"".join(buttons)}</div>'


def back(v: View) -> str:
    return fbtn("Back", "gh", v.click("back"))


def menu_item(v: View, o: dict, key: str) -> str:
    """A copy of a program in its row's menu: where it's from and its version,
    its path, and why Roga would or wouldn't run it."""
    old = o.get("old")
    tag = '<span class="fr-old">Too old</span>' if old else '<span class="tag">Recommended</span>' if o.get("rec") else ""
    mark = "" if old else v.when("chk." + key, ic("check"))
    attrs = ' disabled aria-checked="false"' if old else f' aria-checked="{v.text("chk." + key)}"{v.click("pick." + key)}'
    return (
        f'<button class="fr-mi" role="menuitemradio"{attrs}><span class="fr-ck">{mark}</span><span class="fr-mb">'
        f'<span class="fr-mt"><b>{esc(o["src"])}</b>{tag}<span class="ver">{esc(o["ver"])}</span></span>'
        f'<span class="pth">{esc(o["path"])}</span><span class="why">{esc(o["why"])}</span></span></button>'
    )


def menu(v: View, key: str, name: str, options: list[dict], prefix: str, can_skip: bool = False) -> str:
    items = "".join(menu_item(v, o, f"{prefix}_{o['id']}") for o in options)
    tail = '<div class="fr-ms"></div><button class="fr-mi one" role="menuitem"><span class="fr-ck"></span>Choose another…</button>'
    if can_skip:
        tail += (
            f'<button class="fr-mi one" role="menuitemradio" aria-checked="{v.text("chk.off_" + key)}"{v.click("pick.off_" + key)}>'
            f'<span class="fr-ck">{v.when("chk.off_" + key, ic("check"))}</span>Don’t use {esc(name)}</button>'
        )
    return f'<div class="fr-menu" role="menu" aria-label="Every {esc(name)} Roga found">{items}{tail}</div>'


def prog_row(v: View, key: str, glyph: str, name: str, menu_markup: str) -> str:
    """The program Roga will run: its name and version, the check mark for
    having been found, its path, and the button that opens its menu."""
    picker = (
        f'<span class="fr-pick"><button class="{v.text("slCls." + key)}" aria-haspopup="menu"{v.click("open." + key)}>'
        f'{v.text(f"pk.{key}.src")}{icon("updown")}</button>{v.when("menuOpen." + key, menu_markup) if menu_markup else ""}</span>'
    )
    detected = v.when("used." + key, f'<span class="fr-det">{ic("check")}Detected</span>')
    return (
        f'<div class="{v.text("rowCls." + key)}"><span class="fr-ri">{glyph}</span><span class="fr-rb">'
        f'<span class="fr-rt"><b>{esc(name)}</b><span class="ver">{v.text(f"pk.{key}.ver")}</span>{detected}</span>'
        f'<span class="{v.text(f"pk.{key}.lineCls")}">{v.text(f"pk.{key}.line")}</span></span>{picker}</div>'
    )


def plain_row(glyph: str, title: str, under: str, right: str, off: bool = False, under_cls: str = "pth") -> str:
    return (
        f'<div class="fr-row{" off" if off else ""}"><span class="fr-ri">{glyph}</span><span class="fr-rb">'
        f'<span class="fr-rt">{title}</span><span class="{under_cls}">{under}</span></span>{right}</div>'
    )


def git_row(v: View, with_menu: bool = True) -> str:
    return prog_row(v, "git", icon("git"), "Git", menu(v, "git", "Git", GITS, "git") if with_menu else "")


def agent_row(v: View, k: str, with_menu: bool = True) -> str:
    a = AGENTS[k]
    return prog_row(v, k, ic("agents"), a["name"], menu(v, k, a["name"], a["copies"], "copy_" + k, can_skip=True) if with_menu else "")


def scr_welcome(v: View) -> str:
    return (
        f'<div class="fr-wel{v.text("welCls")}">{house_svg("fr-big")}{wordmark_svg()}'
        '<span class="fr-tag">Rather Opinionated Git App</span>'
        '<p class="fr-lead">A fast Git app for your Mac, made for keeping an eye on your agents and reviewing what they did.</p>'
        f'{acts(fbtn("Get Started", "pri", v.click("start")))}'
        '<p class="fr-fine">Setup takes about a minute. You can change all of it later in Settings.</p></div>'
    )


def scr_looking(v: View) -> str:
    rows = ""
    for key, name, detail in LOOKS:
        rows += (
            '<div class="fr-lk">'
            + v.when("lk." + key, f'<span class="fr-ok">{ic("check")}</span>')
            + v.when("lkSpin." + key, RING.format(cls=v.text("ringCls")))
            + v.when("lkWait." + key, '<span class="fr-wait"><i></i></span>')
            + f'<b>{esc(name)}</b><span class="fr-lv">'
            + v.when("lk." + key, esc(detail)) + v.when("lkSpin." + key, "Looking…")
            + "</span></div>"
        )
    return col(
        head("Your Mac", "Looking around your Mac", "Roga reads your PATH the way your terminal does, then asks each program it finds for its version. Nothing is installed or changed."),
        fcard(rows),
        v.when("lookDone", acts(fbtn("Continue", "pri", v.click("next")))),
        v.when("lookBusy", acts(fbtn("Looking…", "pri", extra=" disabled"))),
    )


def scr_git(v: View) -> str:
    return col(
        head("Git", v.text("gitHead"), "Roga runs the Git on your Mac, with your own configuration, and needs 2.44 or newer."),
        fcard(git_row(v)),
        '<p class="fr-note">Roga found 3 Gits, and recommends the first one in your PATH that\'s new enough.<br>Your terminal runs the one in /usr/local/bin, which is 2.33 and too old.</p>',
        acts(back(v), fbtn("Continue", "pri", v.click("next"))),
    )


def scr_agents(v: View) -> str:
    rows = ""
    for k in KINDS:
        name = esc(AGENTS[k]["name"])
        rows += v.when("found." + k, agent_row(v, k))
        rows += v.when("missing." + k, plain_row(ic("agents"), f"<b>{name}</b>", "Not found in your PATH, or where its installer puts it.",
                                                '<button class="fr-sl plain">Choose…</button>', off=True, under_cls="why"))
    answer = acts(
        back(v), fbtn("Don’t Use Agents", "sec", v.click("noAgents")),
        v.when("canUse", fbtn("Use Agents", "pri", v.click("useAgents"))), v.when("cantUse", fbtn("Use Agents", "pri", extra=" disabled")),
    )
    return col(
        head("Agents", v.text("agentsHead"), v.text("agentsSub")),
        fcard(rows),
        v.when("anyFound", f'<p class="fr-note">{v.text("agentsHint")}</p>' + answer + '<p class="fr-fine">You can change this later in Settings › Agents.</p>'),
        v.when("noneFound", acts(back(v), fbtn("Look Again", "sec"), fbtn("Continue", "pri", v.click("noAgents")))),
    )


MARKS = [
    ("agent/fix-login", "Editing LoginView.swift", "2 min", "3", "ring", "Working", "An agent is busy in this worktree."),
    ("agent/billing", "Needs your OK: git push", "1 min", "1", "alert", "Waiting for you", "It asked a question, or needs your OK."),
    ("agent/search-index", "Finished", "4 min", "7", "dot", "Finished", "It's done, and you haven't looked yet."),
]


def figure(v: View) -> str:
    """Three rows of the sidebar as decision 51 draws them, each with a line
    out to what its mark means, so that it reads as a picture and not a list."""
    marks = {"ring": RING.format(cls=v.text("ringCls")), "alert": icon("alert"), "dot": '<span class="fr-dot"></span>'}
    rows = calls = ""
    for n, (name, words, how_long, count, mark, title, meaning) in enumerate(MARKS):
        rows += (
            f'<div class="fr-sr{" cur" if n == 0 else ""}"><span class="fr-sn">{esc(name)}</span><span class="fr-sm">{marks[mark]}</span><span class="fr-sc">{count}</span>'
            f'<span class="fr-s2{" w" if mark == "alert" else ""}">{esc(words)}</span><span class="fr-st">{how_long}</span></div>'
        )
        calls += f'<div class="fr-cl"><i></i><span><b>{esc(title)}</b><em>{esc(meaning)}</em></span></div>'
    return f'<div class="fr-fig" role="img" aria-label="The sidebar, with a mark on each worktree an agent is in"><div class="fr-sb">{rows}</div><div class="fr-co">{calls}</div></div>'


def hooks_card(v: View) -> str:
    ring, check, alert = RING.format(cls=v.text("ringCls")), ic("check"), icon("alert")
    rows = ""
    for k in KINDS:
        name = esc(AGENTS[k]["name"])
        aside = v.when(f"hk.{k}.no", '<span class="why">asks you to trust the hooks before it runs them</span>') if k == "codex" else ""
        notes = v.when(f"hk.{k}.ok", f'<span class="why">{esc(HOOK_OK[k])}</span>') + v.when(f"hk.{k}.trust", f'<span class="why">{esc(HOOK_TRUST)}</span>')
        status = (
            v.when(f"hk.{k}.no", '<span class="fr-hs">Not installed</span>')
            + v.when(f"hk.{k}.busy", f'<span class="fr-hs">{ring}Installing…</span>')
            + v.when(f"hk.{k}.ok", f'<span class="fr-hs ok">{check}Installed</span>')
            + v.when(f"hk.{k}.trust", f'<span class="fr-hs warn">{alert}Waiting for your OK</span><button class="fr-sm2"{v.click("trusted")}>Check Again</button>')
        )
        rows += v.when("usable." + k, f'<div class="fr-hr"><span class="fr-hb"><span class="fr-hn"><b>{name}</b>{aside}</span>{notes}</span><span class="fr-he">{status}</span></div>')
        rows += v.when("missing." + k, f'<div class="fr-hr off"><span class="fr-hb"><span class="fr-hn"><b>{name}</b></span></span><span class="fr-he"><span class="fr-hs">Not found, so nothing to install</span></span></div>')
    lines = "".join(v.when("usable." + k, install_lines(k)) for k in KINDS)
    return fcard(rows + v.when("hooksBefore", cmd_block(lines)))


def scr_hooks(v: View) -> str:
    before = '<p class="fr-say"><b>Install Hooks</b> adds a small plugin, roga-hooks, to each agent, with the commands below. It only reports what a session is doing, and never changes what the agent does.</p>'
    after = '<p class="fr-say">The roga-hooks plugin is in. You can remove it any time in Settings › Agents.</p>'
    return col(
        head("Hooks", "See what your agents are doing", "Roga's hooks let your agents tell Roga when a session is working, waiting for you or finished. The sidebar then shows it on the worktree:"),
        figure(v),
        v.when("hooksBefore", before) + v.when("hooksAfter", after),
        hooks_card(v),
        acts(
            back(v),
            v.when("pending", fbtn("Not Now", "sec", v.click("skip")) + fbtn("Install Hooks", "pri", v.click("install"))),
            v.when("busy", fbtn("Installing…", "pri", extra=" disabled")),
            v.when("ready", fbtn("Continue", "pri", v.click("next"))),
        ),
    )


def sum_row(glyph: str, key: str, value: str, detail: str, change: str) -> str:
    return f'<div class="fr-hr">{glyph}<span class="fr-k">{key}</span><span class="fr-v"><span>{value}</span>{detail}</span>{change}</div>'


def scr_ready(v: View) -> str:
    ok, warn, off = f'<span class="fr-g ok">{ic("check")}</span>', f'<span class="fr-g warn">{icon("alert")}</span>', f'<span class="fr-g off">{icon("minus")}</span>'

    def change(step: str) -> str:
        return f'<button class="fr-sm2"{v.click("go." + step)}>Change</button>'

    setup = fcard(
        sum_row(ok, "Git", v.text("sum.git"), f'<span class="pth">{v.text("sum.gitPath")}</span>', change("git"))
        + sum_row(v.when("sumG.agentsOk", ok) + v.when("sumG.agentsOff", off), "Agents", v.text("sum.agents"),
                  v.when("sumHas.agentsDetail", f'<span class="why">{v.text("sum.agentsDetail")}</span>'), change("agents"))
        + v.when("sumG.hooksShown", sum_row(
            v.when("sumG.hooksOk", ok) + v.when("sumG.hooksWarn", warn) + v.when("sumG.hooksOff", off), "Hooks", v.text("sum.hooks"),
            v.when("sumHas.hooksDetail", f'<span class="why">{v.text("sum.hooksDetail")}</span>'), change("hooks")))
    )
    updates = fcard(
        f'<div class="fr-hr mid"><span class="fr-hb"><span class="fr-hn"><b>Check for updates automatically</b></span><span class="why">A new version shows in the sidebar.</span></span>'
        f'<button class="{v.text("tgc.check")}" aria-label="Check for updates automatically"{v.click("flip.check")}><i></i></button></div>'
        f'<div class="fr-hr mid"><span class="fr-hb"><span class="fr-hn"><b>Download updates automatically</b></span></span>'
        f'<button class="{v.text("tgc.dl")}" aria-label="Download updates automatically"{v.click("flip.dl")}><i></i></button></div>'
    )
    return col(
        head("Ready", "You're all set", "Here's what you chose. Change anything now, or later in Settings."),
        f'<div class="fr-sec"><span class="fr-lab">What you chose</span>{setup}</div>',
        f'<div class="fr-sec"><span class="fr-lab">One more thing</span>{updates}</div>',
        acts(back(v), fbtn("Open Roga", "pri", v.click("done"))),
    )


def scr_git_none(v: View) -> str:
    rows = (
        plain_row(icon("git"), '<b>Git</b><span class="ver">2.33.0</span><span class="fr-det warn">Too old</span>', "/usr/local/bin/git", "", off=False)
        + plain_row(icon("git"), "<b>Git from Apple</b>", "It comes with the Command Line Tools, which aren't installed.", "", off=True, under_cls="why")
    )
    lines = line((G, "xcode-select"), (F, "--install"))
    return col(
        head("Git", "Roga needs Git 2.44 or newer", "Roga runs the Git on your Mac, and the only one it found is older than that. Apple's comes with the Command Line Tools, which take a few minutes to install."),
        '<p class="fr-say"><b>Install Command Line Tools</b> opens Apple\'s installer, which is what this command does:</p>',
        fcard(rows + cmd_block(lines)),
        '<p class="fr-note">Homebrew\'s Git works too. Install one, or choose one, then Look Again.</p>',
        acts(fbtn("Choose Another…", "gh"), fbtn("Look Again", "sec"), fbtn("Install Command Line Tools", "pri")),
    )


def scr_github(v: View, signed_in: bool) -> str:
    if signed_in:
        row = plain_row(icon("github"), f'<b>GitHub CLI</b><span class="fr-det">{ic("check")}Signed in to github.com</span>', "/opt/homebrew/bin/gh", "")
        say = "<b>Use This Account</b> reads the login the GitHub CLI already has, with these commands:"
        lines = line((G, "gh"), (G, "auth"), (G, "status")) + line((G, "gh"), (G, "repo"), (G, "list"), (F, "--limit"), (R, "100"))
        buttons = acts(back(v), fbtn("Not Now", "sec"), fbtn("Use This Account", "pri"))
        title = "Use your GitHub account?"
    else:
        row = plain_row(icon("github"), '<b>GitHub CLI</b><span class="fr-det warn">Not signed in</span>', "/opt/homebrew/bin/gh", "")
        say = "<b>Sign In with gh</b> runs this command, which finishes in your browser:"
        lines = line((G, "gh"), (G, "auth"), (G, "login"), (F, "--web"))
        buttons = acts(back(v), fbtn("Not Now", "sec"), fbtn("Sign In with gh…", "pri"))
        title = "Sign in to GitHub?"
    return col(
        head("Later", title, "Roga can list the repositories you can clone, using the login the GitHub CLI already has. Roga keeps no account or token of its own."),
        f'<p class="fr-say">{say}</p>', fcard(row + cmd_block(lines)), buttons,
    )


def window(v: View, stage: str, extra: str = "") -> str:
    house = v.when("showHouse", f'<div class="fr-floor"></div><div class="{v.text("hzCls")}" style="left:{v.text("houseX")}px">{house_svg()}</div>')
    scrim = v.when("anyMenu", f'<div class="fr-scrim"{v.click("closeMenu")}></div>')
    return (
        f'<div class="board {{{{th}}}}" style="width:{W}px;height:{H}px"><div class="fr-win">'
        f'<div class="fr-top"><div class="tl"><i></i><i></i><i></i></div>{v.dots()}</div>'
        f'<div class="fr-stage">{stage}</div>{house}{scrim}{extra}</div></div>'
    )


def board(file: str, title: str, draw, st: dict, theme: str = "light") -> Board:
    v = View(derive(st))
    body = window(v, draw(v))
    props = {**s.STATIC_PROPS, "theme": {**s.STATIC_PROPS["theme"], "default": theme}}
    return Board(file, title, W, H, s.dc(title, W, H, body, props, s.STATIC_SCRIPT % theme))


TRY_SCRIPT = r"""class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.data = __DATA__;
    this.state = this.fresh();
  }
  fresh() {
    return { step: "welcome", looked: 0, git: "xcode", use: true, on: { claude: true, codex: true }, copy: { claude: "local", codex: "chatgpt" }, hook: { claude: "no", codex: "no" }, menu: null, check: true, dl: false, done: false };
  }
  componentWillUnmount() { this.stop(); }
  stop() { clearTimeout(this.timer); clearInterval(this.ticker); }
  look() {
    this.stop();
    this.setState({ step: "looking", looked: 0 });
    this.ticker = setInterval(() => {
      const n = this.state.looked + 1;
      this.setState({ looked: n });
      if (n >= this.data.looks.length) clearInterval(this.ticker);
    }, 550);
  }
  renderVals() {
    const s = this.state, d = this.data, K = ["claude", "codex"];
    const and = (xs) => xs.length < 2 ? (xs[0] || "") : xs.slice(0, -1).join(", ") + " and " + xs[xs.length - 1];
    const copyOf = (k) => d.agents[k].copies.find((c) => c.id === s.copy[k]);
    const nameOf = (k) => d.agents[k].name;
    const g = d.gits.find((x) => x.id === s.git);
    const used = { git: true }, usable = {}, found = {}, missing = {}, hk = {};
    const rowCls = { git: "fr-row" }, pk = { git: { ver: g.ver, line: g.path, lineCls: "pth", src: g.src } };
    const chk = {}, pick = {}, open = {}, menuOpen = {}, slCls = {}, flip = {}, tgc = {};
    ["git", "claude", "codex"].forEach((k) => {
      menuOpen[k] = s.menu === k;
      slCls[k] = s.menu === k ? "fr-sl open" : "fr-sl";
      open[k] = () => this.setState({ menu: this.state.menu === k ? null : k });
    });
    d.gits.forEach((x) => {
      if (x.old) return;
      chk["git_" + x.id] = s.git === x.id;
      pick["git_" + x.id] = () => this.setState({ git: x.id, menu: null });
    });
    K.forEach((k) => {
      const c = copyOf(k), h = s.hook[k];
      found[k] = true; missing[k] = false;
      used[k] = s.on[k]; usable[k] = s.use && s.on[k];
      rowCls[k] = used[k] ? "fr-row" : "fr-row off";
      pk[k] = used[k] ? { ver: c.ver, line: c.path, lineCls: "pth", src: c.src } : { ver: "", line: d.unusedLine, lineCls: "why", src: "Not used" };
      hk[k] = { no: h === "no", busy: h === "busy", ok: h === "ok", trust: h === "trust" };
      d.agents[k].copies.forEach((c2) => {
        if (c2.old) return;
        const key = "copy_" + k + "_" + c2.id;
        chk[key] = s.on[k] && s.copy[k] === c2.id;
        pick[key] = () => this.setState({ copy: Object.assign({}, this.state.copy, { [k]: c2.id }), on: Object.assign({}, this.state.on, { [k]: true }), menu: null });
      });
      chk["off_" + k] = !s.on[k];
      pick["off_" + k] = () => this.setState({ on: Object.assign({}, this.state.on, { [k]: false }), menu: null });
    });
    tgc.check = s.check ? "tg on" : "tg";
    tgc.dl = s.dl && s.check ? "tg on" : "tg";
    flip.check = () => this.setState({ check: !this.state.check, dl: this.state.check ? false : this.state.dl });
    flip.dl = () => { if (this.state.check) this.setState({ dl: !this.state.dl }); };
    const canUse = K.some((k) => used[k]);
    const anyUsable = K.some((k) => usable[k]);
    const pending = K.some((k) => usable[k] && s.hook[k] === "no"), busy = K.some((k) => usable[k] && s.hook[k] === "busy");
    const steps = ["looking", "git", "agents"].concat(anyUsable ? ["hooks"] : [], ["ready"]);
    const welcome = s.step === "welcome";
    const at = welcome ? -1 : Math.max(0, steps.indexOf(s.step));
    const goTo = (n) => this.setState({ step: steps[Math.max(0, Math.min(steps.length - 1, n))], menu: null });
    const lookDone = s.looked >= d.looks.length;
    const lk = {}, lkSpin = {}, lkWait = {};
    d.looks.forEach((key, n) => { lk[key] = s.looked > n; lkSpin[key] = s.looked === n; lkWait[key] = s.looked < n; });
    const names = K.filter((k) => usable[k]).map((k) => nameOf(k) + " " + copyOf(k).ver);
    const leftOut = K.filter((k) => s.use && !s.on[k]).map(nameOf);
    const okNames = K.filter((k) => usable[k] && s.hook[k] === "ok").map(nameOf);
    const waiting = K.filter((k) => usable[k] && s.hook[k] === "trust").map(nameOf);
    const hooks = okNames.length && waiting.length ? ["Installed in " + and(okNames), and(waiting) + " is waiting for you to trust them.", "warn"]
      : waiting.length ? ["Installed in " + and(waiting), "It's waiting for you to trust them.", "warn"]
      : okNames.length ? ["Installed in " + and(okNames), "", "ok"]
      : ["Not installed", d.noHooksLine, "off"];
    const agentsDetail = !anyUsable ? d.offLine : leftOut.length ? and(leftOut) + " isn't used." : "";
    const span = d.win - 2 * d.pad - d.house;
    return {
      th: (this.props.theme ?? "light") === "dark" ? "th-d" : "th-l",
      isDone: s.done,
      isWelcome: !s.done && welcome, isLooking: !s.done && s.step === "looking", isGit: !s.done && s.step === "git",
      isAgents: !s.done && s.step === "agents", isHooks: !s.done && s.step === "hooks", isReady: !s.done && s.step === "ready",
      showDots: !s.done && !welcome, showHouse: !s.done && !welcome,
      dots: steps.map((k, n) => ({ cls: n === at ? "cur" : n < at ? "done" : "" })),
      houseX: Math.round(d.pad + Math.max(at, 0) / (steps.length - 1) * span),
      hzCls: (s.step === "looking" && !lookDone) || busy ? "fr-hz go" : "fr-hz",
      ringCls: "fr-ring go", welCls: " go",
      lk, lkSpin, lkWait, lookDone, lookBusy: !lookDone,
      gitHead: "Roga will use Git " + g.ver + " " + g.from,
      agentsHead: "Use " + and(canUse ? K.filter((k) => used[k]).map(nameOf) : K.map(nameOf)) + " in Roga?", agentsSub: d.agentsSub, agentsHint: d.agentsHint,
      found, missing, used, usable, anyFound: true, noneFound: false, canUse, cantUse: !canUse,
      rowCls, pk, chk, pick, open, menuOpen, slCls, anyMenu: s.menu !== null, flip, tgc, hk,
      pending, busy, ready: !pending && !busy, hooksBefore: pending || busy, hooksAfter: !pending && !busy,
      sum: { git: "Git " + g.ver + " " + g.from, gitPath: g.path, agents: anyUsable ? and(names) : "Not used", agentsDetail, hooks: hooks[0], hooksDetail: hooks[1] },
      sumHas: { agentsDetail: agentsDetail !== "", hooksDetail: hooks[1] !== "" },
      sumG: { agentsOk: anyUsable, agentsOff: !anyUsable, hooksShown: anyUsable, hooksOk: hooks[2] === "ok", hooksWarn: hooks[2] === "warn", hooksOff: hooks[2] === "off" },
      closeMenu: () => this.setState({ menu: null }),
      start: () => this.look(),
      next: () => goTo(at + 1),
      back: () => goTo(at - 1),
      useAgents: () => this.setState({ use: true, menu: null, step: "hooks" }),
      noAgents: () => this.setState({ use: false, menu: null, step: "ready" }),
      skip: () => this.setState({ step: "ready" }),
      go: {
        git: () => this.setState({ step: "git" }),
        agents: () => this.setState({ step: "agents" }),
        hooks: () => this.setState({ step: "hooks" })
      },
      install: () => {
        const list = K.filter((k) => usable[k] && this.state.hook[k] === "no");
        const working = Object.assign({}, this.state.hook);
        list.forEach((k) => { working[k] = "busy"; });
        this.setState({ hook: working });
        this.timer = setTimeout(() => {
          const after = Object.assign({}, this.state.hook);
          list.forEach((k) => { after[k] = k === "codex" ? "trust" : "ok"; });
          this.setState({ hook: after });
        }, 1400);
      },
      trusted: () => this.setState({ hook: Object.assign({}, this.state.hook, { codex: "ok" }) }),
      done: () => this.setState({ done: true }),
      again: () => { this.stop(); this.setState(this.fresh()); }
    };
  }
}"""


def try_board() -> Board:
    v = View()
    stage = (
        v.when("isWelcome", scr_welcome(v)) + v.when("isLooking", scr_looking(v)) + v.when("isGit", scr_git(v))
        + v.when("isAgents", scr_agents(v)) + v.when("isHooks", scr_hooks(v)) + v.when("isReady", scr_ready(v))
    )
    app = v.when(
        "isDone",
        f'<div style="position:absolute;inset:0;display:flex;background:var(--sheet)">{SIDEBAR}<div class="fm">'
        '<span>Setup is done, and it doesn\'t come back. This is where your repositories will be.</span>'
        f'{fbtn("Start Over", "sec", v.click("again"))}</div></div>',
    )
    body = window(v, stage, app)
    data = {
        "gits": GITS, "agents": AGENTS, "looks": [key for key, _, _ in LOOKS], "win": WIN_W, "pad": FLOOR_PAD, "house": HOUSE,
        "unusedLine": UNUSED_LINE, "offLine": OFF_LINE, "noHooksLine": NO_HOOKS_LINE, "agentsSub": AGENTS_SUB,
        "agentsHint": copies_hint({"claude": True, "codex": True}),
    }
    script = TRY_SCRIPT.replace("__DATA__", json.dumps(data, ensure_ascii=False))
    return Board("FR-Try.dc.html", "Try it", W, H, s.dc("Try it", W, H, body, {"theme": s.STATIC_PROPS["theme"]}, script), interactive=True)


# ---------------------------------------------------------------------------
# Where the same choices live afterward.


def settings_board(file: str, title: str, page: str, content: tuple[str, int]) -> Board:
    ctx = s.Ctx()
    markup, wh = s.window(ctx, page, content[0], content[1], page=page)
    w, h = 960, wh + 80
    body = f'<div class="board {{{{th}}}}" style="width:{w}px;height:{h}px">{markup}</div>'
    return Board(file, title, w, h, s.dc(title, w, h, body, s.STATIC_PROPS, s.STATIC_SCRIPT % "light"))


def settings_git() -> tuple[str, int]:
    v = View(derive(state()))
    ctx = s.Ctx()
    block = s.block(fcard(git_row(v, with_menu=False)) + '<div style="margin-top:10px;display:flex;gap:8px">' + btn("Look Again") + "</div>", 68 + 38)
    return s.join_sections([
        s.section("Installation", [block], desc='Roga uses the first Git 2.44 or newer in your login shell\'s <span class="mono">PATH</span>, unless you pick another from the menu.'),
        s.section("Fetching and pulling", [
            s.row("Fetch when Roga becomes active", s.toggle(ctx, "fetch", True, "Fetch when Roga becomes active"),
                  "Roga runs git fetch for the repository on screen, at most once a minute, so that it can say how far your branch is from its upstream.", today=True),
        ]),
    ])


def settings_agents() -> tuple[str, int]:
    v = View(derive(state()))
    ctx = s.Ctx()
    rows = "".join(agent_row(v, k, with_menu=False) for k in KINDS)
    return s.join_sections([
        s.section("On this Mac", [
            s.row("Use agents", s.toggle(ctx, "use", True, "Use agents"), "Turning this off hides Roga's agent commands, the Generate button and the sidebar's marks."),
            s.block(fcard(rows) + '<div style="margin-top:10px;display:flex;gap:8px">' + btn("Look Again") + "</div>", 2 * 68 + 1 + 38),
        ]),
        s.section("Working status", [
            s.row("Claude Code", btn("Remove…", "sec"), "Hooks installed.", today=True, cw=90),
            s.row("Codex", btn("Install…", "sec"), "Hooks not installed.", today=True, cw=90),
        ]),
    ])


def all_boards() -> list[list[Board]]:
    after_install = {"claude": "ok", "codex": "trust"}
    row1 = [
        board("FR-0-Welcome.dc.html", "Welcome", scr_welcome, state(step="welcome")),
        board("FR-1-Looking.dc.html", "1 · Looking around", scr_looking, state(step="looking", looked=3)),
        board("FR-2-Git.dc.html", "2 · Git", scr_git, state(step="git")),
        board("FR-3-Agents.dc.html", "3 · Agents", scr_agents, state(step="agents")),
        board("FR-4-Hooks.dc.html", "4 · Hooks", scr_hooks, state(step="hooks")),
        board("FR-5-Ready.dc.html", "5 · Ready", scr_ready, state(step="ready", hook=after_install)),
        try_board(),
    ]
    row2 = [
        board("FR-Git-Menu.dc.html", "Git, with its menu open", scr_git, state(step="git", menu="git")),
        board("FR-Git-None.dc.html", "No usable Git", scr_git_none, state(step="git")),
        board("FR-Agents-Menu.dc.html", "Agents, with Codex's menu open", scr_agents, state(step="agents", menu="codex")),
        board("FR-Agents-One.dc.html", "Agents, without Codex", scr_agents, state(step="agents", on={"codex": False})),
        board("FR-Agents-None.dc.html", "No agents found", scr_agents, state(step="agents", found={"claude": False, "codex": False})),
        board("FR-Hooks-Done.dc.html", "Hooks, after Install", scr_hooks, state(step="hooks", hook=after_install)),
        board("FR-Hooks-One.dc.html", "Hooks, with one agent found", scr_hooks, state(step="hooks", found={"codex": False})),
        board("FR-Ready-NoAgents.dc.html", "Ready, without agents", scr_ready, state(step="ready", use=False)),
        board("FR-Agents-Dark.dc.html", "Agents, dark", scr_agents, state(step="agents", menu="claude"), theme="dark"),
    ]
    row3 = [
        board("FR-GitHub.dc.html", "Later · GitHub, signed in", lambda v: scr_github(v, True), state(step="github", later=True)),
        board("FR-GitHub-Out.dc.html", "Later · GitHub, not signed in", lambda v: scr_github(v, False), state(step="github", later=True)),
        settings_board("FR-Settings-Git.dc.html", "Settings › Git", "git", settings_git()),
        settings_board("FR-Settings-Agents.dc.html", "Settings › Agents", "agents", settings_agents()),
    ]
    row4 = [
        sheet_board("FR-Sheet-Git.dc.html", "Sheet · Git", sheet_git, state()),
        sheet_board("FR-Sheet-Agents.dc.html", "Sheet · Agents", sheet_agents, state(step="agents")),
        sheet_board("FR-Sheet-Hooks.dc.html", "Sheet · Hooks", sheet_hooks, state(step="hooks")),
        sheet_board("FR-Sheet-Finish.dc.html", "Sheet · Finish", sheet_finish, state(step="finish", hook=after_install)),
    ]
    return [row1, row2, row3, row4]


# ---------------------------------------------------------------------------
# Notes that sit with the boards.

TITLES = [
    "First run, in the whole window",
    "When a Mac isn't like this one",
    "Later, and where these choices live",
    "The first draft, as a sheet",
]
INTROS = [
    "Setup takes over the one window the first time Roga runs, and the window becomes the app when it's done. Three things repeat on every screen, so each one reads the same way. "
    "A program Roga will run is a row with its name, version and path, and a menu on that row lists every copy Roga found. A sentence in bold says what the dark button does before you press it. "
    "And a step you can decline is answered with its buttons, so there's no switch to find. Everything here is what this Mac really has, read with each program's --version on November 9. Nothing is built yet.",
    "The steps adapt to what Roga finds. Only a missing Git stops you, because Roga can't open a repository without one. Everything about agents can be declined, and the Hooks step drops out when there's nothing to install, along with its dot at the top.",
    "GitHub is here to hold its place, and it wouldn't ship in the first version. Every choice from setup has a home in Settings, drawn with the same row and menu, and two of those homes need new rows.",
    "Where this page started: a sheet over the empty window, drawn like Roga's dialogs. It read as an interruption rather than an arrival, with Settings rows for content, so it was set aside for the whole-window version above.",
]
NOTES = {
    "FR-0-Welcome.dc.html": "The first thing anyone sees: the house, the wordmark and what Roga is for, with one button. In Try it, the house rocks gently, and it stands still for anyone who asked for less motion, as decision 21 has it. There's no × and no Skip: every step comes filled in, so the dark button is the quick way through.",
    "FR-1-Looking.dc.html": "Roga reads the login shell's PATH and asks each program for its version, and shows it happening. The house waddles along the floor while it looks, and the spinner is the sidebar's own working ring. Nothing is faked: if it all takes under a second, the rows simply fill in quickly. Drawn partway, with Codex still being asked.",
    "FR-2-Git.dc.html": "One answer, said in the heading and again in the row: the version, the check mark for having been found, and the path. The button at the right names where this Git is from, and opens a menu of every Git on this Mac. Recommended means the first Git 2.44 or newer in your PATH, which is Roga's rule today (decisions 3 and 8).",
    "FR-3-Agents.dc.html": "The heading asks, and the buttons answer: Use Agents, or Don't Use Agents. That replaces the switches on each agent and the line of text under them, which made one decision look like three. Each agent is the same row as Git's, with its own menu of copies. The rule for which copy wins is today's: first in PATH for Claude Code, newest for Codex.",
    "FR-4-Hooks.dc.html": "Read from the top, it answers why, what and how. The heading and the picture say why: three rows of the real sidebar, each with a line out to what its mark means, so it can't be mistaken for a list to click. The bold sentence says what Install Hooks does. The card under it names where the plugin goes, and ends in the exact commands, as Roga's dialogs do (decision 29).",
    "FR-5-Ready.dc.html": "Two labeled groups, so it's plain which part looks back and which asks something new. What you chose has a mark for each line, green when it's done and amber when something still waits on you, and Change goes back to that step. Updates are two switches rather than a step, since checking is already on by default.",
    "FR-Try.dc.html": "Press Play and go through it. On Git and Agents, open a row's menu and pick another copy, or Don't use Codex. Answer Agents with either button. On Hooks, Install Hooks shows Claude Code finish while Codex waits for your OK. On Ready, Change takes you back to a step. Theme under Tweaks switches to dark.",
    "FR-Git-Menu.dc.html": "The menu opens on the row it belongs to, where a select would on a Mac. Each copy says where it's from, its version, its path, and why Roga would or wouldn't run it. A Git that's too old is listed but can't be picked, so nobody wonders why Roga doesn't run their terminal's Git. Its name, version and path are faded, and Too old and the reason aren't, so the row reads as one that can't be chosen and says why. Choose another… is for one outside the usual places.",
    "FR-Git-None.dc.html": "The one screen that stops you. The bold sentence says what the dark button does, and the command under the rows is that same thing, for anyone who'd rather run it. Roga never runs /usr/bin/git before knowing the tools are there, because that's what opens Apple's dialog unannounced, which decision 3 ruled out.",
    "FR-Agents-Menu.dc.html": "Codex's menu, open under Codex's own row. It has the copy inside the ChatGPT app and Homebrew's, with what's different about each, then Choose another… and Don't use Codex. Picking a copy changes the version and path in the row straight away.",
    "FR-Agents-One.dc.html": "After Don't use Codex from its menu. The row stays, dimmed, and says how to bring Codex back. Use Agents now means Claude Code alone, and the Hooks step will only install there. This is today's switch per agent, moved into the menu.",
    "FR-Agents-None.dc.html": "Neither agent was found. The rows say so, Choose… points Roga at one in an unusual place, and Look Again checks once more after you install one. Continue goes straight to Ready, since there's nothing to install.",
    "FR-Hooks-Done.dc.html": "After Install Hooks, the commands give way to what happened. Claude Code is done. Codex has the plugin but won't run its hooks until you trust them inside Codex, which Roga can't do for you, so its line says how and Check Again looks once more. Continue stays available, on the idea that setup shouldn't wait on another app.",
    "FR-Hooks-One.dc.html": "What was found and what wasn't. Codex's line says there's nothing to install, and only Claude Code's commands show, because those are the only ones that will run.",
    "FR-Ready-NoAgents.dc.html": "After Don't Use Agents. The Agents line says so with a gray mark, the Hooks line is gone, and there are four dots at the top instead of five. Change brings the question back.",
    "FR-Agents-Dark.dc.html": "The Agents step in dark, with Claude Code's menu open. Two of its three copies are too old for Roga, so they're listed and can't be picked.",
    "FR-GitHub.dc.html": "Sits before Ready once it exists, and is answered with its buttons like the other steps you can decline. It reads the login the GitHub CLI already has, so Roga stores no account or token of its own. What it enables is listing repositories to clone, which is parked for now, and VISION.md keeps Roga from becoming a hosting client.",
    "FR-GitHub-Out.dc.html": "With the GitHub CLI installed but not signed in, the dark button runs gh auth login, which finishes in the browser. Without gh at all, the step doesn't appear.",
    "FR-Settings-Git.dc.html": "Where the choice from setup lives afterward: the same row and the same menu, replacing the single line and Choose… that the Settings page draws. Settings › Git only has fetching in the app today, so this section and the saved path are new work.",
    "FR-Settings-Agents.dc.html": "Where the agents' choices live afterward. Use agents is the one new row, and it's what Don't Use Agents sets. Each agent's row is the one from setup, with its menu, in place of today's switch and the Choose… button on the agent's own page. Hooks stay as they are, with Install… and Remove….",
    "FR-Sheet-Git.dc.html": "The sheet's Git step: every Git as an equal row, with three lines each.",
    "FR-Sheet-Agents.dc.html": "The sheet's Agents step: five copies on one screen, which read like Settings.",
    "FR-Sheet-Hooks.dc.html": "The sheet's Hooks step: it explained the hooks in a table instead of showing what they do.",
    "FR-Sheet-Finish.dc.html": "The sheet's last step: the same facts as Ready, without saying which part looks back.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tFR{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": width, "page": PAGE_ID}
        notes[f"nFR{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the First run page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the First run boards, and optionally merge them into a canvas.json."""
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
        # The page that opens first is the user's call, so launch stays as it was.
        canvas.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        click.echo(f"Merged {len(boards)} boards and {len(notes)} notes into {canvas}")
        for name in stale:
            click.echo(f"No longer drawn, remove from the canvas: project/{name}")


if __name__ == "__main__":
    main()
