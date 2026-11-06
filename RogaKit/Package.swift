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
    name: "RogaKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RogaUI", targets: ["RogaUI"]),
        // What the `roga` helper inside Roga.app is built from. Each agent hook
        // runs the helper, so it links nothing but Foundation.
        .library(name: "AgentHooks", targets: ["AgentHooks"]),
        .executable(name: "roga-bench", targets: ["roga-bench"]),
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
        // Hearing from agents through their hooks: what the helper sends, how
        // Roga listens for it, and what the events mean for a session.
        .target(
            name: "AgentHooks",
            swiftSettings: settings
        ),
        // Running agents' command-line tools: finding them, installing Roga's
        // hooks in them, and writing commit messages with them.
        .target(
            name: "AgentEngine",
            dependencies: ["GitCore", "GitRunner"],
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
            dependencies: ["IconUI"],
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
            name: "RogaUI",
            dependencies: ["GitCore", "GitRunner", "CommitGraph", "RepositoryEngine", "AgentHooks", "AgentEngine", "HistoryUI", "DiffUI", "IconUI", "MenuUI"],
            swiftSettings: viewSettings
        ),
        .executableTarget(
            name: "roga-bench",
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
            name: "AgentHooksTests",
            dependencies: ["AgentHooks"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "AgentEngineTests",
            dependencies: ["AgentEngine", "GitCore", "GitRunner", "TestSupport"],
            swiftSettings: settings
        ),
        .testTarget(
            name: "DiffUITests",
            dependencies: ["DiffUI", "GitCore"],
            swiftSettings: viewSettings
        ),
        .testTarget(
            name: "RogaUITests",
            dependencies: ["RogaUI", "HistoryUI", "DiffUI", "IconUI", "MenuUI", "RepositoryEngine", "AgentHooks", "AgentEngine", "CommitGraph", "GitCore", "GitRunner", "TestSupport"],
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
