// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WindowTabsPreview",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "yaga-tabs",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
