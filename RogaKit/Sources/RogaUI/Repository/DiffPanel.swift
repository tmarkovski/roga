import AppKit
import DiffUI
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// Shows what changed in the selected file, in a commit or a worktree.
struct DiffPanel: View {
    let selection: SelectedFile
    /// The worktree's uncommitted changes, while they're what's showing, which
    /// gives the header a button for staging the file.
    var changes: SelectedChanges?
    /// How much room the panels under history take, which the buttons at the
    /// right of the header change.
    @Binding var size: LowerPanelSize
    /// Whether the header has room for the file's path beside the search box.
    @State private var hasRoomForTitle = true
    /// Whether the panel is wide enough for the buttons that go through the
    /// matches, beside the search box and the buttons for the panels' size.
    @State private var hasRoomForMatchButtons = true

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
            if let changes, let file = selection.file, let group = selection.group {
                Button(group.stageTitle) { changes.toggle(file, in: group) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Palette.separator)
                    }
                    .contentShape(Rectangle())
                    .help("\(group.stageTitle) (\(RepositoryCommands.stageShortcut.symbols))")
                    .fixedSize()
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
            Button(selection.isFindShown ? "Close Find" : "Find in Diff", icon: .search, action: selection.toggleFind)
                .labelStyle(.iconOnly)
                .buttonStyle(.icon(isOn: selection.isFindShown))
                .disabled(!selection.canFind && !selection.isFindShown)
                .help(selection.isFindShown ? "Close Find" : "Find in Diff (\(RepositoryCommands.findShortcut.symbols))")
            LowerPanelSizeButtons(size: $size)
        } content: {
            ZStack {
                switch selection.shown?.content {
                case .patch(let document):
                    DiffText(
                        document: document,
                        isUpdate: selection.shown?.isUpdate == true,
                        matches: selection.matches,
                        matchSteps: selection.matchSteps,
                        findCloses: selection.findCloses,
                        discardHunk: changes?.hunkDiscard
                    )
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
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= Self.widthForMatchButtons
        } action: { hasRoom in
            hasRoomForMatchButtons = hasRoom
        }
    }

    @ViewBuilder private var title: some View {
        if let shown = selection.shown {
            FileTitle(file: shown.file, source: shown.source)
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

/// A file's path, with the folders in gray and its name in full color, then
/// which group of a worktree's changes it's from, where it came from and how
/// its mode changed, if they did.
private struct FileTitle: View {
    let file: DiffFile
    let source: PatchSource

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
        if case .worktree(_, let group, _) = source { details.append(group.title) }
        if let oldPath = file.oldPath { details.append("from " + oldPath) }
        if file.oldMode != file.newMode, file.oldMode != 0, file.newMode != 0 {
            details.append("mode \(String(file.oldMode, radix: 8)) → \(String(file.newMode, radix: 8))")
        }
        return details.joined(separator: " · ")
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
