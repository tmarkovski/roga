import Observation
import SwiftUI

/// Report an Issue… in the Help menu, in place of the help book Roga doesn't
/// have. It shows a dialog on the focused window that says what it will open,
/// and the dialog's button opens a new issue on GitHub (decision 94).
public struct HelpCommands: Commands {
    let request: IssueReportRequest
    @FocusedValue(\.showsIssueReport) private var showsIssueReport
    @Environment(\.openWindow) private var openWindow

    public init(request: IssueReportRequest) {
        self.request = request
    }

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Report an Issue…") {
                if let showsIssueReport {
                    showsIssueReport.wrappedValue = true
                } else {
                    // With no Roga window in front, a new one opens and shows
                    // the dialog as soon as it appears, as Settings does.
                    request.isPending = true
                    openWindow(value: WorkspaceWindow())
                }
            }
        }
    }
}

/// Report an Issue… chosen while no Roga window was in front, for the next
/// window that appears to show.
@MainActor @Observable public final class IssueReportRequest {
    var isPending = false

    public init() {}
}

extension FocusedValues {
    /// Whether the focused window shows the dialog for reporting an issue.
    @Entry var showsIssueReport: Binding<Bool>?
}
