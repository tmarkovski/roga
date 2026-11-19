import Foundation
import GitRunner

/// A new issue on GitHub, which Report an Issue… in the Help menu opens in the
/// browser once its dialog has said what that does (decision 94). The issue
/// starts with the versions of Roga, macOS and Git filled in, and nothing
/// else about this Mac or its repositories.
struct IssueReport: Equatable {
    /// Where GitHub starts a new issue for Roga.
    static let newIssueAddress = "https://github.com/tmarkovski/roga/issues/new"
    /// The repository the issue goes to, as the dialog names it.
    static let repository = "tmarkovski/roga"

    /// Roga's version and build, as in `0.4.1 (57)`, or nil when the bundle
    /// doesn't say.
    var roga: String?
    /// The version and build of macOS, as in `26.1 (25B78)`.
    var macOS: String
    /// The version of the git Roga runs, or nil while Roga is still looking
    /// for one.
    var git: GitFact?

    /// What the issue says about git.
    enum GitFact: Equatable {
        case version(String)
        /// Roga found no git it can use.
        case notFound
    }

    /// The versions on this Mac, with the git that `provider` found.
    @MainActor static func current(git provider: GitProvider) -> IssueReport {
        let git: GitFact? = switch provider.state {
        case .ready(let git): .version(git.installation.version.description)
        case .failed: .notFound
        case .locating: nil
        }
        return IssueReport(
            roga: appVersion(info: Bundle.main.infoDictionary),
            macOS: macOSVersion(ProcessInfo.processInfo.operatingSystemVersion, description: ProcessInfo.processInfo.operatingSystemVersionString),
            git: git
        )
    }

    /// Roga's version and its build, which a release numbers apart.
    static func appVersion(info: [String: Any]?) -> String? {
        guard let version = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, build != version else { return version }
        return "\(version) (\(build))"
    }

    /// The version of macOS with its build, as in `26.1 (25B78)`. `description`
    /// is `ProcessInfo`'s, as in `Version 26.1 (Build 25B78)`, and only the
    /// build is taken from it.
    static func macOSVersion(_ version: OperatingSystemVersion, description: String) -> String {
        var number = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { number += ".\(version.patchVersion)" }
        guard let start = description.range(of: "Build ")?.upperBound,
              let end = description[start...].firstIndex(of: ")"),
              start < end
        else { return number }
        return "\(number) (\(description[start..<end]))"
    }

    /// The versions as the dialog lists them and the issue says them, by name.
    var facts: [(name: String, value: String)] {
        var facts = [(name: "Roga", value: roga ?? "Unknown"), (name: "macOS", value: macOS)]
        switch git {
        case .version(let version): facts.append((name: "Git", value: version))
        case .notFound: facts.append((name: "Git", value: "None found"))
        case nil: break
        }
        return facts
    }

    /// What the issue starts with: a prompt for what happened, which GitHub
    /// hides once it's submitted, then the versions.
    var body: String {
        let versions = facts.map { "- \($0.name) \($0.value)" }.joined(separator: "\n")
        return """
        <!-- What happened, and what did you expect to happen instead? -->



        ---

        \(versions)
        """
    }

    /// GitHub's page for a new issue, with `body` filled in.
    var url: URL {
        // Only unreserved characters stay as they are, because GitHub reads a
        // `+` in a query as a space, and `URLQueryItem` leaves it alone.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "\(Self.newIssueAddress)?body=\(encoded)")!
    }
}

extension DialogContent {
    /// Says what Report an Issue… opens before it opens it: a new issue on
    /// GitHub, in the browser, with the versions it lists filled in.
    static func issueReport(_ report: IssueReport, open: @escaping (URL) -> Void, dismiss: @escaping () -> Void) -> DialogContent {
        DialogContent(
            id: "issue-report",
            title: "Report an issue on GitHub",
            message: "This opens a new issue for \(code: IssueReport.repository) in your browser, with these versions filled in. Nothing is sent until you submit it on GitHub, which needs a GitHub account.",
            cards: [report.facts.map { DialogRow.fact($0.name, $0.value) }],
            note: "Issues on GitHub are public, so leave out anything private, such as code or the names of your repositories.",
            buttons: [
                .cancel(dismiss),
                DialogButton(title: "Open GitHub", kind: .primary) {
                    dismiss()
                    open(report.url)
                },
            ],
            dismiss: dismiss
        )
    }
}
