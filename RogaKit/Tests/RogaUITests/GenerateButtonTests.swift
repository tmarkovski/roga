import AgentEngine
import AppKit
import Foundation
import GitRunner
import SwiftUI
import Testing
@testable import RogaUI

/// What the Generate button, its popover and the Changes menu show for each
/// state of the agents, with a provider whose state is set rather than found,
/// and defaults of the test's own.
@Suite(.timeLimit(.minutes(1)), .removesTemporaryFolders)
struct GenerateButtonTests {
    let defaults: UserDefaults
    let defaultsName: String
    let folder: String

    init() throws {
        folder = try AgentTestSupport.folder()
        (defaults, defaultsName) = AgentTestSupport.defaults()
    }

    private func clean() {
        AgentTestSupport.remove(defaults, named: defaultsName)
    }

    private func found(_ kind: AgentKind) -> AgentLookup {
        .found(AgentInstallation(kind: kind, executable: "/nonexistent/bin/" + kind.rawValue, version: AgentVersion(major: 2, minor: 1, patch: 290)))
    }

    /// A provider that has found both agents, or the lookups given.
    private func provider(_ lookups: [AgentKind: AgentLookup]? = nil) -> AgentProvider {
        let provider = AgentTestSupport.provider(support: folder + "/support", defaults: defaults, codexHome: folder + "/codex")
        provider.setStateForTests(lookups: lookups ?? [.claude: found(.claude), .codex: found(.codex)], programs: Programs(searchPath: "/usr/bin"))
        return provider
    }

    // MARK: The button

    @Test func showsTheWordWhileTheBoxIsEmpty() {
        let state = GenerateButtonState(showsButton: true, agent: .claude, hasText: false, isWriting: false, readiness: .ready)
        #expect(state == .shown(agent: .claude, rewrites: false, readiness: .ready))
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .ready) == "Write the message with Claude Code (⌥\u{2009}⌘\u{2009}L)")
    }

    @Test func theWordNamesTheAgentAClickRuns() {
        #expect(GenerateButton<EmptyView>.title(agent: .claude) == "Generate with Claude")
        #expect(GenerateButton<EmptyView>.title(agent: .codex) == "Generate with Codex")
        #expect(GenerateButton<EmptyView>.rewriteTitle == "Rewrite")
    }

    @Test func showsTheIconAloneToRewriteYourWords() {
        let state = GenerateButtonState(showsButton: true, agent: .codex, hasText: true, isWriting: false, readiness: .ready)
        #expect(state == .shown(agent: .codex, rewrites: true, readiness: .ready))
        #expect(GenerateButton<EmptyView>.help(agent: .codex, rewrites: true, readiness: .ready) == "Rewrite with Codex, starting from your words (⌥\u{2009}⌘\u{2009}L)")
    }

    @Test func saysToStageFilesWhenNothingIsStaged() {
        let state = GenerateButtonState(showsButton: true, agent: .claude, hasText: false, isWriting: false, readiness: .nothingStaged)
        #expect(state == .shown(agent: .claude, rewrites: false, readiness: .nothingStaged))
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .nothingStaged) == "Stage files to write a message for them")
    }

    /// Grayed out, it doesn't offer a shortcut that can't run, and during a
    /// rebase it says why.
    @Test func saysWhyItWaits() {
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .busy) == "Write the message with Claude Code")
        #expect(GenerateButton<EmptyView>.help(agent: .codex, rewrites: true, readiness: .busy) == "Rewrite with Codex, starting from your words")
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: true, readiness: .rebasing) == "Claude Code can write a message once the rebase is done")
    }

    @Test func isHiddenWhenTurnedOffWithoutAnAgentOrWhileWriting() {
        #expect(GenerateButtonState(showsButton: false, agent: .claude, hasText: false, isWriting: false, readiness: .ready) == .hidden)
        #expect(GenerateButtonState(showsButton: true, agent: nil, hasText: false, isWriting: false, readiness: .ready) == .hidden)
        #expect(GenerateButtonState(showsButton: true, agent: .claude, hasText: false, isWriting: true, readiness: .busy) == .hidden)
    }

    @Test func hasNoAgentToRunUntilOneIsFoundAndOn() {
        defer { clean() }
        let provider = AgentTestSupport.provider(support: folder + "/support", defaults: defaults, codexHome: folder + "/codex")
        #expect(provider.generateAgent == nil)
        provider.setStateForTests(lookups: [.claude: .notFound, .codex: found(.codex)])
        #expect(provider.generateAgent == .codex)
        defaults.set(false, forKey: AgentPreferences.enabledKey(.codex))
        provider.reloadSettings()
        #expect(provider.generateAgent == nil)
    }

    // MARK: The popover

    @Test func describesEachAgentsModelAndEffort() {
        #expect(GeneratePopover.detail(.claude, model: "haiku", effort: "low", codexDefaultModel: nil) == "haiku · low effort")
        #expect(GeneratePopover.detail(.claude, model: "", effort: "", codexDefaultModel: "gpt-6-astra") == "default model · default effort")
        #expect(GeneratePopover.detail(.codex, model: "", effort: "", codexDefaultModel: "gpt-6-astra") == "gpt-6-astra · default effort")
        #expect(GeneratePopover.detail(.codex, model: "", effort: "high", codexDefaultModel: nil) == "default model · high effort")
        #expect(GeneratePopover.detail(.codex, model: "o5-mini", effort: "medium", codexDefaultModel: "gpt-6-astra") == "o5-mini · medium effort")
        // The picked agent's two menus say the same two halves.
        #expect(GeneratePopover.modelWords(.codex, model: "", codexDefaultModel: "gpt-6-astra") == "gpt-6-astra")
        #expect(GeneratePopover.modelWords(.claude, model: "", codexDefaultModel: "gpt-6-astra") == "default model")
        #expect(GeneratePopover.effortWords("") == "default effort")
        #expect(GeneratePopover.effortWords("high") == "high effort")
    }

    @Test func saysWhyAnAgentCantBePicked() {
        defer { clean() }
        let old = SkippedAgent(kind: .codex, executable: "/usr/local/bin/codex", reason: .tooOld(AgentVersion(major: 0, minor: 120)))
        let broken = SkippedAgent(kind: .codex, executable: "/usr/local/bin/codex", reason: .timedOut)
        let provider = provider([.claude: .notFound, .codex: .unusable([old])])
        #expect(GeneratePopover.unusableReason(.claude, in: provider) == "Not found")
        #expect(GeneratePopover.unusableReason(.codex, in: provider) == "Too old to use")
        provider.setStateForTests(lookups: [.claude: .configuredMissing("/nowhere/claude"), .codex: .configuredUnusable(broken)])
        #expect(GeneratePopover.unusableReason(.claude, in: provider) == "Not found")
        #expect(GeneratePopover.unusableReason(.codex, in: provider) == "Couldn't run it")
        provider.setStateForTests(lookups: [.claude: found(.claude)])
        #expect(GeneratePopover.unusableReason(.claude, in: provider) == nil)
        #expect(GeneratePopover.unusableReason(.codex, in: provider) == "Looking for it…")
        defaults.set(false, forKey: AgentPreferences.enabledKey(.claude))
        provider.reloadSettings()
        #expect(GeneratePopover.unusableReason(.claude, in: provider) == "Turned off")
    }

    @Test func offersEachAgentsModels() {
        #expect(GenerateChoices.models(for: .claude, stored: "haiku") == ["", "haiku", "sonnet", "opus"])
        #expect(GenerateChoices.models(for: .codex, stored: "") == [""])
        // A model typed on Codex's page in Settings is offered beside Default.
        #expect(GenerateChoices.models(for: .codex, stored: "gpt-6-astra") == ["", "gpt-6-astra"])
        #expect(GeneratePopover.modelTitle("", kind: .codex, codexDefaultModel: "gpt-6-astra") == "Default · gpt-6-astra")
        #expect(GeneratePopover.modelTitle("", kind: .codex, codexDefaultModel: nil) == "Default")
        #expect(GeneratePopover.modelTitle("", kind: .claude, codexDefaultModel: "gpt-6-astra") == "Default")
        #expect(GeneratePopover.modelTitle("sonnet", kind: .claude, codexDefaultModel: nil) == "sonnet")
    }

    @Test func showsTheCommandOfThePickedAgent() throws {
        defer { clean() }
        let provider = provider()
        provider.setGenerateAgent(.codex)
        let setup = try #require(provider.generation(with: provider.generateAgent))
        #expect(setup.kind == .codex)
        let lines = setup.terminal(worktree: "/tmp/work", hasDraft: false)
        #expect(lines.first == .comment("The staged changes go to its standard input"))
        guard case .program(let command, _)? = lines.last else {
            Issue.record("Expected the command")
            return
        }
        #expect(command.executable == "/nonexistent/bin/codex")
        #expect(command.arguments.first == "exec")
        #expect(command.directory == "/tmp/work")
    }

    /// The popover is the only place its command shows, so Codex's, which
    /// wraps onto more lines than a dialog's block shows before it scrolls,
    /// shows whole, with the room under its last line.
    @Test func showsCodexsCommandWhole() throws {
        defer { clean() }
        let provider = provider()
        // A model of its own and extra arguments make it longer still.
        defaults.set("gpt-6-astra-mini", forKey: AgentPreferences.modelKey(.codex))
        defaults.set(
            "-c model_verbosity=low -c model_reasoning_summary=none -c hide_agent_reasoning=true",
            forKey: AgentPreferences.extraArgumentsKey(.codex)
        )
        provider.reloadSettings()
        for kind in AgentKind.allCases {
            let setup = try #require(provider.generation(with: kind))
            let block = CommandBlock(lines: setup.terminal(worktree: "/Users/someone/git/acme/api", hasDraft: true), isCompact: true)
            let height = NSHostingView(rootView: block.frame(width: GeneratePopover.width)).fittingSize.height
            #expect(height < CommandBlock.compactMaximumHeight, "\(kind.name)'s command is cut at \(height) points")
            if kind == .codex {
                #expect(height > CommandBlock.maximumHeight)
            }
        }
    }

    /// The popover hangs from the button under it, so if it changed height
    /// when another agent is picked, every row above the command would move.
    /// Claude Code's command and Codex's wrap onto different numbers of lines.
    @Test func staysTheSameHeightWhicheverAgentIsPicked() throws {
        defer { clean() }
        let provider = provider()
        func height(_ view: some View) -> CGFloat {
            NSHostingView(rootView: view).fittingSize.height
        }
        var commands: [CGFloat] = []
        var popovers: [CGFloat] = []
        for kind in AgentKind.allCases {
            provider.setGenerateAgent(kind)
            let setup = try #require(provider.generation(with: kind))
            commands.append(height(
                CommandBlock(lines: setup.terminal(worktree: "/Users/someone/git/acme/api", hasDraft: false), isCompact: true)
                    .frame(width: GeneratePopover.width)
            ))
            popovers.append(height(
                GeneratePopover(
                    agents: provider, worktree: "/Users/someone/git/acme/api", hasDraft: false,
                    openAgentSettings: { _ in }, close: {}
                )
            ))
        }
        #expect(Set(commands).count > 1, "The commands are all \(commands) tall, so this shows nothing")
        #expect(Set(popovers).count == 1, "The popover is \(popovers) tall")
    }

    /// The picked agent's row has menus on its second line and the others
    /// have words, at the same height, so picking one moves nothing.
    @Test func aRowIsTheSameHeightPickedOrNot() {
        defer { clean() }
        let provider = provider([.claude: found(.claude), .codex: .notFound])
        func height(_ kind: AgentKind, isPicked: Bool) -> CGFloat {
            NSHostingView(rootView: GeneratePopoverAgentRow(kind: kind, agents: provider, isPicked: isPicked).frame(width: 380)).fittingSize.height
        }
        let picked = height(.claude, isPicked: true)
        #expect(height(.claude, isPicked: false) == picked)
        // One that can't be picked says why at the same height.
        #expect(height(.codex, isPicked: false) == picked)
    }

    // MARK: Grays

    /// The darkest gray in a view drawn in light on white, from 0 for black to
    /// 255 for white. A color counts by its lightest channel, so the brand's
    /// orange reads as light as it looks next to gray text.
    private static func darkestGray(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
        renderer.scale = 2
        var drawn: CGImage?
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance { drawn = renderer.cgImage }
        return try darkestGray(in: try #require(drawn))
    }

    /// The same for a view with an `NSView` in it, which `ImageRenderer` can't
    /// draw, in a window that's never shown.
    private static func darkestGrayInAWindow(_ view: some View) throws -> Int {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: hosting.fittingSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        return try darkestGray(in: try #require(bitmap.cgImage))
    }

    private static func darkestGray(in image: CGImage) throws -> Int {
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white)
        context.fill(bounds)
        context.draw(image, in: bounds)
        return stride(from: 0, to: pixels.count, by: 4).map { Int(max(pixels[$0], pixels[$0 + 1], pixels[$0 + 2])) }.min() ?? 255
    }

    private static func button(_ readiness: MessageGenerator.Readiness) -> some View {
        GenerateButton(agent: .claude, rewrites: false, readiness: readiness, isChoosing: .constant(false)) {} choices: { EmptyView() }
    }

    /// The canvas draws a Generate that can't be pressed in its secondary gray,
    /// `DialogColors.note`, #6b6b6b in light, which is dimmed no further.
    @Test func aGenerateThatCantRunIsTheSecondaryGray() throws {
        let gray = try Self.darkestGrayInAWindow(Self.button(.nothingStaged))
        #expect((0x55...0x80).contains(gray), "The darkest gray is \(String(gray, radix: 16))")
        #expect(try Self.darkestGrayInAWindow(Self.button(.ready)) < 0x40)
    }

    /// An agent that can't be picked says why in the same gray, so it can be read.
    @Test func anAgentThatCantBePickedIsTheSecondaryGray() throws {
        defer { clean() }
        let provider = provider([.claude: found(.claude), .codex: .notFound])
        let missing = try Self.darkestGray(GeneratePopoverAgentRow(kind: .codex, agents: provider, isPicked: false).frame(width: 300))
        #expect((0x55...0x80).contains(missing), "The darkest gray is \(String(missing, radix: 16))")
        #expect(try Self.darkestGray(GeneratePopoverAgentRow(kind: .claude, agents: provider, isPicked: true).frame(width: 300)) < 0x40)
    }

    // MARK: The Changes menu

    @Test func generateWithListsTheUsableAgentsWithTheirModels() {
        defer { clean() }
        let provider = provider()
        // Codex on its own default, which its config.toml names.
        provider.setStateForTests(codexDefaultModel: .some("gpt-6-astra"))
        #expect(RepositoryCommands.generateWithItems(provider) == [
            .init(kind: .claude, title: "Claude Code · haiku", isCurrent: true),
            .init(kind: .codex, title: "Codex · gpt-6-astra", isCurrent: false),
        ])
        defaults.set("o5-mini", forKey: AgentPreferences.modelKey(.codex))
        provider.reloadSettings()
        provider.setGenerateAgent(.codex)
        #expect(RepositoryCommands.generateWithItems(provider) == [
            .init(kind: .claude, title: "Claude Code · haiku", isCurrent: false),
            .init(kind: .codex, title: "Codex · o5-mini", isCurrent: true),
        ])
    }

    @Test func generateWithNamesTheAgentAloneWhenItsDefaultIsUnknown() {
        defer { clean() }
        let provider = provider()
        #expect(provider.codexDefaultModel == nil)
        #expect(RepositoryCommands.generateWithItems(provider).map(\.title) == ["Claude Code · haiku", "Codex"])
        // Claude Code's own default isn't one Roga can read.
        defaults.set("", forKey: AgentPreferences.modelKey(.claude))
        provider.reloadSettings()
        provider.setStateForTests(codexDefaultModel: .some("gpt-6-astra"))
        #expect(RepositoryCommands.generateWithItems(provider).map(\.title) == ["Claude Code", "Codex · gpt-6-astra"])
    }

    @Test func generateWithLeavesOutAgentsThatCantRun() {
        defer { clean() }
        let provider = provider([.claude: found(.claude), .codex: .notFound])
        #expect(RepositoryCommands.generateWithItems(provider).map(\.title) == ["Claude Code · haiku"])
        defaults.set(false, forKey: AgentPreferences.enabledKey(.claude))
        provider.reloadSettings()
        #expect(RepositoryCommands.generateWithItems(provider).isEmpty)
    }

    @Test func theShortcutPairsWithWriteMessage() {
        #expect(RepositoryCommands.generateMessageShortcut == KeyboardShortcut("l", modifiers: [.option, .command]))
        #expect(RepositoryCommands.writeMessageShortcut.key == RepositoryCommands.generateMessageShortcut.key)
    }
}
