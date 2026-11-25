import AgentEngine
import AppKit
import Foundation
import GitRunner
import MenuUI
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
        let state = GenerateButtonState(agent: .claude, hasText: false, isWriting: false, readiness: .ready)
        #expect(state == .shown(agent: .claude, rewrites: false, readiness: .ready))
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .ready) == "Generate a commit message with Claude Code (⌥\u{2009}⌘\u{2009}L)")
    }

    @Test func theWordNamesTheAgentAClickRuns() {
        #expect(GenerateButton<EmptyView>.title(agent: .claude) == "Generate with Claude")
        #expect(GenerateButton<EmptyView>.title(agent: .codex) == "Generate with Codex")
        #expect(GenerateButton<EmptyView>.rewriteTitle == "Rewrite")
    }

    @Test func showsTheIconAloneToRewriteYourWords() {
        let state = GenerateButtonState(agent: .codex, hasText: true, isWriting: false, readiness: .ready)
        #expect(state == .shown(agent: .codex, rewrites: true, readiness: .ready))
        #expect(GenerateButton<EmptyView>.help(agent: .codex, rewrites: true, readiness: .ready) == "Rewrite the commit message with Codex using the current draft (⌥\u{2009}⌘\u{2009}L)")
    }

    @Test func saysToStageFilesWhenNothingIsStaged() {
        let state = GenerateButtonState(agent: .claude, hasText: false, isWriting: false, readiness: .nothingStaged)
        #expect(state == .shown(agent: .claude, rewrites: false, readiness: .nothingStaged))
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .nothingStaged) == "Stage changes to generate a commit message")
    }

    /// Grayed out, it doesn't offer a shortcut that can't run, and during a
    /// rebase it says why.
    @Test func saysWhyItWaits() {
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: false, readiness: .busy) == "Generate a commit message with Claude Code")
        #expect(GenerateButton<EmptyView>.help(agent: .codex, rewrites: true, readiness: .busy) == "Rewrite the commit message with Codex using the current draft")
        #expect(GenerateButton<EmptyView>.help(agent: .claude, rewrites: true, readiness: .rebasing) == "Finish the rebase to generate a commit message")
    }

    @Test func isHiddenWithoutAnAgentOrWhileWriting() {
        #expect(GenerateButtonState(agent: nil, hasText: false, isWriting: false, readiness: .ready) == .hidden)
        #expect(GenerateButtonState(agent: .claude, hasText: false, isWriting: true, readiness: .busy) == .hidden)
    }

    @Test func hasNoAgentToRunUntilOneIsFoundOrWhileAgentsAreOff() {
        defer { clean() }
        let provider = AgentTestSupport.provider(support: folder + "/support", defaults: defaults, codexHome: folder + "/codex")
        #expect(provider.defaultAgent == nil)
        provider.setStateForTests(lookups: [.claude: .notFound, .codex: found(.codex)])
        #expect(provider.defaultAgent == .known(.codex))
        defaults.set(false, forKey: AgentPreferences.usesAgentsKey)
        provider.reloadSettings()
        #expect(provider.defaultAgent == nil)
        #expect(provider.generation() == nil)
    }

    // MARK: The popover

    @Test func describesEachAgentsModelAndEffort() {
        #expect(AgentPopover.detail(.claude, model: "haiku", effort: "low", codexDefaultModel: nil) == "haiku · low effort")
        #expect(AgentPopover.detail(.claude, model: "", effort: "", codexDefaultModel: "gpt-6-astra") == "default model · default effort")
        #expect(AgentPopover.detail(.codex, model: "", effort: "", codexDefaultModel: "gpt-6-astra") == "gpt-6-astra · default effort")
        #expect(AgentPopover.detail(.codex, model: "", effort: "high", codexDefaultModel: nil) == "default model · high effort")
        #expect(AgentPopover.detail(.codex, model: "o5-mini", effort: "medium", codexDefaultModel: "gpt-6-astra") == "o5-mini · medium effort")
        // The picked agent's two menus say the same two halves.
        #expect(AgentPopover.modelWords(.codex, model: "", codexDefaultModel: "gpt-6-astra") == "gpt-6-astra")
        #expect(AgentPopover.modelWords(.claude, model: "", codexDefaultModel: "gpt-6-astra") == "default model")
        #expect(AgentPopover.effortWords("") == "default effort")
        #expect(AgentPopover.effortWords("high") == "high effort")
    }

    @Test func saysWhyAnAgentCantBePicked() {
        defer { clean() }
        let old = SkippedAgent(kind: .codex, executable: "/usr/local/bin/codex", reason: .tooOld(AgentVersion(major: 0, minor: 120)))
        let broken = SkippedAgent(kind: .codex, executable: "/usr/local/bin/codex", reason: .timedOut)
        let provider = provider([.claude: .notFound, .codex: .unusable([old])])
        #expect(AgentPopover.unusableReason(.claude, in: provider) == "Not found")
        #expect(AgentPopover.unusableReason(.codex, in: provider) == "Unsupported version")
        provider.setStateForTests(lookups: [.claude: .configuredMissing("/nowhere/claude"), .codex: .configuredUnusable(broken)])
        #expect(AgentPopover.unusableReason(.claude, in: provider) == "Not found")
        #expect(AgentPopover.unusableReason(.codex, in: provider) == "Unable to run")
        provider.setStateForTests(lookups: [.claude: found(.claude)])
        #expect(AgentPopover.unusableReason(.claude, in: provider) == nil)
        #expect(AgentPopover.unusableReason(.codex, in: provider) == "Searching…")
    }

    @Test func offersEachAgentsModels() {
        #expect(GenerateChoices.models(for: .claude, stored: "haiku") == ["", "haiku", "sonnet", "opus"])
        #expect(GenerateChoices.models(for: .codex, stored: "") == [""])
        // A model typed on Codex's page in Settings is offered beside Default.
        #expect(GenerateChoices.models(for: .codex, stored: "gpt-6-astra") == ["", "gpt-6-astra"])
        #expect(AgentPopover.modelTitle("", kind: .codex, codexDefaultModel: "gpt-6-astra") == "Default · gpt-6-astra")
        #expect(AgentPopover.modelTitle("", kind: .codex, codexDefaultModel: nil) == "Default")
        #expect(AgentPopover.modelTitle("", kind: .claude, codexDefaultModel: "gpt-6-astra") == "Default")
        #expect(AgentPopover.modelTitle("sonnet", kind: .claude, codexDefaultModel: nil) == "sonnet")
    }

    @Test func showsTheCommandOfThePickedAgent() throws {
        defer { clean() }
        let provider = provider()
        provider.setDefaultAgent(.known(.codex))
        let setup = try #require(provider.generation(with: provider.defaultAgent))
        #expect(setup.id == .known(.codex))
        let lines = setup.terminal(worktree: "/tmp/work", hasDraft: false)
        #expect(lines.first == .comment("Staged diff supplied via standard input"))
        guard case .program(let command, _)? = lines.last else {
            Issue.record("Expected the command")
            return
        }
        #expect(command.executable == "/nonexistent/bin/codex")
        #expect(command.arguments.first == "exec")
        #expect(command.directory == "/tmp/work")
    }

    /// What a menu's options say, whether each is checked, and what each does.
    private static func options(_ entries: [RefMenu.Entry]) -> [(title: String, isChecked: Bool, action: () -> Void)] {
        entries.compactMap { entry in
            if case let .option(title, isChecked, action) = entry { (title.plain, isChecked, action) } else { nil }
        }
    }

    /// A card's ⋯ has Model and Effort as submenus whose rows name what's
    /// chosen, as the sidebar's Sort by does, then the agent's page.
    @Test func theOptionsMenuNamesWhatsChosen() throws {
        final class Picked {
            var model: String?
            var effort: String?
        }
        let picked = Picked()
        let entries = AgentPopover.options(
            .claude, model: "haiku", effort: "low", codexDefaultModel: nil,
            setModel: { picked.model = $0 }, setEffort: { picked.effort = $0 }, openSettings: {}
        )
        try #require(entries.count == 4)
        guard case let .submenu(model, modelValue, _, models) = entries[0],
              case let .submenu(effort, effortValue, _, efforts) = entries[1],
              case .divider = entries[2],
              case let .command(settings, _, _, _, _) = entries[3]
        else {
            Issue.record("Expected Model, Effort and the agent's page")
            return
        }
        #expect(model.plain == "Model")
        #expect(modelValue == "haiku")
        #expect(effort.plain == "Effort")
        #expect(effortValue == "Low")
        #expect(settings.plain == "Claude Code settings…")
        let modelOptions = Self.options(models)
        #expect(modelOptions.map(\.title) == ["Default", "haiku", "sonnet", "opus"])
        #expect(modelOptions.map(\.isChecked) == [false, true, false, false])
        modelOptions[2].action()
        #expect(picked.model == "sonnet")
        let effortOptions = Self.options(efforts)
        #expect(effortOptions.map(\.title) == ["Default", "Low", "Medium", "High"])
        effortOptions[3].action()
        #expect(picked.effort == "high")
    }

    /// Codex's models end with Another model…, which opens its page, and in a
    /// dialog, where Settings can't open, neither that nor the page is there.
    @Test func aDialogsOptionsLeaveOutSettings() throws {
        let entries = AgentPopover.options(.codex, model: "", effort: "", codexDefaultModel: "gpt-6-astra", setModel: { _ in }, setEffort: { _ in }, openSettings: {})
        guard case let .submenu(_, value, _, models) = try #require(entries.first), case let .command(another, _, _, _, _)? = models.last else {
            Issue.record("Expected Model with Another model… at its end")
            return
        }
        #expect(value == "Default · gpt-6-astra")
        #expect(another.plain == "Another model…")
        let inDialog = AgentPopover.options(.codex, model: "", effort: "", codexDefaultModel: "gpt-6-astra", setModel: { _ in }, setEffort: { _ in }, openSettings: nil)
        #expect(inDialog.count == 2)
        guard case let .submenu(_, _, _, dialogModels) = try #require(inDialog.first) else {
            Issue.record("Expected Model")
            return
        }
        #expect(Self.options(dialogModels).count == dialogModels.count)
        #expect(AgentPopover.settingsEntries("Ollama", open: nil).isEmpty)
    }

    /// Resolve's and Fix's popovers show the command that job runs, with the
    /// same agent and flags and its own prompt and input.
    @Test func showsTheCommandOfEachJob() throws {
        defer { clean() }
        let provider = provider()
        let setup = try #require(provider.generation(with: .known(.claude)))
        let worktree = "/tmp/work"
        #expect(setup.terminal(for: .generate(hasDraft: true), worktree: worktree) == setup.terminal(worktree: worktree, hasDraft: true))
        #expect(setup.terminal(for: .resolve, worktree: worktree) == [
            .comment("Conflicts supplied via standard input"),
            .program(ConflictResolutionWriter.command(for: setup.agent, worktree: worktree), showsPath: setup.showsPath),
        ])
        #expect(setup.terminal(for: .fix, worktree: worktree) == [
            .comment("Git output and diagnostics supplied via standard input"),
            .program(GitFixWriter.command(for: setup.agent, worktree: worktree), showsPath: setup.showsPath),
        ])
    }

    /// The line under the cards says the pick is stored, and that the other
    /// two jobs run the same agent (decision 89).
    @Test func saysWhichJobsUseTheSameAgent() {
        #expect(AgentJob.generate(hasDraft: false).sharedNote == "Selection saved automatically. Resolve and Fix use the same agent.")
        #expect(AgentJob.resolve.sharedNote == "Selection saved automatically. Generate and Fix use the same agent.")
        #expect(AgentJob.fix.sharedNote == "Selection saved automatically. Generate and Resolve use the same agent.")
        #expect(AgentJob.generate(hasDraft: true).input(isCustom: true) == "Instructions and staged diff supplied via standard input")
        #expect(AgentJob.resolve.input(isCustom: true) == "Instructions and conflicts supplied via standard input")
        #expect(AgentJob.fix.input(isCustom: false) == "Git output and diagnostics supplied via standard input")
    }

    /// The popover is the only place its command shows, so Codex's, which
    /// wraps onto more lines than a dialog's block shows before it scrolls,
    /// shows whole, with the room under its last line.
    @Test func showsCodexsCommandWhole() throws {
        defer { clean() }
        let provider = provider()
        // A model of its own and the MCP servers it turns off make it longer
        // still.
        defaults.set("gpt-6-astra-mini", forKey: AgentPreferences.modelKey(.codex))
        provider.reloadSettings()
        provider.setStateForTests(codexMCPServers: ["node_repl", "docs", "github"])
        for kind in AgentKind.allCases {
            let setup = try #require(provider.generation(with: .known(kind)))
            let block = CommandBlock(lines: setup.terminal(worktree: "/Users/someone/git/acme/api", hasDraft: true), isCompact: true)
            let height = NSHostingView(rootView: block.frame(width: AgentPopover.width)).fittingSize.height
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
        for kind in AgentKind.allCases {
            let setup = try #require(provider.generation(with: .known(kind)))
            commands.append(height(
                CommandBlock(lines: setup.terminal(worktree: "/Users/someone/git/acme/api", hasDraft: false), isCompact: true)
                    .frame(width: AgentPopover.width)
            ))
        }
        #expect(Set(commands).count > 1, "The commands are all \(commands) tall, so this shows nothing")
        // Resolve's and Fix's popovers keep their height too, with their own commands.
        for job in [AgentJob.generate(hasDraft: false), .resolve, .fix] {
            var popovers: [CGFloat] = []
            for kind in AgentKind.allCases {
                provider.setDefaultAgent(.known(kind))
                popovers.append(height(
                    AgentPopover(agents: provider, job: job, worktree: "/Users/someone/git/acme/api", openAgentSettings: { _ in }, close: {})
                ))
            }
            #expect(Set(popovers).count == 1, "\(job)'s popover is \(popovers) tall")
        }
    }

    /// The picked agent's card has an ink edge and the others a line, at the
    /// same height, so picking one moves nothing.
    @Test func aRowIsTheSameHeightPickedOrNot() {
        defer { clean() }
        let provider = provider([.claude: found(.claude), .codex: .notFound])
        func height(_ kind: AgentKind, isPicked: Bool) -> CGFloat {
            NSHostingView(rootView: AgentPopoverRow(kind: kind, agents: provider, isPicked: isPicked).frame(width: 380)).fittingSize.height
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
        let missing = try Self.darkestGray(AgentPopoverRow(kind: .codex, agents: provider, isPicked: false).frame(width: 300))
        #expect((0x55...0x80).contains(missing), "The darkest gray is \(String(missing, radix: 16))")
        #expect(try Self.darkestGray(AgentPopoverRow(kind: .claude, agents: provider, isPicked: true).frame(width: 300)) < 0x40)
    }

    // MARK: The Changes menu

    @Test func generateWithListsTheUsableAgentsWithTheirModels() {
        defer { clean() }
        let provider = provider()
        // Codex on its own default, which its config.toml names.
        provider.setStateForTests(codexDefaultModel: .some("gpt-6-astra"))
        #expect(RepositoryCommands.generateWithItems(provider) == [
            .init(id: .known(.claude), title: "Claude Code · haiku", isCurrent: true),
            .init(id: .known(.codex), title: "Codex · gpt-6-astra", isCurrent: false),
        ])
        defaults.set("o5-mini", forKey: AgentPreferences.modelKey(.codex))
        provider.reloadSettings()
        provider.setDefaultAgent(.known(.codex))
        #expect(RepositoryCommands.generateWithItems(provider) == [
            .init(id: .known(.claude), title: "Claude Code · haiku", isCurrent: false),
            .init(id: .known(.codex), title: "Codex · o5-mini", isCurrent: true),
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
        // With agents off, it offers none.
        provider.setUsesAgents(false)
        #expect(RepositoryCommands.generateWithItems(provider).isEmpty)
    }

    @Test func generateWithListsCustomAgentsLast() {
        defer { clean() }
        let provider = provider([.claude: found(.claude), .codex: .notFound])
        let ollama = provider.addCustomAgent(name: "Ollama", command: "ollama run qwen2.5-coder:7b")
        #expect(RepositoryCommands.generateWithItems(provider) == [
            .init(id: .known(.claude), title: "Claude Code · haiku", isCurrent: true),
            .init(id: .custom(ollama.id), title: "Ollama", isCurrent: false),
        ])
        provider.setDefaultAgent(.custom(ollama.id))
        #expect(RepositoryCommands.generateWithItems(provider).map(\.isCurrent) == [false, true])
    }

    @Test func runsACustomAgentsCommandWithItsInstructionsOnStandardInput() throws {
        defer { clean() }
        let provider = provider([.claude: .notFound, .codex: .notFound])
        let ollama = provider.addCustomAgent(name: " Ollama ", command: "ollama run qwen2.5-coder:7b ")
        #expect(provider.defaultAgent == .custom(ollama.id))
        let setup = try #require(provider.generation())
        #expect(setup.named == NamedAgent(id: .custom(ollama.id), name: "Ollama", shortName: "Ollama"))
        #expect(setup.label == "Ollama")
        let lines = setup.terminal(worktree: "/tmp/work", hasDraft: false)
        #expect(lines.first == .comment("Instructions and staged diff supplied via standard input"))
        guard case .program(let command, let showsPath)? = lines.last else {
            Issue.record("Expected the command")
            return
        }
        #expect(command.executable == "/bin/sh")
        #expect(command.arguments == ["-c", "ollama run qwen2.5-coder:7b"])
        #expect(command.directory == "/tmp/work")
        #expect(!showsPath)
    }

    @Test func theShortcutPairsWithWriteMessage() {
        #expect(RepositoryCommands.generateMessageShortcut == KeyboardShortcut("l", modifiers: [.option, .command]))
        #expect(RepositoryCommands.writeMessageShortcut.key == RepositoryCommands.generateMessageShortcut.key)
    }
}
