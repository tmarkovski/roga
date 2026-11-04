// swift-tools-version: 6.2
import PackageDescription

// Every target uses the Swift 6 language mode, which checks concurrency
// completely. These upcoming features match what Xcode calls approachable
// concurrency: a nonisolated async function runs on its caller's actor unless
// it's marked `@concurrent`, and a conformance can be isolated to an actor.
// Member import visibility makes each file import the modules it uses.
let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The view modules make the main actor their default isolation. The engine
// modules keep the normal default, where code isn't isolated unless it says so.
let viewSettings = settings + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "YagaKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "YagaUI", targets: ["YagaUI"]),
        .executable(name: "yaga-bench", targets: ["yaga-bench"]),
    ],
    targets: [
        .target(
            name: "GitCore",
            swiftSettings: settings
        ),
        .target(
            name: "GitRunner",
            dependencies: ["GitCore"],
            swiftSettings: settings
        ),
        .target(
            name: "CommitGraph",
            dependencies: ["GitCore"],
            swiftSettings: settings
        ),
        .target(
            name: "RepositoryEngine",
            dependencies: ["GitCore", "GitRunner", "CommitGraph"],
            swiftSettings: settings
        ),
        // The only target with resources. It doesn't make the main actor its default,
        // so that what SwiftPM generates to find them can be used from anywhere.
        .target(
            name: "IconUI",
            resources: [.process("Icons.xcassets"), .copy("LICENSE-lucide.txt")],
            swiftSettings: settings
        ),
        .target(
            name: "MenuUI",
            swiftSettings: viewSettings
        ),
        .target(
            name: "HistoryUI",
            dependencies: ["GitCore", "CommitGraph", "IconUI", "MenuUI"],
            swiftSettings: viewSettings
        ),
        .target(
            name: "DiffUI",
            dependencies: ["GitCore"],
            swiftSettings: viewSettings
        ),
        .target(
            name: "YagaUI",
            dependencies: ["GitCore", "GitRunner", "CommitGraph", "RepositoryEngine", "HistoryUI", "DiffUI", "IconUI", "MenuUI"],
            swiftSettings: viewSettings
        ),
        .executableTarget(
            name: "yaga-bench",
            dependencies: ["GitCore", "GitRunner", "CommitGraph", "RepositoryEngine", "HistoryUI", "DiffUI"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "GitCoreTests",
            dependencies: ["GitCore"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "GitRunnerTests",
            dependencies: ["GitCore", "GitRunner", "TestSupport"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "CommitGraphTests",
            dependencies: ["CommitGraph", "GitCore", "GitRunner", "TestSupport"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "RepositoryEngineTests",
            dependencies: ["RepositoryEngine", "CommitGraph", "GitCore", "GitRunner", "TestSupport"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "DiffUITests",
            dependencies: ["DiffUI", "GitCore"],
            swiftSettings: viewSettings
        ),
        .testTarget(
            name: "YagaUITests",
            dependencies: ["YagaUI", "HistoryUI", "DiffUI", "IconUI", "MenuUI", "RepositoryEngine", "CommitGraph", "GitCore", "GitRunner", "TestSupport"],
            swiftSettings: viewSettings
        ),
        // Shared by the test targets: the git the tests run, and the test
        // repositories that the scripts in Tests/Fixtures build.
        .target(
            name: "TestSupport",
            dependencies: ["GitRunner"],
            path: "Tests/TestSupport",
            swiftSettings: settings
        ),
    ]
)
