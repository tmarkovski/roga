import AppKit
import DiffUI
import GitCore
import RepositoryEngine
import SwiftUI

/// Shows what changed in the selected file, in a commit or a worktree.
struct DiffPanel: View {
    let selection: SelectedFile

    var body: some View {
        Panel {
            if let shown = selection.shown {
                FileTitle(file: shown.file, source: shown.source)
            } else {
                Text("Diff")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.leading, 4)
            }
        } trailing: {
            Button("Find in Diff", systemImage: "magnifyingglass") {
                selection.find()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.icon)
            .disabled(!selection.canFind)
            .help("Find in Diff (\(RepositoryCommands.findShortcut.symbols))")
        } content: {
            ZStack {
                switch selection.shown?.content {
                case .patch(let document):
                    DiffText(document: document, isUpdate: selection.shown?.isUpdate == true, findRequests: selection.findRequests)
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
    let findRequests: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(findRequests: findRequests)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.controller.view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.controller.show(document, keepingPosition: isUpdate)
        context.coordinator.update(findRequests: findRequests)
    }

    final class Coordinator {
        let controller = DiffTextController()
        private var findRequests: Int

        init(findRequests: Int) {
            self.findRequests = findRequests
        }

        func update(findRequests: Int) {
            guard findRequests != self.findRequests else { return }
            self.findRequests = findRequests
            controller.showFind()
        }
    }
}
