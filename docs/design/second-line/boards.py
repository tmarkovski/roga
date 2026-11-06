"""Boards for the canvas's "Second line" page: what a sidebar row could say
under its name, beside today's one-line rows.

Writes project/SL-*.dc.html under the folder given as the first argument, and
prints each board's size and the canvas.json entries to add.
"""

import html
import json
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
PROJECT = ROOT / "project"
PROJECT.mkdir(parents=True, exist_ok=True)

SIDEBAR_W = 312
SIDEBAR_H = 860
TOOLBAR_H = 52
HEADER_H = 32
ROW_H = 32
ROW2_H = 48
ROW_GAP = 2

# ---------------------------------------------------------------- styles

CSS = """
body{margin:0}
*{box-sizing:border-box}
.board{display:flex;gap:40px;padding:30px;background:#e9e9e6;color:#1f1f1e;font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden;align-items:flex-start}
.cap{font-size:13px;font-weight:500;color:#1f1f1e;height:44px}
.cap i{display:block;font-style:normal;font-weight:400;color:#5c5c58}
.col{position:relative;display:flex;flex-direction:column;flex:none}
.th-l{--nav:#f4f3f2;--edge:#e2e2e2;--t1:rgba(0,0,0,.85);--t2:rgba(0,0,0,.5);--sel:rgba(0,0,0,.11);--hov:rgba(0,0,0,.075);--tree:rgba(0,0,0,.25);--cnt:#ff9500;--act:#c94402;--red:#cd1755;--warn:#9a5200;--fin:#2f6de1;--track:#d6d6d3;--ink:#1a1a1a;--onink:#fff;--mono:rgba(0,0,0,.08)}
.th-d{--nav:#191918;--edge:#393939;--t1:rgba(255,255,255,.85);--t2:rgba(255,255,255,.55);--sel:rgba(255,255,255,.11);--hov:rgba(255,255,255,.075);--tree:rgba(255,255,255,.25);--cnt:#ff9f0a;--act:#f0813f;--red:#fc5884;--warn:#f0a54a;--fin:#2f6de1;--track:#4a4a47;--ink:#ececec;--onink:#161616;--mono:rgba(255,255,255,.1)}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.sb{width:312px;height:860px;flex:none;background:var(--nav);color:var(--t1);display:flex;flex-direction:column;overflow:hidden;border-radius:12px;box-shadow:0 0 0 .5px rgba(0,0,0,.14)}
.tb{height:52px;flex:none;display:flex;align-items:center;padding-left:20px;gap:8px}
.tb i{width:12px;height:12px;border-radius:50%;display:block}
.body{flex:1;min-height:0;display:flex}
.rail{width:55px;flex:none;display:flex;flex-direction:column;align-items:center}
.items{flex:1;min-height:0;display:flex;flex-direction:column;align-items:center;gap:8px;padding-top:2px}
.addw{padding:10px 0;flex:none}
.it{width:38px;height:38px;display:grid;place-items:center;border-radius:9px}
.tile{width:28px;height:28px;border-radius:7.3px;display:grid;place-items:center;font-size:11.2px;font-weight:700;line-height:1;color:var(--t2)}
.tile.mo{background:var(--mono)}
.tile.on{background:var(--ink);color:var(--onink)}
.tile .ic{width:15px;height:15px;stroke-width:1.4}
.vr{width:1px;flex:none;background:var(--edge)}
.lst{flex:1;min-width:0;display:flex;flex-direction:column;overflow:hidden}
.hd{height:32px;flex:none;display:flex;align-items:center;gap:6px;padding:0 12px 0 18px;white-space:nowrap}
.hd b{font-size:14px;font-weight:600}
.hd span{font-size:13px;color:var(--t2)}
.rows{display:flex;flex-direction:column;gap:2px;padding:0 8px}
.r{position:relative;height:32px;flex:none;display:flex;align-items:flex-start;width:100%;padding:0 4px 0 10px;border:0;border-radius:8px;background:none;color:var(--t1);font:inherit;font-size:14px;text-align:left;white-space:nowrap;cursor:default;transition:height .18s ease}
.r.two{height:48px}
.r.on{background:var(--sel)}
.tx{flex:1 1 0;min-width:0;display:flex;flex-direction:column;padding-top:7px}
.wt .tx,.hid .tx{padding-left:20px}
.l1{display:flex;align-items:center;gap:3px;height:18px;line-height:18px;min-width:0}
.nm{min-width:0;overflow:hidden;text-overflow:ellipsis}
.hid .nm{font-size:13px;color:var(--t2)}
.dim .nm{opacity:.6}
.dt{font-size:13px;color:var(--t2);padding-left:3px;min-width:0;overflow:hidden;text-overflow:ellipsis}
.cv{width:11px;height:11px;flex:none;fill:none;stroke:var(--t2);stroke-width:2.2;stroke-linecap:round;stroke-linejoin:round;margin:0 3px}
.l2{display:flex;align-items:center;height:16px;line-height:16px;font-size:13px;color:var(--t2);min-width:0}
.l2.warn{color:var(--warn)}
.l2.red{color:var(--red)}
.l2 .mk{margin-right:5px}
.w{min-width:0;overflow:hidden;text-overflow:ellipsis}
.tm{flex:none;margin-left:4px}
.trail{flex:none;display:flex;align-items:center;height:24px;margin-top:4px;padding-left:6px}
.trail .mk{margin-right:6px}
.cnt{display:inline-flex;align-items:center;gap:3px;font-size:13px;color:var(--cnt);padding-right:7px}
.cnt.red{color:var(--red)}
.cnt .ic{width:13px;height:13px}
.say{font-size:13px;color:var(--t2);padding-right:7px}
.cn{position:absolute;left:14px;top:-2px;bottom:0;width:10px;border-left:1px solid var(--tree)}
.cn.last{bottom:auto;height:18.5px;border-bottom:1px solid var(--tree);border-bottom-left-radius:6px}
.mk{position:relative;width:14px;height:14px;flex:none;display:block}
.mk svg{position:absolute;left:0;top:0;width:14px;height:14px;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.mk .trk{stroke:var(--track)}
.mk .arc{stroke:var(--act);animation:spin 1s linear infinite}
.mk .alert{left:.85px;top:.85px;width:12.3px;height:12.3px;stroke:var(--warn)}
.mk .dot{position:absolute;left:3.5px;top:3.5px;width:7px;height:7px;border-radius:50%;background:var(--fin)}
@keyframes spin{to{transform:rotate(360deg)}}
.tip{position:absolute;z-index:3;max-width:236px;padding:3px 8px;border-radius:6px;background:#f6f6f6;color:#1a1a1a;font-size:11.5px;line-height:15px;box-shadow:0 0 0 .5px rgba(0,0,0,.22),0 6px 16px rgba(0,0,0,.16)}
.ptr{position:absolute;z-index:2;width:12px;height:18px}
"""

# ---------------------------------------------------------------- icons

ICON = {
    "down": '<path d="m6 9 6 6 6-6"></path>',
    "right": '<path d="m9 18 6-6-6-6"></path>',
    "tri": '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"></path><path d="M12 9v4"></path><path d="M12 17h.01"></path>',
    "inbox": '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>',
    "dots": '<circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle><circle cx="5" cy="12" r="1"></circle>',
    "plus": '<path d="M5 12h14"></path><path d="M12 5v14"></path>',
}


def icon(name, cls="ic"):
    return f'<svg class="{cls}" viewBox="0 0 24 24" aria-hidden="true">{ICON[name]}</svg>'


RING = ('<span class="mk"><svg class="trk" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5"></circle></svg>'
        '<svg class="arc" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5A5.5 5.5 0 0 1 13.5 8"></path></svg></span>')
WAIT = ('<span class="mk"><svg class="alert" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="10"></circle>'
        '<line x1="12" x2="12" y1="8" y2="12"></line><line x1="12" x2="12.01" y1="16" y2="16"></line></svg></span>')
FIN = '<span class="mk"><i class="dot"></i></span>'
MARK = {"working": RING, "waiting": WAIT, "finished": FIN}

# ---------------------------------------------------------------- data


def agent(state, words, named, time=None):
    return {"state": state, "words": words, "named": named, "time": time}


def repo(n, **kw):
    return {"kind": "repo", "n": n, **kw}


def wt(n, **kw):
    return {"kind": "wt", "n": n, **kw}


ROWS = [
    repo("api-gateway", id="api", chev="down", commit="Retry webhooks when the endpoint times out"),
    wt("agent/fix-login", id="fix", count=3, on=True, commit="Lock the login after five failed attempts",
       agent=agent("working", "Run the test suite", "Claude Code: Run the test suite", "6 min")),
    wt("agent/rate-limits", id="rate", count=1, commit="Add a token bucket per API key",
       agent=agent("waiting", "Needs your OK: git push", "Codex needs your OK: git push", "2 min")),
    wt("tm/retry-webhooks", id="retry", commit="Retry webhooks with backoff",
       agent=agent("finished", "Added retries with backoff to the webhook client", "Claude Code finished: Added retries with backoff to the webhook client")),
    wt("agent/docs-refresh", id="docs", last=True, commit="Rewrite the setup guide for macOS 26"),
    repo("billing", id="billing", chev="right", commit="Show the invoice total before tax",
         agent=agent("working", "Editing InvoiceView.swift", "Claude Code: Editing InvoiceView.swift", "3 min")),
    {"kind": "hid", "n": "2 worktrees", "id": "billing-hid", "count": 2, "last": True,
     "commit": "agent/tax-rules, tm/invoice-pdf"},
    repo("dashboard", id="dash", commit="Show an empty state when there are no invoices"),
    repo("docs-site", id="site", count=1, commit="Document the rate limits"),
    repo("infra", id="infra", detail="release/2.3", count=2, conf=True, commit="Move the queue to its own cluster",
         roga={"words": "Rebasing release/2.3", "tm": "· 2 conflicts", "tone": "red"}),
    repo("ledger", id="ledger", commit="Pin the payment client to 4.2"),
    repo("mobile-app", id="mobile", commit="Fix the login redirect after a session expires"),
    repo("notifications", id="notif", commit="Batch push notifications by user"),
    repo("payments-sdk", id="sdk", commit="Release 4.2.1"),
    repo("search", id="search", commit="Index the new product fields",
         agent=agent("finished", "Indexed the new product fields", "Codex finished: Indexed the new product fields")),
    repo("status-page", id="status", commit="Add a health check for the queue"),
    repo("web", id="web", commit="Move the rate limiter into its own package"),
]
REPO_COUNT = sum(1 for r in ROWS if r["kind"] == "repo")


def status(row):
    """What the second line says, most urgent first: an agent that waits,
    then a worktree stuck partway, then an agent at work or finished."""
    a, roga = row.get("agent"), row.get("roga")
    if a and a["state"] == "waiting":
        return a, None
    if roga:
        return None, roga
    if a:
        return a, None
    return None, None


# ---------------------------------------------------------------- rows


def row_html(row, layout, markmode="lead"):
    """One row. layout is today, every or needed; markmode is lead (the mark
    starts the second line) or right (it stays before the count)."""
    a, roga = status(row)
    has_status = bool(a or roga)
    if layout == "today":
        two = False
    elif layout == "every":
        two = True
    else:
        two = has_status
    lead = two and markmode == "lead"

    cls = ["r"]
    if row["kind"] != "repo":
        cls.append(row["kind"])
    if two:
        cls.append("two")
    if row.get("on"):
        cls.append("on")
    if row.get("dim"):
        cls.append("dim")

    out = [f'<div class="{" ".join(cls)}">']
    if row["kind"] in ("wt", "hid"):
        out.append(f'<span class="cn{" last" if row.get("last") else ""}"></span>')
    out.append('<span class="tx"><span class="l1">')
    out.append(f'<span class="nm">{html.escape(row["n"])}</span>')
    if row.get("chev"):
        out.append(icon(row["chev"], "cv"))
    if row.get("detail"):
        out.append(f'<span class="dt">{html.escape(row["detail"])}</span>')
    out.append("</span>")
    if two:
        if a:
            tone = " warn" if a["state"] == "waiting" else ""
            words = a["words"] if markmode == "lead" else a["named"]
            out.append(f'<span class="l2{tone}">')
            if lead:
                out.append(MARK[a["state"]])
            out.append(f'<span class="w">{html.escape(words)}</span>')
            if a.get("time"):
                out.append(f'<span class="tm">· {html.escape(a["time"])}</span>')
            out.append("</span>")
        elif roga:
            tone = " " + roga["tone"] if roga.get("tone") else ""
            out.append(f'<span class="l2{tone}"><span class="w">{html.escape(roga["words"])}</span>'
                       f'<span class="tm">{html.escape(roga["tm"])}</span></span>')
        else:
            out.append(f'<span class="l2"><span class="w">{html.escape(row.get("commit", ""))}</span></span>')
    out.append("</span>")

    out.append('<span class="trail">')
    if a and not lead:
        out.append(MARK[a["state"]])
    if row.get("say"):
        out.append(f'<span class="say">{html.escape(row["say"])}</span>')
    elif row.get("count"):
        c = "cnt red" if row.get("conf") else "cnt"
        tri = icon("tri") if row.get("conf") else ""
        out.append(f'<span class="{c}">{tri}{row["count"]}</span>')
    out.append("</span></div>")
    return "".join(out)


def rail_html():
    items = [
        ('<span class="tile">' + icon("inbox") + "</span>"),
        '<span class="tile on">AC</span>',
        '<span class="tile mo">GL</span>',
        '<span class="tile mo">NO</span>',
        '<span class="tile mo">TM</span>',
        ('<span class="tile">' + icon("dots") + "</span>"),
    ]
    return ('<div class="rail"><div class="items">'
            + "".join(f'<span class="it">{t}</span>' for t in items)
            + '</div><div class="addw"><span class="it"><span class="tile">' + icon("plus")
            + "</span></span></div></div>")


def sidebar_html(layout, markmode="lead", rows=ROWS):
    body = "".join(row_html(r, layout, markmode) for r in rows)
    return ('<div class="sb"><div class="tb"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i>'
            '<i style="background:#28c840"></i></div><div class="body">' + rail_html()
            + '<div class="vr"></div><div class="lst"><div class="hd"><b>acme</b>'
            + f"<span>{REPO_COUNT}</span></div>"
            + f'<div class="rows">{body}</div></div></div></div>')


def list_height(layout, markmode="lead"):
    h = 0
    for r in ROWS:
        a, roga = status(r)
        two = layout == "every" or (layout == "needed" and (a or roga))
        h += ROW2_H if two else ROW_H
    return h + ROW_GAP * (len(ROWS) - 1)


LIST_ROOM = SIDEBAR_H - TOOLBAR_H - HEADER_H

# ---------------------------------------------------------------- files


def page(title, body, w, h, script=None, props=None):
    p = {"$preview": {"width": w, "height": h}}
    if props:
        p.update(props)
    data = json.dumps(p, ensure_ascii=False).replace("&", "&amp;").replace("'", "&#39;")
    js = script or "class Component extends DCLogic {\n  renderVals() {\n    return {};\n  }\n}"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{html.escape(title)}</title>
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
<script type="text/x-dc" data-dc-script data-props='{data}'>
{js}
</script>
</body>
</html>
"""


SIZES = {}


def write(name, title, body, w, h, script=None, props=None):
    (PROJECT / name).write_text(page(title, body, w, h, script, props))
    SIZES[name] = (w, h)


def two_up(caption_l, caption_d, layout, markmode="lead", extra_l=""):
    w = 30 + SIDEBAR_W + 40 + SIDEBAR_W + 30
    h = 30 + 44 + SIDEBAR_H + 30
    cols = []
    for theme, cap, extra in (("th-l", caption_l, extra_l), ("th-d", caption_d, "")):
        cols.append(f'<div class="col {theme}" style="width:{SIDEBAR_W}px"><div class="cap">{cap}</div>'
                    f"{sidebar_html(layout, markmode)}{extra}</div>")
    return f'<div class="board" style="width:{w}px;height:{h}px;">{"".join(cols)}</div>', w, h


# Today, with the tooltip open on agent/fix-login.
fix_index = next(i for i, r in enumerate(ROWS) if r["id"] == "fix")
fix_top = 44 + TOOLBAR_H + HEADER_H + fix_index * (ROW_H + ROW_GAP)
tip = (f'<div class="tip" style="left:96px;top:{fix_top + 30}px">Claude Code is working: Run the test suite, for 6 minutes</div>'
       f'<svg class="ptr" style="left:236px;top:{fix_top + 12}px" viewBox="0 0 12 18" aria-hidden="true">'
       '<path d="M1 1v14l3.6-3.4 2.6 5.6 2.2-1-2.6-5.4H12z" fill="#000" stroke="#fff" stroke-width="1"></path></svg>')
body, w, h = two_up("Today<i>The mark, and what the agent's doing in its tooltip</i>",
                    "Today, dark<i>The same rows</i>", "today", extra_l=tip)
write("SL-Today.dc.html", "Today's sidebar rows", body, w, h)

body, w, h = two_up("A · Two lines on every row<i>Quiet rows show their latest commit</i>",
                    "A, dark<i>The list runs past the window</i>", "every")
write("SL-A-Every.dc.html", "Two lines on every row", body, w, h)

body, w, h = two_up("B · A second line when there's something to say<i>The mark starts the line</i>",
                    "B, dark<i>Quiet rows stay one line</i>", "needed")
write("SL-B-WhenNeeded.dc.html", "A second line when needed", body, w, h)

body, w, h = two_up("B2 · The same, with the mark where it is today<i>The line has to name the agent</i>",
                    "B2, dark<i>Marks stay in one column</i>", "needed", "right")
write("SL-B2-MarkRight.dc.html", "A second line with the mark at the right", body, w, h)

# ---------------------------------------------------------------- states

STATES = [
    ("Working", "The agent's line, and from a minute on, for how long",
     wt("agent/fix-login", count=3, last=True, agent=agent("working", "Run the test suite", "", "6 min"))),
    ("In its first minute", "No time yet, as in the tooltip",
     wt("agent/fix-login", count=3, last=True, agent=agent("working", "Editing LoginView.swift", ""))),
    ("Before it has said anything", "The agent's name, which is all there is",
     wt("agent/fix-login", last=True, agent=agent("working", "Claude Code is working", "", "2 min"))),
    ("Waiting for you to allow something", "Amber, like the mark",
     wt("agent/rate-limits", count=1, last=True, agent=agent("waiting", "Needs your OK: git push", "", "2 min"))),
    ("Waiting for an answer", "",
     wt("agent/rate-limits", count=1, last=True, agent=agent("waiting", "Wants a plan approved", "", "4 min"))),
    ("Finished, not seen yet", "The reply's first line, until you select the row",
     wt("tm/retry-webhooks", last=True, agent=agent("finished", "Added retries with backoff to the webhook client", ""))),
    ("Two agents in one worktree", "",
     wt("agent/fix-login", count=3, last=True, agent=agent("working", "2 agents working", "", "6 min"))),
    ("Two agents, one waiting", "With two, the line names the one it's about",
     wt("agent/fix-login", count=3, last=True, agent=agent("waiting", "Codex needs your OK: git push", "", "1 min"))),
    ("Too long for the row", "The agent's words are cut short, and the time stays",
     wt("agent/dashboard", last=True, agent=agent("working", "Subagent: Review the dashboard's empty states and loading spinners", "", "12 min"))),
    ("Stuck partway, with conflicts", "Roga's own line, with no mark",
     repo("infra", detail="release/2.3", count=2, conf=True, roga={"words": "Rebasing release/2.3", "tm": "· 2 conflicts", "tone": "red"})),
    ("Stuck partway, ready to continue", "",
     repo("infra", detail="release/2.3", roga={"words": "Rebasing release/2.3", "tm": "· ready to continue", "tone": ""})),
    ("An agent waits during a rebase", "The agent wins, and the red count still says conflicts",
     repo("infra", detail="release/2.3", count=2, conf=True, agent=agent("waiting", "Wants a plan approved", "", "1 min"),
          roga={"words": "Rebasing release/2.3", "tm": "· 2 conflicts", "tone": "red"})),
    ("A repository's row", "It's the main worktree, so it says the same",
     repo("billing", chev="right", agent=agent("working", "Editing InvoiceView.swift", "", "3 min"))),
    ("Worktrees a collapsed repository hides", "The most urgent of theirs, with its branch",
     {"kind": "hid", "n": "2 worktrees", "count": 2, "last": True,
      "agent": agent("waiting", "agent/tax-rules needs your OK", "", "2 min")}),
    ("Selected", "The fill covers both lines",
     wt("agent/fix-login", count=3, on=True, last=True, agent=agent("working", "Run the test suite", "", "6 min"))),
    ("What stays on the first line", "Deleting… and Folder missing, as today",
     wt("agent/old-spike", say="Folder missing", dim=True, last=True)),
]

STATE_CSS_EXTRA = """
.st{display:grid;grid-template-columns:230px 256px 256px;column-gap:24px;row-gap:10px;align-items:center}
.sh{font-size:13px;font-weight:500;color:#5c5c58}
.lab{font-size:13px;font-weight:500;color:#1f1f1e}
.lab i{display:block;font-style:normal;font-weight:400;color:#5c5c58}
.strip{background:var(--nav);border-radius:10px;padding:6px 0;box-shadow:0 0 0 .5px rgba(0,0,0,.14)}
"""

cells = ['<span class="sh">What\'s going on</span><span class="sh">Light</span><span class="sh">Dark</span>']
for label, sub, row in STATES:
    lab = f'<div class="lab">{html.escape(label)}' + (f"<i>{html.escape(sub)}</i>" if sub else "") + "</div>"
    strips = "".join(f'<div class="strip {t}"><div class="rows">{row_html(row, "needed")}</div></div>' for t in ("th-l", "th-d"))
    cells.append(lab + strips)
state_rows = len(STATES)
sw = 30 + 230 + 24 + 256 + 24 + 256 + 30
sh = 30 + 20 + 10 + state_rows * (60 + 10) + 30
body = (f'<div class="board" style="width:{sw}px;height:{sh}px;display:block">'
        f'<div class="st">{"".join(cells)}</div></div>')
CSS_BASE = CSS
CSS = CSS_BASE + STATE_CSS_EXTRA
write("SL-States.dc.html", "What the second line says", body, sw, sh)
CSS = CSS_BASE

# ---------------------------------------------------------------- try it

TRY_CSS_EXTRA = """
.sheet{background:#f7f7f5;color:#1f1f1e;font:13px/1.35 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border:1px solid #e2e2e0;border-radius:12px;overflow:hidden;display:flex;flex-direction:column;gap:16px}
.bar{display:flex;flex-wrap:wrap;gap:12px 22px;align-items:center}
.grp{display:flex;align-items:center;gap:8px;font-size:12.5px;color:#5c5c58}
.seg{display:flex;background:#ecebe8;border-radius:8px;padding:2px;gap:2px}
.seg.off{opacity:.45}
.sg{border:0;background:none;font:inherit;font-size:12.5px;color:#5c5c58;height:26px;padding:0 10px;border-radius:6px;cursor:pointer}
.sg.on{background:#fff;color:#1f1f1e;font-weight:500;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.main{display:flex;gap:28px;align-items:flex-start}
.side{display:flex;flex-direction:column;gap:14px;width:360px}
.meta{font-size:12.5px;color:#5c5c58}
.meta b{color:#1f1f1e;font-weight:600}
.log{display:flex;flex-direction:column;gap:6px;margin:0;padding:0;list-style:none}
.log li{font-size:12.5px;color:#3c3c3a;line-height:1.35}
.log li i{font-style:normal;color:#8a8a85;margin-right:6px;font-variant-numeric:tabular-nums}
.log li.new{color:#1f1f1e;font-weight:500}
.rows .r{cursor:pointer}
.rows .r:hover{background:var(--hov)}
.rows .r.on:hover{background:var(--sel)}
"""

TRY_ROWS = []
for r in ROWS:
    t = {k: r.get(k) for k in ("id", "kind", "n", "detail", "chev", "count", "conf", "last", "commit")}
    t["roga"] = r.get("roga")
    TRY_ROWS.append(t)

INITIAL = {
    "fix": ["working", "Claude Code", "Run the test suite", -6],
    "rate": ["allow", "Codex", "git push", -2],
    "retry": ["finished", "Claude Code", "Added retries with backoff to the webhook client", -20],
    "billing": ["working", "Claude Code", "Editing InvoiceView.swift", -3],
    "search": ["finished", "Codex", "Indexed the new product fields", -14],
}

# Each event is [row id, phase, agent, line]. Phases: working, allow (waiting
# to be allowed), ask (waiting for an answer), finished, quit.
EVENTS = [
    ["docs", "working", "Claude Code", "Reading setup.md"],
    ["fix", "working", "Claude Code", "Editing LoginView.swift"],
    ["rate", "working", "Codex", "git push"],
    ["docs", "working", "Claude Code", "Editing setup.md"],
    ["billing", "ask", "Claude Code", "Wants a plan approved"],
    ["dash", "working", "Codex", "Searching the code"],
    ["rate", "finished", "Codex", "Pushed agent/rate-limits"],
    ["fix", "allow", "Claude Code", "git push"],
    ["billing", "working", "Claude Code", "Editing InvoiceView.swift"],
    ["docs", "finished", "Claude Code", "Rewrote the setup guide for macOS 26"],
    ["dash", "working", "Codex", "Subagent: Review the dashboard's empty states and loading spinners"],
    ["fix", "working", "Claude Code", "git push"],
    ["retry", "quit", "Claude Code", ""],
    ["rate", "working", "Codex", "Run the linters"],
    ["fix", "working", "Claude Code", "Run the test suite"],
    ["dash", "finished", "Codex", "Reviewed the empty states and fixed two"],
    ["docs", "quit", "Claude Code", ""],
    ["rate", "allow", "Codex", "git push"],
    ["dash", "quit", "Codex", ""],
    ["billing", "working", "Claude Code", "Run the invoice tests"],
    ["search", "quit", "Codex", ""],
    ["retry", "working", "Claude Code", "Reading WebhookClient.swift"],
    ["retry", "finished", "Claude Code", "Added retries with backoff to the webhook client"],
    ["search", "working", "Codex", "Editing ProductIndex.swift"],
    ["search", "finished", "Codex", "Indexed the new product fields"],
]

TRY_JS = r"""
const ROWS = __ROWS__;
const INITIAL = __INITIAL__;
const EVENTS = __EVENTS__;
const TICK_MS = 2200;

const copyAgents = () => {
  const out = {};
  for (const id in INITIAL) {
    const [phase, who, line, since] = INITIAL[id];
    out[id] = { phase, who, line, since };
  }
  return out;
};

const minutes = (now, since) => Math.max(0, now - since);

// What the second line says for an agent: [state, words, named words, time].
function agentLine(a, now) {
  const m = minutes(now, a.since);
  const time = a.phase === "finished" || m < 1 ? "" : "· " + m + " min";
  if (a.phase === "working") return ["working", a.line || a.who + " is working", a.who + ": " + (a.line || "working"), time];
  if (a.phase === "allow") return ["waiting", "Needs your OK: " + a.line, a.who + " needs your OK: " + a.line, time];
  if (a.phase === "ask") return ["waiting", a.line, a.who + ": " + a.line, time];
  return ["finished", a.line, a.who + " finished: " + a.line, ""];
}

function tooltip(a, now) {
  const m = minutes(now, a.since);
  const forHow = a.phase === "finished" || m < 1 ? "" : ", for " + m + (m === 1 ? " minute" : " minutes");
  if (a.phase === "working") return a.who + " is working" + (a.line ? ": " + a.line : "") + forHow;
  if (a.phase === "allow") return a.who + " is waiting for you to allow: " + a.line + forHow;
  if (a.phase === "ask") return a.who + " is waiting for you: " + a.line + forHow;
  return a.who + " finished: " + a.line;
}

function logLine(row, ev) {
  const [, phase, who, line] = ev;
  const name = row.n;
  if (phase === "working") return name + " · " + who + ": " + line;
  if (phase === "allow") return name + " · " + who + " asks to run " + line;
  if (phase === "ask") return name + " · " + who + ": " + line;
  if (phase === "finished") return name + " · " + who + " finished: " + line;
  return name + " · " + who + " quit";
}

class Component extends DCLogic {
  constructor(props) {
    super(props);
    this.state = { layout: "needed", mark: "lead", look: "light", running: true, now: 0, step: 0, sel: "fix", agents: copyAgents(), log: [] };
    this.timer = null;
  }
  componentDidMount() { this.timer = setInterval(() => { if (this.state.running) this.advance(); }, TICK_MS); }
  componentWillUnmount() { clearInterval(this.timer); }

  advance() {
    const s = this.state;
    const ev = EVENTS[s.step % EVENTS.length];
    const [id, phase, who, line] = ev;
    const now = s.now + 1;
    const agents = Object.assign({}, s.agents);
    const before = agents[id];
    if (phase === "quit") {
      delete agents[id];
    } else if (phase === "finished" && id === s.sel) {
      // The worktree on screen saw it finish, so there's nothing to point at.
      delete agents[id];
    } else {
      const same = before && before.phase === phase;
      agents[id] = { phase, who, line, since: same ? before.since : now };
    }
    const row = ROWS.find((r) => r.id === id);
    const log = [{ t: now, text: logLine(row, ev) }].concat(s.log).slice(0, 7);
    this.setState({ now, step: s.step + 1, agents, log });
  }

  select(id) {
    const agents = Object.assign({}, this.state.agents);
    if (agents[id] && agents[id].phase === "finished") delete agents[id];
    this.setState({ sel: id, agents });
  }

  rowVals(r) {
    const s = this.state;
    const a = s.agents[r.id];
    const ag = a ? agentLine(a, s.now) : null;
    // Most urgent first: a waiting agent, a worktree stuck partway, then
    // an agent at work or finished.
    let kind = null;
    if (ag && ag[0] === "waiting") kind = "agent";
    else if (r.roga) kind = "roga";
    else if (ag) kind = "agent";
    const two = s.layout === "every" || (s.layout === "needed" && kind !== null);
    const lead = two && s.mark === "lead";
    const state = kind === "agent" ? ag[0] : "";
    const on = r.id === s.sel;
    let words = "", time = "", l2 = "l2";
    if (kind === "agent") {
      words = lead ? ag[1] : ag[2];
      time = ag[3];
      if (state === "waiting") l2 += " warn";
    } else if (kind === "roga") {
      words = r.roga.words; time = r.roga.tm;
      if (r.roga.tone) l2 += " " + r.roga.tone;
    } else {
      words = r.commit || "";
    }
    const right = !!ag && !lead;
    const leadMark = lead && kind === "agent";
    return {
      cls: "r" + (r.kind !== "repo" ? " " + r.kind : "") + (two ? " two" : "") + (on ? " on" : ""),
      n: r.n, hasDetail: !!r.detail, detail: r.detail || "",
      down: r.chev === "down", right: r.chev === "right",
      tree: r.kind !== "repo", treeCls: "cn" + (r.last ? " last" : ""),
      two, l2, words, hasTime: !!time, time,
      lr: leadMark && state === "working", lw: leadMark && state === "waiting", lf: leadMark && state === "finished",
      rr: right && ag[0] === "working", rw: right && ag[0] === "waiting", rf: right && ag[0] === "finished",
      hasCount: !!r.count, count: r.count ? String(r.count) : "", cntCls: r.conf ? "cnt red" : "cnt", conf: !!r.conf,
      tip: a ? tooltip(a, s.now) : r.n,
      pick: () => this.select(r.id),
    };
  }

  renderVals() {
    const s = this.state;
    const group = (name, key, options, off) => ({
      name,
      segCls: "seg" + (off ? " off" : ""),
      btns: options.map(([v, t]) => ({ t, cls: "sg" + (s[key] === v ? " on" : ""), pressed: s[key] === v ? "true" : "false", pick: () => this.setState({ [key]: v }) })),
    });
    const rows = ROWS.map((r) => this.rowVals(r));
    const twoCount = rows.filter((r) => r.two).length;
    const height = rows.reduce((h, r) => h + (r.two ? 48 : 32), 0) + 2 * (rows.length - 1);
    return {
      groups: [
        group("Rows", "layout", [["today", "Today"], ["every", "A · Every row"], ["needed", "B · When needed"]]),
        group("Mark", "mark", [["lead", "Starts the line"], ["right", "At the right"]], s.layout === "today"),
        group("Look", "look", [["light", "Light"], ["dark", "Dark"]]),
      ],
      runLabel: s.running ? "Pause" : "Play",
      toggleRun: () => this.setState({ running: !s.running }),
      stepOnce: () => this.advance(),
      reset: () => this.setState({ now: 0, step: 0, sel: "fix", agents: copyAgents(), log: [] }),
      colCls: "col " + (s.look === "dark" ? "th-d" : "th-l"),
      rows,
      twoCount: String(twoCount),
      height: String(height),
      room: "776",
      overflows: height > 776,
      fits: height <= 776,
      log: s.log.map((l, i) => ({ t: "min " + l.t, text: l.text, cls: i === 0 ? "new" : "" })),
      hasLog: s.log.length > 0,
      noLog: s.log.length === 0,
    };
  }
}
"""

TRY_JS = (TRY_JS.replace("__ROWS__", json.dumps(TRY_ROWS))
          .replace("__INITIAL__", json.dumps(INITIAL))
          .replace("__EVENTS__", json.dumps(EVENTS)))

MARKS_TPL = {
    "r": RING, "w": WAIT, "f": FIN,
}


def mark_ifs(prefix):
    return "".join(
        f'<sc-if value="{{{{r.{prefix}{k}}}}}" hint-placeholder-val="{{{{false}}}}">{v}</sc-if>'
        for k, v in MARKS_TPL.items())


ROW_TPL = (
    '<button class="{{r.cls}}" type="button" title="{{r.tip}}" onClick="{{r.pick}}">'
    '<sc-if value="{{r.tree}}" hint-placeholder-val="{{false}}"><span class="{{r.treeCls}}"></span></sc-if>'
    '<span class="tx"><span class="l1"><span class="nm">{{r.n}}</span>'
    '<sc-if value="{{r.down}}" hint-placeholder-val="{{false}}">' + icon("down", "cv") + '</sc-if>'
    '<sc-if value="{{r.right}}" hint-placeholder-val="{{false}}">' + icon("right", "cv") + '</sc-if>'
    '<sc-if value="{{r.hasDetail}}" hint-placeholder-val="{{false}}"><span class="dt">{{r.detail}}</span></sc-if>'
    '</span>'
    '<sc-if value="{{r.two}}" hint-placeholder-val="{{false}}"><span class="{{r.l2}}">' + mark_ifs("l")
    + '<span class="w">{{r.words}}</span>'
    '<sc-if value="{{r.hasTime}}" hint-placeholder-val="{{false}}"><span class="tm">{{r.time}}</span></sc-if>'
    '</span></sc-if></span>'
    '<span class="trail">' + mark_ifs("r")
    + '<sc-if value="{{r.hasCount}}" hint-placeholder-val="{{false}}"><span class="{{r.cntCls}}">'
    '<sc-if value="{{r.conf}}" hint-placeholder-val="{{false}}">' + icon("tri") + '</sc-if>{{r.count}}</span></sc-if>'
    '</span></button>'
)

try_sidebar = ('<div class="sb"><div class="tb"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i>'
               '<i style="background:#28c840"></i></div><div class="body">' + rail_html()
               + '<div class="vr"></div><div class="lst"><div class="hd"><b>acme</b>'
               + f"<span>{REPO_COUNT}</span></div>"
               + '<div class="rows"><sc-for list="{{rows}}" as="r" hint-placeholder-count="17">' + ROW_TPL
               + "</sc-for></div></div></div></div>")

tw = 28 + SIDEBAR_W + 28 + 360 + 28
th = 28 + 30 + 16 + SIDEBAR_H + 28
try_body = (
    f'<div class="sheet" style="width:{tw}px;height:{th}px;padding:28px">'
    '<div class="bar"><sc-for list="{{groups}}" as="gp" hint-placeholder-count="3"><div class="grp"><span>{{gp.name}}</span>'
    '<div class="{{gp.segCls}}"><sc-for list="{{gp.btns}}" as="b" hint-placeholder-count="3">'
    '<button class="{{b.cls}}" type="button" aria-pressed="{{b.pressed}}" onClick="{{b.pick}}">{{b.t}}</button>'
    '</sc-for></div></div></sc-for></div>'
    '<div class="main"><div class="{{colCls}}" style="width:312px">' + try_sidebar + '</div>'
    '<div class="side">'
    '<div class="grp"><span>Agents</span><div class="seg">'
    '<button class="sg on" type="button" onClick="{{toggleRun}}">{{runLabel}}</button>'
    '<button class="sg" type="button" onClick="{{stepOnce}}">Next event</button>'
    '<button class="sg" type="button" onClick="{{reset}}">Start over</button></div></div>'
    '<div class="meta"><b>{{twoCount}}</b> rows have a second line. The list needs <b>{{height}}</b> of the <b>{{room}}</b> points an 860-point window has for it'
    '<sc-if value="{{overflows}}" hint-placeholder-val="{{false}}">, so its end scrolls away</sc-if>'
    '<sc-if value="{{fits}}" hint-placeholder-val="{{true}}">, so all of it fits</sc-if>.</div>'
    '<div class="meta">What just happened, newest first</div>'
    '<ul class="log"><sc-if value="{{noLog}}" hint-placeholder-val="{{true}}"><li>Nothing yet. An event comes every two seconds.</li></sc-if>'
    '<sc-for list="{{log}}" as="l" hint-placeholder-count="5"><li class="{{l.cls}}"><i>{{l.t}}</i>{{l.text}}</li></sc-for></ul>'
    '<div class="meta">Hover a row with a mark for its tooltip. Clicking a row selects it, which is what clears a finished agent\'s dot, and in B its line too.</div>'
    '</div></div></div>'
)
CSS = CSS_BASE + TRY_CSS_EXTRA
write("SL-Try.dc.html", "Try the second line", try_body, tw, th, script=TRY_JS)
CSS = CSS_BASE

# ---------------------------------------------------------------- report

print("list room", LIST_ROOM)
for layout in ("today", "every", "needed"):
    print(layout, list_height(layout))
for name, (w, h) in SIZES.items():
    print(f"{name}: {w}x{h}")
