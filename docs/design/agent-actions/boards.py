"""Boards for the canvas's "Agent actions" page: ways to mark a command that a
locally running agent carries out, in place of the sparkles.

Writes project/Ag-*.dc.html under the folder given as the first argument and
prints each board's size.
"""

import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "out")
PROJECT = ROOT / "project"
PROJECT.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------- styles

CSS = """
body{margin:0}
*{box-sizing:border-box}
.th-l{--page:#deded9;--wint:#1f1f1e;--wint2:#5c5c58;--sheet:#fff;--bg:#fff;--surface:#fafaf9;--tx:#1c1c1a;--tx2:#696964;--card:#f2f2f0;--line:#d6d6d3;--sep:#e2e2df;--sec:#efefed;--ink:#1a1a18;--onink:#fff;--act:#c94402;--actf:#c94402;--term:#272822;--dng:#cd1755;--fin:#2f6de1;--track:#d6d6d3;--hov:rgba(0,0,0,.05);--sa:#2559b0;--sab:#e9f0fb;--sb:#7136b8;--sbb:#f4edfb;--flt:#fff;--sel:rgba(0,0,0,.11);--sh:0 18px 50px rgba(0,0,0,.2),0 0 0 .5px rgba(0,0,0,.14);--edge:rgba(201,68,2,.42);--edgeh:rgba(201,68,2,.85);--tint:rgba(201,68,2,.09);--gl:#e8590c;--glow:rgba(232,89,12,.45)}
.th-d{--page:#141413;--wint:#ececea;--wint2:#b3b3ae;--sheet:#2a2a29;--bg:#222;--surface:#252524;--tx:#ececea;--tx2:#a9a9a3;--card:#353534;--line:#4a4a47;--sep:#3f3f3d;--sec:#3b3b3a;--ink:#ececea;--onink:#16150e;--act:#f0813f;--actf:#c94402;--term:#1a1b17;--dng:#fc5884;--fin:#2f6de1;--track:#4a4a47;--hov:rgba(255,255,255,.06);--sa:#8fb4f7;--sab:#1c2536;--sb:#c4a2ff;--sbb:#2a2136;--flt:#2c2c2b;--sel:rgba(255,255,255,.12);--sh:0 18px 50px rgba(0,0,0,.55),0 0 0 .5px rgba(255,255,255,.12);--edge:rgba(240,129,63,.45);--edgeh:rgba(240,129,63,.9);--tint:rgba(240,129,63,.13);--gl:#ffb27d;--glow:rgba(255,160,100,.6)}
.bd{display:flex;font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.bd.st{flex-direction:column}
.th{flex:1 1 0;min-width:0;padding:30px 36px;background:var(--page);color:var(--wint)}
.tt{font-size:14px;font-weight:600;margin:0 0 14px}
.tt i{font-style:normal;font-weight:400;color:var(--wint2)}
.ch-h{font-size:12px;color:var(--wint2);align-self:end}
.lab b{display:block;font-size:13px;font-weight:600}
.lab i{display:block;font-style:normal;font-size:12px;line-height:1.3;color:var(--wint2);margin-top:1px}
.lab{align-self:center}
.rw{display:contents}
.cg{display:grid;grid-template-columns:190px 250px 340px 290px;gap:10px 14px}
.sg{display:grid;grid-template-columns:170px repeat(5,190px);gap:10px 12px}
.ic{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:1.75;stroke-linecap:round;stroke-linejoin:round;display:block;flex:none}
.ic.xs{width:11px;height:11px;stroke-width:2.6}
.ic.s{width:13px;height:13px;stroke-width:2}
.ref{font:12px ui-monospace,"SF Mono",Menlo,monospace;white-space:nowrap;font-variant-ligatures:none}

.pn{border-radius:10px;min-width:0;align-self:center}
.pn.b{background:var(--surface);padding:6px;box-shadow:0 0 0 .5px rgba(0,0,0,.08)}
.pn.h{display:flex;align-items:center;gap:4px;height:40px;padding:0 10px;background:var(--bg);box-shadow:0 0 0 .5px rgba(0,0,0,.1);color:var(--tx)}
.pn.h .ref{flex:1 1 0;min-width:0;overflow:hidden;text-overflow:ellipsis}
.pn.d{display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:12px 14px;background:var(--sheet);color:var(--tx);box-shadow:0 0 0 .5px rgba(0,0,0,.1)}
.pn.s{display:flex;align-items:center;justify-content:center;height:60px;background:var(--surface);color:var(--tx);box-shadow:0 0 0 .5px rgba(0,0,0,.08)}
.dots{width:24px;height:24px;display:grid;place-items:center;color:var(--tx2);flex:none}
.pl{height:24px;padding:0 8px;border-radius:6px;border:0;box-shadow:inset 0 0 0 1px var(--sep);background:none;color:var(--tx);font:inherit;font-size:12px;white-space:nowrap;flex:none;cursor:default}

.ab{position:relative;display:inline-flex;height:24px;border-radius:7px;font-size:12px;font-weight:500;line-height:1;color:var(--tx);background:var(--card);flex:none;vertical-align:top}
.ab::after{content:"";position:absolute;inset:0;border-radius:inherit;pointer-events:none;box-shadow:inset 0 0 0 1px var(--bd,transparent);transition:box-shadow .15s ease}
.ab.hdr{--bd:var(--sep);background:none;font-weight:400;border-radius:6px}
.ab.dlg{height:28px;border-radius:9px;background:var(--sec);font-size:13px}
.ab .in{display:inline-flex;align-items:stretch;border-radius:inherit;overflow:hidden;position:relative}
.ab button{border:0;background:none;color:inherit;font:inherit;display:inline-flex;align-items:center;gap:5px;padding:0 8px;cursor:default;white-space:nowrap}
.ab.dlg .m{padding:0 12px}
.ab .ch{padding:0 5px;color:var(--tx2);border-left:1px solid var(--line)}
.g{display:none;align-items:center;flex:none}
.g>*{display:none}
.ab .t{display:inline-block}
.rwo .w,.rwo .an{display:none}

.mk{position:relative;width:14px;height:14px;flex:none}
.mk svg{position:absolute;left:0;top:0;width:14px;height:14px;fill:none;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
.mk .trk{stroke:var(--track)}
.mk .arc{stroke:var(--act);animation:spin 1s linear infinite}
.mk .dt{fill:var(--act);stroke:none}
.mk .dot{position:absolute;left:3.5px;top:3.5px;width:7px;height:7px;border-radius:50%;background:var(--fin)}
.spn{width:12px;height:12px;border-radius:50%;border:1.5px solid var(--line);border-top-color:var(--tx2);animation:spin .9s linear infinite;flex:none}
@keyframes spin{to{transform:rotate(360deg)}}

.gl{display:none;position:absolute;inset:0;pointer-events:none}
.gl svg{position:absolute;inset:0;width:100%;height:100%;overflow:visible;display:block}
.gl rect{width:calc(100% - 1px);height:calc(100% - 1px);fill:none;stroke-linecap:round;opacity:0}
.gl .gt{stroke:var(--edgeh);stroke-width:1;stroke-dasharray:26 74}
.gl .gh{stroke:var(--gl);stroke-width:1.5;stroke-dasharray:9 91;filter:drop-shadow(0 0 2.5px var(--glow))}
@keyframes glt{from{stroke-dashoffset:0}to{stroke-dashoffset:-100}}
@keyframes glh{from{stroke-dashoffset:-17}to{stroke-dashoffset:-117}}
@keyframes glo{0%{opacity:0}12%{opacity:1}85%{opacity:1}100%{opacity:0}}
@keyframes gltl{0%{stroke-dashoffset:0}45%,100%{stroke-dashoffset:-100}}
@keyframes glhl{0%{stroke-dashoffset:-17}45%,100%{stroke-dashoffset:-117}}
@keyframes glol{0%{opacity:0}5%{opacity:1}38%{opacity:1}45%,100%{opacity:0}}
@keyframes br{50%{opacity:.5}}
@keyframes bl{50%{opacity:0}}
@keyframes brs{50%{box-shadow:0 0 0 1px var(--edge)}}

.o0 .ab .g,.oC .ab .g,.oD .ab .g{display:inline-flex}
.o0 .g-s{display:block;color:var(--act)}
.o0 .ab:hover,.o0 .ab.hv,.oC .ab:hover,.oC .ab.hv,.oD .ab:hover,.oD .ab.hv{box-shadow:0 0 0 1.5px var(--line)}
.o0 .iconly .t{display:none}

.oA .ab,.oB .ab{--bd:var(--edge)}
.oA .ab:hover,.oA .ab.hv,.oB .ab:hover,.oB .ab.hv{--bd:var(--edgeh)}
.oA .ab.run::after{animation:br 1.6s ease-in-out infinite;box-shadow:inset 0 0 0 1px var(--edgeh)}

.oB .gl{display:block}
.oB .ab:hover .gt{animation:glt 1.15s cubic-bezier(.45,.05,.4,.95) 1,glo 1.15s linear 1}
.oB .ab:hover .gh{animation:glh 1.15s cubic-bezier(.45,.05,.4,.95) 1,glo 1.15s linear 1}
.oB .ab.hv .gt{animation:gltl 2.6s cubic-bezier(.45,.05,.4,.95) infinite,glol 2.6s linear infinite}
.oB .ab.hv .gh{animation:glhl 2.6s cubic-bezier(.45,.05,.4,.95) infinite,glol 2.6s linear infinite}
.oB .run>.gl .gt{opacity:1;animation:glt 1.7s linear infinite}
.oB .run>.gl .gh{opacity:1;animation:glh 1.7s linear infinite}

.oC .g-m{display:block}
.mk .arc,.mk .trk{display:block}
.g-m .arc{display:none}
.run .g-m .arc{display:block}
.run .g-m .dt{display:none}

.oD .g-p{display:block;color:var(--act)}
.oD .an{font-family:ui-monospace,"SF Mono",Menlo,monospace;text-transform:lowercase;font-size:11.5px}
.oD .run .cur{animation:bl 1s steps(2) infinite}

.oE .ab .m{align-items:stretch;padding-right:0}
.oE .ab .t{display:inline-flex;align-items:center}
.oE .w{display:none}
.oE .rwo .an,.oE .an{display:inline-flex;align-items:center;align-self:stretch;margin:0 0 0 8px;padding:0 8px;background:var(--tint);color:var(--act);box-shadow:inset 1px 0 0 var(--edge)}
.oE .ab.dlg .m{padding-right:0}
.oE .ab .ch{background:var(--tint);color:var(--act);border-left:0}
.oE .ab.run{background:var(--tint)}
.oE .ab.run .in{animation:br 1.6s ease-in-out infinite}
.oE .ab.run .m{padding-right:8px}
.oE .ab.run .t{color:var(--act)}

.oF .ab{background:var(--tint);color:var(--act);--bd:transparent}
.oF .ab .ch{color:var(--act);border-left-color:var(--edge)}
.oF .ab:hover{background:color-mix(in srgb,var(--tint) 100%,var(--act) 12%)}
.oF .ab.run .in{animation:br 1.6s ease-in-out infinite}

.ab.dis{--edge:var(--sep);--edgeh:var(--sep);--tint:var(--card);--act:var(--tx2);color:var(--tx2)}
.ab.dis .gl{display:none}
.ab.dis:hover{box-shadow:none}
.nt{font-size:12px;color:var(--tx2);text-align:center;padding:0 10px;line-height:1.3}
.inl{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--tx2)}

.sf{display:grid;grid-template-columns:180px 490px 490px;gap:20px 24px}
.sl{align-self:start;padding-top:2px}
.sl b{display:block;font-size:13px;font-weight:600}
.sl i{display:block;font-style:normal;font-size:12px;line-height:1.35;color:var(--wint2);margin-top:2px}
.mb{background:var(--surface);color:var(--tx);border-radius:12px;padding:10px 12px 12px;box-shadow:0 0 0 .5px rgba(0,0,0,.08)}
.ed{position:relative;min-height:84px;border:1px solid var(--line);border-radius:10px;padding:9px 11px;background:var(--sheet);font-size:13px;line-height:1.45;transition:background .2s}
.ph{color:var(--tx2)}
.pos{position:absolute;right:6px;bottom:6px}
.bar{height:8px;border-radius:4px;background:var(--card);margin-top:6px}
.bar.t{margin-top:12px}
.nl{display:flex;align-items:center;gap:7px;padding:8px 2px 0;font-size:12px;color:var(--tx2)}
.nl .txt{flex:1 1 0;min-width:0}
.act{border:0;background:none;font:inherit;font-size:12px;font-weight:500;color:var(--act);padding:0;cursor:default;flex:none}
.sp-r,.dn-d{display:block}
.sp-t,.dn-s{display:none}
.o0 .sp-t{display:block}
.o0 .sp-r{display:none}
.o0 .dn-s{display:block;color:var(--act)}
.o0 .dn-d{display:none}
.oA .ed.run{box-shadow:0 0 0 1px var(--edgeh);animation:brs 1.6s ease-in-out infinite}
.oF .ed.run{background:color-mix(in srgb,var(--sheet) 92%,var(--act) 8%)}

.df{background:var(--bg);color:var(--tx);border-radius:12px;overflow:hidden;box-shadow:0 0 0 .5px rgba(0,0,0,.1)}
.dh{display:flex;align-items:center;gap:4px;height:40px;padding:0 10px;border-bottom:1px solid var(--sep)}
.dh .ref{flex:1 1 0;min-width:0;overflow:hidden;text-overflow:ellipsis}
.bn{display:flex;align-items:flex-start;gap:8px;padding:8px 12px;background:var(--hov);border-bottom:1px solid var(--sep);font-size:12px;line-height:1.4}
.bn .txt{flex:1 1 0;min-width:0}
.bn .pl{height:22px}
.bn .g2{display:grid;place-items:center;width:14px;height:17px;flex:none}
.cf{position:relative;margin:10px 12px 12px;border-radius:8px;box-shadow:0 0 0 1px var(--sep)}
.cf .cin{border-radius:inherit;overflow:hidden;font:12px/19px ui-monospace,"SF Mono",Menlo,monospace}
.cb{display:flex;align-items:center;height:26px;padding:0 10px;font:12px -apple-system,system-ui,sans-serif;color:var(--tx2);background:var(--card)}
.cs1{padding:2px 10px;background:var(--sab);color:var(--sa)}
.cs2{padding:2px 10px;background:var(--sbb);color:var(--sb)}

.dlg{position:relative;width:100%;background:var(--sheet);color:var(--tx);border-radius:18px;box-shadow:var(--sh);display:flex;flex-direction:column;overflow:hidden}
.top{padding:16px 18px 14px;display:flex;flex-direction:column;gap:10px}
.ti{margin:0;font-size:15px;font-weight:600;line-height:1.35}
.msg{margin:0}
.btns{display:flex;justify-content:flex-end;align-items:center;gap:8px;padding:0 18px 14px}
.bt{height:28px;padding:0 12px;border-radius:9px;border:0;font:inherit;font-weight:500;white-space:nowrap;background:var(--sec);color:var(--tx);cursor:default}
.bt.pri{background:var(--ink);color:var(--onink)}
.cmd{position:relative;background:var(--term);color:#f8f8f2;font:12px/1.55 ui-monospace,"SF Mono",Menlo,monospace;padding:11px 18px 13px;font-variant-ligatures:none}
.cmd .cm{color:#a59f85}
.cmd .fl{color:#e6db74}
.lin{display:none;position:absolute;left:0;right:0;top:0;height:1.5px;overflow:hidden}
.lin i{position:absolute;top:0;left:0;width:30%;height:100%;background:linear-gradient(90deg,transparent,var(--gl),transparent);animation:lin 1.7s ease-in-out infinite}
.oB .lin{display:block}
@keyframes lin{from{transform:translateX(-100%)}to{transform:translateX(420%)}}

.menu{width:250px;padding:6px;background:var(--flt);color:var(--tx);border:1px solid var(--sep);border-radius:10px;box-shadow:0 8px 28px rgba(0,0,0,.14)}
.mi{display:flex;align-items:center;height:28px;padding:0 10px;border-radius:6px;font-size:13px;white-space:nowrap}
.mi.on{background:var(--sel)}
.msp{height:1px;background:var(--sep);margin:4px 8px}
.sb{background:var(--surface);color:var(--tx);border-radius:10px;padding:6px;box-shadow:0 0 0 .5px rgba(0,0,0,.08)}
.sr{display:flex;align-items:flex-start;padding:7px 10px;border-radius:8px;font-size:14px}
.sr .tx{flex:1 1 0;min-width:0}
.sr .l2{font-size:13px;color:var(--tx2);margin-top:1px}

.try{width:1360px;height:760px;padding:26px 30px;background:var(--page);color:var(--wint);display:flex;flex-direction:column;gap:18px;font:13px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;border-radius:12px;overflow:hidden}
.tb2{display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.tb2 .sp{flex:1 1 0}
.pill{height:28px;padding:0 12px;border:0;border-radius:8px;background:var(--hov);color:var(--wint);font:inherit;font-size:12.5px;cursor:pointer}
.pill.on{background:var(--ink);color:var(--onink);font-weight:500}
.tcs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:22px;align-items:start}
.tcap{font-size:13px;font-weight:500;margin:0 0 9px}
.tcap i{font-style:normal;font-weight:400;color:var(--wint2)}
.ab button.lk{cursor:pointer}
.tip{font-size:12.5px;color:var(--wint2)}
"""

# ---------------------------------------------------------------- parts

SPARK = ('<svg class="ic s g-s" viewBox="0 0 24 24" aria-hidden="true"><path d="M9.94 15.5A2 2 0 0 0 8.5 14.06l-6.14-1.58a.5.5 0 0 1 0-.96L8.5 9.94A2 2 0 0 0 9.94 8.5l1.58-6.14a.5.5 0 0 1 .96 0l1.58 6.14a2 2 0 0 0 1.44 1.44l6.14 1.58a.5.5 0 0 1 0 .96l-6.14 1.58a2 2 0 0 0-1.44 1.44l-1.58 6.14a.5.5 0 0 1-.96 0z"></path><path d="M20 3v4M22 5h-4"></path></svg>')
MARK = ('<span class="mk g-m"><svg class="trk" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5"></circle></svg>'
        '<svg class="dt" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="2.3"></circle></svg>'
        '<svg class="arc" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5A5.5 5.5 0 0 1 13.5 8"></path></svg></span>')
PROMPT = ('<svg class="ic s g-p" viewBox="0 0 24 24" aria-hidden="true"><path class="cur" d="M12 19h8"></path><path d="m4 17 6-6-6-6"></path></svg>')
GLYPHS = f'<span class="g">{SPARK}{MARK}{PROMPT}</span>'
CHEV = '<svg class="ic xs" viewBox="0 0 24 24" aria-hidden="true"><path d="m6 9 6 6 6-6"></path></svg>'
DOTS = '<svg class="ic" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle><circle cx="5" cy="12" r="1"></circle></svg>'
RING = ('<span class="mk sp-r"><svg class="trk" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="5.5"></circle></svg>'
        '<svg class="arc" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5A5.5 5.5 0 0 1 13.5 8"></path></svg></span>')
SPIN = '<span class="spn sp-t"></span>'
WORKING = SPIN + RING
FIN = '<span class="mk dn-d"><i class="dot"></i></span>'
DONE = SPARK.replace('g-s', 'dn-s') + FIN


def glint(rx):
    return ('<span class="gl" aria-hidden="true"><svg>'
            f'<rect class="gt" x=".5" y=".5" rx="{rx}" pathLength="100"></rect>'
            f'<rect class="gh" x=".5" y=".5" rx="{rx}" pathLength="100"></rect>'
            '</svg></span>')


RX = {"box": 6.5, "hdr": 5.5, "dlg": 8.5}


def ab(ctx, verb="Generate", agent="Claude", chev=False, state="", label=None, on=None):
    """A button for an agent's command, with every option's parts in it. The
    option class on an ancestor picks which of them show."""
    if label:
        text = f'<span class="t">{label}</span>'
    else:
        text = f'<span class="t"><span class="v">{verb}</span><span class="w"> with </span><span class="an">{agent}</span></span>'
    handler = f' onClick="{{{{{on}}}}}"' if on else ""
    cursor = " lk" if on else ""
    ch = f'<button class="ch" type="button" aria-label="Choose an agent">{CHEV}</button>' if chev else ""
    return (f'<div class="ab {ctx} {state}"><div class="in"><button class="m{cursor}" type="button"{handler}>'
            f'{GLYPHS}{text}</button>{ch}</div>{glint(RX[ctx])}</div>')


OPTIONS = [
    ("o0", "Today", "Orange sparkles"),
    ("oA", "A · Hairline", "A thin orange line, and no icon"),
    ("oB", "B · Glint", "A’s line, with light that runs round it"),
    ("oC", "C · Standby mark", "The sidebar’s ring, lit from the middle"),
    ("oD", "D · Prompt", "A shell prompt, and the command’s own name"),
    ("oE", "E · Agent half", "The verb, then who does it, in a warm half"),
    ("oF", "F · Warm tint", "A soft wash of orange, and no line"),
]


def page(title, body, width, height, props='', script_body=None, head_const=""):
    props_json = '{' + (props + ',' if props else '') + f'"$preview":{{"width":{width},"height":{height}}}' + '}'
    body_js = script_body or "  renderVals() { return {}; }"
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
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
<script type="text/x-dc" data-dc-script data-props='{props_json}'>
{head_const}
class Component extends DCLogic {{
{body_js}
}}
</script>
</body>
</html>
"""


def write(name, content, width, height):
    (PROJECT / name).write_text(content)
    print(f"{name}: {width}x{height}")


# ---------------------------------------------------------------- compare


def compare_theme(th, name):
    rows = []
    for cls, title, desc in OPTIONS:
        box = ab("box", chev=True)
        hdr = ab("hdr", verb="Resolve")
        dlg = ab("dlg", verb="Fix")
        rows.append(
            f'<div class="rw {cls}">'
            f'<div class="lab"><b>{title}</b><i>{desc}</i></div>'
            f'<div class="pn b"><div class="ed" style="min-height:58px"><span class="ph">Message</span><div class="pos">{box}</div></div></div>'
            f'<div class="pn h"><span class="ref">LoginView.swift</span>{hdr}<span class="dots">{DOTS}</span><button class="pl" type="button">Mark Resolved</button></div>'
            f'<div class="pn d">{dlg}<button class="bt pri" type="button">OK</button></div>'
            '</div>'
        )
    return (f'<section class="th {th}"><p class="tt">{name} <i>· hover them, in Play</i></p><div class="cg">'
            '<span></span><span class="ch-h">In the message box</span><span class="ch-h">In the diff’s header</span><span class="ch-h">In a dialog</span>'
            + "".join(rows) + '</div></section>')


W, H = 2368, 720
write("Ag-Compare.dc.html", page("Agent actions · Compare", f'<div class="bd" style="width:{W}px;height:{H}px">{compare_theme("th-l", "Light")}{compare_theme("th-d", "Dark")}</div>', W, H), W, H)

# ---------------------------------------------------------------- states


def states_theme(th, name):
    rows = []
    for cls, title, desc in OPTIONS:
        rest = ab("box", chev=True)
        hover = ab("box", chev=True, state="hv")
        if cls == "o0":
            words = ab("box", chev=True, state="iconly")
            working = f'<span class="inl">{SPIN}Claude Code is writing… 3 s</span>'
        else:
            words = ab("box", chev=True, state="rwo", verb="Rewrite")
            working = ab("box", state="run", label="Claude is writing…")
        off = ab("box", chev=True, state="dis")
        rows.append(
            f'<div class="rw {cls}"><div class="lab"><b>{title}</b><i>{desc}</i></div>'
            f'<div class="pn s">{rest}</div><div class="pn s">{hover}</div><div class="pn s">{words}</div>'
            f'<div class="pn s">{working}</div><div class="pn s">{off}</div></div>'
        )
    return (f'<section class="th {th}"><p class="tt">{name} <i>· Hover repeats here so it can be seen. In the app it’s once each time the pointer arrives.</i></p><div class="sg">'
            '<span></span><span class="ch-h">At rest</span><span class="ch-h">Hover</span><span class="ch-h">With words in the box</span><span class="ch-h">While it works</span><span class="ch-h">Nothing staged</span>'
            + "".join(rows) + '</div></section>')


W, H = 1252, 1250
write("Ag-States.dc.html", page("Agent actions · States", f'<div class="bd st" style="width:{W}px;height:{H}px">{states_theme("th-l", "Light")}{states_theme("th-d", "Dark")}</div>', W, H), W, H)

# ---------------------------------------------------------------- surfaces

BARS = '<div style="width:78%" class="bar"></div><div style="width:92%" class="bar t"></div><div style="width:60%" class="bar"></div>'
TEXT = 'Retry the login when the session has expired'


def box(inner, btn="", below="", run=False):
    pos = f'<div class="pos">{btn}</div>' if btn else ""
    cls = "ed run" if run else "ed"
    gl = glint(9.5) if run else ""
    return f'<div class="mb"><div class="{cls}">{inner}{pos}{gl}</div>{below}</div>'


def note(mark, words, action):
    return f'<div class="nl">{mark}<span class="txt">{words}</span><button class="act" type="button">{action}</button></div>'


def header(btn):
    return f'<div class="df"><div class="dh"><span class="ref">LoginView.swift</span>{btn}<span class="dots">{DOTS}</span><button class="pl" type="button">Mark Resolved</button></div></div>'


def conflict(run=False):
    gl = glint(7.5) if run else ""
    cls = "cf run" if run else "cf"
    return (f'<div class="{cls}"><div class="cin"><div class="cb">Conflict 1 of 2</div>'
            '<div class="cs1">Button("Retry", action: retry)</div>'
            '<div class="cs2">Text(session.error).font(.caption)</div></div>'
            f'{gl}</div>')


def banner(mark, words, buttons):
    return f'<div class="bn"><span class="g2">{mark}</span><span class="txt">{words}</span>{buttons}</div>'


def resolving():
    return ('<div class="df">' + banner(WORKING, 'Claude is resolving 2 conflicts… 7 s', '<button class="pl" type="button">Stop</button>')
            + conflict(run=True) + '</div>')


def resolved():
    return ('<div class="df">' + banner(DONE, 'Claude resolved 2 conflicts in 9 s. Read them over before marking the file resolved.', '<button class="pl" type="button">Put Conflicts Back</button>') + '</div>')


def refused(btn):
    return (f'<div class="dlg"><div class="top"><h3 class="ti">The push was rejected</h3>'
            '<p class="msg"><span class="ref">main</span> has commits on <span class="ref">origin</span> that you don’t have yet.</p></div>'
            f'<div class="btns">{btn}<button class="bt pri" type="button">OK</button></div>'
            '<div class="cmd"><span class="cm">$</span> git push origin main</div></div>')


def asking():
    return ('<div class="dlg"><div class="top"><h3 class="ti">Asking Claude Code…</h3>'
            '<p class="msg">Roga is sending it what git said and what read-only commands show about this worktree. Nothing runs until you say so.</p></div>'
            '<div class="btns"><button class="bt" type="button">Stop</button></div>'
            '<div class="cmd"><span class="lin"><i></i></span><span class="cm">$</span> claude -p <span class="fl">--safe-mode</span> <span class="fl">--model</span> haiku</div></div>')


MENU = ('<div class="menu"><div class="mi on">Resolve with Claude Code</div><div class="msp"></div><div class="mi">Keep main’s Version</div><div class="mi">Keep origin/main’s Version</div></div>')
SIDEBAR = ('<div class="sb"><div class="sr"><div class="tx">agent/fix-login<div class="l2">Editing LoginView.swift · 2 min</div></div>' + RING + '</div>'
           '<div class="sr"><div class="tx">tm/retry-webhooks<div class="l2">Finished · 4 min</div></div><span class="mk"><i class="dot"></i></span></div></div>')


def surfaces(th, name):
    today_b = ab("box", chev=True)
    rows = [
        ("The message box", "Empty. It says what a click does and who does it.",
         box('<span class="ph">Message</span>', today_b),
         box('<span class="ph">Message</span>', today_b)),
        ("With words in the box", "Without an icon, it needs a word. It’s still narrower than Generate with Claude.",
         box(TEXT, ab("box", chev=True, state="iconly")),
         box(TEXT, ab("box", chev=True, state="rwo", verb="Rewrite"))),
        ("While it writes", "The line runs around what the agent is working on, rather than the button, which steps aside as it does today.",
         box(BARS, below=note(WORKING, "Claude Code is writing… 3 s", "Stop")),
         box(BARS, below=note(WORKING, "Claude Code is writing… 3 s", "Stop"), run=True)),
        ("Once it’s written", "The sidebar’s blue dot already means finished, and nobody has looked yet.",
         box(TEXT, below=note(DONE, "Claude Code · haiku wrote this in 4 s.", "Undo")),
         box(TEXT, below=note(DONE, "Claude Code · haiku wrote this in 4 s.", "Undo"))),
        ("A conflicted file", "Today’s gray outline is the same as every other button in this row.",
         header(ab("hdr", verb="Resolve")),
         header(ab("hdr", verb="Resolve"))),
        ("While it resolves", "Same idea: the line goes around the conflict it was handed.",
         resolving(), resolving()),
        ("Once it’s resolved", "Same dot as the commit box and the sidebar.",
         resolved(), resolved()),
        ("What git refused", "A secondary button still, beside OK.",
         refused(ab("dlg", verb="Fix")), refused(ab("dlg", verb="Fix"))),
        ("Asking the agent", "The command block already says what’s running. A line along its top says that it still is.",
         asking(), asking()),
    ]
    cells = "".join(
        f'<div class="sl"><b>{t}</b><i>{d}</i></div><div class="o0">{a}</div><div class="oB">{b}</div>'
        for t, d, a, b in rows
    )
    tail = (f'<div class="sl"><b>Left as they are</b><i>A menu’s rows can’t carry a line, and “with Claude Code” already says it. The sidebar is where the ring and the dot come from.</i></div>'
            f'<div>{MENU}</div><div class="oB">{SIDEBAR}</div>')
    return (f'<section class="th {th}"><p class="tt">{name}</p><div class="sf">'
            '<span></span><span class="ch-h">Today</span><span class="ch-h">With B</span>'
            + cells + tail + '</div></section>')


W, H = 1300, 1680
write("Ag-Surfaces.dc.html", page("Agent actions · Around the app", f'<div class="bd" style="width:{W}px;height:{H}px">{surfaces("th-l", "Light")}</div>', W, H), W, H)
write("Ag-Surfaces-Dark.dc.html", page("Agent actions · Around the app, dark", f'<div class="bd" style="width:{W}px;height:{H}px">{surfaces("th-d", "Dark")}</div>', W, H), W, H)

# ---------------------------------------------------------------- try it

FIRST_RUN = """<sc-if value="{{%s}}" hint-placeholder-val="{{false}}">%s</sc-if>"""


def when(flag, inner):
    return FIRST_RUN % (flag, inner)


GEN_BTN = ab("box", chev=True, on="runGen")
RES_BTN = ab("hdr", verb="Resolve", on="runRes")
FIX_BTN = ab("dlg", verb="Fix", on="runFix")

TRY_BODY = (
    '<div class="try {{cls}}">'
    '<div class="tb2"><sc-for list="{{opts}}" as="o" hint-placeholder-count="7"><button class="{{o.cls}}" type="button" aria-pressed="{{o.on}}" onClick="{{o.pick}}">{{o.label}}</button></sc-for>'
    '<span class="sp"></span><button class="pill" type="button" onClick="{{flip}}">{{flipLabel}}</button></div>'
    '<div class="tcs">'
    # The message box.
    '<div><p class="tcap">The message box <i>· click Generate</i></p><div class="mb"><div class="{{genCls}}">'
    + when("genIdle", f'<span class="ph">Message</span><div class="pos">{GEN_BTN}</div>')
    + when("genRun", BARS)
    + when("genDone", TEXT)
    + glint(9.5)
    + '</div>'
    + when("genRun", f'<div class="nl">{WORKING}<span class="txt">Claude Code is writing…</span><button class="act" type="button" onClick="{{{{resetGen}}}}">Stop</button></div>')
    + when("genDone", f'<div class="nl">{DONE}<span class="txt">Claude Code · haiku wrote this in 3 s.</span><button class="act" type="button" onClick="{{{{resetGen}}}}">Undo</button></div>')
    + '</div></div>'
    # The diff.
    '<div><p class="tcap">A conflicted file <i>· click Resolve</i></p><div class="df"><div class="dh"><span class="ref">LoginView.swift</span>'
    + when("resIdle", RES_BTN)
    + f'<span class="dots">{DOTS}</span><button class="pl" type="button">Mark Resolved</button></div>'
    + when("resRun", banner(WORKING, "Claude is resolving 2 conflicts…", '<button class="pl" type="button" onClick="{{resetRes}}">Stop</button>'))
    + when("resDone", banner(DONE, "Claude resolved 2 conflicts in 3 s. Read them over before marking the file resolved.", '<button class="pl" type="button" onClick="{{resetRes}}">Put Conflicts Back</button>'))
    + '<div class="{{resCls}}"><div class="cin"><div class="cb">Conflict 1 of 2</div>'
    + when("resNotDone", '<div class="cs1">Button("Retry", action: retry)</div><div class="cs2">Text(session.error).font(.caption)</div>')
    + when("resDone", '<div style="padding:2px 10px">Button("Retry", action: retry)</div><div style="padding:2px 10px">Text(session.error).font(.caption)</div>')
    + '</div>' + glint(7.5) + '</div></div></div>'
    # The dialog.
    '<div><p class="tcap">What git refused <i>· click Fix</i></p><div class="dlg">'
    + when("fixIdle", '<div class="top"><h3 class="ti">The push was rejected</h3><p class="msg"><span class="ref">main</span> has commits on <span class="ref">origin</span> that you don’t have yet.</p></div>'
           f'<div class="btns">{FIX_BTN}<button class="bt pri" type="button">OK</button></div><div class="cmd"><span class="cm">$</span> git push origin main</div>')
    + when("fixRun", '<div class="top"><h3 class="ti">Asking Claude Code…</h3><p class="msg">Roga is sending it what git said and what read-only commands show about this worktree. Nothing runs until you say so.</p></div>'
           '<div class="btns"><button class="bt" type="button" onClick="{{resetFix}}">Stop</button></div><div class="cmd"><span class="lin"><i></i></span><span class="cm">$</span> claude -p <span class="fl">--safe-mode</span> <span class="fl">--model</span> haiku</div>')
    + when("fixDone", '<div class="top"><h3 class="ti">What Claude suggests</h3><p class="msg">Your branch is one commit behind. Pull it in with a rebase, then push again.</p></div>'
           '<div class="btns"><button class="bt" type="button" onClick="{{resetFix}}">Cancel</button><button class="bt pri" type="button" onClick="{{resetFix}}">Run</button></div><div class="cmd"><span class="cm">$</span> git pull <span class="fl">--rebase</span><br><span class="cm">$</span> git push origin main</div>')
    + '</div></div></div>'
    '<p class="tip">Hover a button to see what the pointer does to it, and click it to see what the work looks like. Each one takes about three seconds, and Stop, Undo or Run brings it back.</p>'
    '</div>'
)

TRY_CONST = """const OPTS = [["o0","Today"],["oA","A · Hairline"],["oB","B · Glint"],["oC","C · Standby mark"],["oD","D · Prompt"],["oE","E · Agent half"],["oF","F · Warm tint"]];"""

TRY_JS = """  constructor(props) {
    super(props);
    this.state = { opt: "oB", dark: false, gen: "idle", res: "idle", fix: "idle" };
    this.timers = {};
  }
  componentWillUnmount() { Object.values(this.timers).forEach(clearTimeout); }
  start(key) {
    clearTimeout(this.timers[key]);
    this.setState({ [key]: "run" });
    this.timers[key] = setTimeout(() => this.setState({ [key]: "done" }), 3000);
  }
  reset(key) {
    clearTimeout(this.timers[key]);
    this.setState({ [key]: "idle" });
  }
  renderVals() {
    const s = this.state;
    return {
      cls: (s.dark ? "th-d " : "th-l ") + s.opt,
      opts: OPTS.map(([id, label]) => ({ label, on: s.opt === id ? "true" : "false", cls: "pill" + (s.opt === id ? " on" : ""), pick: () => this.setState({ opt: id }) })),
      flip: () => this.setState({ dark: !s.dark }),
      flipLabel: s.dark ? "Light" : "Dark",
      genCls: "ed" + (s.gen === "run" ? " run" : ""),
      resCls: "cf" + (s.res === "run" ? " run" : ""),
      genIdle: s.gen === "idle", genRun: s.gen === "run", genDone: s.gen === "done",
      resIdle: s.res === "idle", resRun: s.res === "run", resDone: s.res === "done", resNotDone: s.res !== "done",
      fixIdle: s.fix === "idle", fixRun: s.fix === "run", fixDone: s.fix === "done",
      runGen: () => this.start("gen"), runRes: () => this.start("res"), runFix: () => this.start("fix"),
      resetGen: () => this.reset("gen"), resetRes: () => this.reset("res"), resetFix: () => this.reset("fix"),
    };
  }"""

W, H = 1360, 760
write("Ag-Try.dc.html", page("Agent actions · Try them", TRY_BODY, W, H, script_body=TRY_JS, head_const=TRY_CONST), W, H)
