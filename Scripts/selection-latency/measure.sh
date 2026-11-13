#!/bin/bash
# Times selecting rows in history, in a test copy of Roga.
#
#   Scripts/selection-latency/measure.sh <Roga.app> <worktree> <log> [click|keys] [steps]
#
# It copies the app under its own bundle ID (sh.roga.test.selection), with a
# home folder of its own, so the real Roga's settings, window sizes and list of
# repositories are left alone. The copy opens on <worktree>, and the probe
# (probe.m) selects rows in its history and writes what it timed to <log>.
# Then analyze.py reads the log:
#
#   uv run Scripts/selection-latency/analyze.py <log>
#
# The window comes up on screen and takes the keyboard for the run, about
# half a minute. The probe posts its clicks to the app, so the pointer doesn't
# move. Roga writes commit-graph files into the repository it shows, so give it
# a copy, which `cp -cR` makes cheaply on APFS. Run `git update-index --refresh`
# in a copied worktree first, or git hashes every file to find what changed.
#
# Environment: ROGA_PROBE_HOLD, ROGA_PROBE_GAP, ROGA_PROBE_SAMPLE and
# ROGA_PROBE_SETTLE pass through to the probe (see probe.m).
set -euo pipefail

app=$1
worktree=$(cd "$2" && pwd)
log=$3
mode=${4:-click}
steps=${5:-30}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/roga-selection.XXXXXX")
id=sh.roga.test.selection
copy="$work/RogaSelectionTest.app"
home="$work/home"
pid=

cleanup() {
    if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; fi
    defaults delete "$id" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

clang -dynamiclib -fobjc-arc -O2 -framework AppKit -framework CoreVideo -framework QuartzCore \
    "$here/probe.m" -o "$work/probe.dylib"

cp -cR "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $id" "$copy/Contents/Info.plist"
codesign --force --deep -s - "$copy" 2>/dev/null

support="$home/Library/Application Support/$id"
mkdir -p "$support"
cat > "$support/repositories.json" <<EOF
{"version": 1,
 "repositories": [{"path": "$worktree/.git", "isExpanded": true}],
 "lastSelection": {"repository": "$worktree/.git", "worktree": "$worktree"}}
EOF
defaults delete "$id" >/dev/null 2>&1 || true
defaults write "$id" setupDone -bool true
defaults write "$id" fetchesByItself -bool false
defaults write "$id" "NSWindow Frame workspace-AppWindow-1" "80 80 1280 800 0 0 2560 1415 "

rm -f "$log" "$log.done" "$log.activate"
# Started directly rather than with open, which would drop DYLD_INSERT_LIBRARIES.
env HOME="$home" CFFIXED_USER_HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DYLD_INSERT_LIBRARIES="$work/probe.dylib" ROGA_PROBE_LOG="$log" \
    ROGA_PROBE_MODE="$mode" ROGA_PROBE_STEPS="$steps" \
    "$copy/Contents/MacOS/Roga" -ApplePersistenceIgnoreState YES >"$log.app.txt" 2>&1 &
pid=$!

for _ in $(seq 1 600); do
    [[ -e "$log.done" ]] && break
    if [[ -e "$log.activate" ]]; then
        rm -f "$log.activate"
        open -a "$copy"
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "The test copy quit early. Its output:" >&2
        tail -20 "$log.app.txt" >&2
        exit 1
    fi
    sleep 0.5
done
rm -f "$log.done"
[[ -s "$log" ]] || { echo "The probe wrote nothing to $log" >&2; exit 1; }
echo "Wrote $log"
