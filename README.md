# Roga

Rather Opinionated Git App. A fast, native Git client for macOS, written in Swift.

https://roga.sh

See [VISION.md](VISION.md) for what Roga is trying to be, [ROADMAP.md](ROADMAP.md) for the order of the work, [ARCHITECTURE.md](ARCHITECTURE.md) for how the app is put together, [docs/decisions](docs/decisions/README.md) for the decisions behind it, and [docs/performance](docs/performance/README.md) for what's been measured and improved.

The landing page is in [site](site/README.md).

## Installing

Roga needs macOS 26 or later. Download it from [roga.sh](https://roga.sh), or install it with Homebrew:

```bash
brew install --cask tmarkovski/roga/roga
```

It keeps itself up to date with Sparkle.

## Building

Roga needs macOS 26 or later and Xcode 27.2, which is the first version to create projects in the JSON format that `Roga.xcodeproj` uses. Open `Roga.xcodeproj` and run the Roga scheme. Development builds are signed to run on your own Mac, so you don't need a developer account.

Almost all of the code is in the RogaKit package, which you can build and test without the Xcode project:

```bash
swift test --package-path RogaKit
```

## License

Roga is licensed under the [Apache License 2.0](LICENSE).
