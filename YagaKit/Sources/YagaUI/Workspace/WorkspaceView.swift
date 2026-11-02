import GitRunner
import SwiftUI

/// The contents of a yaga window: one repository, or a prompt to open one.
///
/// For now each window shows one repository. Tabs that hold several come
/// later (decision 10).
public struct WorkspaceView: View {
    /// The folder the window shows, which SwiftUI saves with the window and
    /// restores when yaga launches again.
    @Binding var path: String?
    @Environment(GitProvider.self) private var gitProvider

    public init(path: Binding<String?>) {
        _path = path
    }

    public var body: some View {
        content
            .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder private var content: some View {
        switch gitProvider.state {
        case .locating:
            ProgressView()
                .controlSize(.small)
        case .failed(let error):
            ContentUnavailableView {
                Label("yaga Can't Use Git", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.description)
            }
        case .ready(let git):
            if let path {
                RepositoryView(path: path, git: git)
                    .id(path)
            } else {
                ContentUnavailableView {
                    Label("No Repository Open", systemImage: "folder")
                } description: {
                    Text("Open a repository to see its history.")
                } actions: {
                    Button("Open Repository…") {
                        if let folder = chooseRepositoryFolder() { path = folder }
                    }
                }
                .focusedSceneValue(\.emptyWindowPath, $path)
            }
        }
    }
}
