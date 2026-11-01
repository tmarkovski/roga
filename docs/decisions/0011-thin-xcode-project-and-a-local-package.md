# 11. Keep the Xcode project thin and the code in a local Swift package

Accepted on 2026-11-01.

## Context

yaga is a Mac app distributed outside the App Store, so it needs an Xcode project for its Info.plist, entitlements, asset catalog, signing settings and Sparkle. Xcode's traditional project file, `project.pbxproj`, is a property list full of generated identifiers. A single change in Xcode can touch many lines of it, and it's a common source of merge conflicts.

Xcode 27.2 made a JSON format the default for new projects. Its `project.xcproj` file sits inside the `.xcodeproj` bundle in place of `project.pbxproj`. It identifies files by name and path rather than by generated identifiers, so changes in it are easier to review and less likely to conflict. Apple publishes the format as an open-source Swift package, [xcode-project-format](https://github.com/apple/xcode-project-format).

We also considered generating the project with XcodeGen or Tuist. That keeps the project file out of the repository, but every contributor has to install another tool and regenerate the project after changes.

## Decision

- We commit an Xcode project in the JSON format. It contains only the app target, with its entry point, Info.plist, entitlements, assets, signing settings, and the Sparkle dependency.
- All other code lives in one local Swift package, YagaKit, with a library target for each module, the benchmark tool, and the tests. [ARCHITECTURE.md](../../ARCHITECTURE.md#project-layout) lists the modules.

## Consequences

- `swift build` and `swift test` work on the package from the command line and in CI, without opening the Xcode project.
- The package enforces the boundaries between modules: a module can only use another one that its target lists as a dependency.
- Contributors and CI machines need Xcode 27 or later, because older versions can't open the JSON format.
- Tools that read `project.pbxproj`, such as fastlane and the `xcodeproj` Ruby gem, don't understand the new format. yaga's release scripts call `xcodebuild`, `notarytool` and Sparkle's own tools directly.
- The format is new. Xcode 27 supports both formats, so if the JSON format causes trouble, we can switch the project back to the traditional one.
