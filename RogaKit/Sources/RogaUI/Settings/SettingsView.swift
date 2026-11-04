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

/// Roga's Settings window.
public struct SettingsView: View {
    @AppStorage(UserDefaults.keepsCommitGraphCurrentKey) private var keepsCommitGraphCurrent = true
    @AppStorage(UserDefaults.fetchesByItselfKey) private var fetchesByItself = true

    public init() {}

    public var body: some View {
        Form {
            Toggle(isOn: $keepsCommitGraphCurrent) {
                Text("Keep commit-graph files up to date")
                Text("Roga runs git commit-graph write in the background, so that large repositories open quickly. It writes to each repository's objects folder and never changes your git configuration.")
            }
            Toggle(isOn: $fetchesByItself) {
                Text("Fetch when Roga becomes active")
                Text("Roga runs git fetch for the repository on screen, at most once a minute, so that it can say how far your branch is from its upstream. It only moves remote branches, and it never asks for credentials.")
            }
            HouseAnimationSettings()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
