import Foundation
import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// Settings › Git › Identity: who every repository's commits go out as unless
/// it sets its own, from the user's global config (decision 103). It has the
/// identity popover's fields, and each change runs `git config --global` at
/// once: a field's when Return is pressed or the field is left, and a
/// switch's or a format's as it changes. Each row says its key and where its
/// value comes from, which can be a file that `~/.gitconfig` includes.
///
/// Search shows it too, with only the settings it found.
struct IdentitySection: View {
    /// The settings to show, which search narrows.
    var items = SettingsGroup.identity.items
    /// Whether the page's name goes beside the heading, as in search.
    var namesPage = false
    @Environment(RepositoryList.self) private var list
    @State private var name = ""
    @State private var email = ""
    @State private var key = ""
    /// The field being typed in, whose words a new read of the config
    /// leaves alone.
    @FocusState private var focus: CommitIdentityCommands.Key?
    @State private var failure: String?
    /// The keys on this Mac for each format the Key row has shown.
    @State private var keyListings: [CommitIdentity.SigningFormat: SigningKeys.Listing] = [:]
    /// Each format's program and whether it's on this Mac (decision 108).
    @State private var signingPrograms: SigningPrograms.Found?

    private typealias Key = CommitIdentityCommands.Key
    private let globalFiles = GlobalConfigFiles()

    private var identity: CommitIdentity { list.defaultIdentity ?? CommitIdentity() }

    var body: some View {
        SettingsSection(
            title: SettingsGroup.identity.title,
            description: namesPage ? nil : SettingsGroup.identity.styledDescription
        ) {
            if namesPage {
                Text(SettingsPage.git.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            ForEach(shownItems, id: \.self) { row($0) }
            if let failure {
                SettingsBlock {
                    Text(failure)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(SettingsColors.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { load(keeping: nil) }
        .onChange(of: list.defaultIdentity) { load(keeping: focus) }
        // The keys are listed only while the Key row shows, once for each
        // format (decision 106).
        .task(id: identity.signs ? identity.format : nil) {
            let format = identity.format
            guard identity.signs, format != .x509, keyListings[format] == nil else { return }
            if let listing = await list.signingKeys(format, for: nil) { keyListings[format] = listing }
        }
        // Whether each format's program is here, each time the format shows
        // (decision 108).
        .task(id: identity.signs) {
            guard identity.signs else { return }
            signingPrograms = await list.signingPrograms(for: nil)
        }
        // Leaving a field saves it, as Return does.
        .onChange(of: focus) { left, _ in
            if let left { save(left) }
        }
    }

    /// The format and the key show only while commits are signed.
    private var shownItems: [SettingsItem] {
        items.filter { identity.signs || ($0 != .signingFormat && $0 != .signingKey) }
    }

    @ViewBuilder private func row(_ item: SettingsItem) -> some View {
        switch item {
        case .identityName:
            fieldRow(item, key: .name, text: $name, placeholder: "Your Name")
        case .identityEmail:
            fieldRow(item, key: .email, text: $email, placeholder: "you@example.com")
        case .signsCommits:
            settingRow(item, key: .signsCommits) {
                Toggle(item.title, isOn: Binding {
                    identity.signs
                } set: { signs in
                    write(.set(.signsCommits, signs ? "true" : "false", in: .everyRepository))
                })
                .toggleStyle(.settings)
            }
        case .signingFormat:
            settingRow(item, key: .signingFormat) {
                SettingsSegments(selection: Binding {
                    identity.format
                } set: { format in
                    write(.set(.signingFormat, format.rawValue, in: .everyRepository))
                }, options: CommitIdentity.SigningFormat.allCases.map { ($0, $0.title) }, unavailable: {
                    IdentityPopover.unavailable($0, programs: signingPrograms, current: identity.format)
                })
            }
            if let warning = signingPrograms?[identity.format].warning {
                SettingsBlock {
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentColors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .signingKey:
            settingRow(item, key: .signingKey) {
                SigningKeyField(
                    text: $key,
                    format: identity.format,
                    listing: keyListings[identity.format],
                    email: identity.shownEmail,
                    hasDefaultKeyCommand: identity.hasDefaultKeyCommand,
                    width: 240,
                    focus: $focus,
                    choose: { _ in save(.signingKey) },
                    maker: signingPrograms?[identity.format].isFound == false ? nil : KeyMaker(list: list, repository: nil, name: identity.shownName ?? "", savesAtOnce: true) { made in
                        keyListings[made.format, default: SigningKeys.Listing(keys: [])].keys.append(made.key)
                    }
                )
                .onSubmit { save(.signingKey) }
            }
        default:
            EmptyView()
        }
    }

    private func fieldRow(_ item: SettingsItem, key: Key, text: Binding<String>, placeholder: String, isMonospaced: Bool = false) -> some View {
        settingRow(item, key: key) {
            SettingsTextField(text: text, placeholder: placeholder, width: 240, isMonospaced: isMonospaced)
                .focused($focus, equals: key)
                .onSubmit { save(key) }
        }
    }

    /// A row whose gray line says the setting's key and where its value
    /// comes from, as in `user.email · from ~/.gitconfig`.
    private func settingRow(_ item: SettingsItem, key: Key, @ViewBuilder control: () -> some View) -> some View {
        let words = "\(key.rawValue) · \(origin(key))"
        return SettingsRow(title: item.title, help: words) {
            Text(AttributedString.settingsWords(words, typedNames: [key.rawValue]))
        } control: {
            control()
        }
    }

    private func origin(_ key: Key) -> String {
        guard let origin = setting(key)?.origin else { return key == .signingFormat ? "git's default" : "not set" }
        return IdentityWords.origin(origin, globalFiles: globalFiles)
    }

    private func setting(_ key: Key) -> CommitIdentity.Setting? {
        switch key {
        case .name: identity.name
        case .email: identity.email
        case .signsCommits: identity.signsCommits
        case .signingFormat: identity.signingFormat
        case .signingKey: identity.signingKey
        }
    }

    /// What a field shows for the identity as it was read.
    private func readValue(_ key: Key) -> String {
        switch key {
        case .name: identity.shownName ?? ""
        case .email: identity.shownEmail ?? ""
        case .signingKey: identity.key ?? ""
        case .signsCommits, .signingFormat: ""
        }
    }

    /// Fills the fields from the identity, except the one being typed in.
    private func load(keeping typing: Key?) {
        if typing != .name { name = readValue(.name) }
        if typing != .email { email = readValue(.email) }
        if typing != .signingKey { key = readValue(.signingKey) }
    }

    /// Writes a field when it says something other than what was read. An
    /// emptied field is removed from the global config.
    private func save(_ field: Key) {
        let typed: String
        switch field {
        case .name: typed = name
        case .email: typed = email
        case .signingKey: typed = key
        case .signsCommits, .signingFormat: return
        }
        let value = typed.trimmingCharacters(in: .whitespaces)
        guard value != readValue(field) else { return }
        write(value.isEmpty ? .unset(field, in: .everyRepository) : .set(field, value, in: .everyRepository))
    }

    private func write(_ change: CommitIdentityCommands.Change) {
        failure = nil
        Task {
            do {
                try await list.changeGlobalIdentity([change])
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

/// Settings › Git › Repositories that commit as someone else: each repository
/// in the sidebar whose name or email isn't the global identity, with the
/// email and where it comes from, and each whose commits would go wrong
/// (decision 103). Repositories that a file included for their folder gives
/// the same email share a row. A repository's own value has Use Global, which
/// runs `git config --local --unset`, and one whose commits would go wrong has
/// Set…, which opens the identity popover.
struct IdentityExceptionsSection: View {
    /// Whether the page's name goes beside the heading, as in search.
    var namesPage = false
    @Environment(RepositoryList.self) private var list

    var body: some View {
        SettingsSection(
            title: SettingsGroup.identityExceptions.title,
            description: namesPage ? nil : SettingsGroup.identityExceptions.styledDescription
        ) {
            if namesPage {
                Text(SettingsPage.git.title)
                    .foregroundStyle(SettingsColors.note)
            }
        } content: {
            SettingsBlock {
                let rows = IdentityExceptionRow.rows(list.identityExceptions)
                if rows.isEmpty {
                    Text("Every repository in the sidebar commits as the global identity.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(SettingsColors.note)
                } else {
                    SettingsList {
                        ForEach(rows) { row in
                            IdentityExceptionRowView(row: row, list: list)
                        }
                    }
                }
            }
        }
    }
}

/// One row of the repositories that commit as someone else: the repositories
/// it's about, and what they have in common.
struct IdentityExceptionRow: Identifiable, Equatable {
    var repositories: [ListedRepository]
    var exception: IdentityException

    var id: String { repositories.map(\.path).joined(separator: "\n") }

    static func == (lhs: IdentityExceptionRow, rhs: IdentityExceptionRow) -> Bool {
        lhs.repositories.map(\.path) == rhs.repositories.map(\.path) && lhs.exception == rhs.exception
    }

    /// The repositories' names, as in `api, billing and web`.
    var names: String {
        let names = repositories.map(\.name)
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Whether Use Global can remove what makes it someone else: only a
    /// repository's own value, which is in its own config.
    var canUseGlobal: Bool {
        guard case .someoneElse(let identity) = exception else { return false }
        return identity.email?.origin.scope == .local || identity.name?.origin.scope == .local
    }

    /// The rows for these repositories, with those that a file outside them
    /// gives the same identity in one row, since they change together. A
    /// repository that sets its own, or whose commits would go wrong, has a
    /// row of its own, since each is fixed on its own.
    static func rows(_ exceptions: [(repository: ListedRepository, exception: IdentityException)]) -> [IdentityExceptionRow] {
        var rows: [IdentityExceptionRow] = []
        for (repository, exception) in exceptions {
            if case .someoneElse(let identity) = exception,
               identity.email?.origin.scope == .global,
               let index = rows.firstIndex(where: { $0.exception == exception })
            {
                rows[index].repositories.append(repository)
            } else {
                rows.append(IdentityExceptionRow(repositories: [repository], exception: exception))
            }
        }
        return rows
    }
}

private struct IdentityExceptionRowView: View {
    let row: IdentityExceptionRow
    let list: RepositoryList
    @State private var isEditing = false
    @State private var failure: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch row.exception {
            case .someoneElse:
                IdentityPerson(look: .init(row.exception), style: .inline)
            case .problem:
                Icon.warning.image
                    .font(.system(size: 12 / 1.128, weight: .semibold))
                    .foregroundStyle(AgentColors.warn)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.names)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(failure ?? line)
                    .font(.system(size: 12.5))
                    .foregroundStyle(failure != nil ? SettingsColors.danger : isProblem ? AgentColors.warn : SettingsColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.canUseGlobal {
                Button("Use Global", action: useGlobal)
                    .buttonStyle(.settings(small: true))
                    .help(useGlobalChanges.map { BranchModel.command($0.arguments) }.joined(separator: "\n"))
            } else if isProblem, let repository = row.repositories.first {
                Button("Set…") { isEditing = true }
                    .buttonStyle(.settings(small: true))
                    .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                        IdentityPopover(repository: repository, list: list) { isEditing = false }
                    }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .accessibilityElement(children: .combine)
    }

    private var isProblem: Bool {
        if case .problem = row.exception { true } else { false }
    }

    private var line: String {
        switch row.exception {
        case .problem(let problem):
            let words = IdentityWords.problem(problem)
            return "\(words.title). \(words.detail)"
        case .someoneElse(let identity):
            let email = identity.shownEmail ?? "No email"
            guard let origin = (identity.email ?? identity.name)?.origin else { return email }
            return "\(email) · \(IdentityWords.origin(origin, globalFiles: GlobalConfigFiles()))"
        }
    }

    /// What Use Global runs: removing the repository's own name and email.
    private var useGlobalChanges: [CommitIdentityCommands.Change] {
        guard case .someoneElse(let identity) = row.exception else { return [] }
        return [(CommitIdentityCommands.Key.name, identity.name), (.email, identity.email)]
            .compactMap { key, setting in setting?.origin.scope == .local ? .unset(key, in: .repository) : nil }
    }

    /// Removes the repository's own name and email, so that it commits as the
    /// global identity again.
    private func useGlobal() {
        guard let repository = row.repositories.first else { return }
        let changes = useGlobalChanges
        failure = nil
        Task {
            do {
                try await list.changeIdentity(changes, of: repository)
            } catch {
                failure = String(describing: error)
            }
        }
    }
}
