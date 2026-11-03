# yaga

Yet Another Git App. A fast, native Git client for macOS, written in Swift.

https://yaga.build

See [VISION.md](VISION.md) for what yaga is trying to be, [ROADMAP.md](ROADMAP.md) for the order of the work, [ARCHITECTURE.md](ARCHITECTURE.md) for how the app is put together, and [docs/decisions](docs/decisions/README.md) for the decisions behind it.

The landing page is in [site](site/README.md).

## Building

yaga needs macOS 26 or later and Xcode 27.2, which is the first version to create projects in the JSON format that `Yaga.xcodeproj` uses. Open `Yaga.xcodeproj` and run the Yaga scheme. Development builds are signed to run on your own Mac, so you don't need a developer account.

Almost all of the code is in the YagaKit package, which you can build and test without the Xcode project:

```bash
swift test --package-path YagaKit
```

## License

yaga is licensed under the [Apache License 2.0](LICENSE).
