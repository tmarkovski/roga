import GitRunner
import IconUI
import SwiftUI

/// Settings › Git › Installation: the git Roga runs, on the same row setup
/// shows it on, with a menu of every git Roga found.
///
/// The repositories in the sidebar are opened with one git and keep it until
/// Roga quits, so choosing another here says that it takes over the next
/// time Roga opens.
///
/// Search shows it too.
struct GitProgramSection: View {
    var items = SettingsGroup.installation.items
    var namesPage = false
    @Environment(GitProvider.self) private var gitProvider
    @Environment(RepositoryList.self) private var list

    var body: some View {
        SettingsSection(
            title: SettingsGroup.installation.title,
            description: namesPage ? nil : SettingsGroup.installation.styledDescription
        ) {
            if namesPage {
                Text(SettingsPage.git.title)
                    .foregroundStyle(SettingsColors.note)
            } else {
                Spacer(minLength: 0)
                Button {
                    gitProvider.lookAgain()
                } label: {
                    HStack(spacing: 6) {
                        AgentListSection.lookAgainIcon.image
                            .font(.system(size: 11))
                        Text("Rescan")
                    }
                }
                .buttonStyle(.settings(small: true))
                .disabled(gitProvider.isLooking)
                .help("Scan for Git installations")
            }
        } content: {
            if items.contains(.gitProgram) {
                SettingsBlock {
                    VStack(alignment: .leading, spacing: 10) {
                        SetupCard {
                            ProgramRow(
                                icon: .branch,
                                content: .git(state: gitProvider.state, survey: gitProvider.survey),
                                menu: .git(gitProvider),
                                choose: choose
                            )
                        }
                        if let notice = Self.restartNotice(running: list.git?.installation, chosen: gitProvider.git?.installation) {
                            SettingsNotice(text: notice) {
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    private func choose() {
        if let path = ProgramPanel.choose("git", startingAt: gitProvider.git?.installation.executable) {
            gitProvider.choose(path)
        }
    }

    /// What to say when the git chosen isn't the one the repositories were
    /// opened with, or nil when it is.
    static func restartNotice(running: GitInstallation?, chosen: GitInstallation?) -> String? {
        guard let running, let chosen, running.executable != chosen.executable else { return nil }
        return "Restart Roga to use the selected Git installation. Currently using \(AgentSummaries.abbreviated(running.executable)) (\(running.version))."
    }
}
