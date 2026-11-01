#!/bin/bash
# Builds the preview, wraps it in an app bundle so it behaves like a normal Mac
# app, and opens it with a few repositories to try.
#
#   run.sh [--open-all]
#
# With --open-all, it skips the welcome window and opens every repository as a tab.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

swift build --package-path "$here" -c debug
bin="$(swift build --package-path "$here" -c debug --show-bin-path)/yaga-tabs"

app="$here/.build/yaga-tabs.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/yaga-tabs"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>yaga-tabs</string>
    <key>CFBundleIdentifier</key><string>build.yaga.preview.tabs</string>
    <key>CFBundleName</key><string>yaga</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null

if [ ! -d "$root/bench-repos/agents-demo" ]; then
    "$here/make-demo-repo.sh" "$root/bench-repos"
fi

repos=("$root/bench-repos/agents-demo" "$root")
for extra in linux git; do
    [ -d "$root/bench-repos/$extra/.git" ] && repos+=("$root/bench-repos/$extra")
done

open -n "$app" --args "$@" "${repos[@]}"
