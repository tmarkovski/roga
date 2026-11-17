# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Draws the Agent settings boards for the design canvas "yaga layout options".

Today's Agents, agent and Commit pages as they're built on main, next to one
switch for agents: Use agents, then the agents Roga found and custom ones, the
default agent, and Status for the agents whose hooks Roga can install. An
agent's page keeps only its copy, model, effort and Run Test, and the Commit
page folds into Git. It borrows the styles, the window and the rows of
`docs/design/settings/boards.py`, and the setup screens of
`docs/design/first-run/boards.py`, so the pages stay one family.

    uv run docs/design/agent-settings/boards.py --out /path/to/root --canvas /path/to/root/project/canvas.json

Boards that an earlier run put on the page and this one doesn't are listed at
the end, so they can be removed from the canvas when it's published.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path

import click

HERE = Path(__file__).resolve().parent
PAGE_ID = "agentsettings"
PAGE_NAME = "Agent settings"

_spec = importlib.util.spec_from_file_location("first_run_boards", HERE.parent / "first-run" / "boards.py")
fr = importlib.util.module_from_spec(_spec)
sys.modules["first_run_boards"] = fr
_spec.loader.exec_module(fr)
s = fr.s

esc, ic, Board, Ctx = s.esc, s.ic, s.Board, s.Ctx
row, block, section, toggle, popup, select, field_, command = s.row, s.block, s.section, s.toggle, s.popup, s.select, s.field_, s.command
P, G, F, R, S = s.P, s.G, s.F, s.R, s.S

s.CSS += r"""
.b.sec{flex-direction:row}
.as-val{font-size:12.5px;color:var(--tx2);white-space:nowrap;align-self:center}
.as-pick{position:absolute;z-index:3}
.as-pick .menu{width:240px}
.as-pick .mi .why{color:var(--tx2);font-size:12px;margin-left:auto}
.as-tag{display:inline-block;margin-left:8px;padding:0 6px;border-radius:5px;background:var(--card);color:var(--tx2);font-size:11px;font-weight:500;vertical-align:1px}
.as-only{display:flex;flex-direction:column;gap:0}
"""

# What this Mac has, as the first-run boards draw it.
CLAUDE_LINE = "~/.local/bin/claude · 2.1.318"
CODEX_LINE = "/Applications/ChatGPT.app/…/MacOS/codex · 0.167.0-alpha.3.2"
OLLAMA = "ollama run qwen2.5-coder:7b"
HEARD = "Last heard from 2 minutes ago, in acme/api."
TRUST = "Not installed. Codex asks you to trust a new hook the first time it runs."
USE_HELP = "Generate commit messages, resolve conflicts and fix Git errors with a coding agent, and see what your agents are doing in the sidebar."
AGENTS_DESC = "Generate, Resolve and Fix run the default agent with its tools off, and send what they need to its provider."


def chev(name: str) -> str:
    return f'<button class="chev" aria-label="{esc(name)} settings">{ic("right")}</button>'


def rescan() -> str:
    return f'<button class="b sec sm">{ic("refresh", "ic s")}Rescan</button>'


# ---------------------------------------------------------------------------
# Shared rows.


def hook_list(prefix: str = "") -> tuple[str, int]:
    rows = [
        ("Claude Code", f'<span class="okt">{prefix}Installed</span> (roga-hooks plugin). {HEARD}', '<button class="b sec sm">Remove…</button>'),
        ("Codex", f"{prefix}{TRUST}" if not prefix else f"{prefix}not installed. Codex asks you to trust them the first time they run.", '<button class="b pri sm">Install…</button>'),
    ]
    out = "".join(
        f'<div class="hk"><div class="an"><b>{esc(name)}</b><span class="rh">{detail}</span></div><div class="rc">{btn}</div></div>'
        for name, detail, btn in rows
    )
    return f'<div class="lst">{out}</div>', 2 * 77 + 2


def legend() -> tuple[str, int]:
    markup = (
        '<div class="lg" role="img" aria-label="How the sidebar marks a worktree">'
        f'<div class="lgr">{s.RING}<span class="ref">agent/fix-login</span><span class="lv">Working</span></div>'
        f'<div class="lgr">{s.DOT}<span class="ref">agent/search-index</span><span class="lv">Finished, unread</span></div>'
        f'<div class="lgr">{fr.icon("alert")}<span class="ref">agent/billing</span><span class="lv">Waiting for a response</span></div></div>'
    )
    return markup, 3 * 26 + 4 + 12


def flags_card(kind: str) -> tuple[str, int]:
    flags = [
        ("-p", "Print the response and exit."),
        ("--safe-mode", "Disable hooks, plugins, skills, MCP servers and CLAUDE.md instructions."),
        ("--setting-sources user", "Load user settings only; exclude the worktree's .claude settings."),
        ("--tools=", "Disable all tools, including shell commands and file access."),
        ("--no-session-persistence", "Disable session history."),
    ]
    card = '<div class="card">' + "".join(f'<div class="cr"><span class="h">{esc(f)}</span><span class="v">{esc(v)}</span></div>' for f, v in flags) + "</div>"
    return card, 5 * 18 + 4 * 7 + 20 + 18


def claude_line(model: str = "haiku", effort: str = "low") -> list[list[tuple[str, str]]]:
    return [[
        (P, "$"), (G, "claude"), (F, "-p"), (F, "--safe-mode"), (F, "--setting-sources"), (R, "user"),
        (F, "--model"), (R, model), (F, "--effort"), (R, effort), (F, "--tools="), (F, "--no-session-persistence"),
        (F, "--output-format"), (R, "json"), (F, "--system-prompt"), (R, "…"),
    ]]


def test_row(result: str, rest: str = "with a two-line message for a sample diff.") -> str:
    return (
        '<div style="display:flex;align-items:center;gap:12px"><button class="b sec">Run Test</button>'
        f'<span class="res"><span class="ok" style="white-space:nowrap">{ic("check", "ic s")}{esc(result)}</span>{esc(rest)}</span></div>'
    )


def executable_row(kind: str, how: bool = True) -> tuple[str, int]:
    path, version, source, found = (
        ("~/.local/bin/claude", "Claude Code 2.1.318", "Your PATH", "Found in your login shell's PATH.") if kind == "claude"
        else ("/Applications/ChatGPT.app/…/MacOS/codex", "Codex 0.167.0-alpha.3.2", "ChatGPT app", "Latest detected version.")
    )
    helper = f'<span class="mono" style="color:var(--tx)">{esc(path)}</span> · {esc(version)}' + (f"<br>{esc(found)}" if how else "")
    sel = f'<button class="sel" style="width:150px"><span class="sv">{esc(source)}</span>{fr.icon("updown", "ic s")}</button>'
    return row("Executable", sel, help_html=helper, help="x" * 60, extra=1 if how else 0, cw=150)


def instructions_block() -> tuple[str, int]:
    text = "Follow the repository's own style for commit messages. Start with a short summary of what changed…"
    return block(
        '<div style="display:flex;flex-direction:column;gap:6px"><div style="display:flex;align-items:baseline"><span class="rt" style="flex:1 1 0">Custom instructions</span><button class="lnk">Restore Defaults</button></div>'
        f'<textarea class="ta" aria-label="Custom instructions">{esc(text)}</textarea></div>',
        23 + 6 + 84,
    )


# ---------------------------------------------------------------------------
# Today, as RogaKit/Sources/RogaUI/Settings draws it on main.


def today_agents(ctx: Ctx) -> tuple[str, int]:
    rows = [("Claude Code", CLAUDE_LINE), ("Codex", CODEX_LINE)]
    lst = "".join(
        f'<div class="ar"><button class="an"><b>{esc(n)}</b><span class="ap">{esc(line)}</span></button>'
        f'<div class="rc">{toggle(ctx, "en_" + n, True, "Enable " + n)}{chev(n)}</div></div>'
        for n, line in rows
    )
    hooks, hh = hook_list()
    lg, lh = legend()
    s1 = section("Command-line agents", [block(f'<div class="lst">{lst}</div>', 2 * 59 + 2)], aside=rescan(),
                 desc='Detect agents in your login shell\'s <span class="mono">PATH</span> and standard installation locations. Commit message generation runs locally with tools disabled.')
    s2 = section("Agent status", [
        block(hooks, hh),
        row("Show agents in the sidebar", toggle(ctx, "marks", True, "Show agents in the sidebar"), "Show working, waiting and finished states beside each worktree."),
        block(lg, lh),
    ], desc="Show agent activity for worktrees in the sidebar. Status updates come from agent hooks.")
    return s.join_sections([s1, s2])


def today_agent(ctx: Ctx) -> tuple[str, int]:
    s1 = section("Configuration", [
        row("Enable Claude Code", toggle(ctx, "en", True, "Enable Claude Code"), "Available for commit message generation. Hook settings are independent."),
        executable_row("claude"),
        row("Model", popup("haiku"), "Passed as --model. Default uses Claude Code's configured model.", cw=120),
        row("Reasoning effort", popup("Low"), "Passed as --effort. Default uses Claude Code's configured effort.", cw=120),
        row("Additional arguments", field_("", "Additional arguments", mono=True, width=220, placeholder="--append-system-prompt …"), "Appended after the default arguments.", cw=220),
        row("Timeout", popup("60 seconds"), "Maximum duration for commit message generation.", cw=130),
    ])
    card, ch = flags_card("claude")
    s2 = section("Command-line arguments", [
        block(card, ch),
        block('<div style="display:flex;flex-direction:column;gap:12px">' + command(claude_line(), comment="Staged diff supplied via standard input") + test_row("Replied in 2.4 s") + "</div>", 19 + 21 + 19 * 2 + 12 + 28),
    ], desc="Default arguments for commit message generation, applied before additional arguments.")
    events = [
        ("UserPromptSubmit, PreToolUse", s.RING, "Working"),
        ("Notification, PermissionRequest", fr.icon("alert"), "Waiting for input"),
        ("Stop", s.DOT, "Finished"),
        ("SessionEnd", "", "Removed from sidebar"),
    ]
    ev = '<div class="card">' + "".join(
        f'<div class="cr" style="align-items:center"><span class="h">{esc(e)}</span><span class="v" style="display:flex;align-items:center;gap:7px">'
        f'<span style="width:14px;height:14px;display:block">{m}</span>{esc(t)}</span></div>'
        for e, m, t in events
    ) + "</div>"
    s3 = section("Agent status", [
        row("Hooks", '<button class="b sec">Remove…</button>', help_html=f'<span class="okt">Installed</span> (roga-hooks plugin). {HEARD}', help="x" * 70, cw=90),
        block(ev, 4 * 18 + 3 * 7 + 20),
    ], desc='Hooks send session events and worktree paths via <span class="key">roga hook --host claude</span>. They return immediately and have no effect when Roga is closed.')
    return s.join_sections([s1, s2, s3])


def today_commit(ctx: Ctx) -> tuple[str, int]:
    effort = s.seg(ctx, "effort", ["Default", "Low", "Medium", "High"], "Low", "Reasoning effort")
    return s.join_sections([section("Commit message generation", [
        row("Show Generate button", toggle(ctx, "gb", True, "Show Generate button"), "Generate commit messages from the message editor or with ⌥⌘L."),
        row("Agent", select("Claude Code", 200), "The staged diff is sent to the selected agent's provider.", cw=200),
        row("Model", popup("haiku"), "Model used for commit message generation.", cw=110),
        row("Reasoning effort", effort, cw=300),
        row("Match repository commit style", toggle(ctx, "style", True, "Match repository commit style"), "Include the last 20 commit subjects as style examples."),
        instructions_block(),
        block(
            '<div style="display:flex;flex-direction:column;gap:7px">'
            + command(claude_line(), comment="Staged diff supplied via standard input")
            + '<span class="rh">Runs in the worktree with tools, hooks, plugins, MCP servers and repository agent settings disabled. Configure the executable and arguments in Agents.</span></div>',
            19 + 21 + 19 * 2 + 7 + 36,
        ),
    ])])


# ---------------------------------------------------------------------------
# One switch.


def use_row(ctx: Ctx, on: bool) -> tuple[str, int]:
    return row("Use agents", toggle(ctx, "use", on, "Use agents"), USE_HELP)


def agent_list(menu: bool = False) -> tuple[str, int]:
    rows = [
        ("Claude Code", CLAUDE_LINE, ""),
        ("Codex", CODEX_LINE, ""),
        ("Ollama", OLLAMA, '<span class="as-tag">Custom</span>'),
    ]
    out = "".join(
        f'<div class="ar"><button class="an"><b>{esc(n)}{tag}</b><span class="ap">{esc(line)}</span></button>'
        f'<div class="rc">{chev(n)}</div></div>'
        for n, line, tag in rows
    )
    out += f'<button class="aradd">{ic("plus")}Add Custom Agent…</button>'
    return f'<div class="lst">{out}</div>', 3 * 59 + 45 + 2


def default_row(menu: bool = False) -> tuple[str, int]:
    pick = select("Claude Code", 200)
    if menu:
        items = [("Claude Code", "2.1.318"), ("Codex", "0.167.0"), ("Ollama", "Custom")]
        rows = "".join(
            f'<div class="mi"><span class="ck">{ic("check", "ic xs") if name == "Claude Code" else ""}</span><span>{name}</span><span class="why">{why}</span></div>'
            for name, why in items
        )
        pick = f'<span style="position:relative;display:inline-block">{pick}<span class="as-pick" style="right:-10px;top:36px"><span class="menu" role="menu" aria-label="Default agent">{rows}</span></span></span>'
    return row("Default agent", pick, cw=200)


def agents_on(ctx: Ctx, menu: bool = False) -> tuple[str, int]:
    use, uh = use_row(ctx, True)
    lst, lh = agent_list()
    d, dh = default_row(menu)
    hooks, hh = hook_list()
    lg, lh2 = legend()
    s0 = (f'<section class="sec" aria-label="Use agents">{use}</section>', uh)
    s1 = section("Agents", [block(lst, lh), (d, dh)], aside=rescan(), desc=AGENTS_DESC)
    s2 = section("Status", [block(hooks, hh), block(lg, lh2)])
    return s.join_sections([s0, s1, s2])


def agents_off(ctx: Ctx) -> tuple[str, int]:
    use, uh = use_row(ctx, False)
    return s.join_sections([(f'<section class="sec" aria-label="Use agents">{use}</section>', uh)])


def agent_page(kind: str) -> tuple[str, int]:
    if kind == "claude":
        model, effort, result = popup("haiku"), popup("Low"), "Replied in 2.4 s"
    else:
        model = field_("", "Model", width=170, placeholder="Default · gpt-6-astra")
        effort, result = popup("Low"), "Replied in 6.1 s"
    t, th = block(test_row(result), 28)
    return s.join_sections([section("Configuration", [
        executable_row(kind, how=False),
        row("Model", model, cw=170),
        row("Reasoning effort", effort, cw=120),
        (t, th),
    ])])


def custom_page() -> tuple[str, int]:
    t, th = block(test_row("Replied in 3.1 s", "with a three-line message for a sample diff."), 28)
    rows = [
        row("Name", field_("Ollama", "Name", width=220), cw=220),
        row("Command", field_(OLLAMA, "Command", mono=True, width=260), "Gets the instructions and the diff on standard input, and prints its answer.", cw=260),
        (t, th),
        block('<button class="b dng">Delete Agent…</button>', 28),
    ]
    return s.join_sections([section("Configuration", rows)])


def add_custom_dialog() -> str:
    lines = [[(P, "$"), (G, "sh"), (F, "-c"), (R, "'ollama run qwen2.5-coder:7b'")]]
    return (
        '<div class="over"><div class="scrim"></div><div class="dlg" role="dialog" aria-label="Add Custom Agent"><div class="dtop">'
        f'<div class="dhd"><h3 class="dti">Add Custom Agent</h3><button class="x" aria-label="Close">{ic("x")}</button></div>'
        '<p class="msg">Any command that reads from standard input and prints its answer, such as a local model. Roga can\'t install hooks in it, so it has no status in the sidebar.</p>'
        '<div class="fld"><label for="an">Name</label><input id="an" class="tf" type="text" value="Ollama"></div>'
        f'<div class="fld"><label for="ac">Command</label><input id="ac" class="tf mono" type="text" value="{esc(OLLAMA)}"></div>'
        + test_row("Replied in 3.1 s", "with a three-line message for a sample diff.")
        + '</div><div class="dft">'
        + command(lines, comment="Instructions and staged diff supplied via standard input")
        + '<div class="btns"><button class="b sec">Cancel</button><button class="b pri">Add Agent</button></div>'
        "</div></div></div>"
    )


def git_page(ctx: Ctx) -> tuple[str, int]:
    v = fr.View(fr.derive(fr.state()))
    git = block(fr.fcard(fr.git_row(v, with_menu=False)), 68)
    return s.join_sections([
        section("Installation", [git], aside=rescan(), desc="Requires Git 2.44 or later."),
        section("Fetching", [
            row("Fetch when Roga becomes active", toggle(ctx, "fetch", True, "Fetch when Roga becomes active"), "At most once a minute. Only remote-tracking branches are updated."),
        ]),
        section("Large repositories", [
            row("Keep commit-graph files up to date", toggle(ctx, "graph", True, "Keep commit-graph files up to date"), "Runs git commit-graph write in the background, without changing Git configuration."),
        ]),
        section("Commit messages", [
            row("Show Generate button", toggle(ctx, "gb", True, "Show Generate button")),
            row("Match repository commit style", toggle(ctx, "style", True, "Match repository commit style"), "Sends the last 20 commit subjects with the diff."),
            instructions_block(),
        ]),
    ])


# ---------------------------------------------------------------------------
# First run.


def scr_agents_one_switch(v) -> str:
    rows = "".join(fr.prog_row(v, k, ic("agents"), fr.AGENTS[k]["name"], fr.menu(v, k, fr.AGENTS[k]["name"], fr.AGENTS[k]["copies"], "copy_" + k)) for k in fr.KINDS)
    answer = fr.acts(fr.back(v), fr.fbtn("Don’t Use Agents", "sec"), fr.fbtn("Use Agents", "pri"))
    return fr.col(
        fr.head("Agents", "Use Claude Code and Codex in Roga?", "Generate commit messages, resolve conflicts and fix Git errors with a coding agent, and see what your agents are doing in the sidebar."),
        fr.fcard(rows),
        f'<p class="fr-note">{v.text("agentsHint")}</p>' + answer
        + '<p class="fr-fine">Claude Code is the default. You can change this later in Settings › Agents.</p>',
    )


def scr_ready_one_switch(v) -> str:
    ok = f'<span class="fr-g ok">{ic("check")}</span>'
    warn = f'<span class="fr-g warn">{fr.icon("alert")}</span>'

    def change() -> str:
        return '<button class="fr-sm2">Change</button>'

    setup = fr.fcard(
        fr.sum_row(ok, "Git", "Git 2.54.0 from Xcode", '<span class="pth">/usr/bin/git</span>', change())
        + fr.sum_row(ok, "Agents", "Claude Code 2.1.318 and Codex 0.167.0", '<span class="why">Claude Code is the default.</span>', change())
        + fr.sum_row(warn, "Hooks", "Installed in Claude Code and Codex", '<span class="why">Hook approval required in Codex.</span>', change())
    )
    updates = fr.fcard(
        '<div class="fr-hr mid"><span class="fr-hb"><span class="fr-hn"><b>Check for updates automatically</b></span><span class="why">A new version shows in the sidebar.</span></span>'
        '<button class="tg on" aria-label="Check for updates automatically"><i></i></button></div>'
        '<div class="fr-hr mid"><span class="fr-hb"><span class="fr-hn"><b>Download updates automatically</b></span></span>'
        '<button class="tg" aria-label="Download updates automatically"><i></i></button></div>'
    )
    return fr.col(
        fr.head("Ready", "You're all set", "Here's what you chose. Change anything now, or later in Settings."),
        f'<div class="fr-sec"><span class="fr-lab">What you chose</span>{setup}</div>',
        f'<div class="fr-sec"><span class="fr-lab">One more thing</span>{updates}</div>',
        fr.acts(fr.back(v), fr.fbtn("Open Roga", "pri")),
    )


# ---------------------------------------------------------------------------
# Boards.


TODAY_NAV = s.NAV
# Settings' sidebar loses Commit and Advanced, which fold into Git.
NEW_NAV = [g for g in ([(k, t) for k, t in group if k not in ("commit", "advanced")] for group in s.NAV) if g]


def settings_board(file: str, title: str, page: str, selected: str, content: tuple[str, int], theme: str = "light", overlay: str = "", page_title: str = "", today: bool = False) -> Board:
    ctx = Ctx()
    s.NAV = TODAY_NAV if today else NEW_NAV
    markup, wh = s.window(ctx, selected, content[0], content[1], overlay=overlay, page=page)
    if page_title:
        markup = markup.replace("<h2>Codex</h2>", f"<h2>{esc(page_title)}</h2>", 1)
    w, h = 960, wh + 80
    body = f'<div class="board {{{{th}}}}" style="width:{w}px;height:{h}px">{markup}</div>'
    props = {**s.STATIC_PROPS, "theme": {**s.STATIC_PROPS["theme"], "default": theme}}
    return Board(file, title, w, h, s.dc(title, w, h, body, props, s.STATIC_SCRIPT % theme))


def setup_board(file: str, title: str, draw, step: str, **changes) -> Board:
    st = fr.state(step=step, **changes)
    v = fr.View(fr.derive(st))
    body = fr.window(v, draw(v))
    return Board(file, title, fr.W, fr.H, s.dc(title, fr.W, fr.H, body, s.STATIC_PROPS, s.STATIC_SCRIPT % "light"))


def all_boards() -> list[list[Board]]:
    c = Ctx()
    today = [
        settings_board("As-Today-Agents.dc.html", "Today · Agents", "agents", "agents", today_agents(c), today=True),
        settings_board("As-Today-Claude.dc.html", "Today · Agents › Claude Code", "claude", "agents", today_agent(c), today=True),
        settings_board("As-Today-Commit.dc.html", "Today · Commit", "commit", "commit", today_commit(c), today=True),
    ]
    switch = [
        settings_board("As-Agents.dc.html", "Agents", "agents", "agents", agents_on(c)),
        settings_board("As-Agents-Off.dc.html", "Agents, turned off", "agents", "agents", agents_off(c)),
        settings_board("As-Agents-Default.dc.html", "Agents, choosing the default", "agents", "agents", agents_on(c, menu=True)),
        settings_board("As-Agents-Add.dc.html", "Agents › Add Custom Agent…", "agents", "agents", agents_on(c), overlay=add_custom_dialog()),
        settings_board("As-Claude.dc.html", "Agents › Claude Code", "claude", "agents", agent_page("claude")),
        settings_board("As-Codex-Dark.dc.html", "Agents › Codex, dark", "codex", "agents", agent_page("codex"), theme="dark"),
        settings_board("As-Custom.dc.html", "Agents › Ollama, a custom agent", "codex", "agents", custom_page(), page_title="Ollama"),
        settings_board("As-Git.dc.html", "Git, with large repositories and commit messages", "git", "git", git_page(c)),
    ]
    setup = [
        setup_board("As-Setup-Agents.dc.html", "First run · Agents", scr_agents_one_switch, "agents"),
        setup_board("As-Setup-Ready.dc.html", "First run · Ready", scr_ready_one_switch, "ready"),
    ]
    return [today, switch, setup]


TITLES = [
    "Agent settings today",
    "One switch for agents",
    "First run",
]

INTROS = [
    "Where agents are set up on main. The same two agents are listed twice on the Agents page and again on each agent's page, Enable only decides whether Roga runs an agent, and the agent, its model and effort are chosen on the Commit page, on the agent's page and in the Generate popover.",
    "Use agents turns everything about agents on or off. While it's on, the page lists the agents Roga found and any custom ones, which one is the default for Generate, Resolve and Fix, and Status for the agents whose hooks Roga can install. An agent's page is its copy, model, effort and Run Test. The Commit and Advanced pages fold into Git.",
    "Setup asks one question about agents, answered with its buttons, as before. Don't use Codex leaves each copy's menu, since there's no switch for one agent. The first agent found is the default, and Hooks follows Use Agents.",
]

NOTES = {
    "As-Today-Agents.dc.html": "Command-line agents lists Claude Code and Codex with Enable, which only decides whether Roga runs them. Agent status lists the same two again, with their hooks.",
    "As-Today-Claude.dc.html": "Enable again, with help that has to say \"Hook settings are independent\". Model and effort, extra arguments, a timeout, the flags and their reasons, the command, and the hooks again with a table of hook events.",
    "As-Today-Commit.dc.html": "Agent, Model and Effort here also decide who resolves conflicts and fixes Git errors, though the section says commit messages.",
    "As-Agents.dc.html": "Use agents first. Agents lists what Roga found, then a custom agent, each with the arrow to its page, and Add Custom Agent… at the end. Default agent is what Generate, Resolve and Fix run, and the Generate popover still switches it. Status has the hooks for Claude Code and Codex only, since a custom command has none, and the legend. Show agents in the sidebar is gone: Use agents and the hooks cover it.",
    "As-Agents-Off.dc.html": "With Use agents off there's nothing else on the page, and Roga does nothing with agents: no Generate, Resolve or Fix, no marks, and no looking for agents at launch. Hooks already installed stay, and return at once without Roga listening. Its help is the one line that says what agents bring.",
    "As-Agents-Default.dc.html": "The default is any agent in the list, custom ones too. There's no None: turning agents off is Use agents.",
    "As-Agents-Add.dc.html": "A custom agent is a name and a command that reads the instructions and the diff on standard input and prints its answer, as Ollama does. The block shows what runs, the command in sh -c, and Run Test under the fields tries it on a sample diff before it's added. It has no hooks, no model or effort, and nothing to detect.",
    "As-Claude.dc.html": "An agent's page is its copy, model, effort and Run Test, and nothing else. The flags, the command, extra arguments, the timeout and the hooks are gone. The exact command still shows in the Generate popover, and the time limit is fixed: 60 seconds for a message, at least 3 minutes to resolve or fix.",
    "As-Codex-Dark.dc.html": "Codex's model is typed, since its names depend on the account, and the placeholder says what Default is.",
    "As-Custom.dc.html": "A custom agent's page: its name, its command, Run Test, and Delete.",
    "As-Git.dc.html": "The Commit page folds into Git as Commit messages: the Generate button, the repository's style and the instructions. It shows only while agents are on. Advanced folds in too, since its one setting runs git in each repository: Large repositories comes after Fetching, and the sidebar ends at Agents. Help stays only where it says something the title doesn't.",
    "As-Setup-Agents.dc.html": "Use Claude Code and Codex in Roga? with Don't Use Agents and Use Agents, as setup asks today, with each row's menu of copies. The menu loses Don't use Codex, since agents are on or off together.",
    "As-Setup-Ready.dc.html": "Ready says which agents are in use and which is the default, and Hooks follows as before.",
}


def layout(rows: list[list[Board]]) -> tuple[dict, dict]:
    boards: dict[str, dict] = {}
    notes: dict[str, dict] = {}
    y = 0
    for index, row_boards in enumerate(rows):
        width = sum(b.w for b in row_boards) + 80 * (len(row_boards) - 1)
        notes[f"tAs{index}"] = {"x": 0, "y": y - 520, "text": TITLES[index], "kind": "title1", "maxW": width, "page": PAGE_ID}
        notes[f"nAs{index}"] = {"x": 0, "y": y - 340, "w": 1000, "text": INTROS[index], "page": PAGE_ID}
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
@click.option("--canvas", "canvas", type=click.Path(dir_okay=False, exists=True, path_type=Path), help="A canvas.json to add the Agent settings page to.")
def main(out: Path, canvas: Path | None) -> None:
    """Write the Agent settings boards, and optionally merge them into a canvas.json."""
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
