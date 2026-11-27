import AgentEngine
import AgentHooks
import AppKit
import Foundation
import GitRunner
import IconUI
import Observation
import SwiftUI

/// Claude Code's or Codex's own page, under Agents: which copy Roga runs, its
/// model and effort, and a test run (decisions 41 and 89). The model and
/// effort are the same ones the Generate popover shows. Its hooks are on the
/// Agents page, under Status, and the exact command shows in the Generate
/// popover.
struct AgentDetailPage: View {
    let kind: AgentKind
    @Environment(AgentProvider.self) private var agents
    /// The program someone chose, or nil for the one Roga finds. Changing it
    /// makes the provider look for the agent again.
    @AppStorage private var program: String?
    @AppStorage(AgentPreferences.instructionsKey) private var instructions = CommitMessagePrompt.defaultStyle
    @State private var test = AgentTestRun()

    init(kind: AgentKind) {
        self.kind = kind
        _program = AppStorage(AgentPreferences.programKey(kind))
    }

    var body: some View {
        SettingsSection("Configuration") {
            programRow
            SettingsRow(title: "Model", help: nil) {
                AgentModelControl(kind: kind)
            }
            SettingsRow(title: "Reasoning effort", help: nil) {
                AgentEffortControl(kind: kind)
            }
            SettingsBlock {
                AgentTestRow(test: test, name: kind.name, agent: agents.commitMessageAgent(kind), style: instructions)
            }
        }
        .onDisappear { test.stop() }
    }

    private var programRow: some View {
        let detail = AgentDetailPage.programDetail(kind, lookup: agents.lookups[kind], isChosen: program?.isEmpty == false)
        return SettingsRow(title: "Executable", help: detail.plain, namesControl: false) {
            VStack(alignment: .leading, spacing: 2) {
                if let path = detail.path {
                    // One line, cut in the middle, so that both the start of
                    // the path and the version show.
                    Self.pathLine(path, version: detail.version)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let sentence = detail.sentence {
                    Text(sentence)
                        .foregroundStyle(detail.isWarning ? AgentColors.warn : SettingsColors.note)
                }
            }
        } control: {
            // The same popover as on the agent's row in setup: every copy
            // Roga found, and Choose Another… for one it didn't. Roga looks at
            // what was chosen as soon as it's stored, and says on this page
            // if it can't use it.
            if let picker = ProgramPicker.agent(kind, agents: agents, choose: { program = $0 }) {
                ProgramSelect(title: Self.selectTitle(lookup: agents.lookups[kind], program: program), picker: picker)
            } else {
                Button("Choose…", action: choose)
                    .buttonStyle(.settings())
                    .disabled(agents.isLooking)
            }
        }
    }

    /// Asks for the program in an open panel, before Roga has a list of
    /// copies to show.
    private func choose() {
        if let path = ProgramPanel.choose(kind.executableName, startingAt: agents.installation(kind)?.executable) {
            program = path
        }
    }

    /// What the Program row's button says: where the copy in use is from, or
    /// that there's none.
    static func selectTitle(lookup: AgentLookup?, program: String?, home: String = NSHomeDirectory()) -> String {
        if case .found(let installation)? = lookup {
            return ProgramSource.of(installation.executable, home: home).name
        }
        if let program, !program.isEmpty {
            return ProgramSource.of(program, home: home).name
        }
        return "None"
    }

    // MARK: What it says

    /// What the Executable row says under its title.
    struct ProgramDetail: Equatable {
        /// The program's path, with the home folder as `~`.
        var path: String?
        /// The agent's name and version, as in "Claude Code 2.1.286".
        var version: String?
        /// Why there's no program Roga can use, or that it's looking. A copy
        /// that's found needs no words: the menu says where it's from.
        var sentence: String?
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

    /// Where the program is, or why there's none.
    static func programDetail(_ kind: AgentKind, lookup: AgentLookup?, isChosen: Bool) -> ProgramDetail {
        switch lookup {
        case nil:
            return ProgramDetail(sentence: "Searching…")
        case .found(let installation)?:
            return ProgramDetail(
                path: AgentSummaries.abbreviated(installation.executable),
                version: "\(kind.name) \(installation.version)"
            )
        case .notFound?:
            return ProgramDetail(sentence: "Not found in your login shell's PATH.")
        case .unusable(let skipped)?:
            return ProgramDetail(sentence: AgentSummaries.sentence(skipped.map(\.description).joined(separator: "; ")), isWarning: true)
        case .configuredMissing(let path)?:
            return ProgramDetail(
                path: AgentSummaries.abbreviated(path),
                sentence: "Custom executable not found or cannot be run.",
                isWarning: true
            )
        case .configuredUnusable(let skipped)?:
            return ProgramDetail(sentence: AgentSummaries.sentence(skipped.description), isWarning: true)
        }
    }
}

/// A custom agent's page, under Agents: its name and command, a test run,
/// and Delete Agent… (decision 89).
struct CustomAgentPage: View {
    let custom: CustomAgent
    /// Goes back to the Agents page, once the agent is deleted.
    let back: () -> Void
    @Environment(AgentProvider.self) private var agents
    @AppStorage(AgentPreferences.instructionsKey) private var instructions = CommitMessagePrompt.defaultStyle
    @State private var test = AgentTestRun()
    @State private var isDeleting = false

    var body: some View {
        SettingsSection("Configuration") {
            SettingsRow(title: "Name", help: nil) {
                SettingsTextField(text: field(\.name), width: 220)
            }
            SettingsRow(title: "Command", help: CustomAgentWords.commandHelp) {
                SettingsTextField(text: field(\.command), placeholder: CustomAgentWords.commandPlaceholder, width: 260, isMonospaced: true)
            }
            SettingsBlock {
                AgentTestRow(test: test, name: custom.shownName, agent: custom.agent, style: instructions)
            }
            SettingsBlock {
                Button("Delete Agent…") {
                    isDeleting = true
                }
                .buttonStyle(.settings(.destructive))
            }
        }
        .onDisappear { test.stop() }
        .dialog {
            guard isDeleting else { return nil }
            return CustomAgentWords.deleteDialog(custom, agents: agents) {
                isDeleting = false
            } delete: {
                isDeleting = false
                test.stop()
                agents.deleteCustomAgent(custom.id)
                back()
            }
        }
    }

    /// A field of the agent, stored as it's typed.
    private func field(_ path: WritableKeyPath<CustomAgent, String>) -> Binding<String> {
        Binding {
            agents.customAgent(custom.id)?[keyPath: path] ?? custom[keyPath: path]
        } set: { value in
            var changed = agents.customAgent(custom.id) ?? custom
            changed[keyPath: path] = value
            agents.updateCustomAgent(changed)
        }
    }
}

/// Adding a custom agent, as a Roga dialog (decision 29): its name and its
/// command, with the command it'll run along the bottom edge, and Run Test to
/// try it on a sample diff before it's added.
struct AddCustomAgentDialog: View {
    /// What to do with the agent once it's added.
    let added: (CustomAgent) -> Void
    @Environment(AgentProvider.self) private var agents
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AgentPreferences.instructionsKey) private var instructions = CommitMessagePrompt.defaultStyle
    @State private var name = ""
    @State private var command = ""
    @State private var test = AgentTestRun()

    private var draft: CustomAgent {
        CustomAgent(name: name, command: command)
    }

    private var hasCommand: Bool {
        !command.allSatisfy(\.isWhitespace)
    }

    var body: some View {
        DialogSheet(content: content) {
            VStack(alignment: .leading, spacing: 12) {
                labeled("Name") {
                    SettingsTextField(text: $name, placeholder: "Ollama", width: DialogSheet<EmptyView>.width - 36)
                }
                labeled("Command") {
                    SettingsTextField(text: $command, placeholder: CustomAgentWords.commandPlaceholder, width: DialogSheet<EmptyView>.width - 36, isMonospaced: true)
                }
                AgentTestRow(test: test, name: draft.shownName, agent: hasCommand ? draft.agent : nil, style: instructions)
            }
        }
        .onDisappear { test.stop() }
    }

    private var content: DialogContent {
        DialogContent(
            id: "addCustomAgent",
            title: "Add Custom Agent",
            message: DialogText(stringLiteral: CustomAgentWords.addMessage),
            terminal: CustomAgentWords.terminal(command),
            terminalHeight: 64,
            buttons: [
                DialogButton(title: "Cancel", kind: .secondary, action: close),
                DialogButton(title: "Add Agent", kind: .primary, isEnabled: hasCommand) {
                    test.stop()
                    added(agents.addCustomAgent(name: name, command: command))
                    dismiss()
                },
            ],
            dismiss: close
        )
    }

    private func close() {
        test.stop()
        dismiss()
    }

    private func labeled(_ title: String, @ViewBuilder field: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
            field()
        }
    }
}

/// What the custom agents' page and dialogs say, kept apart from the views so
/// that tests can check it.
enum CustomAgentWords {
    static let commandPlaceholder = "ollama run qwen2.5-coder:7b"

    static let commandHelp = "Reads the prompt from standard input and prints the response."

    static let addMessage = "A command that reads a prompt from standard input and prints a response, such as a local model. Custom agents don't show status in the sidebar."

    /// What runs, as the dialog's block shows it: where the instructions and
    /// the diff go, then the command in the shell, or the shell alone until
    /// there's a command.
    static func terminal(_ command: String) -> [TerminalLine] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let program = ProgramCommand(CommitMessageCommand.shell, trimmed.isEmpty ? ["-c", "…"] : ["-c", trimmed])
        return [.comment("Instructions and staged diff supplied via standard input"), .program(program)]
    }

    /// Asks before deleting a custom agent, and says what Generate, Resolve
    /// and Fix run instead when it's the default.
    static func deleteDialog(_ custom: CustomAgent, agents: AgentProvider, cancel: @escaping () -> Void, delete: @escaping () -> Void) -> DialogContent {
        let isDefault = agents.defaultAgent == .custom(custom.id)
        let next = agents.availableAgents.first { $0 != .custom(custom.id) }.flatMap(agents.named)
        let instead = isDefault ? (next.map { " Generate, Resolve and Fix will use \($0.name)." } ?? " Generate, Resolve and Fix will be hidden until another agent is available.") : ""
        return DialogContent(
            id: "deleteCustomAgent-\(custom.id)",
            title: "Delete \(custom.shownName)?",
            message: DialogText(stringLiteral: "Its command will no longer run.\(instead)"),
            buttons: [
                DialogButton(title: "Cancel", kind: .secondary, action: cancel),
                DialogButton(title: "Delete Agent", kind: .destructive, action: delete),
            ],
            dismiss: cancel
        )
    }
}

/// Run Test and what it says, on an agent's page and in Add Custom Agent.
struct AgentTestRow: View {
    let test: AgentTestRun
    /// What the agent is called, for "Waiting for Ollama…".
    let name: String
    /// How to run it, or nil while it can't be.
    let agent: CommitMessageAgent?
    let style: String
    @Environment(AgentProvider.self) private var agents

    var body: some View {
        HStack(spacing: 12) {
            Button(test.isRunning ? "Stop" : "Run Test") {
                if test.isRunning {
                    test.stop()
                } else if let agent, let programs = agents.programs {
                    test.start(agent, style: style) { try await programs.run($0, input: $1) }
                }
            }
            .buttonStyle(.settings())
            .disabled(!test.isRunning && (agent == nil || agents.programs == nil))
            AgentTestResult(name: name, state: test.state)
        }
    }
}

/// What Run a Test says: what it does before it's run, that it's waiting,
/// how long the agent took, or how it failed.
struct AgentTestResult: View {
    let name: String
    let state: AgentTestRun.State

    var body: some View {
        Group {
            switch state {
            case .idle:
                Text("Generate a commit message from a sample diff in a temporary folder.")
                    .foregroundStyle(SettingsColors.note)
            case .running:
                HStack(spacing: 7) {
                    AgentMark(state: .working)
                    Text("Waiting for \(name)…")
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
            return .failed("Couldn't make a folder for the test: \(error.localizedDescription)")
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

    /// Describes the generation time and the length of the sample commit message.
    nonisolated static func replied(in duration: Duration, lines: Int) -> (time: String, rest: String) {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let numbers = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let count = (1...numbers.count).contains(lines) ? numbers[lines - 1] : String(lines)
        return ("Generated in \(String(format: "%.1f", seconds)) s", "\(count)-line commit message from a sample diff.")
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
