# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Turns what probe.m recorded into timings for selecting a row in history.

    uv run Scripts/selection-latency/analyze.py LOG [--steps] [--profile]

Every time is in milliseconds. For each step it finds the event that was
posted, when AppKit dispatched it, when the row's view became selected, when
the row drew its highlight, and when the Core Animation commit with that
drawing finished. From that commit, the window server composites the frame at
the screen's next refresh and the screen shows it one refresh later, which
the CVDisplayLink's output time gives.

With --profile, and a log recorded with ROGA_PROBE_SAMPLE=1, it also says what
the main thread was doing in each part of a step, from the stack samples.
"""

import bisect
import statistics
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import click

MOUSE_DOWN, MOUSE_UP, KEY_DOWN = 1, 2, 10


@dataclass
class Step:
    index: int
    row: int
    events: list = field(default_factory=list)

    def first(self, kind, after=float("-inf"), a=None):
        for t, k, x, _ in self.events:
            if k == kind and t >= after and (a is None or x == a):
                return t
        return None


@dataclass
class Log:
    header: dict
    steps: list
    vsyncs: list  # (refresh time, output time)
    samples: list  # (time, [pc, ...]) from the leaf
    symbols: dict
    images: list  # (base, size, path)


def read_log(path: Path) -> Log:
    header, steps, vsyncs, samples, symbols, images = {}, [], [], [], {}, []
    current = None
    for line in path.read_text().splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "#":
            if parts[1] == "mode":
                header = {**dict(zip(parts[1::2], parts[2::2])), "checks": header.get("checks", [])}
            elif parts[1] == "check":
                header.setdefault("checks", []).append(line[len("# check "):])
            continue
        if parts[0] == "symbol":
            symbols[int(parts[1], 16)] = (parts[2], " ".join(parts[3:]))
            continue
        if parts[0] == "recognizer":
            continue
        if parts[0] == "image":
            images.append((int(parts[1], 16), int(parts[2], 16), " ".join(parts[3:])))
            continue
        t, kind = float(parts[0]), parts[1]
        if kind == "sample":
            samples.append((t, [int(pc, 16) for pc in parts[2:]]))
        elif kind == "vsync":
            vsyncs.append((int(parts[2]) / 1000, int(parts[3]) / 1000))
        elif kind == "step":
            current = Step(int(parts[2]), int(parts[3]))
            steps.append(current)
            current.events.append((t, kind, int(parts[2]), int(parts[3])))
        elif current is not None:
            current.events.append((t, kind, int(parts[2]), int(parts[3])))
    vsyncs.sort()
    return Log(header, steps, vsyncs, samples, symbols, images)


def on_screen(log: Log, committed: float):
    """When a frame committed at this time is shown: the output time of the
    first refresh after the commit."""
    times = [v[0] for v in log.vsyncs]
    index = bisect.bisect_left(times, committed)
    return log.vsyncs[index][1] if index < len(log.vsyncs) else None


def timings(log: Log, step: Step):
    """The moments of one step, from when its first event was posted."""
    keys = log.header.get("mode") == "keys"
    start = step.first("post-key-down" if keys else "post-down")
    if start is None:
        return None
    m = {"start": start}
    m["dispatched"] = step.first("send-begin", start, KEY_DOWN if keys else MOUSE_DOWN)
    if not keys:
        m["released"] = step.first("post-up", start)
        m["up dispatched"] = step.first("send-begin", start, MOUSE_UP)
        # Once the main thread has handled the mouse-up and drawn whatever it
        # set off, the run loop goes back to waiting. When the table tracks the
        # mouse itself, the mouse-up ends the mouse-down's dispatch instead.
        ends = [t for t, k, _, _ in step.events if k == "send-end" and m["released"] is not None and t >= m["released"]]
        m["free after release"] = step.first("rl-committed", ends[0]) if ends else None
    m["selected"] = step.first("row-selected", start, step.row)
    if m["selected"] is None:
        return None
    # A build that tells the model once the frame is drawn does it from
    # sendReport, which the probe records, rather than when the selection changes.
    if any(k == "report-begin" for _, k, _, _ in step.events):
        m["model told"] = step.first("report-begin", m["selected"])
        m["model done"] = step.first("report-end", m["selected"])
    else:
        m["model told"] = step.first("did-change-begin", m["selected"])
        m["model done"] = step.first("did-change-end", m["selected"])
    m["drawn"] = step.first("draw-selection-end", m["selected"], step.row)
    m["draw began"] = step.first("draw-selection-begin", m["selected"], step.row)
    if m["drawn"] is None:
        return None
    # AppKit draws inside a Core Animation commit, so the frame with the
    # highlight is committed once the run-loop stage that drew it is over. Logs
    # from before the probe watched every stage only have Core Animation's own.
    if any(k == "rl-done" for _, k, _, _ in step.events):
        m["committed"] = step.first("rl-done", m["drawn"])
    else:
        m["committed"] = step.first("rl-committed", m["drawn"])
    # 0 when the probe didn't look, 1 when it found none and 2 when it found one.
    looked = next((b for t, k, a, b in step.events if k == "draw-selection-begin" and a == step.row and t == m["draw began"]), 0)
    m["drawn inside a commit"] = looked - 1 if looked else None
    m["shown"] = on_screen(log, m["committed"]) if m["committed"] else None
    return m


def hold_report(log: Log):
    """What holding down an arrow key did, hold by hold, and the medians."""
    deferred = any(k == "report-begin" for s in log.steps for _, k, _, _ in s.events)
    report_kind = "report-begin" if deferred else "did-change-begin"
    rows = []
    for step in log.steps:
        direction, presses = next(((a, b) for _, k, a, b in step.events if k == "hold"), (1, 0))
        posted = [t for t, k, _, _ in step.events if k == "post-key-down"]
        handled = [t for t, k, a, _ in step.events if k == "send-begin" and a == KEY_DOWN]
        waits = [h - p for p, h in zip(posted, handled)]
        released = step.first("post-key-up")
        # Each change of selection, which the list hears about in both kinds of
        # build. Row views report being selected again as they scroll into view.
        selections = [t for t, k, _, _ in step.events if k in ("did-change-begin", "did-change-deferred")]
        reports = [t for t, k, _, _ in step.events if k == report_kind]
        end_row = next((b for _, k, _, b in step.events if k == "step-end"), None)
        moved = (end_row - step.row) * direction if end_row is not None else None
        rows.append({
            "presses": len(posted), "handled": len(handled), "moved": moved, "reports": len(reports),
            "median wait": statistics.median(waits) if waits else None, "longest wait": max(waits) if waits else None,
            "moving after release": max(0.0, selections[-1] - released) if selections and released else None,
            "last report after release": reports[-1] - released if reports and released else None,
        })
    click.echo(f"  {'hold':4s} {'keys':>5s} {'handled':>8s} {'rows':>5s} {'reports':>8s} {'median wait':>12s} "
               f"{'longest wait':>13s} {'moving after':>13s} {'last report':>12s}")
    for index, r in enumerate(rows):
        def f(v):
            return f"{v:.1f}" if isinstance(v, float) else ("–" if v is None else str(v))
        click.echo(f"  {index:4d} {r['presses']:5d} {r['handled']:8d} {f(r['moved']):>5s} {r['reports']:8d} "
                   f"{f(r['median wait']):>12s} {f(r['longest wait']):>13s} {f(r['moving after release']):>13s} "
                   f"{f(r['last report after release']):>12s}")
    for key in ["reports", "median wait", "longest wait", "moving after release", "last report after release"]:
        click.echo(f"  {key:38s} {summary([r[key] for r in rows])}")


def summary(values):
    values = [v for v in values if v is not None]
    if not values:
        return "–"
    values.sort()
    return f"median {statistics.median(values):6.1f}   min {values[0]:6.1f}   max {values[-1]:6.1f}"


def symbolicate(log: Log) -> dict:
    """Names every sampled address, asking atos for the app's own code, which
    has its symbols on disk, and keeping the probe's names for the rest."""
    names = {pc: f"{image}`{name}" for pc, (image, name) in log.symbols.items()}
    by_image = defaultdict(list)
    for pc in log.symbols:
        for base, size, path in log.images:
            if base <= pc < base + size and ".app/Contents/MacOS/" in path:
                by_image[(base, path)].append(pc)
    for (base, path), pcs in by_image.items():
        result = subprocess.run(
            ["atos", "-o", path, "-l", hex(base), *[hex(pc) for pc in pcs]],
            capture_output=True, text=True,
        )
        for pc, line in zip(pcs, result.stdout.splitlines()):
            name = line.split(" (in ")[0]
            names[pc] = f"{Path(path).name}`{name}"
    return names


# What a sample counts as, by the first of these that any of its frames match.
CATEGORIES = [
    ("waiting for an event", lambda leaf, names: "mach_msg2_trap" in leaf),
    ("SwiftUI updating the menu bar", lambda leaf, names: any("MainMenu" in n or "makeMainMenu" in n for n in names)),
    ("SwiftUI updating the toolbar", lambda leaf, names: any("Toolbar" in n and ("SwiftUI" in n or "AppKit" in n) for n in names)),
    ("drawing history's rows", lambda leaf, names: any("CommitCellView" in n or "CommitRowView" in n for n in names)),
    ("SwiftUI updating and laying out the window", lambda leaf, names: any(
        n.startswith(("SwiftUI", "AttributeGraph", "RenderBox")) for n in names)),
    ("Core Animation committing and drawing", lambda leaf, names: any("CA11Transaction" in n or "CA5Layer" in n for n in names)),
    ("AppKit handling the event", lambda leaf, names: any("sendEvent" in n for n in names)),
    ("other", lambda leaf, names: True),
]


def category(names_of_frames: list) -> str:
    leaf = names_of_frames[0] if names_of_frames else ""
    for title, matches in CATEGORIES:
        if matches(leaf, names_of_frames):
            return title
    return "other"


def profile(log: Log, names: dict, windows: list, title: str, top: int):
    """What the main thread was doing in these windows of time, by how many
    samples each function was on the stack for."""
    times = [s[0] for s in log.samples]
    picked = []
    total = 0.0
    for a, b in windows:
        if a is None or b is None or b <= a:
            continue
        total += b - a
        lo, hi = bisect.bisect_left(times, a), bisect.bisect_right(times, b)
        picked.extend(log.samples[lo:hi])
    click.echo(f"\n{title}: {len(windows)} windows, {total:.0f} ms in all, {len(picked)} samples")
    if not picked:
        return
    categories = Counter(category([names.get(pc, hex(pc)) for pc in pcs]) for _, pcs in picked)
    click.echo(f"  By what it was doing (ms per window, from the share of samples):")
    for name, count in categories.most_common():
        click.echo(f"    {total * count / len(picked) / len([w for w in windows if w[0] is not None and w[1] is not None and w[1] > w[0]]):6.1f}  {100 * count / len(picked):5.1f}%  {name}")
    inclusive, leaf = Counter(), Counter()
    for _, pcs in picked:
        seen = set()
        for pc in pcs:
            name = names.get(pc, hex(pc))
            if name not in seen:
                inclusive[name] += 1
                seen.add(name)
        leaf[names.get(pcs[0], hex(pcs[0]))] += 1
    click.echo("  On the stack (share of samples):")
    for name, count in inclusive.most_common(top):
        click.echo(f"    {100 * count / len(picked):5.1f}%  {name[:150]}")
    own = [(n, c) for n, c in inclusive.most_common() if n.startswith("Roga") and "`main" not in n]
    if own:
        click.echo("  Roga's own code on the stack (share of samples):")
        for name, count in own[:top]:
            click.echo(f"    {100 * count / len(picked):5.1f}%  {name[:150]}")
    click.echo("  Running (share of samples):")
    for name, count in leaf.most_common(12):
        click.echo(f"    {100 * count / len(picked):5.1f}%  {name[:150]}")


@click.command()
@click.argument("logs", nargs=-1, required=True, type=click.Path(exists=True, path_type=Path))
@click.option("--steps", "show_steps", is_flag=True, help="Print every step's timings.")
@click.option("--profile", "show_profile", is_flag=True, help="Say what the main thread did, from the samples.")
@click.option("--top", default=30, help="How many functions the profile lists.")
def main(logs, show_steps, show_profile, top):
    for path in logs:
        log = read_log(path)
        keys = log.header.get("mode") == "keys"
        if log.header.get("mode") == "hold":
            click.echo(f"{path.name}: hold, {len(log.steps)} holds, experiment {log.header.get('experiment', 'none')}")
            hold_report(log)
            click.echo()
            continue
        if log.header.get("mode") == "checks":
            click.echo(f"{path.name}: checks, experiment {log.header.get('experiment', 'none')}")
            for line in log.header.get("checks", []):
                click.echo(f"  {line}")
            click.echo()
            continue
        click.echo(f"{path.name}: {log.header.get('mode')}, hold {log.header.get('hold')} ms, "
                   f"{len(log.steps)} steps, sampling {log.header.get('sampling')}, "
                   f"experiment {log.header.get('experiment', 'none')}")
        rows = [(s, timings(log, s)) for s in log.steps]
        done = [(s, m) for s, m in rows if m]
        if len(done) < len(rows):
            click.echo(f"  {len(rows) - len(done)} steps didn't select and draw their row")

        def since(m, a, b):
            return m[b] - m[a] if m.get(a) is not None and m.get(b) is not None else None

        if show_steps:
            for s, m in done:
                parts = [f"step {s.index:2d} row {s.row:2d}"]
                for a, b in [("start", "selected"), ("selected", "drawn"), ("drawn", "committed"), ("start", "committed"), ("start", "shown")]:
                    value = since(m, a, b)
                    parts.append(f"{a}→{b} {value:6.1f}" if value is not None else f"{a}→{b} –")
                click.echo("  " + "  ".join(parts))

        first = "pressed" if not keys else "key pressed"
        lines = [(f"{first} → dispatched", "start", "dispatched")]
        if not keys:
            lines += [("pressed → released (posted)", "start", "released"),
                      ("released → row selected", "released", "selected")]
        lines += [(f"{first} → row selected", "start", "selected"),
                  ("row selected → model told", "selected", "model told"),
                  ("model told → model done", "model told", "model done"),
                  ("row selected → highlight drawn", "selected", "drawn"),
                  ("highlight drawn → committed", "drawn", "committed"),
                  (f"{first} → committed", "start", "committed"),
                  (f"{first} → on screen (estimate)", "start", "shown")]
        if not keys:
            lines += [("released → committed", "released", "committed"),
                      ("released → on screen (estimate)", "released", "shown"),
                      ("released → main thread free again", "released", "free after release")]
        for title, a, b in lines:
            click.echo(f"  {title:38s} {summary([since(m, a, b) for _, m in done])}")
        watches_every_stage = any(k == "rl-done" for s in log.steps for _, k, _, _ in s.events)
        inside = [m["drawn inside a commit"] for _, m in done if watches_every_stage and m.get("drawn inside a commit") is not None]
        if inside:
            told_after = sum(1 for _, m in done if m["model told"] is not None and m["model told"] >= m["committed"])
            click.echo(f"  highlight drawn inside a commit in {sum(inside)} of {len(inside)} steps, "
                       f"model told after that commit in {told_after} of {len(done)}")

        if show_profile and log.samples:
            names = symbolicate(log)
            profile(log, names, [(m["model done"], m["draw began"]) for _, m in done],
                    "From telling the model until the highlight is drawn", top)
            if not keys:
                profile(log, names, [(m.get("up dispatched"), m.get("free after release")) for _, m in done],
                        "From the mouse-up until the main thread is free again", top)
            profile(log, names, [(m["draw began"], m["committed"]) for _, m in done],
                    "From drawing the highlight until the commit", top)
            if not keys:
                profile(log, names, [(m["dispatched"], m.get("released")) for _, m in done],
                        "While the button is down", top)
        click.echo()


if __name__ == "__main__":
    main()
