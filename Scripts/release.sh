#!/bin/bash
# Builds a release of Roga: archives the app, signs it with the Developer ID
# certificate, notarizes and staples it, zips it, and adds it to the Sparkle
# appcast. docs/releasing.md describes the setup it needs and how to publish
# what it makes.
#
# Usage: ROGA_TEAM_ID=<team> ROGA_NOTARY_PROFILE=<profile> Scripts/release.sh
#
# The version is MARKETING_VERSION from the project. The archive and the
# exported app go to build/release/<version>. The zip and appcast.xml go to
# build/updates, which keeps every release's zip so that generate_appcast can
# write the whole appcast.
set -euo pipefail

cd "$(dirname "$0")/.."

team="${ROGA_TEAM_ID:?Set ROGA_TEAM_ID to the team that owns the Developer ID certificate.}"
notary_profile="${ROGA_NOTARY_PROFILE:?Set ROGA_NOTARY_PROFILE to a profile saved with xcrun notarytool store-credentials.}"

if ! /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" App/Info.plist > /dev/null 2>&1; then
    echo "App/Info.plist has no SUPublicEDKey, so this release couldn't install updates." >&2
    exit 1
fi

version="$(xcodebuild -showBuildSettings -project Roga.xcodeproj -scheme Roga -configuration Release 2>/dev/null \
    | awk '$1 == "MARKETING_VERSION" { print $3 }')"
work="build/release/$version"
updates="build/updates"
derived="build/DerivedData"
zip="$updates/roga-$version.zip"

if [[ -e "$zip" ]]; then
    echo "$zip already exists. Raise MARKETING_VERSION for a new release." >&2
    exit 1
fi
rm -rf "$work"
mkdir -p "$work" "$updates"

echo "Archiving Roga $version"
xcodebuild archive \
    -project Roga.xcodeproj \
    -scheme Roga \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$derived" \
    -archivePath "$work/roga.xcarchive" \
    -onlyUsePackageVersionsFromResolvedFile \
    DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application"

cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>$team</string>
</dict>
</plist>
EOF

echo "Signing with the Developer ID certificate"
xcodebuild -exportArchive \
    -archivePath "$work/roga.xcarchive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist"

app="$work/export/Roga.app"
codesign --verify --strict --deep --verbose=2 "$app"
if ! codesign --display --verbose=2 "$app" 2>&1 | grep -q "flags=.*runtime"; then
    echo "$app isn't signed with the hardened runtime, which notarization requires." >&2
    exit 1
fi

# Agents' hooks run the roga helper inside the app (decision 41), so a
# release without it would never hear from them. Notarization rejects a
# helper without the hardened runtime, and the export should have signed it
# with the app's certificate, so check it here rather than after the upload.
helper="$app/Contents/Helpers/roga"
if [[ ! -f "$helper" || ! -x "$helper" ]]; then
    echo "$helper is missing or isn't executable, so agents' hooks couldn't reach Roga." >&2
    exit 1
fi
helper_signature="$(codesign --display --verbose=2 "$helper" 2>&1 || true)"
if ! grep -q "flags=.*runtime" <<< "$helper_signature"; then
    echo "$helper isn't signed with the hardened runtime, which notarization requires." >&2
    exit 1
fi
helper_team="$(awk -F= '$1 == "TeamIdentifier" && $2 != "not set" { print $2 }' <<< "$helper_signature")"
if [[ "$helper_team" != "$team" ]]; then
    echo "$helper isn't signed by team $team like the app (its team: ${helper_team:-none})." >&2
    exit 1
fi

echo "Notarizing"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarize.zip"
xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose=2 "$app"

echo "Updating the appcast"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
"$derived/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --download-url-prefix "https://github.com/tmarkovski/yaga/releases/download/v$version/" \
    "$updates"

echo
echo "Roga $version is ready:"
echo "  $zip"
echo "  $updates/appcast.xml"
echo "docs/releasing.md lists the steps to publish them."
