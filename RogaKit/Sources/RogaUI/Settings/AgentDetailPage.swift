import AgentEngine
import AgentHooks
import AppKit
import Foundation
import GitRunner
import IconUI
import Observation
import SwiftUI

/// An agent's own page, under Agents: which program Roga runs and how it
/// runs it to write a commit message, a test run, and the agent's hooks
/// (decision 41). The model and effort are the same ones the Commit page and
/// the Generate popover show.
struct AgentDetailPage: View {
    let kind: AgentKind
    @Environment(AgentProvider.self) private var agents
    @Environment(AgentMonitor.self) private var monitor
    @Environment(RepositoryList.self) private var list
    @AppStorage private var isEnabled: Bool
    /// The program someone chose, or nil for the one Roga finds. Changing it
    /// makes the provider look for the agent again.
    @AppStorage private var program: String?
    @AppStorage private var extraArguments: String
    @AppStorage private var timeLimit: Int
    @AppStorage(AgentPreferences.instructionsKey) private var instructions = CommitMessagePrompt.defaultStyle
    @State private var test = AgentTestRun()
    @State private var dialog: HooksDialog.Request?
    @State private var places = HeardPlaces()

    init(kind: AgentKind) {
        self.kind = kind
        _isEnabled = AppStorage(wrappedValue: true, AgentPreferences.enabledKey(kind))
        _program = AppStorage(AgentPreferences.programKey(kind))
        _extraArguments = AppStorage(wrappedValue: "", AgentPreferences.extraArgumentsKey(kind))
        _timeLimit = AppStorage(wrappedValue: AgentPreferences.defaultTimeLimit, AgentPreferences.timeLimitKey(kind))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            commandSection
            runsSection
            workingStatusSection
        }
        .sheet(item: $dialog) { request in
            HooksDialog(request: request)
                .environment(agents)
        }
        .onDisappear { test.stop() }
    }

    // MARK: Command

    private var commandSection: some View {
        SettingsSection("Command") {
            SettingsRow(title: "Use \(kind.name)", help: "Off takes it out of the Generate button's picker. Its hooks stay as they are.") {
                Toggle("Use \(kind.name)", isOn: $isEnabled)
                    .toggleStyle(.settings)
            }
            programRow
            SettingsRow(title: "Model", help: GenerateChoices.modelHelp(kind, onAgentPage: true, agents: agents)) {
                AgentModelControl(kind: kind, typesName: kind == .codex)
            }
            SettingsRow(title: "Effort", help: GenerateChoices.effortHelp(kind, agents: agents)) {
                AgentEffortControl(kind: kind, isSegmented: false)
            }
            SettingsRow(title: "Extra arguments", help: "Added after Roga's own.") {
                SettingsTextField(
                    text: $extraArguments,
                    placeholder: kind == .claude ? "--append-system-prompt …" : "-c model_verbosity=low",
                    width: 220,
                    isMonospaced: true
                )
            }
            SettingsRow(title: "Time limit", help: "Roga stops the agent after this long.") {
                SettingsPopup(
                    selection: $timeLimit,
                    options: GenerateChoices.timeLimits(stored: timeLimit).map { (value: $0, title: "\($0) seconds") }
                )
            }
        }
    }

    private var programRow: some View {
        let detail = AgentDetailPage.programDetail(
            kind,
            lookup: agents.lookups[kind],
            isChosen: program?.isEmpty == false,
            isFirstInPath: agents.installation(kind).map { !agents.showsPath($0.executable) } ?? false
        )
        return SettingsRow(title: "Program", help: detail.plain, namesControl: false) {
            VStack(alignment: .leading, spacing: 2) {
                if let path = detail.path {
                    // One line, cut in the middle, so that both the start of
                    // the path and the version show.
                    Self.pathLine(path, version: detail.version)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(detail.sentence)
                    .foregroundStyle(detail.isWarning ? AgentColors.warn : SettingsColors.note)
            }
        } control: {
            HStack(spacing: 8) {
                if program?.isEmpty == false {
                    Button("Use the One Roga Finds") {
                        program = nil
                    }
                    .buttonStyle(.settings())
                }
                Button("Choose…", action: choose)
                    .buttonStyle(.settings())
            }
        }
    }

    /// Asks for the program in an open panel. Roga looks at what was chosen
    /// as soon as it's stored, and says on this page if it can't use it.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // The Codex inside the ChatGPT app is inside its bundle, and Claude
        // Code's is in a hidden folder.
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.message = "Choose the \(kind.executableName) program for Roga to run."
        if let current = agents.installation(kind)?.executable {
            panel.directoryURL = URL(filePath: (current as NSString).deletingLastPathComponent, directoryHint: .isDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        program = url.path(percentEncoded: false)
    }

    // MARK: How Roga runs it

    private var runsSection: some View {
        SettingsSection(
            title: "How Roga runs it",
            description: AttributedString("Each flag is there to keep a small job small. Roga always adds these, before your extra arguments.")
        ) {
            EmptyView()
        } content: {
            SettingsBlock {
                SettingsCard {
                    ForEach(Array(Self.flags(kind).enumerated()), id: \.offset) { _, flag in
                        SettingsCardRow(flag.flag, flag.why)
                    }
                }
            }
            SettingsBlock {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsCommand(lines: GenerateChoices.terminal(for: kind, agents: agents, style: instructions))
                    testRow
                }
            }
        }
    }

    private var testRow: some View {
        HStack(spacing: 12) {
            Button(test.isRunning ? "Stop" : "Run a Test") {
                if test.isRunning {
                    test.stop()
                } else if let agent = agents.commitMessageAgent(kind), let programs = agents.programs {
                    test.start(agent, style: instructions) { try await programs.run($0, input: $1) }
                }
            }
            .buttonStyle(.settings())
            .disabled(!test.isRunning && (agents.commitMessageAgent(kind) == nil || agents.programs == nil))
            AgentTestResult(kind: kind, state: test.state)
        }
    }

    // MARK: Working status

    private var workingStatusSection: some View {
        SettingsSection(
            title: "Working status",
            description: .settingsWords([
                ("Each hook runs ", false),
                ("roga hook --host \(kind.rawValue)", true),
                (", which tells Roga the event and the folder. It returns at once, and does nothing while Roga is closed.", false),
            ])
        ) {
            EmptyView()
        } content: {
            TimelineView(.everyMinute) { _ in
                let line = AgentSummaries.hookLine(kind, agents: agents, heard: heard, now: .now) {
                    places.place(of: $0, in: list)
                }
                SettingsRow(title: "Hooks", help: line.spoken, namesControl: false) {
                    HookLineText(line: line)
                } control: {
                    if let button = line.button {
                        Button(button.title) {
                            dialog = HooksDialog.Request(
                                kind: kind,
                                action: button.action,
                                offers: HooksDialog.otherAgent(for: kind, action: button.action, agents: agents)
                            )
                        }
                        .buttonStyle(.settings(button.action == .install ? .primary : .secondary))
                        .disabled(!button.isEnabled)
                        .accessibilityLabel(button.spokenTitle(kind))
                    }
                }
            }
            SettingsBlock {
                SettingsCard {
                    ForEach(Array(Self.events(kind).enumerated()), id: \.offset) { _, event in
                        SettingsCardRow(name: event.names, centersValue: true) {
                            HStack(spacing: 7) {
                                Group {
                                    if let state = event.state {
                                        AgentMark(state: state, size: 14)
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 14, height: 14)
                                Text(event.meaning)
                            }
                        }
                    }
                }
            }
        }
    }

    private var heard: AgentProvider.Heard? {
        AgentHost(rawValue: kind.rawValue).flatMap { monitor.lastHeard[$0] }
    }

    // MARK: What it says

    /// What the Program row says under its title.
    struct ProgramDetail: Equatable {
        /// The program's path, with the home folder as `~`.
        var path: String?
        /// The agent's name and version, as in "Claude Code 2.1.286".
        var version: String?
        var sentence: String
        var isWarning = false

        /// All of it in words, for VoiceOver.
        var plain: String {
            [path.map { $0 + (version.map { " · " + $0 } ?? "") }, sentence].compactMap(\.self).joined(separator: ". ")
        }
    }

    /// The program's path in ink, in the code font, and its version in gray
    /// after it, as the canvas draws them. The ink is `Color.primary`, the
    /// row title's color: the row draws its help in gray, and `.primary` on
    /// its own would mean the first level of that gray.
    static func pathLine(_ path: String, version: String?) -> Text {
        let path = Text(path).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.primary)
        let version = Text(version.map { " · \($0)" } ?? "").foregroundStyle(SettingsColors.note)
        return Text("\(path)\(version)")
    }

    /// Where the program is and how Roga came to it, or why it has none.
    ///
    /// - Parameter isFirstInPath: Whether the program is the one its name
    ///   finds in the login shell's `PATH`.
    static func programDetail(_ kind: AgentKind, lookup: AgentLookup?, isChosen: Bool, isFirstInPath: Bool) -> ProgramDetail {
        switch lookup {
        case nil:
            return ProgramDetail(sentence: "Looking…")
        case .found(let installation)?:
            let how = if isChosen {
                "Chosen by you."
            } else if kind.prefersNewest, !installation.others.isEmpty {
                "The newest of the copies Roga found."
            } else if isFirstInPath {
                "Found in your login shell's PATH."
            } else {
                "Found outside your login shell's PATH, where its installer puts it."
            }
            return ProgramDetail(
                path: AgentSummaries.abbreviated(installation.executable),
                version: "\(kind.name) \(installation.version)",
                sentence: how
            )
        case .notFound?:
            return ProgramDetail(sentence: "Not found in your login shell's PATH.")
        case .unusable(let skipped)?:
            return ProgramDetail(sentence: AgentSummaries.sentence(skipped.map(\.description).joined(separator: "; ")), isWarning: true)
        case .configuredMissing(let path)?:
            return ProgramDetail(
                path: AgentSummaries.abbreviated(path),
                sentence: "Chosen by you, but Roga can't find or run it.",
                isWarning: true
            )
        case .configuredUnusable(let skipped)?:
            return ProgramDetail(sentence: AgentSummaries.sentence(skipped.description), isWarning: true)
        }
    }

    /// The flags Roga always gives the agent, and why, in the order the
    /// command has them (`CommitMessageCommand`).
    static func flags(_ kind: AgentKind) -> [(flag: String, why: String)] {
        switch kind {
        case .claude:
            [
                ("-p", "Prints its answer and exits, rather than starting a conversation."),
                ("--safe-mode", "Leaves out your hooks, plugins, skills, MCP servers and CLAUDE.md, so only Roga's instructions count."),
                ("--setting-sources user", "Leaves out the worktree's own .claude settings, which it would otherwise use without asking whether you trust the folder."),
                ("--tools=", "No tools, so it can't run commands, read other files or change anything."),
                ("--no-session-persistence", "Leaves no session behind in Claude Code's history."),
            ]
        case .codex:
            [
                ("exec", "Prints its answer and exits, rather than starting a conversation."),
                ("--ephemeral", "Leaves no session behind in Codex's history."),
                ("--sandbox read-only", "It can read the worktree, but can't change files or reach the network."),
                ("--disable hooks …", "And plugins, apps and its shell tool, so nothing of yours runs and it answers without running commands."),
                ("-c mcp_servers.<name>.enabled=false", "Turns off each MCP server in your config.toml, since they would start with every run and act outside the sandbox."),
            ]
        }
    }

    /// Which of the agent's hook events change the sidebar's mark, and to
    /// what, as `AgentSessions` reads them.
    static func events(_ kind: AgentKind) -> [(names: String, state: AgentSummary.State?, meaning: String)] {
        let waiting = switch kind {
        case .claude: "Notification, PermissionRequest"
        case .codex: "PermissionRequest"
        }
        return [
            ("UserPromptSubmit, PreToolUse", .working, "Working"),
            (waiting, .waiting(.permission), "Waiting for you"),
            ("Stop", .finished, "Finished"),
            ("SessionEnd", nil, "Gone from the sidebar"),
        ]
    }
}

/// What Run a Test says: what it does before it's run, that it's waiting,
/// how long the agent took, or how it failed.
struct AgentTestResult: View {
    let kind: AgentKind
    let state: AgentTestRun.State

    var body: some View {
        Group {
            switch state {
            case .idle:
                Text("Writes a message for a small sample diff, in a folder of its own.")
                    .foregroundStyle(SettingsColors.note)
            case .running:
                HStack(spacing: 7) {
                    SettingsSpinner()
                    Text("Waiting for \(kind.name)…")
                        .foregroundStyle(SettingsColors.note)
                }
            case .replied(let duration, let lines):
                let words = AgentTestRun.replied(in: duration, lines: lines)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Icon.check.image
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(words.time)
                            .fontWeight(.medium)
                    }
                    .foregroundStyle(AgentColors.ok)
                    Text(words.rest)
                        .foregroundStyle(SettingsColors.note)
                }
            case .failed(let words):
                Text(words)
                    .foregroundStyle(SettingsColors.danger)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 12.5))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small ring with a darker quarter that turns, while something runs. With
/// Reduce Motion on, it stays still, as the commit box's does, and the words
/// beside it say that something runs.
struct SettingsSpinner: View {
    @State private var isTurning = false
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    var body: some View {
        Circle()
            .strokeBorder(SettingsColors.line, lineWidth: 1.5)
            .overlay {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(SettingsColors.note, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(0.75)
                    .rotationEffect(.degrees(isTurning ? 270 : -90))
            }
            .frame(width: 12, height: 12)
            .onAppear {
                guard !reducesMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { isTurning = true }
            }
            .accessibilityHidden(true)
    }
}

/// One run of Run a Test on an agent's page: the agent writes a message for
/// a small sample diff, in a temporary folder of its own, with what's chosen
/// for it, so that someone can see it works before relying on Generate.
@MainActor @Observable
final class AgentTestRun {
    enum State: Equatable {
        case idle
        case running
        case replied(Duration, lines: Int)
        case failed(String)
    }

    private(set) var state = State.idle
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Watches for Roga quitting while the agent runs, as `MessageGenerators`
    /// does for Generate, since the agent's process group would outlive Roga.
    @ObservationIgnored private var termination: (any NSObjectProtocol)?

    var isRunning: Bool { state == .running }
    /// Whether quitting Roga would stop the agent, for tests.
    var isWatchingForQuit: Bool { termination != nil }

    /// Runs the agent once, stopping a run that's under way first.
    ///
    /// - Parameter run: Runs a command with bytes for its standard input,
    ///   which is `{ try await programs.run($0, input: $1) }` in the app.
    func start(
        _ agent: CommitMessageAgent,
        style: String,
        run: @escaping @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult
    ) {
        task?.cancel()
        state = .running
        watchForQuit()
        task = Task {
            let outcome = await Self.test(agent, style: style, run: run)
            guard !Task.isCancelled else { return }
            state = outcome
            stopWatchingForQuit()
        }
    }

    /// Stops the agent, if it's running, and forgets the run.
    func stop() {
        task?.cancel()
        task = nil
        stopWatchingForQuit()
        if state == .running { state = .idle }
    }

    private func watchForQuit() {
        guard termination == nil else { return }
        termination = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    private func stopWatchingForQuit() {
        if let termination { NotificationCenter.default.removeObserver(termination) }
        termination = nil
    }

    /// The test itself, away from the main actor: a folder of its own, which
    /// is removed afterward, the sample, and the agent's reply.
    @concurrent
    static func test(
        _ agent: CommitMessageAgent,
        style: String,
        run: @Sendable (ProgramCommand, [UInt8]) async throws -> ProgramResult
    ) async -> State {
        let folder = FileManager.default.temporaryDirectory.appending(path: "roga-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .failed("Roga couldn't make a folder for the test: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        let request = CommitMessageRequest(
            worktree: folder.path(percentEncoded: false),
            repository: "sample",
            branch: "fix-sign-in",
            changes: sample,
            style: style
        )
        do {
            let message = try await CommitMessageWriter.write(request, with: agent, run: run)
            return .replied(message.duration, lines: lineCount(message.text))
        } catch let error as CommitMessageError {
            return .failed(error.description)
        } catch is CancellationError {
            return .idle
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// What the result says: "Replied in 2.4 s" and "with a two-line message
    /// for a sample diff."
    nonisolated static func replied(in duration: Duration, lines: Int) -> (time: String, rest: String) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let count = (1...numbers.count).contains(lines) ? numbers[lines - 1] : String(lines)
        return ("Replied in \(String(format: "%.1f", seconds)) s", "with a \(count)-line message for a sample diff.")
    }

    /// The lines of a message that have something on them.
    nonisolated static func lineCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }.count
    }

    /// A small change to sign-in, which is what the agent writes a message
    /// for.
    nonisolated static let sample = CommitMessageInput(
        files: [CommitMessageInput.File(path: "Sources/App/SessionStore.swift", status: "M", added: 5, deleted: 1)],
        patch: """
            diff --git a/Sources/App/SessionStore.swift b/Sources/App/SessionStore.swift
            index 3b18e51..a9c4f02 100644
            --- a/Sources/App/SessionStore.swift
            +++ b/Sources/App/SessionStore.swift
            @@ -12,7 +12,11 @@ final class SessionStore {
                 func signIn() async throws -> Session {
                     let token = try await tokens.current()
            -        return try await api.login(token)
            +        do {
            +            return try await api.login(token)
            +        } catch APIError.expired {
            +            return try await api.login(tokens.refresh())
            +        }
                 }

            """
    )
}
