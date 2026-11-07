# Releasing

Roga is distributed outside the Mac App Store, signed with a Developer ID certificate, notarized by Apple, and updated through Sparkle (decision 1). GitHub Actions builds each release, the same way it builds Errol's, and [Scripts/release/release.py](../Scripts/release/release.py) does the work in each step, so every step can also run on a Mac.

Roga's code is in a private repository, and a private repository's releases can't be downloaded without signing in. So the downloads and the Homebrew cask each have a public repository of their own, with no code in either:

- **[tmarkovski/roga-releases](https://github.com/tmarkovski/roga-releases)** has a GitHub release for each version, with the ZIP that Sparkle and Homebrew download, the DMG people download from roga.sh, and the update feed.
- **[tmarkovski/homebrew-roga](https://github.com/tmarkovski/homebrew-roga)** is the Homebrew tap, with the cask at `Casks/roga.rb`, so people install Roga with:

  ```bash
  brew install --cask tmarkovski/roga/roga
  ```

## How a release works

1. Pushing a tag like `v0.1.0` from `main` starts the [Release workflow](../.github/workflows/release.yml). It runs RogaKit's tests, archives the app with Developer ID, notarizes and staples it, packs the ZIP and the DMG, notarizes the DMG, checks both with [Scripts/verify-artifact.sh](../Scripts/verify-artifact.sh), writes the update feed, and publishes all of it as a **prerelease** in `roga-releases`. The debug symbols go to a release of the same tag in this repository, since they'd show the code's structure to anyone.
2. Installed copies don't see it yet. They read `https://roga.sh/appcast.xml`, which [site/public/_redirects](../site/public/_redirects) points at the feed in the latest release of `roga-releases`, and GitHub never counts a prerelease as the latest. `roga.sh/download` points at the latest release's `Roga.dmg` the same way.
3. Try the update on a real Mac by pointing a copy of Roga at the prerelease's own feed, choosing Check for Updates, and confirming that Roga relaunches and agents' marks still come through:

   ```bash
   defaults write sh.roga.app SUFeedURL https://github.com/tmarkovski/roga-releases/releases/download/v0.1.0/appcast.xml
   ```

   ```bash
   defaults delete sh.roga.app SUFeedURL
   ```

4. Run the [Publish workflow](../.github/workflows/publish.yml). It makes the prerelease the latest release, so every installed copy is offered the update, writes the cask for it into the tap, and checks that `roga.sh/appcast.xml` offers the new build. Errol's workflow waits for a reviewer to approve this step instead, but GitHub only enforces required reviewers in a private repository on its Enterprise plan, so starting the workflow by hand is the approval here.

The version is the tag without its `v`, and the build number, which Sparkle compares, is the number of commits on `main`. The project's own `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` only matter to development builds, which never check for updates: their build number is 1, so every release would look newer to them.

Started by hand from the Actions tab, the Release workflow is a dry run. It signs ad hoc, needs no credentials, and keeps the app, the ZIP and the DMG as workflow artifacts.

## Setting it up

This is done once. Every value below is a credential, so none of it goes into the repository, and each `gh secret set` asks for its value rather than taking it on the command line. Roga ships under the same team as Errol, TM Code & Co. LLC (`JN3SN725AZ`), so the certificate and the notarization key are the ones Errol's secrets already hold.

1. **The Developer ID certificate**, exported with its private key as a `.p12`, and the password it was exported with:

   ```bash
   base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_CERT_P12 --repo tmarkovski/roga
   ```

   ```bash
   gh secret set DEVELOPER_ID_CERT_PASSWORD --repo tmarkovski/roga
   ```

2. **The App Store Connect API key for notarization.** The Issuer ID is shown above the list of keys in App Store Connect, under Users and Access → Integrations → App Store Connect API, and the Key ID is in the key's row.

   ```bash
   gh secret set NOTARY_ISSUER_ID --repo tmarkovski/roga
   ```

   ```bash
   gh secret set NOTARY_KEY_ID --repo tmarkovski/roga
   ```

   ```bash
   base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY_P8 --repo tmarkovski/roga
   ```

   For notarizing on a Mac, the same key goes into the keychain under the profile name the release script uses:

   ```bash
   xcrun notarytool store-credentials roga-notary --key AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer YOUR-ISSUER-ID
   ```

3. **Sparkle's signing key.** Sparkle checks every update against the public key in [App/Info.plist](../App/Info.plist), `SUPublicEDKey`, so the private key that signs updates must never be lost or shared. If it's lost, the copies of Roga that people already have can't install any later update. Roga has a key of its own, made on 2026-11-07, apart from Errol's. Its backup is the password of "Sparkle for Roga" in Passwords, and on the Mac that made it, the login keychain has it under the account `roga`. Paste it into the secret:

   ```bash
   gh secret set SPARKLE_ED_PRIVATE_KEY --repo tmarkovski/roga
   ```

   To put it in another Mac's keychain, save it to a file, import it, and delete the file:

   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account roga -f <file>
   ```

4. **The two public repositories**, `tmarkovski/roga-releases` and `tmarkovski/homebrew-roga`, each with a README, because a release tags its repository's default branch and the cask is pushed onto it.

5. **A token for publishing to them.** The workflows' own token can only write to this repository. Make a fine-grained personal access token whose resource owner is `tmarkovski`, limited to `roga-releases` and `homebrew-roga`, with read and write access to Contents and nothing else, and save it:

   ```bash
   gh secret set RELEASES_TOKEN --repo tmarkovski/roga
   ```

   Fine-grained tokens expire, so note the date it does. A release after that fails at its first step that writes to `roga-releases`, before anything is published.

## Making a release

1. Write the release notes in `docs/release-notes/0.1.0.md`, and merge them to `main`. They show on the release and in Sparkle's update window, and the Release workflow stops if they're missing.
2. Tag `main` and push the tag:

   ```bash
   git fetch origin && git tag v0.1.0 origin/main
   ```

   ```bash
   git push origin v0.1.0
   ```

3. When the Release workflow finishes, its summary says how to try the prerelease. Try it.
4. Publish it:

   ```bash
   gh workflow run publish.yml --repo tmarkovski/roga -f version=0.1.0
   ```

For the first release, the site's download link has nothing to point at until the Publish workflow has run, so merge the change to `site/public/index.html` after that.

## Running the steps on a Mac

Each step of the workflow is a command of the release script, which `uv` runs with its own dependencies. On a Mac, notarizing uses the `roga-notary` profile and the feed is signed with the key in the keychain:

```bash
uv run Scripts/release/release.py archive --version 0.1.0 --build 212 --out build/release
```

```bash
uv run Scripts/release/release.py notarize build/release/Roga.app
```

```bash
uv run Scripts/release/release.py zip build/release/Roga.app dist/Roga-0.1.0.zip
```

```bash
uv run Scripts/release/release.py dmg build/release/Roga.app dist/Roga-0.1.0.dmg --sign
```

```bash
uv run Scripts/release/release.py notarize dist/Roga-0.1.0.dmg
```

```bash
Scripts/verify-artifact.sh build/release/Roga.app
```

```bash
uv run Scripts/release/release.py appcast dist/Roga-0.1.0.zip --tag v0.1.0 --out dist
```

`archive --signing adhoc` builds without the Developer ID certificate, for trying the packaging without it.

## Trying an update before a release

The notice for a new version ([decision 43](decisions/0043-show-a-new-version-in-the-sidebar-rather-than-sparkles-window.md)) and Sparkle's installing can be tried with two builds and a feed served from this Mac. Nothing goes to roga.sh, GitHub or the keychain. Build an old and a new copy ad hoc, the new one with the higher build number:

```bash
uv run Scripts/release/release.py archive --version 0.1.0 --build 1 --signing adhoc --out build/rehearsal/old
```

```bash
uv run Scripts/release/release.py archive --version 0.1.1 --build 2 --signing adhoc --out build/rehearsal/new
```

Then rehearse the update:

```bash
uv run Scripts/release/release.py rehearse build/rehearsal/old/Roga.app build/rehearsal/new/Roga.app --work build/rehearsal/work
```

It gives both copies the bundle identifier `sh.roga.test.update`, so they have their own settings and Application Support and never touch the Roga you use every day. It makes them trust a throwaway Sparkle key and a feed at `http://127.0.0.1:8765`, writes that feed with a delta from the old copy, installs the old copy in `build/rehearsal/work/install`, serves the feed until interrupted, and prints what to try. Sparkle accepts an `http` feed because the update is signed, and logs a warning about it. It relaunches the installed copy through launchd, so the copy starts without any environment the old one was opened with, such as a different `HOME`.
