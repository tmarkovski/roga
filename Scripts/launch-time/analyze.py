# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1"]
# ///
"""Turns what probe.m recorded into timings for Roga's launch.

    uv run Scripts/launch-time/analyze.py FOLDER [--timeline N] [--profile [--tree MS]]
    uv run Scripts/launch-time/analyze.py FOLDER FOLDER...

Each FOLDER is one that measure.sh wrote for a build, with warmup.log and
run-N.log. Every time is in milliseconds from when the kernel started the
process. For one folder, it gives each milestone's median, minimum and maximum
over the runs, and the warm-up's time on its own, since that launch is the
first after a build. For several, it compares their medians.

With --timeline N it lists everything run N recorded in order: the milestones,
and each child process with when it started and ended. With --profile, for
logs recorded with ROGA_PROBE_SAMPLE=1, it says what the main thread was doing
in each stretch of the launch, and with --tree, which calls that time went to.
"""

import bisect
import re
import statistics
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import click


@dataclass
class Spawn:
    pid: int
    start: float
    args: str
    end: float | None = None


@dataclass
class Run:
    name: str
    events: list = field(default_factory=list)  # (t, kind, a, b)
    spawns: list = field(default_factory=list)
    samples: list = field(default_factory=list)  # (t, [pc, ...])
    symbols: dict = field(default_factory=dict)  # pc -> (image, name)
    images: list = field(default_factory=list)  # (base, size, path)

    def first(self, kind, after=float("-inf"), a=None, b=None):
        for t, k, x, y in self.events:
            if k == kind and t >= after and (a is None or x == a) and (b is None or y == b):
                return t
        return None


def read_run(path: Path) -> Run:
    run = Run(path.stem)
    exec_time = 0.0
    by_pid = {}
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line:
            continue
        if line.startswith("symbol "):
            _, pc, image, name = line.split(" ", 3)
            run.symbols[int(pc, 16)] = (image, name)
            continue
        if line.startswith("image "):
            _, base, size, image = line.split(" ", 3)
            run.images.append((int(base, 16), int(size, 16), image))
            continue
        parts = line.split(" ", 4)
        t, kind = float(parts[0]), parts[1]
        if kind == "exec":
            exec_time = t
            continue
        t -= exec_time
        if kind == "sample":
            run.samples.append((t, [int(pc, 16) for pc in line.split()[2:]]))
            continue
        a, b = int(parts[2]), int(parts[3])
        if kind == "spawn":
            spawn = Spawn(a, t, parts[4] if len(parts) > 4 else "")
            run.spawns.append(spawn)
            by_pid[a] = spawn
            continue
        if kind == "exit":
            if a in by_pid:
                by_pid[a].end = t
            continue
        run.events.append((t, kind, a, b))
    run.events.sort()
    run.samples.sort(key=lambda s: s[0])
    return run


def is_login_shell(spawn: Spawn) -> bool:
    return "_ROGA_PATH_START_" in spawn.args


def is_git(spawn: Spawn) -> bool:
    return re.match(r"^\S*git(\s|$)", spawn.args) is not None


def is_git_version(spawn: Spawn) -> bool:
    return is_git(spawn) and spawn.args.rstrip().endswith(" version")


def frame_after(run: Run, t):
    """When the run-loop pass that drew at `t` ended, after Core Animation's
    commit, which sends the frame to the window server."""
    return None if t is None else run.first("rl-done", after=t)


def milestones(run: Run) -> dict:
    m = {}
    m["probe loaded (dyld done)"] = run.first("probe-loaded")
    m["run loop first entered"] = run.first("rl-entry")
    m["will finish launching"] = run.first("will-finish-launching")
    m["did finish launching"] = run.first("did-finish-launching")
    ordered = next((t for t, k, a, _ in run.events if k == "order-window-end" and a != 0), None)
    m["window ordered in"] = ordered
    m["window's first frame committed"] = frame_after(run, ordered)
    m["window server: window visible"] = run.first("window-occlusion", b=1)
    m["window key"] = run.first("window-key")
    shell = next((s for s in run.spawns if is_login_shell(s)), None)
    m["login shell started"] = shell.start if shell else None
    m["login shell ended"] = shell.end if shell else None
    versions = [s for s in run.spawns if is_git_version(s)]
    m["first `git version` ended"] = versions[0].end if versions else None
    repo_git = next((s for s in run.spawns if is_git(s) and not is_git_version(s)), None)
    m["first repository git started"] = repo_git.start if repo_git else None
    m["history rows drawn"] = run.first("history-draw-end")
    m["history on screen (frame committed)"] = frame_after(run, run.first("history-draw-end"))
    return m


def summary(values):
    values = sorted(v for v in values if v is not None)
    if not values:
        return "      –        –        –"
    return f"{statistics.median(values):7.0f}  {values[0]:7.0f}  {values[-1]:7.0f}"


def timeline(run: Run):
    rows = []
    for name, t in milestones(run).items():
        if t is not None:
            rows.append((t, f"** {name}"))
    for spawn in run.spawns:
        took = f"{spawn.end - spawn.start:7.1f} ms" if spawn.end is not None else "   still running"
        rows.append((spawn.start, f"   spawn {spawn.pid:6d} {took}  ends {spawn.end or 0:7.1f}  {spawn.args[:160]}"))
    for t, kind, a, b in run.events:
        if kind in ("spinner-start", "did-become-active", "window-occlusion", "order-window-begin", "make-key-and-order-front-begin", "finish"):
            rows.append((t, f"   {kind} {a} {b}"))
    rows.sort(key=lambda r: r[0])
    for t, text in rows:
        click.echo(f"{t:9.1f}  {text}")


def symbolicate(run: Run, app_binary: Path | None) -> dict:
    """Names every sampled address, asking atos for the app's own code, and
    keeping the probe's names for the rest."""
    names = {pc: f"{image}`{name}" for pc, (image, name) in run.symbols.items()}
    by_image = defaultdict(list)
    for pc in run.symbols:
        for base, size, path in run.images:
            if base <= pc < base + size and ".app/Contents/MacOS/" in path:
                by_image[(base, path)].append(pc)
    for (base, path), pcs in by_image.items():
        binary = app_binary if app_binary and app_binary.exists() else Path(path)
        if not binary.exists():
            continue
        result = subprocess.run(
            ["atos", "-o", str(binary), "-l", hex(base), *[hex(pc) for pc in pcs]],
            capture_output=True, text=True,
        )
        for pc, line in zip(pcs, result.stdout.splitlines()):
            name = line.split(" (in ")[0]
            names[pc] = f"Roga`{name}"
    return names


# What a sample counts as, by the first of these that any of its frames match.
CATEGORIES = [
    ("waiting for an event", lambda leaf, names: "mach_msg2_trap" in leaf and any("__CFRunLoopServiceMachPort" in n for n in names)),
    ("waiting for another process to answer", lambda leaf, names: "mach_msg2_trap" in leaf),
    ("Roga's App.init", lambda leaf, names: any("RogaApplication" in n and "init" in n for n in names)),
    ("dyld loading and starting libraries", lambda leaf, names: any(n.startswith("dyld`") and n != "dyld`start" for n in names)),
    ("SwiftUI updating the menu bar", lambda leaf, names: any("MainMenu" in n or "makeMainMenu" in n for n in names)),
    ("drawing history's rows", lambda leaf, names: any("CommitCellView" in n or "CommitRowView" in n for n in names)),
    ("SwiftUI updating and laying out the window", lambda leaf, names: any(
        n.startswith(("SwiftUI", "AttributeGraph", "RenderBox", "SwiftUICore")) for n in names)),
    ("Core Animation committing and drawing", lambda leaf, names: any("CA11Transaction" in n or "CA5Layer" in n for n in names)),
    ("AppKit", lambda leaf, names: any(n.startswith("AppKit`") for n in names)),
    ("other", lambda leaf, names: True),
]


def category(names_of_frames: list) -> str:
    leaf = names_of_frames[0] if names_of_frames else ""
    for title, matches in CATEGORIES:
        if matches(leaf, names_of_frames):
            return title
    return "other"


def tree(stacks: list, per_run: float, threshold: float, depth: int = 60):
    """Prints where the samples were from the root down, in ms a run, leaving
    out calls under `threshold`."""
    root = {}
    for frames in stacks:
        node = root
        for name in reversed(frames):
            entry = node.setdefault(name, [0, {}])
            entry[0] += 1
            node = entry[1]

    def show(node, indent, level):
        if level > depth:
            return
        for name, (count, children) in sorted(node.items(), key=lambda item: -item[1][0]):
            ms = count * per_run
            if ms < threshold:
                continue
            click.echo(f"    {ms:6.1f}  {'  ' * indent}{name[:150]}")
            show(children, indent + 1, level + 1)

    show(root, 0, 0)


def profile(runs: list, names_by_run: dict, stretch, title: str, top: int, threshold: float = 0):
    picked, total, count = [], 0.0, 0
    for run in runs:
        a, b = stretch(run)
        if a is None or b is None or b <= a:
            continue
        total += b - a
        count += 1
        times = [s[0] for s in run.samples]
        lo, hi = bisect.bisect_left(times, a), bisect.bisect_right(times, b)
        names = names_by_run[run.name]
        picked.extend([[names.get(pc, hex(pc)) for pc in pcs] for _, pcs in run.samples[lo:hi]])
    click.echo(f"\n{title}: {count} runs, {total / max(count, 1):.0f} ms a run, {len(picked)} samples")
    if not picked:
        return
    categories = Counter(category(frames) for frames in picked)
    click.echo("  By what it was doing (ms a run, from the share of samples):")
    for name, n in categories.most_common():
        click.echo(f"    {total * n / len(picked) / count:6.1f}  {100 * n / len(picked):5.1f}%  {name}")
    inclusive, leaf = Counter(), Counter()
    for frames in picked:
        for name in set(frames):
            inclusive[name] += 1
        leaf[frames[0]] += 1
    own = [(n, c) for n, c in inclusive.most_common() if n.startswith("Roga`") and "`main" not in n]
    if own:
        click.echo("  Roga's own code on the stack (ms a run):")
        for name, n in own[:top]:
            click.echo(f"    {total * n / len(picked) / count:6.1f}  {name[:170]}")
    click.echo("  On the stack (ms a run):")
    for name, n in inclusive.most_common(top):
        click.echo(f"    {total * n / len(picked) / count:6.1f}  {name[:170]}")
    click.echo("  Running (ms a run):")
    for name, n in leaf.most_common(12):
        click.echo(f"    {total * n / len(picked) / count:6.1f}  {name[:170]}")
    if threshold:
        click.echo(f"  From the root down, calls of {threshold:g} ms a run or more:")
        tree(picked, total / len(picked) / count, threshold)


def read_runs(folder: Path):
    runs = [read_run(p) for p in sorted(folder.glob("run-*.log"), key=lambda p: int(p.stem.split("-")[1]))]
    warmup = read_run(folder / "warmup.log") if (folder / "warmup.log").exists() else None
    if not runs:
        raise click.ClickException(f"No run-N.log in {folder}")
    return runs, warmup


@click.command()
@click.argument("folders", nargs=-1, required=True, type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option("--timeline", "timeline_run", type=int, help="List everything run N of the first folder recorded, in order.")
@click.option("--profile", "show_profile", is_flag=True, help="Say what the main thread did, from the first folder's samples.")
@click.option("--app", "app", type=click.Path(path_type=Path), help="The Roga.app that was measured, for naming its code. measure.sh notes it in app-path.")
@click.option("--top", default=25, help="How many functions each profile lists.")
@click.option("--tree", "threshold", default=0.0, help="With --profile, also print a call tree of calls taking this many ms a run or more.")
def main(folders, timeline_run, show_profile, app, top, threshold):
    """Times from the logs in FOLDERS, each written by measure.sh for one
    build. With more than one, it compares their medians."""
    if len(folders) > 1:
        loaded = [read_runs(folder) for folder in folders]
        medians = [[milestones(r) for r in runs] for runs, _ in loaded]
        click.echo(f"Medians in ms from the process starting, {', '.join(f'{len(runs)} runs of {folder.name}' for folder, (runs, _) in zip(folders, loaded))}")
        click.echo(f"{'':44s} " + "  ".join(f"{folder.name[:10]:>10s}" for folder in folders) + "      change")
        for name in medians[0][0]:
            values = []
            for runs in medians:
                found = [m[name] for m in runs if m[name] is not None]
                values.append(statistics.median(found) if found else None)
            cells = "  ".join(f"{v:10.0f}" if v is not None else f"{'–':>10s}" for v in values)
            change = f"{values[-1] - values[0]:+10.0f}" if values[0] is not None and values[-1] is not None else ""
            click.echo(f"{name:44s} {cells}  {change}")
        return

    logs = folders[0]
    runs, warmup = read_runs(logs)
    all_milestones = [milestones(r) for r in runs]
    warm = milestones(warmup) if warmup else {}
    click.echo(f"{len(runs)} runs, in ms from the process starting")
    click.echo(f"{'':44s} {'median':>7s}  {'min':>7s}  {'max':>7s}   warm-up")
    for name in all_milestones[0]:
        w = warm.get(name)
        click.echo(f"{name:44s} {summary([m[name] for m in all_milestones])}   {w:7.0f}" if w is not None else
                   f"{name:44s} {summary([m[name] for m in all_milestones])}         –")
    missing = [r.name for r, m in zip(runs, all_milestones) if m["history rows drawn"] is None]
    if missing:
        click.echo(f"\nHistory never drew in {', '.join(missing)}.")

    if timeline_run:
        click.echo(f"\nRun {timeline_run}:")
        timeline(runs[timeline_run - 1])

    if show_profile:
        if app is None and (logs / "app-path").exists():
            app = Path((logs / "app-path").read_text().strip())
        sampled = [r for r in runs if r.samples]
        if not sampled:
            raise click.ClickException("No samples. Record with ROGA_PROBE_SAMPLE=1.")
        binary = None
        if app:
            dsym = Path(str(app) + ".dSYM") / "Contents/Resources/DWARF/Roga"
            binary = dsym if dsym.exists() else app / "Contents/MacOS/Roga"
        names_by_run = {r.name: symbolicate(r, binary) for r in sampled}
        profile(sampled, names_by_run, lambda r: (r.first("probe-loaded"), r.first("will-finish-launching")),
                "From the probe loading to AppKit's will-finish-launching", top, threshold)
        profile(sampled, names_by_run, lambda r: (r.first("will-finish-launching"), r.first("order-window-begin")),
                "From will-finish-launching to ordering the window in", top, threshold)
        profile(sampled, names_by_run, lambda r: (r.first("order-window-begin"), milestones(r)["window's first frame committed"]),
                "From ordering the window in to its first frame", top, threshold)
        profile(sampled, names_by_run, lambda r: (milestones(r)["window's first frame committed"], milestones(r)["history on screen (frame committed)"]),
                "From the window's first frame to history on screen", top, threshold)


if __name__ == "__main__":
    main()
