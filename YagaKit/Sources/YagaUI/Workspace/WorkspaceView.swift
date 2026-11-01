import SwiftUI

/// The contents of a yaga window. Until repositories can be opened, it shows
/// the empty state that a window without tabs will have.
public struct WorkspaceView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView {
            Label("No Repository Open", systemImage: "folder")
        } description: {
            Text("Repositories you open appear here as tabs.")
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}
