import AgentEngine
import AppKit
import DiffUI
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI
import ThemeUI

/// Shows what changed in the selected file, in a commit or a worktree.
struct DiffPanel: View {
    let selection: SelectedFile
    /// The worktree's uncommitted changes, while they're what's showing, which
    /// gives the header a button for staging the file.
    var changes: SelectedChanges?
    /// How much room the panels under history take, which the buttons at the
    /// right of the header change.
    @Binding var size: LowerPanelSize
    /// The agents, for asking the one Generate runs to resolve a file's
    /// conflicts (decision 60). A view that's tested on its own has none.
    @Environment(AgentProvider.self) private var agents: AgentProvider?
    /// Whether the header has room for the file's path beside the search box.
    @State private var hasRoomForTitle = true
    /// Whether the panel is wide enough for the buttons that go through the
    /// matches, beside the search box and the buttons for the panels' size.
    @State private var hasRoomForMatchButtons = true
    /// Whether diffs show only their hunks or the whole file (decision 74).
    @AppStorage(DiffSettings.layout) private var layout = DiffLayout.hunks

    /// The widest the search box gets, so that it doesn't reach across a wide
    /// screen.
    nonisolated private static let findBoxWidth = 320.0
    /// How much room the path needs to be worth showing beside the box.
    nonisolated private static let titleWidthBesideFindBox = 120.0
    /// The space after the path.
    nonisolated private static let titleSpacing = 12.0
    /// How wide the panel has to be for the buttons that go through the
    /// matches. In a narrower one, they give way so that the box keeps room
    /// for what's typed, since Return, Shift-Return and Command-G do the same.
    nonisolated private static let widthForMatchButtons = 240.0

    var body: some View {
        @Bindable var selection = selection
        Panel {
            HStack(spacing: 0) {
                if !selection.isFindShown || hasRoomForTitle {
                    title
                        .padding(.trailing, Self.titleSpacing)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer(minLength: 0)
                }
                if selection.isFindShown {
                    PanelSearchField(
                        prompt: "Find",
                        label: "Find in Diff",
                        text: $selection.findText,
                        wantsFocus: $selection.wantsFindFocus,
                        note: selection.matchesNote,
                        submit: { isBackwards in
                            if isBackwards { selection.findPrevious() } else { selection.findNext() }
                        },
                        close: selection.closeFind
                    )
                    .frame(maxWidth: Self.findBoxWidth)
                    .layoutPriority(1)
                }
            }
            .onGeometryChange(for: Bool.self) { geometry in
                geometry.size.width >= Self.findBoxWidth + Self.titleSpacing + Self.titleWidthBesideFindBox
            } action: { hasRoom in
                hasRoomForTitle = hasRoom
            }
        } trailing: {
            if let changes, let file = selection.file, let group = selection.group, file.isSubmodule {
                // Once the panel has read the submodule, the buttons go by the
                // same reading as the words under them.
                SubmoduleButtons(file: selection.shownSubmodule ?? changes.listed(file, in: group), group: group, changes: changes)
            } else if let changes, let file = selection.file, let group = selection.group {
                if group == .conflicted, let conflicts = selection.shown?.conflicts, selection.shown?.file.path == file.path {
                    let setup = conflicts.left > 0 && changes.agentWork[file.path]?.isWorking != true ? agents?.generation() : nil
                    if let setup, let worktree {
                        ResolveWithAgentButton(title: "Resolve with \(setup.kind.shortName)") {
                            changes.askAgent(setup)
                        }
                        .help(Self.agentHelp(setup, worktree: worktree, left: conflicts.left))
                    }
                    ConflictFileMenu(
                        file: file,
                        sides: conflicts.sides,
                        worktree: worktree,
                        agent: setup.map { setup in ("Resolve with \(setup.kind.name)", { changes.askAgent(setup) }) },
                        keep: { changes.keep($0, of: file) },
                        putBack: { changes.putConflictsBack(in: file) }
                    )
                }
                // Once a conflicted file has no markers left, marking it resolved
                // is what's next, so it's orange, as a button that runs now is.
                let isNext = group == .conflicted && selection.shown?.conflicts?.left == 0 && selection.shown?.file.path == file.path
                Button(group.stageTitle) { changes.toggle(file, in: group) }
                    .buttonStyle(OutlinedButtonStyle(height: 24, cornerRadius: 6, isNext: isNext))
                    .help("\(group.stageTitle) (\(RepositoryCommands.stageShortcut.symbols))")
            }
            if selection.isFindShown, hasRoomForMatchButtons {
                Button("Previous Match", icon: .chevronUp, action: selection.findPrevious)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.icon)
                    .disabled(!selection.hasMatches)
                    .help("Previous Match (\(RepositoryCommands.findPreviousShortcut.symbols))")
                Button("Next Match", icon: .chevronDown, action: selection.findNext)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.icon)
                    .disabled(!selection.hasMatches)
                    .help("Next Match (\(RepositoryCommands.findNextShortcut.symbols))")
            }
            // It looks pressed while the whole file shows, as the button for a
            // tree of files does while they're in one.
            Button(layout.switchTitle, icon: .inlineDiff) {
                layout = layout == .inline ? .hunks : .inline
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.icon(isOn: layout == .inline))
            .disabled(!selection.canChangeLayout)
            .help(layout.switchTitle)
            Button(selection.isFindShown ? "Close Find" : "Find in Diff", icon: .search, action: selection.toggleFind)
                .labelStyle(.iconOnly)
                .buttonStyle(.icon(isOn: selection.isFindShown))
                .disabled(!selection.canFind && !selection.isFindShown)
                .help(selection.isFindShown ? "Close Find" : "Find in Diff (\(RepositoryCommands.findShortcut.symbols))")
            LowerPanelSizeButtons(size: $size)
        } content: {
            VStack(spacing: 0) {
            if let changes, selection.group == .conflicted, let path = selection.file?.path, let work = changes.agentWork[path] {
                AgentNote(
                    work: work,
                    stop: { changes.stopAgent(for: path) },
                    putBack: { if let file = selection.file { changes.putConflictsBack(in: file) } },
                    close: { changes.forgetAgentWork(for: path) },
                    tryAgain: agents?.generation(with: work.kind).map { setup in { changes.askAgent(setup) } }
                )
            }
            ZStack {
                switch selection.shown?.content {
                case .patch(let document):
                    DiffText(
                        document: document,
                        isUpdate: selection.shown?.isUpdate == true,
                        matches: selection.matches,
                        matchSteps: selection.matchSteps,
                        findCloses: selection.findCloses,
                        discardHunk: changes?.hunkDiscard,
                        resolveConflict: changes?.conflictResolve,
                        agentIsResolving: selection.file.flatMap { changes?.agentWork[$0.path]?.isWorking } == true
                    )
                case .submodule(let details):
                    SubmoduleReportView(report: SubmoduleReport(details, path: selection.shown?.file.path ?? ""))
                case .note(let text):
                    note(text)
                case .failed(let message):
                    note(message)
                        .textSelection(.enabled)
                case nil:
                    Color.clear
                }
                if selection.isWaiting {
                    Palette.surface
                    ProgressView()
                        .controlSize(.small)
                }
            }
            }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= Self.widthForMatchButtons
        } action: { hasRoom in
            hasRoomForMatchButtons = hasRoom
        }
        // A diff built before another code font was chosen is built again in
        // that one: as it's chosen, and when a panel comes back to a diff from
        // before (decision 73).
        .onChange(of: CodeFont.observed, initial: true) {
            selection.followCodeFont()
        }
        // A diff read before the other layout was chosen is read again in
        // that one: as it's chosen, here or in the View menu, and when a panel
        // comes back to a diff from before (decision 74).
        .onChange(of: layout, initial: true) {
            selection.followLayout()
        }
    }

    /// What asking an agent does, and the exact command, as decision 29 asks.
    private static func agentHelp(_ setup: GenerationSetup, worktree: String, left: Int) -> String {
        let conflicts = left == 1 ? "the conflict" : "the \(left) conflicts"
        let command = CommandBlock.copied([.program(ConflictResolutionWriter.command(for: setup.agent, worktree: worktree), showsPath: setup.showsPath)])
        return "Resolve \(conflicts) with \(setup.label). Conflicts are supplied via standard input. Review the result before marking the file resolved.\n\n" + command
    }

    /// The worktree the uncommitted changes are in, for opening a file there.
    private var worktree: String? {
        if case .worktree(let path, _, _) = selection.source { path } else { nil }
    }

    @ViewBuilder private var title: some View {
        if let shown = selection.shown {
            FileTitle(file: shown.file, source: shown.source, conflicts: shown.conflicts)
        } else {
            Text("Diff")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The name of the setting that the diff panel and the menu bar share.
enum DiffSettings {
    static let layout = "diffLayout"
}

extension DiffLayout {
    /// The layout `defaults` has, which is hunks until another is chosen.
    static func stored(in defaults: UserDefaults = .standard) -> DiffLayout {
        defaults.string(forKey: DiffSettings.layout).flatMap(DiffLayout.init(rawValue:)) ?? .hunks
    }

    /// What the View menu calls it.
    var title: String {
        switch self {
        case .hunks: "Hunks"
        case .inline: "Inline"
        }
    }

    /// What the diff panel's button does while this layout shows, which says
    /// what the other one is as well as its name.
    var switchTitle: String {
        switch self {
        case .hunks: "Show the Whole File (Inline View)"
        case .inline: "Show Only the Hunks (Hunk View)"
        }
    }
}

/// A file's path, with the folders in gray and its name in full color, then
/// which group of a worktree's changes it's from, where it came from and how
/// its mode changed, if they did.
private struct FileTitle: View {
    let file: DiffFile
    let source: PatchSource
    var conflicts: ConflictSummary?

    var body: some View {
        HStack(spacing: 8) {
            path
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(1)
            if !details.isEmpty {
                Text(details)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.leading, 4)
        .help(file.path)
    }

    private var path: Text {
        let folder = file.folder.isEmpty ? "" : file.folder + "/"
        return Text("\(Text(folder).foregroundStyle(.secondary))\(Text(file.name))")
    }

    private var details: String {
        var details: [String] = []
        if let group = source.group { details.append(group.title) }
        if file.isSubmodule { details.append("Submodule") }
        if let conflicts, conflicts.total > 0 {
            details.append(conflicts.left == 0 ? "none left" : "\(conflicts.left) of \(conflicts.total) left")
        }
        if let oldPath = file.oldPath { details.append("from " + oldPath) }
        if file.oldMode != file.newMode, file.oldMode != 0, file.newMode != 0 {
            details.append("mode \(String(file.oldMode, radix: 8)) → \(String(file.newMode, radix: 8))")
        }
        return details.joined(separator: " · ")
    }
}

/// The header's buttons for a submodule's row under uncommitted changes, which
/// go by what staging it would do (decision 75).
///
/// - A checkout with new commits has **Stage**, which records them.
/// - One that's behind what's recorded has **Update**, in the orange of what
///   comes next, and staging it is in the menu, for someone who means to go back.
/// - One that has commits of its own and is missing some has both in the menu
///   and neither as a button, because either one leaves commits out. So has
///   one that hasn't been read, or couldn't be.
/// - One with only files of its own changed has nothing, because the parent
///   can't stage those.
private struct SubmoduleButtons: View {
    let file: DiffFile
    let group: WorktreeChanges.Group
    let changes: SelectedChanges

    var body: some View {
        switch group == .unstaged ? file.submoduleStaging : nil {
        case nil:
            // Under Staged, and for a submodule whose folder is gone, it's
            // staged and unstaged as any file is.
            let title = group == .staged ? "Unstage" : "Stage"
            Button(title) { changes.toggle(file, in: group) }
                .buttonStyle(OutlinedButtonStyle(height: 24, cornerRadius: 6))
                .help("\(title) (\(RepositoryCommands.stageShortcut.symbols))")
        case .recordsNewCommits:
            Button("Stage") { changes.toggle(file, in: group) }
                .buttonStyle(OutlinedButtonStyle(height: 24, cornerRadius: 6))
                .help("Record the commit that's checked out (\(RepositoryCommands.stageShortcut.symbols))")
        case .takesCommitsAway:
            Button("Update") { changes.updateSubmodule(file) }
                .buttonStyle(OutlinedButtonStyle(height: 24, cornerRadius: 6, isNext: true))
                .help(SubmoduleWords.updateHelp(file))
            menu {
                Button("Stage the checked-out commit instead") { changes.toggle(file, in: group) }
            }
        case .takesSomeAndAddsSome, .unknown:
            // One that couldn't be read has both too, so that it can still be
            // staged or updated from here by someone who knows which they want.
            menu {
                Button("Update to the recorded commit") { changes.updateSubmodule(file) }
                Button("Stage the checked-out commit") { changes.toggle(file, in: group) }
            }
        case .nothingToStage:
            EmptyView()
        }
    }

    private func menu(@ViewBuilder _ items: () -> some View) -> some View {
        Menu(content: items) {
            Icon.ellipsis.image
        }
        .menuStyle(.button)
        .buttonStyle(.icon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Update or Stage the Submodule")
        .accessibilityLabel("Update or Stage the Submodule")
    }
}

/// Places the AppKit text view in SwiftUI (decision 9).
private struct DiffText: NSViewRepresentable {
    let document: DiffDocument
    /// Whether the document is a newer copy of the one showing.
    let isUpdate: Bool
    let matches: SelectedFile.Matches?
    let matchSteps: Int
    let findCloses: Int
    let discardHunk: ((Int) -> Void)?
    let resolveConflict: ((ConflictRequest) -> Void)?
    /// Whether an agent is working on the conflicts showing.
    let agentIsResolving: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(matchSteps: matchSteps, findCloses: findCloses)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.controller.view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let controller = context.coordinator.controller
        controller.show(document, keepingPosition: isUpdate)
        controller.discardHunk = discardHunk
        controller.resolveConflict = resolveConflict
        if (controller.makeConflictOutline != nil) != agentIsResolving {
            controller.makeConflictOutline = agentIsResolving ? { AgentOutlineView.aroundWork(cornerRadius: 6) } : nil
        }
        // Before the marks go away, since closing selects the current one.
        context.coordinator.update(findCloses: findCloses)
        // What's marked can be from the document before this one, until the
        // search of this one is done.
        let shown = matches?.document === document ? matches : nil
        controller.showMatches(shown?.ranges ?? [], current: shown?.current)
        context.coordinator.update(matchSteps: matchSteps)
    }

    final class Coordinator {
        let controller = DiffTextController()
        private var matchSteps: Int
        private var findCloses: Int

        init(matchSteps: Int, findCloses: Int) {
            self.matchSteps = matchSteps
            self.findCloses = findCloses
        }

        func update(matchSteps: Int) {
            guard matchSteps != self.matchSteps else { return }
            self.matchSteps = matchSteps
            controller.scrollToCurrentMatch()
        }

        func update(findCloses: Int) {
            guard findCloses != self.findCloses else { return }
            self.findCloses = findCloses
            controller.endFind()
        }
    }
}

/// The menu for a conflicted file in the diff panel's header: one side's whole
/// version, for a file such as a lockfile where one side is right, and opening the
/// file in the app that opens it, for resolving it there (decision 60).
private struct ConflictFileMenu: View {
    let file: DiffFile
    let sides: ConflictSides
    let worktree: String?
    /// Asking the agent Generate runs, with what the item says, when it can be asked.
    let agent: (title: String, ask: () -> Void)?
    let keep: (ConflictSide) -> Void
    let putBack: () -> Void

    var body: some View {
        Menu {
            if let agent {
                Button(agent.title, action: agent.ask)
                Divider()
            }
            Button("\(sides.ours.keepTitle) version") { keep(.ours) }
            Button("\(sides.theirs.keepTitle) version") { keep(.theirs) }
            Button("Restore conflicts", action: putBack)
            if let url {
                Divider()
                Button("Open in \(Self.appName(opening: url) ?? "default app")") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Icon.ellipsis.image
        }
        .menuStyle(.button)
        .buttonStyle(.icon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Keep a Version or Open the File")
        .accessibilityLabel("Keep a Version or Open the File")
    }

    private var url: URL? {
        worktree.map { URL(filePath: $0).appending(path: file.path) }
    }

    /// The name of the app that opening a file opens it in, such as Xcode.
    private static func appName(opening url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path(percentEncoded: false)).replacing(/\.app$/, with: "")
    }
}

/// The button in the header for asking an agent to resolve a file's conflicts,
/// with the orange line that marks an agent's command (decision 68).
private struct ResolveWithAgentButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .contentShape(Rectangle())
            .overlay {
                AgentOutline(shape: .outline(cornerRadius: 6), isHovering: isHovering)
            }
            .onHover { isHovering = $0 }
            .fixedSize()
    }
}

/// What an agent asked to resolve a file's conflicts is doing, or what came of it,
/// in a strip above the file (decision 60).
private struct AgentNote: View {
    let work: SelectedChanges.AgentWork
    let stop: () -> Void
    let putBack: () -> Void
    let close: () -> Void
    let tryAgain: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            icon
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                title
                    .font(.system(size: 12, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(5)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.hover)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var conflicts: String {
        work.asked == 1 ? "the conflict" : "\(work.asked) conflicts"
    }

    @ViewBuilder private var icon: some View {
        switch work.phase {
        case .working: AgentMark(state: .working)
        case .done: AgentMark(state: .finished)
        case .failed: Icon.warning.image.foregroundStyle(Palette.red)
        }
    }

    @ViewBuilder private var title: some View {
        switch work.phase {
        case .working(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Text("\(work.label) is resolving \(conflicts)… \(seconds) s")
                    .monospacedDigit()
            }
        case .done(_, let resolved, let duration):
            let seconds = max(1, Int(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 + 0.5))
            let which = resolved == work.asked ? conflicts : "\(resolved) of \(work.asked) conflicts"
            Text("\(work.label) resolved \(which) in \(seconds) s. Review the changes before marking the file resolved.")
        case .failed:
            Text("\(work.kind.name) didn't resolve them")
        }
    }

    private var detail: String? {
        switch work.phase {
        case .working: nil
        case .done(let explanation, _, _): explanation.isEmpty ? nil : explanation
        case .failed(let message, let output): output.map { message + "\n" + $0 } ?? message
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch work.phase {
            case .working:
                noteButton("Stop", action: stop)
            case .done:
                noteButton("Restore Conflicts", action: putBack)
                closeButton
            case .failed:
                if let tryAgain { noteButton("Try Again", action: tryAgain) }
                closeButton
            }
        }
    }

    private func noteButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.outlined)
    }

    /// As tall as the button beside it.
    private var closeButton: some View {
        Button("Close", icon: .x) { close() }
            .labelStyle(.iconOnly)
            .buttonStyle(.icon(size: 22))
            .help("Close")
    }
}

extension SelectedChanges.AgentWork {
    var isWorking: Bool {
        if case .working = phase { true } else { false }
    }
}
