import Foundation
import Testing
@testable import RogaUI

/// Report an Issue…: the versions it fills in, the address it opens, and the
/// dialog that says so first (decision 94).
@Suite struct IssueReportTests {
    private let report = IssueReport(roga: "0.4.1 (57)", macOS: "26.1 (25B78)", git: .version("2.54.0"))

    // MARK: Versions

    @Test func rogasVersionComesWithItsBuild() {
        #expect(IssueReport.appVersion(info: ["CFBundleShortVersionString": "0.4.1", "CFBundleVersion": "57"]) == "0.4.1 (57)")
        #expect(IssueReport.appVersion(info: ["CFBundleShortVersionString": "0.4.1", "CFBundleVersion": "0.4.1"]) == "0.4.1")
        #expect(IssueReport.appVersion(info: ["CFBundleShortVersionString": "0.4.1"]) == "0.4.1")
        #expect(IssueReport.appVersion(info: [:]) == nil)
        #expect(IssueReport.appVersion(info: nil) == nil)
    }

    @Test func macOSsVersionComesWithItsBuild() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(IssueReport.macOSVersion(version, description: "Version 26.1 (Build 25B78)") == "26.1 (25B78)")
        let patched = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        #expect(IssueReport.macOSVersion(patched, description: "Version 26.1.2 (Build 25B92)") == "26.1.2 (25B92)")
        #expect(IssueReport.macOSVersion(version, description: "Version 26.1") == "26.1")
    }

    @Test func listsGitOnlyOnceItsBeenLookedFor() {
        #expect(report.facts.map(\.name) == ["Roga", "macOS", "Git"])
        #expect(report.facts.map(\.value) == ["0.4.1 (57)", "26.1 (25B78)", "2.54.0"])
        var withoutGit = report
        withoutGit.git = .notFound
        #expect(withoutGit.facts.last?.value == "None found")
        withoutGit.git = nil
        #expect(withoutGit.facts.map(\.name) == ["Roga", "macOS"])
        withoutGit.roga = nil
        #expect(withoutGit.facts.first?.value == "Unknown")
    }

    // MARK: The issue

    @Test func theIssueEndsWithTheVersions() {
        #expect(report.body.hasPrefix("<!-- What happened, and what did you expect to happen instead? -->\n"))
        #expect(report.body.hasSuffix("\n---\n\n- Roga 0.4.1 (57)\n- macOS 26.1 (25B78)\n- Git 2.54.0"))
    }

    @Test func opensGitHubsPageForANewIssue() throws {
        let components = try #require(URLComponents(url: report.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "github.com")
        #expect(components.path == "/tmarkovski/roga/issues/new")
        #expect(components.queryItems?.map(\.name) == ["body"])
        #expect(components.queryItems?.first?.value == report.body)
    }

    @Test func encodesWhatAQueryWouldMisread() {
        var plus = report
        plus.roga = "1.0+beta & more=yes"
        let query = plus.url.query(percentEncoded: true) ?? ""
        #expect(!query.dropFirst("body=".count).contains(where: { "+&= ".contains($0) }))
        #expect(URLComponents(url: plus.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == plus.body)
    }

    // MARK: The dialog

    @Test func theDialogSaysWhatItOpensAndWhatItFillsIn() {
        let dialog = DialogContent.issueReport(report, open: { _ in }, dismiss: {})
        #expect(dialog.title == "Report an issue on GitHub")
        #expect(dialog.message?.plain.contains("tmarkovski/roga in your browser") == true)
        #expect(dialog.message?.plain.contains("Nothing is sent until you submit it on GitHub") == true)
        #expect(dialog.cards == [[.fact("Roga", "0.4.1 (57)"), .fact("macOS", "26.1 (25B78)"), .fact("Git", "2.54.0")]])
        #expect(dialog.note?.plain.contains("public") == true)
        #expect(dialog.terminal.isEmpty)
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Open GitHub"])
        #expect(dialog.buttons.last?.kind == .primary)
    }

    @Test func onlyTheButtonOpensTheBrowser() {
        var opened: [URL] = []
        var dismissals = 0
        let dialog = DialogContent.issueReport(report, open: { opened.append($0) }, dismiss: { dismissals += 1 })
        dialog.buttons[0].action()
        dialog.dismiss()
        #expect(opened.isEmpty)
        #expect(dismissals == 2)
        dialog.buttons[1].action()
        #expect(opened == [report.url])
        #expect(dismissals == 3)
    }
}
