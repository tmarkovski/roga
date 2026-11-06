import Foundation
import Testing
@testable import RogaUI

/// Settings › General, the notice of a new version that Sparkle's state drives,
/// and the terminal that Open in Terminal uses.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GeneralPageTests {
    /// Sparkle as `Updates` sees it, recording what it was asked to do.
    final class FakeSparkle: UpdaterControls {
        var asked: [String] = []
        func setChecksAutomatically(_ checks: Bool) { asked.append("checks \(checks)") }
        func setDownloadsAutomatically(_ downloads: Bool) { asked.append("downloads \(downloads)") }
        func showUpdate() { asked.append("show") }
        func installNow() { asked.append("install") }
    }

    @Test func generalComesFirstBesideAppearance() {
        #expect(SettingsPage.groups.first == [.general, .appearance])
        #expect(SettingsPage.allCases.first == .general)
        #expect(SettingsGroup.allCases.filter { $0.page == .general } == [.openIn, .updates])
    }

    @Test func searchFindsTheTerminalAndUpdatesByWhatTheyDo() {
        #expect(SettingsItem.terminal.matches("Ghostty"))
        #expect(SettingsItem.terminal.matches("Open in Terminal"))
        #expect(SettingsItem.checksForUpdates.matches("updates"))
        #expect(SettingsItem.downloadsUpdates.matches("Restart to Update"))
        #expect(!SettingsItem.terminal.matches("Sparkle"))
    }

    @Test func theNoticeSaysWhatAClickDoes() {
        #expect(Updates.Pending.found(version: "1.4").title == "Update to 1.4")
        #expect(Updates.Pending.downloaded(version: "1.4").title == "Restart to Update")
        #expect(Updates.Pending.downloaded(version: "1.4").version == "1.4")
    }

    @Test func clickingAFoundUpdateShowsSparklesWindowAndADownloadedOneInstalls() {
        let updates = Updates()
        let sparkle = FakeSparkle()
        updates.controls = sparkle
        updates.open()
        #expect(sparkle.asked.isEmpty)
        updates.pending = .found(version: "1.4")
        updates.open()
        updates.pending = .downloaded(version: "1.4")
        updates.open()
        #expect(sparkle.asked == ["show", "install"])
    }

    @Test func theSwitchesShowTheirNewValueAndTellSparkle() {
        let updates = Updates()
        let sparkle = FakeSparkle()
        updates.controls = sparkle
        updates.setChecksAutomatically(true)
        updates.setDownloadsAutomatically(true)
        #expect(updates.checksAutomatically && updates.downloadsAutomatically)
        #expect(sparkle.asked == ["checks true", "downloads true"])
    }

    @Test func aCopyWithoutSparkleCantUpdate() {
        let updates = Updates()
        #expect(!updates.canUpdate)
        do {
            let sparkle = FakeSparkle()
            updates.controls = sparkle
            #expect(updates.canUpdate)
            updates.controls = nil
        }
        #expect(!updates.canUpdate)
    }

    @Test func openInTerminalUsesTerminalUntilAnotherIsChosenAndInstalled() {
        let (defaults, name) = AgentTestSupport.defaults()
        defer { AgentTestSupport.remove(defaults, named: name) }
        #expect(TerminalApp.chosen(in: defaults) == .terminal)
        defaults.set("com.example.not-a-terminal", forKey: TerminalApp.key)
        #expect(TerminalApp.chosen(in: defaults) == .terminal)
        #expect(TerminalApp.installed.first == .terminal)
        // One that isn't on this Mac falls back to Terminal, and one that is
        // stays chosen.
        for app in TerminalApp.allCases where app != .terminal {
            defaults.set(app.rawValue, forKey: TerminalApp.key)
            #expect(TerminalApp.chosen(in: defaults) == (app.url == nil ? .terminal : app))
        }
    }
}
