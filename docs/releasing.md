# Releasing

Roga is distributed outside the Mac App Store, signed with a Developer ID certificate, notarized by Apple, and updated through Sparkle (decision 1). [Scripts/release.sh](../Scripts/release.sh) does the building, signing and notarizing. Publishing what it makes is left to a person.

## Setting up a Mac to make releases

You only do this once, on the Mac that makes releases. None of these credentials go into the repository.

1. **Developer ID certificate.** In the Apple Developer Program, create a "Developer ID Application" certificate and install it, with its private key, in the login keychain. Note the team ID that owns it.
2. **Notarization credentials.** Save them in the keychain under a profile name, for example `roga-notary`. The command asks for an app-specific password, or you can pass an App Store Connect API key instead:

   ```bash
   xcrun notarytool store-credentials roga-notary --apple-id <apple-id> --team-id <team-id>
   ```

3. **Sparkle's signing key.** Sparkle checks every update against a public key in the app, so the private key that signs updates must never be lost or shared. Download Sparkle's tools and create the key, which `generate_keys` stores in the login keychain:

   ```bash
   xcodebuild -resolvePackageDependencies -project Roga.xcodeproj -scheme Roga -derivedDataPath build/DerivedData
   ```

   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Add the public key it prints to [App/Info.plist](../App/Info.plist) as `SUPublicEDKey`, and commit that change. Then back up the private key somewhere safe with `generate_keys -x <file>`. If it's lost, the copies of Roga that people already have can't install any later update.

Until `SUPublicEDKey` is in the Info.plist, the app doesn't start Sparkle, and the release script refuses to run.

## Making a release

1. Raise both version numbers. Sparkle compares the build number, `CURRENT_PROJECT_VERSION`, to decide whether an update is newer, and people see the marketing version.

   ```bash
   xcrun xcodeproj setting set MARKETING_VERSION 0.2.0 --target Roga
   ```

   ```bash
   xcrun xcodeproj setting set CURRENT_PROJECT_VERSION 2 --target Roga
   ```

2. Commit, and tag the commit `v0.2.0`.
3. Run the release script with the team ID and the notarization profile:

   ```bash
   ROGA_TEAM_ID=<team-id> ROGA_NOTARY_PROFILE=roga-notary Scripts/release.sh
   ```

   It writes `build/updates/roga-0.2.0.zip` and updates `build/updates/appcast.xml`, signing the new entry with the key from the keychain. Before notarizing, it stops if `Contents/Helpers/roga`, the helper the agents' hooks run (decision 41), is missing, isn't executable, or isn't signed with the hardened runtime by the same team.

   The first release with the helper is the first time it's signed with a Developer ID, so check it once the app is stapled:

   ```bash
   build/release/0.2.0/export/Roga.app/Contents/Helpers/roga --version
   ```

   ```bash
   codesign --verify --strict --verbose=2 build/release/0.2.0/export/Roga.app/Contents/Helpers/roga
   ```
4. Create a GitHub release for the tag with the zip attached. The appcast expects the zip at `https://github.com/tmarkovski/roga/releases/download/v0.2.0/roga-0.2.0.zip`.

   ```bash
   gh release create v0.2.0 build/updates/roga-0.2.0.zip --title "Roga 0.2.0" --notes-file <notes>
   ```

5. Copy `build/updates/appcast.xml` to `site/public/appcast.xml` and merge it to `main`. [`site.yml`](../.github/workflows/site.yml) deploys it to `https://roga.sh/appcast.xml`, the feed address in the Info.plist.
6. Update the Homebrew cask, once there is one.

Keep `build/updates` between releases. `generate_appcast` updates the `appcast.xml` it finds there, and it uses the zips of earlier releases to build smaller delta updates.

## Trying an update before a release

The notice for a new version ([decision 43](decisions/0043-show-a-new-version-in-the-sidebar-rather-than-sparkles-window.md)) and Sparkle's installing can be tried with two copies of a Debug build, a test key and an appcast served from this Mac. Nothing goes to roga.sh, GitHub or the keychain.

1. Make a test key in a file with Homebrew's OpenSSL, since the system's LibreSSL has no Ed25519, and print its public half for the Info.plist:

   ```bash
   /opt/homebrew/bin/openssl genpkey -algorithm ed25519 -out test-key.pem
   ```

   ```bash
   /opt/homebrew/bin/openssl pkey -in test-key.pem -pubout -outform DER | tail -c 32 | base64
   ```

2. Copy the Debug build twice, as `old/RogaUpd.app` and `new/RogaUpd.app`. In each copy's Info.plist, set `CFBundleIdentifier` to a test ID such as `sh.roga.test.update`, so that it has its own defaults and Application Support, set `SUFeedURL` to `http://127.0.0.1:8765/appcast.xml` and add `SUPublicEDKey` with the test key. Give the old copy a lower `CFBundleVersion` and `CFBundleShortVersionString` than the new one, such as 3 and 1.3 against 4 and 1.4, then sign each with `codesign --force --deep -s -`.
3. Zip the new copy with `ditto -c -k --sequesterRsrc --keepParent`, sign the zip, and write an `appcast.xml` beside it with one item whose enclosure has the zip's address, its `length` and that signature as `sparkle:edSignature`:

   ```bash
   /opt/homebrew/bin/openssl pkeyutl -sign -inkey test-key.pem -rawin -in RogaUpd-1.4.zip | base64
   ```

4. Serve that folder on this Mac only. Sparkle accepts an `http` feed because the update is signed, and logs a warning about it.

   ```bash
   python3 -m http.server 8765 --bind 127.0.0.1
   ```

5. Open the old copy. It has never checked, so Sparkle checks at once, and the arrow shows above the gear without Sparkle's window. To try Restart to Update, quit it, then turn on downloading and clear the last check, and open it again:

   ```bash
   defaults write sh.roga.test.update SUAutomaticallyUpdate -bool true
   ```

   ```bash
   defaults delete sh.roga.test.update SULastCheckTime
   ```

   Sparkle relaunches the installed copy through launchd, so it starts without any environment the old one was opened with, such as a different `HOME`.

6. Afterward, delete the test ID's defaults and its folders in `~/Library/Caches` and `~/Library/Application Support`.
