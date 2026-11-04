#!/bin/bash
# Builds the preview, wraps it in an app bundle so it behaves like a normal Mac
# app, and opens it with a few repositories to try.
#
#   run.sh [--open-all]
#
# With --open-all, every repository opens as a tab. Without it, the window lists
# them so you can pick.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

swift build --package-path "$here" -c debug
bin="$(swift build --package-path "$here" -c debug --show-bin-path)/roga-main-window"

app="$here/.build/roga-main-window.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/roga-main-window"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>roga-main-window</string>
    <key>CFBundleIdentifier</key><string>sh.roga.preview.main-window</string>
    <key>CFBundleName</key><string>Roga</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1

if [ ! -d "$root/bench-repos/agents-demo" ]; then
    "$root/prototypes/window-tabs/make-demo-repo.sh" "$root/bench-repos"
fi

repos=("$root/bench-repos/agents-demo" "$root")
for extra in linux git; do
    [ -d "$root/bench-repos/$extra/.git" ] && repos+=("$root/bench-repos/$extra")
done

open_all=0
[[ " $* " == *" --open-all "* ]] && open_all=1
list="$(IFS='|'; echo "${repos[*]}")"
open -n "$app" --env ROGA_PREVIEW_REPOS="$list" --env ROGA_PREVIEW_OPEN_ALL="$open_all"
