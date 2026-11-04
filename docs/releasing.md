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

   It writes `build/updates/roga-0.2.0.zip` and updates `build/updates/appcast.xml`, signing the new entry with the key from the keychain.
4. Create a GitHub release for the tag with the zip attached. The appcast expects the zip at `https://github.com/tmarkovski/yaga/releases/download/v0.2.0/roga-0.2.0.zip`.

   ```bash
   gh release create v0.2.0 build/updates/roga-0.2.0.zip --title "Roga 0.2.0" --notes-file <notes>
   ```

5. Copy `build/updates/appcast.xml` to `site/public/appcast.xml` and merge it to `main`. [`site.yml`](../.github/workflows/site.yml) deploys it to `https://roga.sh/appcast.xml`, the feed address in the Info.plist.
6. Update the Homebrew cask, once there is one.

Keep `build/updates` between releases. `generate_appcast` updates the `appcast.xml` it finds there, and it uses the zips of earlier releases to build smaller delta updates.
