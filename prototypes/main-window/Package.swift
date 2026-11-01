// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MainWindowPreview",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "yaga-main-window",
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
    ]
)
