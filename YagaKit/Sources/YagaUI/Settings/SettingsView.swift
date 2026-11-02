import SwiftUI

extension UserDefaults {
    static let keepsCommitGraphCurrentKey = "keepsCommitGraphCurrent"

    /// Whether yaga keeps commit-graph files up to date, which it does unless
    /// the user turned that off (decision 6).
    var keepsCommitGraphCurrent: Bool {
        object(forKey: Self.keepsCommitGraphCurrentKey) as? Bool ?? true
    }
}

/// yaga's Settings window.
public struct SettingsView: View {
    @AppStorage(UserDefaults.keepsCommitGraphCurrentKey) private var keepsCommitGraphCurrent = true

    public init() {}

    public var body: some View {
        Form {
            Toggle(isOn: $keepsCommitGraphCurrent) {
                Text("Keep commit-graph files up to date")
                Text("yaga runs git commit-graph write in the background, so that large repositories open quickly. It writes to each repository's objects folder and never changes your git configuration.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
