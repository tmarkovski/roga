import AppKit
import CommitGraph
import GitCore
import GitRunner
import RepositoryEngine
import SwiftUI

/// One worktree: its history, and the commit and file selected in it.
struct RepositoryView: View {
    let model: RepositoryModel
    /// Shows one of the repository's worktrees in the window, by its folder,
    /// with a commit selected in it.
    let showWorktree: (String, ObjectID?) -> Void
    @AppStorage("commitPanelHeight") private var commitPanelHeight = 340.0
    @AppStorage("commitPanelWidth") private var commitPanelWidth = 320.0

    var body: some View {
        content
            .task(id: model.loadRequest) {
                model.updateCommitGraph()
                await model.appear()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.becameActive()
            }
            .focusedSceneValue(\.repository, model)
            .alert(
                "Can't Check Out \(model.checkoutFailure?.branch ?? "")",
                isPresented: Binding { model.checkoutFailure != nil } set: { if !$0 { model.checkoutFailure = nil } },
                presenting: model.checkoutFailure
            ) { _ in
            } message: { failure in
                Text(failure.message)
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            LoadingHistory(explanation: model.slowHistoryExplanation)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't Show This Repository", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.reload() }
            }
        case .ready:
            PanelSplit(lowerHeight: $commitPanelHeight) {
                HistoryPanel(model: model, showWorktree: showWorktree)
            } lower: {
                PanelColumns(leadingWidth: $commitPanelWidth) {
                    if model.selectedChanges.isSelected {
                        ChangesPanel(selection: model.selectedChanges)
                    } else {
                        CommitPanel(model: model)
                    }
                } trailing: {
                    DiffPanel(selection: model.selectedFile)
                }
            }
        }
    }
}

/// A spinner that says why, once history has taken a moment to load.
private struct LoadingHistory: View {
    var explanation: String?
    @State private var isTakingLong = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            if isTakingLong, let explanation {
                Text(explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            isTakingLong = true
        }
    }
}

/// The list of commits. It has no header, because what it would say is in the
/// title row: how many commits there are after the branch, and its commands at
/// the right end.
struct HistoryPanel: View {
    let model: RepositoryModel
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        Group {
            if let history = model.history, history.isComplete, history.rows.isEmpty, !model.hasWorkingTreeRow {
                ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("Commits appear here once there are some."))
            } else {
                CommitList(model: model, version: model.historyVersion, selectedRow: model.selectedRow, showWorktree: showWorktree)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface)
    }
}

/// History's part of the title row. The window declares it, because macOS puts
/// the items of a view inside another after that view's, and the button for the
/// refs panel has to come last.
struct HistoryCommands: ToolbarContent {
    @Bindable var model: RepositoryModel

    var body: some ToolbarContent {
        if let branch = model.slowCheckout {
            ToolbarItem {
                Text("Checking out \(branch)…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        if model.historyWasSlowToLoad, let explanation = model.slowHistoryExplanation {
            ToolbarItem {
                Group {
                    if model.commitGraphState == .updating {
                        Text("Writing commit-graph file…")
                    } else {
                        Label("Opens slowly", systemImage: "tortoise")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(explanation)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem {
            Menu {
                Picker("Order", selection: $model.sort) {
                    Text("Topological Order").tag(HistoryOrder.Sort.topological)
                    Text("Date Order").tag(HistoryOrder.Sort.date)
                }
                .pickerStyle(.inline)
            } label: {
                HoverIcon { Image(systemName: "line.3.horizontal.decrease") }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Order of History")
            .accessibilityLabel("Order of History")
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension FocusedValues {
    /// The repository in the focused window, for the menu commands.
    @Entry var repository: RepositoryModel?
}
