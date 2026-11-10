import AgentEngine
import AgentHooks
import AppKit
import Foundation
import GitCore
import GitRunner
import IconUI
import Synchronization
import SwiftUI
import Testing
@testable import RogaUI

/// What Settings' Commit and Agents pages and each agent's page say and offer,
/// for each state the provider and the monitor can be in, which tests set
/// through the provider's test hook or with fake `claude` and `codex` scripts.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SettingsPagesTests {
    let folder: String
    let bin: String
    let support: String
    let codexHome: String
    let log: String
    let defaults: UserDefaults
    let defaultsName: String
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Agents at paths that can't exist, so that nothing a test does with
    /// them could run the claude or codex installed on this Mac.
    static let claude = AgentInstallation(kind: .claude, executable: "/nonexistent/bin/claude", version: AgentVersion(major: 2, minor: 1, patch: 286))
    static let codex = AgentInstallation(kind: .codex, executable: "/nonexistent/bin/codex", version: AgentVersion(major: 0, minor: 166, patch: 0))
    /// One in the home folder, for how its path is drawn with `~`. There's
    /// nothing there either.
    static let homeClaude = AgentInstallation(kind: .claude, executable: NSHomeDirectory() + "/nonexistent/bin/claude", version: AgentVersion(major: 2, minor: 1, patch: 286))

    init() throws {
        folder = try AgentTestSupport.folder()
        bin = folder + "/bin"
        support = folder + "/support"
        codexHome = folder + "/codex"
        log = folder + "/runs.log"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: codexHome, withIntermediateDirectories: true)
        (defaults, defaultsName) = AgentTestSupport.defaults()
    }

    private func clean() {
        AgentTestSupport.remove(defaults, named: defaultsName)
    }

    /// A provider that hasn't started, so it finds and runs nothing, in the
    /// state a test gives it.
    private func provider(helper: Bool = true, lookups: [AgentKind: AgentLookup], hookStatus: [AgentKind: HookStatus] = [:], hookWork: [AgentKind: AgentProvider.HookWork] = [:]) -> AgentProvider {
        let provider = AgentTestSupport.provider(support: support, helperPath: helper ? bin + "/roga" : nil, defaults: defaults, codexHome: codexHome)
        provider.setStateForTests(lookups: lookups, hookStatus: hookStatus, hookWork: hookWork)
        return provider
    }

    /// A provider with both fake agents, started and done looking, so that it
    /// has an installer and the commands it shows are the ones it would run.
    private func started(helper: Bool = true) async throws -> AgentProvider {
        try AgentTestSupport.claude(in: bin, log: log)
        try AgentTestSupport.codex(in: bin, log: log)
        let helperPath = helper ? try AgentTestSupport.script("exit 0", named: "roga", in: folder) : nil
        let provider = AgentTestSupport.provider(support: support, helperPath: helperPath, defaults: defaults, codexHome: codexHome)
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { !provider.isLooking && provider.hookStatus.count == 2 })
        return provider
    }

    private func line(_ kind: AgentKind, _ provider: AgentProvider, heard: AgentProvider.Heard? = nil) -> HookLine {
        AgentSummaries.hookLine(kind, agents: provider, heard: heard, now: now) { "in " + ($0 as NSString).lastPathComponent }
    }

    /// A provider with the fake Claude Code and a fake Codex that can't add
    /// Roga's marketplace, as when another copy of Roga added it, until a
    /// file called `fixed` exists. Then it lists the plugin as installed.
    private func startedWithFailingCodex() async throws -> AgentProvider {
        try AgentTestSupport.claude(in: bin, log: log)
        try AgentTestSupport.script("""
            if [ "$1" = "--version" ]; then echo 'codex-cli 0.166.0'; exit 0; fi
            if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then
                if [ -f '\(folder)/fixed' ]; then
                    echo '{"installed":[{"pluginId":"\(HookPlugin.pluginID)","installed":true,"enabled":true}]}'
                else
                    echo '{"installed":[]}'
                fi
                exit 0
            fi
            if [ "$1" = "plugin" ] && [ "$2" = "marketplace" ] && [ "$3" = "add" ] && [ ! -f '\(folder)/fixed' ]; then
                echo 'Error: marketplace `roga` is already added from a different source' >&2
                exit 1
            fi
            exit 0
            """, named: "codex", in: bin)
        let helperPath = try AgentTestSupport.script("exit 0", named: "roga", in: folder)
        let provider = AgentTestSupport.provider(support: support, helperPath: helperPath, defaults: defaults, codexHome: codexHome)
        provider.start(git: try await AgentTestSupport.git(searchPath: bin))
        #expect(await AgentTestSupport.eventually { !provider.isLooking && provider.hookStatus.count == 2 })
        return provider
    }

    /// Someone fixing Codex in Terminal: its marketplace now works, and
    /// `config.toml` trusts one of the plugin's hooks.
    private func fixCodex() throws {
        try "".write(toFile: folder + "/fixed", atomically: true, encoding: .utf8)
        try "[hooks.state.\"\(HookPlugin.pluginID):\(HookPlugin.codexHooksPath):stop:0:0\"]\ntrusted = true\n"
            .write(toFile: codexHome + "/config.toml", atomically: true, encoding: .utf8)
    }

    // MARK: The agents' rows

    @Test func anAgentsRowSaysWhereItsProgramIs() {
        #expect(AgentSummaries.programLine(nil) == ProgramLine(text: "Looking…", tone: .plain))
        #expect(AgentSummaries.programLine(.found(Self.homeClaude)) == ProgramLine(text: "~/nonexistent/bin/claude · 2.1.286", tone: .path))
        #expect(AgentSummaries.programLine(.found(Self.claude)) == ProgramLine(text: "/nonexistent/bin/claude · 2.1.286", tone: .path))
        #expect(AgentSummaries.programLine(.notFound) == ProgramLine(text: "Not found in your login shell's PATH.", tone: .plain))
    }

    @Test func anAgentRogaCantUseSaysWhyInAmber() {
        let old = SkippedAgent(kind: .codex, executable: NSHomeDirectory() + "/nonexistent/bin/codex", reason: .tooOld(AgentVersion(major: 0, minor: 120, patch: 0)))
        #expect(AgentSummaries.programLine(.unusable([old])) == ProgramLine(text: "~/nonexistent/bin/codex is Codex 0.120.0, older than 0.131.0.", tone: .warn))
        #expect(AgentSummaries.programLine(.configuredUnusable(old)).tone == .warn)
        #expect(AgentSummaries.programLine(.configuredMissing("/nonexistent/local/bin/codex")) == ProgramLine(text: "Roga can't find or run /nonexistent/local/bin/codex, which you chose.", tone: .warn))
    }

    @Test func theProgramRowSaysHowRogaCameToIt() {
        let found = AgentDetailPage.programDetail(.claude, lookup: .found(Self.homeClaude), isChosen: false, isFirstInPath: true)
        #expect(found.path == "~/nonexistent/bin/claude")
        #expect(found.version == "Claude Code 2.1.286")
        #expect(found.sentence == "Found in your login shell's PATH.")
        #expect(found.plain == "~/nonexistent/bin/claude · Claude Code 2.1.286. Found in your login shell's PATH.")
        #expect(AgentDetailPage.programDetail(.claude, lookup: .found(Self.claude), isChosen: true, isFirstInPath: false).sentence == "Chosen by you.")
        #expect(AgentDetailPage.programDetail(.claude, lookup: .found(Self.claude), isChosen: false, isFirstInPath: false).sentence.hasPrefix("Found outside"))
        // Codex runs the newest copy, wherever it is.
        var newest = Self.codex
        newest.others = [FoundAgent(executable: "/nonexistent/local/bin/codex", version: AgentVersion(major: 0, minor: 140, patch: 0))]
        #expect(AgentDetailPage.programDetail(.codex, lookup: .found(newest), isChosen: false, isFirstInPath: false).sentence == "The newest of the copies Roga found.")
        let missing = AgentDetailPage.programDetail(.codex, lookup: .configuredMissing("/nonexistent/local/bin/codex"), isChosen: true, isFirstInPath: false)
        #expect(missing.isWarning)
        #expect(missing.path == "/nonexistent/local/bin/codex")
        #expect(AgentDetailPage.programDetail(.codex, lookup: .notFound, isChosen: false, isFirstInPath: false).sentence == "Not found in your login shell's PATH.")
        #expect(AgentDetailPage.programDetail(.codex, lookup: nil, isChosen: false, isFirstInPath: false).sentence == "Looking…")
    }

    @Test func pathIsInTheCodeFontWithoutTheKeysGround() throws {
        let words = try #require(SettingsGroup.commandLineAgents.styledDescription)
        #expect(String(words.characters) == SettingsGroup.commandLineAgents.description)
        let font = AttributeScopes.SwiftUIAttributes.FontAttribute.self
        let typed = words.runs.filter { $0[font] != nil }
        #expect(typed.map { String(words[$0.range].characters) } == ["PATH"])
        #expect(typed.first?[font] == .system(size: 12.5, design: .monospaced))
        #expect(words.runs.allSatisfy { $0[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] == nil })
        // Working status has nothing typed in it.
        #expect(SettingsGroup.workingStatus.styledDescription?.runs.count == 1)
    }

    @Test func lookAgainHasTheBoardsIcon() {
        // The canvas draws Lucide's rotate-cw, one arrow, not refresh-cw's two.
        #expect(AgentListSection.lookAgainIcon == .rotateCw)
        #expect(Icon.rotateCw.nsImage != nil)
    }

    // MARK: The hooks' rows

    @Test func notInstalledOffersInstall() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)], hookStatus: [.claude: .notInstalled, .codex: .notInstalled])
        #expect(line(.claude, agents) == HookLine(tone: .plain, text: "Not installed.", button: .init(action: .install, title: "Install…", isEnabled: true)))
        #expect(line(.codex, agents).text == "Not installed. Codex asks you to trust a new hook the first time it runs.")
    }

    @Test func installedSaysWhenRogaLastHeardAndWhere() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude)], hookStatus: [.claude: .installed])
        let heard = AgentProvider.Heard(date: now.addingTimeInterval(-130), cwd: "/git/acme/api")
        let installed = line(.claude, agents, heard: heard)
        #expect(installed.tone == .installed)
        #expect(installed.text == "Installed, as the roga-hooks plugin. Last heard from 2 minutes ago, in api.")
        #expect(installed.button == .init(action: .remove, title: "Remove…", isEnabled: true))
        // Without a word since Roga opened, it says only that it's installed.
        #expect(line(.claude, agents).text == "Installed, as the roga-hooks plugin.")
        let folderless = AgentProvider.Heard(date: now.addingTimeInterval(-30), cwd: nil)
        #expect(line(.claude, agents, heard: folderless).text == "Installed, as the roga-hooks plugin. Last heard from less than a minute ago.")
    }

    @Test func installedButNotRunningSaysWhatToDo() {
        defer { clean() }
        let agents = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookStatus: [.claude: .disabled, .codex: .needsTrust]
        )
        #expect(line(.claude, agents) == HookLine(tone: .warn, text: "Installed, but turned off in Claude Code.", button: .init(action: .remove, title: "Remove…", isEnabled: true)))
        #expect(line(.codex, agents).text == "Installed, but Codex hasn't trusted it yet. Open /hooks in Codex to trust it.")
        #expect(line(.codex, agents).tone == .warn)
    }

    @Test func anotherCopysHooksAreTakenOverInClaudeAndRemovedFirstInCodex() {
        defer { clean() }
        let other = NSHomeDirectory() + "/Library/Application Support/sh.roga.app.dev/plugins"
        let agents = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookStatus: [.claude: .anotherCopy(folder: other), .codex: .anotherCopy(folder: other)]
        )
        #expect(line(.claude, agents).text == "Installed by another copy of Roga, from ~/Library/Application Support/sh.roga.app.dev/plugins.")
        #expect(line(.claude, agents).button?.action == .install)
        #expect(line(.codex, agents).button?.action == .remove)
    }

    @Test func aStatusRogaCantTellSaysTheAgentsWords() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude)], hookStatus: [.claude: .unknown("claude plugin list exited with status 1: Unknown command")])
        #expect(line(.claude, agents).text == "Roga couldn't tell whether it's installed: claude plugin list exited with status 1: Unknown command.")
        #expect(line(.claude, agents).tone == .warn)
        #expect(line(.claude, agents).button?.action == .install)
    }

    @Test func whileCheckingOrLookingThereIsNoButton() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude)])
        #expect(line(.claude, agents) == HookLine(tone: .plain, text: "Checking…"))
        #expect(line(.codex, agents) == HookLine(tone: .plain, text: "Checking…"))
        let missing = provider(lookups: [.codex: .notFound])
        #expect(line(.codex, missing) == HookLine(tone: .plain, text: "Roga needs to find Codex before it can install its hooks."))
    }

    @Test func theButtonWaitsWhileInstallOrRemoveRuns() {
        defer { clean() }
        let agents = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookStatus: [.claude: .notInstalled, .codex: .installed],
            hookWork: [.claude: .installing, .codex: .removing]
        )
        #expect(line(.claude, agents).button == .init(action: .install, title: "Installing…", isEnabled: false, isWorking: true))
        #expect(line(.codex, agents).button == .init(action: .remove, title: "Removing…", isEnabled: false, isWorking: true))
    }

    @Test func eachHooksButtonNamesItsAgentToVoiceOver() {
        defer { clean() }
        let agents = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookStatus: [.claude: .notInstalled, .codex: .installed]
        )
        // The titles stay as the canvas draws them.
        #expect(line(.claude, agents).button?.title == "Install…")
        #expect(line(.claude, agents).button?.spokenTitle(.claude) == "Install Roga's hooks in Claude Code")
        #expect(line(.codex, agents).button?.title == "Remove…")
        #expect(line(.codex, agents).button?.spokenTitle(.codex) == "Remove Roga's hooks from Codex")
        // While the commands run, it says so.
        agents.setStateForTests(hookWork: [.claude: .installing, .codex: .removing])
        #expect(line(.claude, agents).button?.spokenTitle(.claude) == "Installing Roga's hooks in Claude Code")
        #expect(line(.codex, agents).button?.spokenTitle(.codex) == "Removing Roga's hooks from Codex")
        // They're the dialog's own titles.
        #expect(HookLine.Offer(action: .install, title: "Install…", isEnabled: true).spokenTitle(.codex) == HooksDialog.title(.init(kind: .codex, action: .install)))
        #expect(HookLine.Offer(action: .remove, title: "Remove…", isEnabled: true).spokenTitle(.claude) == HooksDialog.title(.init(kind: .claude, action: .remove)))
    }

    @Test func aFailureShowsTheAgentsOwnWords() {
        defer { clean() }
        let words = "marketplace `roga` is already added from a different source"
        let agents = provider(
            lookups: [.codex: .found(Self.codex)],
            hookStatus: [.codex: .notInstalled],
            hookWork: [.codex: .failed(.install, words)]
        )
        #expect(line(.codex, agents).problems == [words])
        // It can be tried again.
        #expect(line(.codex, agents).button?.isEnabled == true)
        // While Roga checks again, right after the failure, it stays.
        agents.setStateForTests(hookStatus: [:])
        #expect(line(.codex, agents).problems == [words])
        // So it does while Roga looks for the agent again.
        agents.setStateForTests(lookups: [:])
        #expect(line(.codex, agents).problems == [words])
        // Once Roga can't find the agent, the line says that instead.
        agents.setStateForTests(lookups: [.codex: .notFound])
        #expect(line(.codex, agents).problems.isEmpty)
    }

    @Test func aFailedInstallGoesFromTheRowOnceItsFixed() async throws {
        defer { clean() }
        let agents = try await startedWithFailingCodex()
        #expect(await !agents.installHooks([.codex]))
        #expect(await AgentTestSupport.eventually { agents.hookStatus[.codex] == .notInstalled })
        let failed = line(.codex, agents)
        #expect(failed.problems == ["Error: marketplace `roga` is already added from a different source"])

        try fixCodex()
        agents.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { agents.hookStatus[.codex] == .installed })
        let fixed = line(.codex, agents)
        #expect(fixed.tone == .installed)
        #expect(fixed.problems.isEmpty)
    }

    @Test func aFailureShowsInEverySheetUntilSomeoneLooksAgain() async throws {
        defer { clean() }
        let agents = try await startedWithFailingCodex()
        #expect(await !agents.installHooks([.codex]))
        #expect(await AgentTestSupport.eventually { agents.hookStatus[.codex] == .notInstalled })
        // A sheet that opens afresh checks the hooks again, and the failure
        // still applies, so its row shows it too.
        agents.refreshHookStatus()
        #expect(await AgentTestSupport.eventually { agents.hookStatus[.codex] == .notInstalled })
        #expect(line(.codex, agents).problems == ["Error: marketplace `roga` is already added from a different source"])
        agents.lookAgain()
        #expect(line(.codex, agents).problems.isEmpty)
    }

    @Test func theHooksRowReadsAsOneSentenceToVoiceOver() {
        defer { clean() }
        let agents = provider(
            helper: false,
            lookups: [.codex: .found(Self.codex)],
            hookStatus: [.codex: .notInstalled],
            hookWork: [.codex: .failed(.install, "Error: marketplace `roga` is already added from a different source")]
        )
        #expect(line(.codex, agents).spoken == "Not installed. Codex asks you to trust a new hook the first time it runs. This copy of Roga has no roga helper, so it can't install hooks. Error: marketplace `roga` is already added from a different source.")
        // With a detail, the row reads its help as the value; without one,
        // the help shows as it is and isn't read twice.
        let detailed = SettingsRow(title: "Hooks", help: "Not installed.", namesControl: false) { Text("Not installed.") } control: { EmptyView() }
        #expect(detailed.spokenDetail == "Not installed.")
        #expect(SettingsRow(title: "Effort", help: "Passed as --effort.") { EmptyView() }.spokenDetail == nil)
    }

    @Test func withoutTheHelperInstallCantWork() {
        defer { clean() }
        let agents = provider(helper: false, lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)], hookStatus: [.claude: .notInstalled, .codex: .installed])
        let claude = line(.claude, agents)
        #expect(claude.button == .init(action: .install, title: "Install…", isEnabled: false))
        #expect(claude.note == "This copy of Roga has no roga helper, so it can't install hooks.")
        // Removing needs no helper.
        #expect(line(.codex, agents).button?.isEnabled == true)
        #expect(line(.codex, agents).note == nil)
    }

    @Test func whereAnAgentWasHeardFromIsTheSidebarsName() {
        let list = RepositoryList(listing: [
            ListedRepository(path: "/git/acme/api/.git", owners: ["acme"], worktrees: [
                Worktree(path: "/git/acme/api", branch: "refs/heads/main", isMain: true),
                Worktree(path: "/git/acme/api/.claude/worktrees/fix", branch: "refs/heads/agent/fix-login"),
            ]),
        ])
        let places = HeardPlaces()
        #expect(places.place(of: "/git/acme/api/Sources", in: list) == "in acme/api")
        #expect(places.place(of: "/git/acme/api/.claude/worktrees/fix", in: list) == "on agent/fix-login in acme/api")
        #expect(places.place(of: "/elsewhere/scratch", in: list) == "in scratch")
    }

    @Test func placingWhereAnAgentWasHeardResolvesEachFolderOnceAwayFromTheMainActor() async {
        let resolved = Mutex<[String]>([])
        let onMain = Mutex(0)
        let places = HeardPlaces { path in
            resolved.withLock { $0.append(path) }
            if Thread.isMainThread { onMain.withLock { $0 += 1 } }
            return path
        }
        var worktrees = (0..<3).map { Worktree(path: $0 == 0 ? "/git/acme/api" : "/git/acme/api-\($0)", branch: "refs/heads/b\($0)", isMain: $0 == 0) }
        func list(_ worktrees: [Worktree]) -> RepositoryList {
            RepositoryList(listing: [ListedRepository(path: "/git/acme/api/.git", owners: ["acme"], worktrees: worktrees)])
        }
        let listed = list(worktrees)
        // The hooks' rows ask on every event an agent sends.
        for _ in 0..<20 {
            #expect(places.place(of: "/git/acme/api-1/Sources", in: listed) == "on b1 in acme/api")
        }
        #expect(await AgentTestSupport.eventually { !places.isResolving })
        // Three worktrees and the folder, once each, and none of them on the
        // main actor.
        #expect(resolved.withLock { $0.count } == 4)
        #expect(onMain.withLock { $0 } == 0)
        for _ in 0..<20 {
            #expect(places.place(of: "/git/acme/api-1/Sources", in: listed) == "on b1 in acme/api")
        }
        _ = places.place(of: "/elsewhere/scratch", in: listed)
        #expect(await AgentTestSupport.eventually { !places.isResolving })
        #expect(resolved.withLock { $0.count } == 5)

        // A commit in a worktree moves its HEAD, and the list reads it
        // again, but its folders are the same.
        worktrees[2].head = ObjectID(hex: "0123456789abcdef0123456789abcdef01234567")
        worktrees[1].branch = "refs/heads/agent/fix-login"
        #expect(places.place(of: "/git/acme/api-1/Sources", in: list(worktrees)) == "on agent/fix-login in acme/api")
        #expect(!places.isResolving)

        // A new worktree is one more folder to resolve.
        worktrees.append(Worktree(path: "/git/acme/api-1/Sources", branch: "refs/heads/nested"))
        #expect(places.place(of: "/git/acme/api-1/Sources", in: list(worktrees)) == "on nested in acme/api")
        #expect(await AgentTestSupport.eventually { !places.isResolving })
        #expect(resolved.withLock { $0 } == ["/git/acme/api", "/git/acme/api-1", "/git/acme/api-2", "/git/acme/api-1/Sources", "/elsewhere/scratch"])
    }

    @Test func aFolderSpelledThroughALinkIsPlacedOnceItsResolved() async throws {
        let real = folder + "/real/api"
        try FileManager.default.createDirectory(atPath: real + "/Sources", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: folder + "/real")
        let list = RepositoryList(listing: [
            ListedRepository(path: real + "/.git", owners: ["acme"], worktrees: [Worktree(path: real, branch: "refs/heads/main", isMain: true)]),
        ])
        let places = HeardPlaces()
        let heard = folder + "/link/api/Sources"
        _ = places.place(of: heard, in: list)
        #expect(await AgentTestSupport.eventually { !places.isResolving && places.place(of: heard, in: list) == "in acme/api" })
    }

    @Test func howLongAgoIsInWords() {
        #expect(AgentSummaries.ago(now.addingTimeInterval(-20), now: now) == "less than a minute ago")
        #expect(AgentSummaries.ago(now.addingTimeInterval(-61), now: now) == "1 minute ago")
        #expect(AgentSummaries.ago(now.addingTimeInterval(-60 * 59), now: now) == "59 minutes ago")
        #expect(AgentSummaries.ago(now.addingTimeInterval(-60 * 60 * 3), now: now) == "3 hours ago")
        #expect(AgentSummaries.ago(now.addingTimeInterval(-60 * 60 * 30), now: now) == "yesterday")
        #expect(AgentSummaries.ago(now.addingTimeInterval(-60 * 60 * 24 * 4), now: now) == "4 days ago")
        // A clock that moved back doesn't make it the future.
        #expect(AgentSummaries.ago(now.addingTimeInterval(30), now: now) == "less than a minute ago")
    }

    @Test func aNoticeSaysWhenTheMarksCantShow() {
        #expect(AgentSummaries.listeningNotice(.listening) == nil)
        #expect(AgentSummaries.listeningNotice(.starting) == nil)
        #expect(AgentSummaries.listeningNotice(.anotherCopy)?.hasPrefix("Another copy of Roga is listening") == true)
        // The listener's error already says that Roga can't listen, and
        // where, so the notice says it once, with the home folder as ~.
        let socket = NSHomeDirectory() + "/Library/Application Support/sh.roga.app/hooks.sock"
        let inUse = AgentSummaries.listeningNotice(.failed(String(describing: HookListenerError.system("bind", path: socket, errorNumber: EADDRINUSE))))
        #expect(inUse == "Roga can't listen for agents' hooks at ~/Library/Application Support/sh.roga.app/hooks.sock, because bind failed: Address already in use. Until it can, the sidebar can't show the agents' marks.")
        let tooLong = AgentSummaries.listeningNotice(.failed(String(describing: HookListenerError.pathTooLong(socket))))
        #expect(tooLong?.components(separatedBy: "can't listen").count == 2, "\(tooLong ?? "")")
        #expect(tooLong?.contains(NSHomeDirectory()) == false)
        // Words that don't say it get the notice's own start.
        #expect(AgentSummaries.listeningNotice(.failed("The socket's path is too long")) == "Roga can't listen for the agents' hooks. The socket's path is too long. Until it can, the sidebar can't show the agents' marks.")
    }

    @Test func anotherCopyListeningShowsTheNotice() async throws {
        defer { clean() }
        let agents = provider(lookups: [:])
        let first = AgentMonitor(supportFolder: URL(filePath: folder + "/m", directoryHint: .isDirectory), checkInterval: nil)
        let second = AgentMonitor(supportFolder: URL(filePath: folder + "/m", directoryHint: .isDirectory), checkInterval: nil)
        defer {
            first.stop()
            second.stop()
        }
        first.start(agents: agents)
        #expect(await AgentTestSupport.eventually { first.listening == .listening })
        second.start(agents: agents)
        #expect(await AgentTestSupport.eventually { second.listening == .anotherCopy })
        #expect(AgentSummaries.listeningNotice(second.listening) != nil)
    }

    // MARK: The install and remove dialog

    @Test func theInstallDialogOffersTheOtherAgentOnlyWhenItsNotInstalled() {
        defer { clean() }
        let both = provider(lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)], hookStatus: [.claude: .notInstalled, .codex: .notInstalled])
        #expect(HooksDialog.otherAgent(for: .claude, action: .install, agents: both) == .codex)
        #expect(HooksDialog.otherAgent(for: .codex, action: .install, agents: both) == .claude)
        #expect(HooksDialog.otherAgent(for: .claude, action: .remove, agents: both) == nil)
        let installed = provider(lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)], hookStatus: [.claude: .notInstalled, .codex: .needsTrust])
        #expect(HooksDialog.otherAgent(for: .claude, action: .install, agents: installed) == nil)
        let alone = provider(lookups: [.claude: .found(Self.claude), .codex: .notFound], hookStatus: [.claude: .notInstalled])
        #expect(HooksDialog.otherAgent(for: .claude, action: .install, agents: alone) == nil)
    }

    @Test func theDialogSaysWhatChanges() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude)])
        let install = HooksDialog.Request(kind: .claude, action: .install, offers: .codex)
        #expect(HooksDialog.title(install) == "Install Roga's hooks in Claude Code")
        #expect(HooksDialog.message(install).hasPrefix("Claude Code will tell Roga when a session starts"))
        #expect(HooksDialog.facts(install, agents: agents).map(\.name) == ["roga-hooks", "~/.claude/settings.json", "Remove"])
        let codex = HooksDialog.Request(kind: .codex, action: .install)
        #expect(HooksDialog.message(codex).hasSuffix("Codex asks you to trust them the first time they run."))
        // Before the provider starts, Codex's folder is the usual one.
        #expect(HooksDialog.facts(codex, agents: agents)[1].name == "~/.codex/config.toml")
        let remove = HooksDialog.Request(kind: .claude, action: .remove)
        #expect(HooksDialog.title(remove) == "Remove Roga's hooks from Claude Code")
        #expect(HooksDialog.buttonTitle(.remove, isWorking: false) == "Remove")
        #expect(HooksDialog.buttonTitle(.install, isWorking: true) == "Installing…")
        #expect(HooksDialog.kinds(for: install, alsoOther: true) == [.claude, .codex])
        #expect(HooksDialog.kinds(for: install, alsoOther: false) == [.claude])
        #expect(HooksDialog.kinds(for: remove, alsoOther: true) == [.claude])
    }

    @Test func removingSaysWhatEachAgentKeeps() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)])
        // Codex's commands leave the trust it recorded for the hooks in its
        // config.toml, which Roga doesn't edit, so neither dialog may say
        // that nothing stays.
        let codexRemove = HooksDialog.Request(kind: .codex, action: .remove)
        let codexInstall = HooksDialog.Request(kind: .codex, action: .install)
        let codexWords = [HooksDialog.message(codexRemove)]
            + HooksDialog.facts(codexRemove, agents: agents).map(\.what)
            + HooksDialog.facts(codexInstall, agents: agents).map(\.what)
        for words in codexWords {
            #expect(!words.contains("nothing"), "\(words)")
            #expect(!words.contains("Nothing"), "\(words)")
        }
        #expect(HooksDialog.message(codexRemove).hasSuffix("Codex keeps in its config.toml any trust you gave Roga's hooks, so if you install the same hooks again, it won't ask again."))
        #expect(HooksDialog.facts(codexInstall, agents: agents).last?.what == "Runs codex plugin remove. Codex keeps any trust you gave the hooks.")
        #expect(HooksDialog.facts(codexRemove, agents: agents)[1].what.hasSuffix("but keeps any trust you gave its hooks."))
        // Claude Code's settings keep nothing of Roga's, and it deletes its
        // copy of the plugin by itself.
        let claudeRemove = HooksDialog.Request(kind: .claude, action: .remove)
        #expect(HooksDialog.message(claudeRemove).hasSuffix("Its settings keep nothing of Roga's, and it deletes its own copy of the plugin later."))
        #expect(HooksDialog.facts(HooksDialog.Request(kind: .claude, action: .install), agents: agents).last?.what == "Runs claude plugin uninstall, which leaves nothing of Roga's in its settings.")
    }

    @Test func theDialogShowsTheExactCommands() async throws {
        defer { clean() }
        let agents = try await started()
        let installer = try #require(agents.installer)
        let folder = installer.pluginsFolder.path(percentEncoded: false)
        let plugins = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        let install = HooksDialog.Request(kind: .claude, action: .install, offers: .codex)
        let lines = HooksDialog.terminal(for: install, alsoOther: true, agents: agents)
        let commands = lines.compactMap { line -> [String]? in
            if case .program(let command, _) = line { [command.name] + command.arguments } else { nil }
        }
        #expect(commands == [
            ["claude", "plugin", "marketplace", "add", plugins],
            ["claude", "plugin", "install", "roga-hooks@roga", "--scope", "user"],
            ["claude", "plugin", "update", "roga-hooks@roga", "--scope", "user"],
            ["codex", "plugin", "marketplace", "add", plugins],
            ["codex", "plugin", "add", "roga-hooks@roga"],
        ])
        // The agents are the first of their name in PATH, so the block names
        // them as someone would type them.
        #expect(lines.allSatisfy { if case .program(_, let showsPath) = $0 { !showsPath } else { true } })
        #expect(CommandBlock.copied(lines).split(separator: "\n").first == "\(bin)/claude plugin marketplace add \(ShellQuoting.quoted(plugins))")

        // Turned off, Codex's commands keep their room, hidden, and aren't copied.
        let alone = HooksDialog.terminal(for: install, alsoOther: false, agents: agents)
        #expect(alone.count == lines.count)
        #expect(alone.suffix(2).allSatisfy { if case .room = $0 { true } else { false } })
        #expect(CommandBlock.copied(alone).split(separator: "\n").count == 3)

        let remove = HooksDialog.terminal(for: HooksDialog.Request(kind: .codex, action: .remove), alsoOther: true, agents: agents)
        #expect(remove.map { if case .program(let command, _) = $0 { command.arguments } else { [] } } == [
            ["plugin", "remove", "roga-hooks@roga"],
            ["plugin", "marketplace", "remove", "roga"],
        ])
    }

    @Test func theDialogCanRunOnlyWhatCanWork() {
        defer { clean() }
        let agents = provider(lookups: [.claude: .found(Self.claude), .codex: .notFound])
        #expect(HooksDialog.canRun(.init(kind: .claude, action: .install), agents: agents))
        #expect(!HooksDialog.canRun(.init(kind: .codex, action: .install), agents: agents))
        let helperless = provider(helper: false, lookups: [.claude: .found(Self.claude)])
        #expect(!HooksDialog.canRun(.init(kind: .claude, action: .install), agents: helperless))
        #expect(HooksDialog.canRun(.init(kind: .claude, action: .remove), agents: helperless))
    }

    @Test func theDialogSaysHowEachAgentFailed() {
        defer { clean() }
        let words = "marketplace `roga` is already added from a different source"
        let agents = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookWork: [.codex: .failed(.install, words)]
        )
        let failed = HooksDialog.failed([.claude, .codex], agents: agents)
        #expect(failed == [HooksDialog.Failure(kind: .codex, words: words)])
        // The heading names the agent that failed, which the line then needn't.
        #expect(HooksDialog.failureHeading(.install, failed: failed.map(\.kind)) == "Codex didn't install Roga's hooks")
        #expect(HooksDialog.failureLines(failed) == [words])
        #expect(HooksDialog.failureHeading(.remove, failed: [.claude]) == "Claude Code didn't remove Roga's hooks")

        let both = provider(
            lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)],
            hookWork: [.claude: .failed(.install, "Claude Code's words."), .codex: .failed(.install, words)]
        )
        let all = HooksDialog.failed([.claude, .codex], agents: both)
        #expect(HooksDialog.failureHeading(.install, failed: all.map(\.kind)) == "Claude Code and Codex didn't install Roga's hooks")
        #expect(HooksDialog.failureLines(all) == ["Claude Code: Claude Code's words.", "Codex: \(words)"])
    }

    @Test func whenOnlyTheOtherAgentFailsTheDialogNamesIt() async throws {
        defer { clean() }
        let agents = try await startedWithFailingCodex()
        let request = HooksDialog.Request(kind: .claude, action: .install, offers: .codex)
        let kinds = HooksDialog.kinds(for: request, alsoOther: true)
        #expect(await !agents.installHooks(kinds))
        let failed = HooksDialog.failed(kinds, agents: agents)
        #expect(failed.map(\.kind) == [.codex])
        #expect(HooksDialog.failureHeading(request.action, failed: failed.map(\.kind)) == "Codex didn't install Roga's hooks")
        #expect(HooksDialog.failureLines(failed) == ["Error: marketplace `roga` is already added from a different source"])
    }

    @Test func installingFromTheDialogRunsTheAgentsCommands() async throws {
        defer { clean() }
        let agents = try await started()
        let request = HooksDialog.Request(kind: .claude, action: .install, offers: .codex)
        #expect(await agents.installHooks(HooksDialog.kinds(for: request, alsoOther: true)))
        let ran = AgentTestSupport.runs(in: log).filter { $0.first == "plugin" && $0.dropFirst().first != "list" }
        let expected = HooksDialog.terminal(for: request, alsoOther: true, agents: agents).compactMap { line -> [String]? in
            if case .program(let command, _) = line { command.arguments } else { nil }
        }
        #expect(ran == expected)
    }

    // MARK: The Commit page

    @Test func theCommitPageShowsTheAgentGenerateRuns() {
        defer { clean() }
        let both = provider(lookups: [.claude: .found(Self.claude), .codex: .found(Self.codex)])
        #expect(GenerateChoices.shownAgent(both) == .claude)
        both.setGenerateAgent(.codex)
        #expect(GenerateChoices.shownAgent(both) == .codex)
        defaults.set(false, forKey: AgentPreferences.enabledKey(.codex))
        both.reloadSettings()
        #expect(GenerateChoices.shownAgent(both) == .claude)

        let none = provider(lookups: [.claude: .notFound, .codex: .notFound])
        #expect(GenerateChoices.shownAgent(none) == .claude)
        #expect(GenerateChoices.noAgentTitle(none) == "None found")
        let looking = provider(lookups: [:])
        #expect(GenerateChoices.noAgentTitle(looking) == "Looking…")
        defaults.set(false, forKey: AgentPreferences.enabledKey(.claude))
        let off = provider(lookups: [.claude: .found(Self.claude), .codex: .notFound])
        #expect(off.usableAgents.isEmpty)
        #expect(GenerateChoices.noAgentTitle(off) == "Turned off")
        // Its model and effort are still the found one's.
        #expect(GenerateChoices.shownAgent(off) == .claude)
    }

    /// The Instructions box shows every line. In the Settings sheet the text
    /// view reported its height from before its text was laid out, so the
    /// box stopped at four lines and cut the fourth in half.
    @Test func theInstructionsBoxIsAsTallAsItsLines() {
        let width: CGFloat = 560
        func laidOut(_ text: String) -> CGFloat {
            // What AppKit's own text view makes of the same text.
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 10))
            view.textContainer?.lineFragmentPadding = SettingsTextArea.linePadding
            view.textContainer?.containerSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = SettingsTextArea.lineSpacing
            view.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: SettingsTextArea.fontSize), .paragraphStyle: paragraph,
            ]))
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            return view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
        }
        let roga = CommitMessagePrompt.defaultStyle
        let one = SettingsTextArea.textHeight("Write short subjects.", width: width)
        let two = SettingsTextArea.textHeight("Write short subjects.\nNo prefixes.", width: width)
        for text in ["Write short subjects.", "Write short subjects.\nNo prefixes.", roga] {
            let measured = SettingsTextArea.textHeight(text, width: width)
            let actual = laidOut(text)
            #expect(measured >= actual, "\(measured) is shorter than the text view's \(actual)")
            #expect(measured <= actual + SettingsTextArea.lineSpacing + 1, "\(measured) is much taller than the text view's \(actual)")
        }
        #expect(two > one + SettingsTextArea.fontSize)
        // A new line at the end makes room for the line being started.
        #expect(SettingsTextArea.textHeight("Write short subjects.\n", width: width) == two)
        // Roga's own instructions take more than the four lines the box starts with.
        #expect(SettingsTextArea.textHeight(roga, width: width) > 4 * one)
        #expect(SettingsTextArea.textHeight(roga, width: 300) > SettingsTextArea.textHeight(roga, width: width))
        // Before the box knows its width, it's one line.
        #expect(SettingsTextArea.textHeight(roga, width: 0) == one)
    }

    @Test func returnStartsANewLineInTheInstructions() async throws {
        let typed = Typed("First line")
        let area = SettingsTextArea(text: Binding { typed.text } set: { typed.text = $0 }, label: "Instructions")
        let host = NSHostingView(rootView: area.frame(width: 400))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        // The box is the first view that takes typing: a text view, or a
        // field whose editor is one.
        let box = try #require(Self.subviews(of: host).first { $0 is NSTextView || $0 is NSTextField })
        #expect(window.makeFirstResponder(box))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        let returnKey = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        editor.keyDown(with: returnKey)
        editor.insertText("Second line", replacementRange: editor.selectedRange())
        #expect(await AgentTestSupport.eventually(within: .seconds(2)) { typed.text == "First line\nSecond line" }, "The instructions are \(typed.text.debugDescription)")
    }

    /// The views under a view, depth first.
    private static func subviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + subviews(of: $0) }
    }

    @Test func pickersOfferWhatsStoredToo() {
        #expect(GenerateChoices.models(for: .claude, stored: "haiku") == ["", "haiku", "sonnet", "opus"])
        #expect(GenerateChoices.models(for: .claude, stored: "claude-haiku-4-5") == ["", "haiku", "sonnet", "opus", "claude-haiku-4-5"])
        #expect(GenerateChoices.models(for: .codex, stored: "") == [""])
        #expect(GenerateChoices.models(for: .codex, stored: "gpt-6-astra") == ["", "gpt-6-astra"])
        #expect(GenerateChoices.efforts(stored: "low") == ["", "low", "medium", "high"])
        #expect(GenerateChoices.efforts(stored: "xhigh") == ["", "low", "medium", "high", "xhigh"])
        #expect(GenerateChoices.timeLimits(stored: 60) == [30, 60, 120])
        #expect(GenerateChoices.timeLimits(stored: 90) == [30, 60, 90, 120])
    }

    @Test func theModelsHelpSaysWhereCodexsDefaultComesFrom() {
        defer { clean() }
        let agents = provider(lookups: [:])
        #expect(GenerateChoices.modelHelp(.claude, onAgentPage: false, agents: agents) == "Something fast is plenty for a commit message.")
        #expect(GenerateChoices.modelHelp(.claude, onAgentPage: true, agents: agents).hasPrefix("Passed as --model."))
        #expect(GenerateChoices.modelHelp(.codex, onAgentPage: true, agents: agents) == "Passed as -m. Default is the model in ~/.codex/config.toml.")
        agents.setStateForTests(codexDefaultModel: .some("gpt-6-astra"))
        #expect(GenerateChoices.modelHelp(.codex, onAgentPage: true, agents: agents) == "Passed as -m. Default is the model in ~/.codex/config.toml (gpt-6-astra).")
    }

    @Test func theCommandIsWhatGenerateRuns() async throws {
        defer { clean() }
        defaults.set("sonnet", forKey: AgentPreferences.modelKey(.claude))
        defaults.set("", forKey: AgentPreferences.effortKey(.claude))
        defaults.set("--verbose", forKey: AgentPreferences.extraArgumentsKey(.claude))
        let agents = try await started()
        let lines = GenerateChoices.terminal(for: .claude, agents: agents, style: "Be brief.")
        let setup = try #require(agents.generation(with: .claude))
        #expect(lines.first == .comment("The staged changes go to its standard input"))
        guard case .program(let command, let showsPath)? = lines.last else {
            Issue.record("There's no command")
            return
        }
        #expect(!showsPath)
        #expect(command.executable == bin + "/claude")
        #expect(command.arguments.contains("sonnet"))
        #expect(!command.arguments.contains("--effort"))
        #expect(command.arguments.contains("--verbose"))
        // The same as Generate's, but for the style the page shows.
        var expected = setup
        expected.style = "Be brief."
        #expect(command.arguments == expected.command(worktree: NSHomeDirectory(), hasDraft: false).arguments)
    }

    @Test func theCommandShowsWhatWouldRunBeforeTheAgentIsFound() {
        defer { clean() }
        let agents = provider(lookups: [.codex: .notFound])
        let lines = GenerateChoices.terminal(for: .codex, agents: agents, style: CommitMessagePrompt.defaultStyle)
        guard case .program(let command, let showsPath)? = lines.last else {
            Issue.record("There's no command")
            return
        }
        #expect(command.executable == "codex")
        #expect(!showsPath)
        #expect(command.arguments.starts(with: ["exec", "--ephemeral"]))
    }

    // MARK: An agent's page

    @Test func theProgramsPathIsInInkUnderTheGrayHelp() throws {
        let path = "~/.local/bin/claude"
        let mono = Font.system(size: 12, design: .monospaced)
        // The row draws its help in gray, which is where the path sits.
        let shown = try Self.darkest(VStack { AgentDetailPage.pathLine(path, version: nil) }.foregroundStyle(SettingsColors.note))
        let ink = try Self.darkest(Text(path).font(mono).foregroundStyle(Color.primary))
        let gray = try Self.darkest(Text(path).font(mono).foregroundStyle(SettingsColors.note))
        #expect(abs(shown - ink) < 12, "The path's darkest gray is \(shown), and ink's is \(ink)")
        #expect(gray - shown > 40, "The path's darkest gray is \(shown), and the help's is \(gray)")
    }

    /// The darkest gray in a view drawn on white, from 0 for black to 255,
    /// as the red of its darkest pixel.
    private static func darkest(_ view: some View) throws -> Int {
        let renderer = ImageRenderer(content: view.padding(4).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).map { Int(pixels[$0]) }.min() ?? 255
    }

    @Test func theSelectSaysWhatsChosenToVoiceOverToo() {
        let options: [(value: AgentKind, title: String)] = [(.claude, "Claude Code"), (.codex, "Codex")]
        #expect(SettingsSelect(selection: .constant(.codex), options: options).shownTitle == "Codex")
        #expect(SettingsSelect(selection: .constant(AgentKind.claude), options: [], emptyTitle: "None found").shownTitle == "None found")
    }

    @Test func theFlagsCardListsFlagsTheCommandHas() {
        for kind in AgentKind.allCases {
            // A server named as the card writes the placeholder, so that row
            // is found word for word.
            let agent = CommitMessageAgent(kind: kind, executable: kind.executableName, model: "m", effort: "low", mcpServers: ["<name>"])
            let arguments = CommitMessageCommand.command(for: agent, worktree: "/tmp", style: "s", hasDraft: false).arguments
            for flag in AgentDetailPage.flags(kind) {
                let words = flag.flag.split(separator: " ").map(String.init).filter { $0 != "…" }
                let found = arguments.indices.contains { start in
                    Array(arguments[start...].prefix(words.count)) == words
                }
                #expect(found, "\(flag.flag) isn't in \(kind.name)'s command")
            }
        }
    }

    @Test func theEventsCardListsEventsTheHooksSend() {
        for kind in AgentKind.allCases {
            let sent = kind == .claude ? HookPlugin.claudeEvents : HookPlugin.codexEvents
            for event in AgentDetailPage.events(kind) {
                for name in event.names.split(separator: ", ") {
                    #expect(sent.contains(String(name)), "\(name) isn't one of \(kind.name)'s hooks")
                }
            }
        }
    }

    @Test func runATestWritesAMessageForTheSampleInAFolderOfItsOwn() async {
        let agent = CommitMessageAgent(kind: .claude, executable: "/bin/claude", model: "haiku", effort: "low")
        let seen = Seen()
        let state = await AgentTestRun.test(agent, style: CommitMessagePrompt.defaultStyle) { command, input in
            let exists = command.directory.map { FileManager.default.fileExists(atPath: $0) } ?? false
            await seen.note(command.directory, String(decoding: input, as: UTF8.self), exists: exists)
            let reply = #"{"type":"result","is_error":false,"result":"Retry sign-in once after the token expires\n\nThe token was only refreshed at launch."}"#
            return ProgramResult(status: .exited(0), output: Array(reply.utf8), errorOutput: "", duration: .milliseconds(2400))
        }
        #expect(state == .replied(.milliseconds(2400), lines: 2))
        let (directory, input, existed) = await seen.values
        #expect(directory?.contains("roga-test-") == true)
        #expect(existed)
        #expect(input.contains("SessionStore.swift"))
        // The folder goes once the test is done.
        #expect(directory.map { !FileManager.default.fileExists(atPath: $0) } == true)
        let words = AgentTestRun.replied(in: .milliseconds(2400), lines: 2)
        #expect(words.time == "Replied in 2.4 s")
        #expect(words.rest == "with a two-line message for a sample diff.")
        #expect(AgentTestRun.replied(in: .seconds(6), lines: 14).rest == "with a 14-line message for a sample diff.")
    }

    @Test func runATestSaysHowTheAgentFailed() async {
        let agent = CommitMessageAgent(kind: .claude, executable: "/bin/claude")
        let state = await AgentTestRun.test(agent, style: "") { _, _ in
            let reply = #"{"type":"result","is_error":true,"result":"Failed to authenticate: OAuth session expired and could not be refreshed"}"#
            return ProgramResult(status: .exited(1), output: Array(reply.utf8), errorOutput: "", duration: .seconds(1))
        }
        #expect(state == .failed("Claude Code isn't signed in. Run claude auth login in Terminal."))
    }

    @Test func stoppingATestForgetsIt() async {
        let run = AgentTestRun()
        let agent = CommitMessageAgent(kind: .codex, executable: "/bin/codex")
        run.start(agent, style: "") { _, _ in
            try await Task.sleep(for: .seconds(30))
            return ProgramResult(status: .exited(0), output: [], errorOutput: "", duration: .zero)
        }
        #expect(run.isRunning)
        run.stop()
        #expect(run.state == .idle)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(run.state == .idle)
    }

    /// Quitting Roga stops a running test. Posting the real notification here
    /// would stop other suites' monitors too, so this checks that the run
    /// watches for it only while the agent runs.
    @Test func aRunningTestStopsWhenRogaQuits() async {
        let run = AgentTestRun()
        let agent = CommitMessageAgent(kind: .codex, executable: "/nonexistent/bin/codex")
        #expect(!run.isWatchingForQuit)
        run.start(agent, style: "") { _, _ in
            try await Task.sleep(for: .seconds(30))
            return ProgramResult(status: .exited(0), output: [], errorOutput: "", duration: .zero)
        }
        #expect(run.isWatchingForQuit)
        run.stop()
        #expect(!run.isWatchingForQuit)

        run.start(agent, style: "") { _, _ in
            ProgramResult(status: .exited(0), output: Array("Fix the sign-in button".utf8), errorOutput: "", duration: .milliseconds(10))
        }
        #expect(run.isWatchingForQuit)
        #expect(await AgentTestSupport.eventually { !run.isRunning })
        #expect(!run.isWatchingForQuit)
    }

    // MARK: Search

    @Test func searchFindsTheNewSettingsByTheirWords() {
        func found(_ query: String) -> [SettingsItem] {
            SettingsItem.allCases.filter { $0.matches(query) }
        }
        #expect(found("Generate button") == [.showsGenerateButton])
        #expect(found("instructions").contains(.instructions))
        #expect(found("Reset to Roga").contains(.instructions))
        #expect(found("subjects") == [.matchesStyle])
        #expect(found("roga-hooks") == [.hooks])
        // Git and the agents each have one.
        #expect(found("Look Again") == [.gitProgram, .agentList])
        #expect(found("Homebrew") == [.gitProgram])
        #expect(SettingsGroup.allCases.filter { $0.page == .git } == [.installation, .fetching])
        #expect(found("Codex").contains(.agentList))
        #expect(found("Codex").contains(.hooks))
        #expect(found("sidebar").contains(.showsMarks))
        #expect(found("Waiting for you") == [.marksLegend])
        #expect(found("plugins").contains(.generateCommand))
        // A page's name finds everything on it.
        #expect(Set(found("Agents")).isSuperset(of: [.agentList, .hooks, .showsMarks, .marksLegend]))
        #expect(SettingsGroup.generate.items.allSatisfy { $0.group.page == .commit })
        #expect(SettingsGroup.allCases.filter { $0.page == .agents } == [.commandLineAgents, .workingStatus])
    }
}

/// What someone typed in a box, for a binding to write to.
@MainActor
private final class Typed {
    var text: String

    init(_ text: String) {
        self.text = text
    }
}

/// What a fake run saw, kept across the run's task.
private actor Seen {
    private var directory: String?
    private var input = ""
    private var existed = false

    func note(_ directory: String?, _ input: String, exists: Bool) {
        self.directory = directory
        self.input = input
        existed = exists
    }

    var values: (String?, String, Bool) { (directory, input, existed) }
}
