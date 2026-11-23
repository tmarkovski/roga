#!/bin/bash
# Times Roga's launch, in test copies of one or more builds of the app.
#
#   Scripts/launch-time/measure.sh <fixture> <logs folder> <runs> <selection> <label>=<Roga.app> [<label>=<Roga.app> ...]
#
# <fixture> is a folder that fixture.sh made, and <selection> is the repository
# in it to select, such as roga or large. Each build runs as a copy under its
# own bundle ID (sh.roga.test.launch) with a home folder of its own, so the
# real Roga's settings and list of repositories are left alone, and the copy
# lists the fixture's repositories.
#
# Each build is launched once to warm up, written to <logs>/<label>/warmup.log,
# and then <runs> times, to <logs>/<label>/run-N.log. With more than one build,
# their runs take turns, so that whatever else the Mac is doing slows them
# alike. Each run starts from the same list and selection, and ends half a
# second after history's rows have drawn. Before the next one starts, the git
# processes the last one left behind are given time to finish. Then
# analyze.py reads the logs:
#
#   uv run Scripts/launch-time/analyze.py <logs folder>/<label>
#
# The login shell that Roga starts to read PATH gets the real home folder, so
# that it reads the real dotfiles and takes as long as it does for Roga
# itself. Set ROGA_PROBE_SHELL_HOME to another folder, or to nothing, to
# change that. ROGA_PROBE_SAMPLE=1 samples the main thread, for
# `analyze.py --profile`. It slows the app slightly, so time without it.
set -euo pipefail

fixture=$(cd "$1" && pwd)
logs=$2
runs=$3
selection=$4
shift 4
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/roga-launch.XXXXXX")
id=sh.roga.test.launch
home="$work/home"
shell_home=${ROGA_PROBE_SHELL_HOME-$HOME}
pid=

cleanup() {
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    defaults delete "$id" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$logs"
logs=$(cd "$logs" && pwd)

clang -dynamiclib -fobjc-arc -O2 -framework AppKit -framework QuartzCore \
    "$here/probe.m" -o "$work/probe.dylib"

labels=()
for build in "$@"; do
    label=${build%%=*}
    app=${build#*=}
    labels+=("$label")
    mkdir -p "$work/$label" "$logs/$label"
    cp -cR "$app" "$work/$label/RogaLaunchTest.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$work/$label/RogaLaunchTest.app/Contents/Info.plist"
    # Signed again without the hardened runtime, which would ignore
    # DYLD_INSERT_LIBRARIES.
    codesign --force --deep -s - "$work/$label/RogaLaunchTest.app" 2>/dev/null
    # For analyze.py to name the app's own code.
    echo "$app" > "$logs/$label/app-path"
done

support="$home/Library/Application Support/$id"
mkdir -p "$support"
defaults delete "$id" >/dev/null 2>&1 || true
defaults write "$id" setupDone -bool true
defaults write "$id" fetchesByItself -bool false
defaults write "$id" "NSWindow Frame workspace-AppWindow-1" "80 80 1280 800 0 0 2560 1415 "

# The same list and selection for every run.
python3 - "$fixture" "$selection" "$support/repositories.template.json" <<'EOF'
import json, os, sys

fixture, selection, out = sys.argv[1:]
contents = json.load(open(os.path.join(fixture, "repositories.json")))
path = os.path.join(fixture, selection)
contents["lastSelection"] = {"repository": os.path.join(path, ".git"), "worktree": path}
json.dump(contents, open(out, "w"), indent=2)
EOF

# Waits for the processes a run started to end, for up to 30 seconds, so that
# a git status still going in Linux doesn't slow the next run.
settle() {
    local log=$1
    local pids
    pids=$(awk '$2 == "spawn" && $3 > 0 { print $3 }' "$log")
    for _ in $(seq 1 300); do
        local alive=0
        for child in $pids; do
            if kill -0 "$child" 2>/dev/null; then alive=1; break; fi
        done
        [[ $alive == 0 ]] && break
        sleep 0.1
    done
    sleep 0.5
}

launch() {
    local label=$1 log=$2
    cp "$support/repositories.template.json" "$support/repositories.json"
    rm -f "$log"
    # Started directly rather than with open, which would drop
    # DYLD_INSERT_LIBRARIES.
    env HOME="$home" CFFIXED_USER_HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        DYLD_INSERT_LIBRARIES="$work/probe.dylib" ROGA_PROBE_LOG="$log" \
        ROGA_PROBE_SHELL_HOME="$shell_home" \
        "$work/$label/RogaLaunchTest.app/Contents/MacOS/Roga" -ApplePersistenceIgnoreState YES >"$log.app.txt" 2>&1 &
    pid=$!
    wait "$pid" || true
    pid=
    [[ -s "$log" ]] || { echo "The probe wrote nothing to $log. The app's output:" >&2; tail -20 "$log.app.txt" >&2; exit 1; }
    settle "$log"
}

for label in "${labels[@]}"; do
    echo "Warming up $label"
    launch "$label" "$logs/$label/warmup.log"
done
# What the first warm-up saved, with a bookmark for each repository and its
# owners, as a list that has been opened before has, so that the runs don't
# each make and save them.
cp "$support/repositories.json" "$support/repositories.template.json"
for n in $(seq 1 "$runs"); do
    for label in "${labels[@]}"; do
        echo "Run $n of $runs: $label"
        launch "$label" "$logs/$label/run-$n.log"
    done
done
echo "Wrote $runs runs of each build to $logs"
