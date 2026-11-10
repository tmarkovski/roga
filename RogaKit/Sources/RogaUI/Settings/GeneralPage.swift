import SwiftUI

/// A section of Settings › General: the terminal for Open in Terminal, or
/// updates. The boards also draw reopening windows at launch, the rail of
/// organizations and an editor for Open in Editor. Reopening windows and the
/// editor wait until they can work, since there's no Open in Editor yet, and
/// groups in the sidebar's list replaced the rail (decision 53).
///
/// Search shows it too, with only the settings it found.
struct GeneralSection: View {
    let group: SettingsGroup
    /// The settings to show, which search narrows.
    var items: [SettingsItem]
    /// Whether the page's name goes beside the heading, as in search.
    var namesPage = false

    @Environment(Updates.self) private var updates: Updates?
    @AppStorage(TerminalApp.key) private var terminal = TerminalApp.terminal
    /// The terminals on this Mac, found once each time the section shows.
    @State private var terminals = TerminalApp.installed

    var body: some View {
        SettingsSection(title: group.title, description: group.styledDescription) {
            if namesPage {
                Text(SettingsPage.general.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            if group == .updates, updates?.canUpdate != true {
                SettingsBlock {
                    SettingsNotice(text: GeneralSection.cantUpdateNotice) {
                        EmptyView()
                    }
                }
            }
            ForEach(items, id: \.self) { item in
                row(item)
            }
        }
    }

    /// Why the switches are off, in a copy of Roga that Sparkle doesn't run in.
    static let cantUpdateNotice = "Automatic updates are available in release builds only."

    /// The chosen terminal, or Terminal while that one is gone from this Mac.
    private var shownTerminal: Binding<TerminalApp> {
        Binding {
            terminals.contains(terminal) ? terminal : .terminal
        } set: {
            terminal = $0
        }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .terminal:
            SettingsRow(title: item.title, help: item.help) {
                SettingsPopup(selection: shownTerminal, options: terminals.map { (value: $0, title: $0.name) })
            }
        case .checksForUpdates:
            let isEnabled = updates?.canUpdate == true
            SettingsRow(title: item.title, help: item.help) {
                Toggle(item.title, isOn: Binding {
                    updates?.checksAutomatically ?? false
                } set: {
                    updates?.setChecksAutomatically($0)
                })
                .toggleStyle(.settings)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
        case .downloadsUpdates:
            // Sparkle downloads only what its daily check finds.
            let isEnabled = updates?.canUpdate == true && updates?.checksAutomatically == true
            SettingsRow(title: item.title, help: item.help) {
                Toggle(item.title, isOn: Binding {
                    updates?.downloadsAutomatically ?? false
                } set: {
                    updates?.setDownloadsAutomatically($0)
                })
                .toggleStyle(.settings)
            }
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.45)
        default:
            EmptyView()
        }
    }
}
