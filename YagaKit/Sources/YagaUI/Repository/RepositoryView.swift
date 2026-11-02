import CommitGraph
import GitRunner
import RepositoryEngine
import SwiftUI

/// One worktree: its history, and the commit and file selected in it.
struct RepositoryView: View {
    let model: RepositoryModel
    @AppStorage("commitPanelHeight") private var commitPanelHeight = 340.0
    @AppStorage("commitPanelWidth") private var commitPanelWidth = 320.0

    var body: some View {
        content
            .task(id: model.loadRequest) {
                model.updateCommitGraph()
                await model.load()
            }
            .focusedSceneValue(\.repository, model)
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
                HistoryPanel(model: model)
            } lower: {
                PanelColumns(leadingWidth: $commitPanelWidth) {
                    CommitPanel(model: model)
                } trailing: {
                    DiffPanel(selection: model.selectedCommit.selectedFile)
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

struct HistoryPanel: View {
    @Bindable var model: RepositoryModel

    var body: some View {
        Panel {
            Text("History")
                .font(.system(size: 13, weight: .medium))
                .padding(.leading, 4)
            if let history = model.history, history.isComplete {
                Text(history.rows.count == 1 ? "1 commit" : "\(history.rows.count.formatted()) commits")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            if model.historyWasSlowToLoad, let explanation = model.slowHistoryExplanation {
                Group {
                    if model.commitGraphState == .updating {
                        Text("Writing commit-graph file…")
                    } else {
                        Label("Opens slowly", systemImage: "tortoise")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 8)
                .help(explanation)
            }
        } trailing: {
            if let head = model.headDescription {
                Label(head, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.trailing, 6)
            }
            Menu {
                Picker("Order", selection: $model.sort) {
                    Text("Topological Order").tag(HistoryOrder.Sort.topological)
                    Text("Date Order").tag(HistoryOrder.Sort.date)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Order of History")
        } content: {
            if let history = model.history, history.isComplete, history.rows.isEmpty {
                ContentUnavailableView("No Commits Yet", systemImage: "clock", description: Text("Commits appear here once there are some."))
            } else {
                CommitList(model: model, version: model.historyVersion, selectedRow: model.selectedRow)
            }
        }
    }
}

extension FocusedValues {
    /// The repository in the focused window, for the menu commands.
    @Entry var repository: RepositoryModel?
}
