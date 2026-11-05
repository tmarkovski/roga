import IconUI
import SwiftUI

extension UserDefaults {
    static let keepsCommitGraphCurrentKey = "keepsCommitGraphCurrent"
    static let fetchesByItselfKey = "fetchesByItself"

    /// Whether Roga keeps commit-graph files up to date, which it does unless
    /// the user turned that off (decision 6).
    var keepsCommitGraphCurrent: Bool {
        object(forKey: Self.keepsCommitGraphCurrentKey) as? Bool ?? true
    }

    /// Whether Roga fetches when it becomes active, which it does unless the
    /// user turned that off (decision 20).
    var fetchesByItself: Bool {
        object(forKey: Self.fetchesByItselfKey) as? Bool ?? true
    }
}

/// The pages of the Settings window, in the order its sidebar lists them. The
/// design canvas has more pages, which wait until there's something to put on
/// them (docs/design/settings).
enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case git
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .git: "Git"
        case .advanced: "Advanced"
        }
    }

    var icon: Icon {
        switch self {
        case .appearance: .eye
        case .git: .branch
        case .advanced: .settings
        }
    }
}

/// Roga's Settings window, with its pages in a sidebar. Settings apply to the
/// whole app, so they're in a window of their own rather than a sheet on one of
/// Roga's windows.
public struct SettingsView: View {
    /// It opens on the page it was on last, because going back is usually to
    /// change the same thing again.
    @AppStorage("settingsPage") private var page = SettingsPage.appearance

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: Binding {
                page
            } set: { selected in
                // A click on the space below the pages would otherwise leave
                // none selected.
                if let selected { page = selected }
            }) { page in
                Label(page.title, icon: page.icon)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch page {
                case .appearance: AppearanceSettings()
                case .git: GitSettings()
                case .advanced: AdvancedSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(page.title)
        }
        .frame(width: 680, height: 480)
    }
}

/// The house's animations, and how the panels lay out their lists.
private struct AppearanceSettings: View {
    @AppStorage(FileListSettings.layout) private var fileLayout = FileLayout.list
    @AppStorage(RefsPanelSettings.sort) private var refsSort = RefsModel.Sort.name
    @AppStorage(CommitPanelSettings.collapsesBody) private var collapsesBody = false

    var body: some View {
        Form {
            HouseAnimationSettings()
            Section("Lists") {
                Picker(selection: $fileLayout) {
                    ForEach(FileLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                } label: {
                    Text("Show files")
                    Text("How the commit panel and the changes panel lay out the files that changed. View > Show Files changes it too.")
                }
                Picker(selection: $refsSort) {
                    ForEach(RefsModel.Sort.allCases, id: \.self) { sort in
                        Text(sort.title).tag(sort)
                    }
                } label: {
                    Text("Sort refs by")
                    Text("How the refs panel orders branches, remotes and tags. The current branch always comes first. View > Sort Refs changes it too.")
                }
                Toggle(isOn: $collapsesBody) {
                    Text("Fold commit descriptions")
                    Text("The commit panel shows only a commit's first line, and clicking it shows the rest. Folding one there folds them all.")
                }
            }
        }
    }
}

/// What Roga runs git for without being asked.
private struct GitSettings: View {
    @AppStorage(UserDefaults.fetchesByItselfKey) private var fetchesByItself = true

    var body: some View {
        Form {
            Section("Fetching") {
                Toggle(isOn: $fetchesByItself) {
                    Text("Fetch when Roga becomes active")
                    Text("Roga runs git fetch for the repository on screen, at most once a minute, so that it can say how far your branch is from its upstream. It only moves remote branches, and it never asks for credentials.")
                }
            }
        }
    }
}

/// What Roga does in the background to keep large repositories quick.
private struct AdvancedSettings: View {
    @AppStorage(UserDefaults.keepsCommitGraphCurrentKey) private var keepsCommitGraphCurrent = true

    var body: some View {
        Form {
            Section("Large repositories") {
                Toggle(isOn: $keepsCommitGraphCurrent) {
                    Text("Keep commit-graph files up to date")
                    Text("Roga runs git commit-graph write in the background, so that large repositories open quickly. It writes to each repository's objects folder and never changes your git configuration.")
                }
            }
        }
    }
}
