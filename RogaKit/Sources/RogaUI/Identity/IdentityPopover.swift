import Foundation
import GitCore
import IconUI
import Observation
import RepositoryEngine
import SwiftUI

/// What the identity popover holds while someone changes it: the fields,
/// where Save writes, and the exact `git config` commands that Save runs
/// (decision 103).
@Observable
final class IdentityEditor {
    typealias Key = CommitIdentityCommands.Key
    typealias Change = CommitIdentityCommands.Change
    typealias Place = CommitIdentityCommands.Place

    /// The identity as it was read when the popover opened.
    let identity: CommitIdentity
    /// What a repository gets when it sets nothing of its own, which Use
    /// Global goes back to.
    let defaultIdentity: CommitIdentity?
    let globalFiles: GlobalConfigFiles

    var name: String { didSet { keepUsingGlobal(.name) } }
    var email: String { didSet { keepUsingGlobal(.email) } }
    var signs: Bool { didSet { keepUsingGlobal(.signsCommits) } }
    var format: CommitIdentity.SigningFormat { didSet { keepUsingGlobal(.signingFormat) } }
    var key: String { didSet { keepUsingGlobal(.signingKey) } }
    /// Where Save writes. The repository's own config is the default, because
    /// writing the global config from one repository changes every other one
    /// that doesn't set its own.
    var place = Place.repository
    /// The settings whose repository's own value Save removes, so that the
    /// global one counts again.
    private(set) var usingGlobal: Set<Key> = []

    init(identity: CommitIdentity, defaultIdentity: CommitIdentity?, globalFiles: GlobalConfigFiles = GlobalConfigFiles()) {
        self.identity = identity
        self.defaultIdentity = defaultIdentity
        self.globalFiles = globalFiles
        name = identity.shownName ?? ""
        email = identity.shownEmail ?? ""
        signs = identity.signs
        format = identity.format
        key = identity.key ?? ""
    }

    /// The setting as it was read.
    func setting(_ key: Key) -> CommitIdentity.Setting? {
        switch key {
        case .name: identity.name
        case .email: identity.email
        case .signsCommits: identity.signsCommits
        case .signingFormat: identity.signingFormat
        case .signingKey: identity.signingKey
        }
    }

    /// Whether the repository sets this itself, so that Use Global can remove
    /// it. A worktree's own `config.worktree` is shown but not changed.
    func canUseGlobal(_ key: Key) -> Bool {
        setting(key)?.origin.scope == .local && !usingGlobal.contains(key)
    }

    /// Removes the repository's own value when Save runs, and shows the
    /// global one in the meantime.
    func useGlobal(_ key: Key) {
        usingGlobal.insert(key)
        let global = defaultIdentity ?? CommitIdentity()
        switch key {
        case .name: name = global.shownName ?? ""
        case .email: email = global.shownEmail ?? ""
        case .signsCommits: signs = global.signs
        case .signingFormat: format = global.format
        case .signingKey: self.key = global.key ?? ""
        }
    }

    /// Stops removing the repository's own value once the field says
    /// something other than the global value.
    private func keepUsingGlobal(_ key: Key) {
        guard usingGlobal.contains(key), value(key, in: defaultIdentity ?? CommitIdentity()) != value(key) else { return }
        usingGlobal.remove(key)
    }

    /// What a field says now, as git would write it.
    private func value(_ key: Key) -> String {
        switch key {
        case .name: name.trimmingCharacters(in: .whitespaces)
        case .email: email.trimmingCharacters(in: .whitespaces)
        case .signsCommits: signs ? "true" : "false"
        case .signingFormat: format.rawValue
        case .signingKey: self.key.trimmingCharacters(in: .whitespaces)
        }
    }

    /// What an identity says for a field, as git would write it.
    private func value(_ key: Key, in identity: CommitIdentity) -> String {
        switch key {
        case .name: identity.shownName ?? ""
        case .email: identity.shownEmail ?? ""
        case .signsCommits: identity.signs ? "true" : "false"
        case .signingFormat: identity.format.rawValue
        case .signingKey: identity.key ?? ""
        }
    }

    /// The fields the popover shows: the format and the key only while
    /// signing is on.
    private var shownKeys: [Key] {
        signs ? Key.allCases : [.name, .email, .signsCommits]
    }

    /// Whether a field says something other than what was read.
    func isChanged(_ key: Key) -> Bool {
        value(key) != value(key, in: identity)
    }

    /// What Save runs, in order. A field that's emptied is removed from
    /// where Save writes.
    var changes: [Change] {
        shownKeys.compactMap { key in
            if usingGlobal.contains(key) { return .unset(key, in: .repository) }
            guard isChanged(key) else { return nil }
            let value = value(key)
            return value.isEmpty ? .unset(key, in: place) : .set(key, value, in: place)
        }
    }

    /// Where a field's value comes from, or where Save will put it once it
    /// has changed.
    func originWords(_ key: Key) -> String {
        if usingGlobal.contains(key) { return "the global value, once saved" }
        if isChanged(key) {
            let file = globalFiles.shownFile ?? "~/.gitconfig"
            if value(key).isEmpty {
                return place == .repository ? "removed from this repository once saved" : "removed from \(file) once saved"
            }
            return place == .repository ? "this repository's own, once saved" : "in \(file), once saved"
        }
        guard let setting = setting(key) else { return key == .signingFormat ? "git's default" : "not set" }
        return IdentityWords.origin(setting.origin, globalFiles: globalFiles)
    }

    /// Why saving to the global config won't change this repository, when
    /// something it reads after the global config sets a field Save changes.
    var shadowNote: String? {
        guard place == .everyRepository else { return nil }
        for key in shownKeys where isChanged(key) && !usingGlobal.contains(key) {
            guard let origin = setting(key)?.origin else { continue }
            let what = Self.label(key)
            switch origin.scope {
            case .local:
                return "This repository sets its own \(what), so saving it for every repository won't change it here."
            case .worktree:
                return "This worktree sets its own \(what), so saving it for every repository won't change it here."
            case .command:
                return "git's environment sets the \(what), so saving it for every repository won't change it here."
            case .global:
                if let file = origin.file, !globalFiles.paths.contains(file) {
                    return "\(globalFiles.abbreviated(file)) sets the \(what) for this repository, so saving it for every repository won't change it here."
                }
            case .system, .unknown:
                break
            }
        }
        return nil
    }

    private static func label(_ key: Key) -> String {
        switch key {
        case .name: "name"
        case .email: "email"
        case .signsCommits: "signing"
        case .signingFormat: "signing format"
        case .signingKey: "signing key"
        }
    }
}

/// Changes who a repository's commits go out as, with `git config`
/// (decision 103). It has Name, Email and Sign commits, with the format and
/// the key under Sign commits while it's on, and each says where its value
/// comes from. Save to chooses the repository's own config, which is the
/// default, or the global config, and the block along its bottom shows the
/// exact commands that Save runs (decision 29).
struct IdentityPopover: View {
    let repository: ListedRepository
    let list: RepositoryList
    let close: () -> Void
    /// What the fields hold, from the identity as it was when the popover
    /// opened, so that a change on disk while it's open doesn't undo what
    /// someone typed.
    @State private var editor: IdentityEditor?
    @State private var isSaving = false
    @State private var failure: String?
    /// The keys on this Mac for each format the Key field has shown.
    @State private var keyListings: [CommitIdentity.SigningFormat: SigningKeys.Listing] = [:]
    /// Each format's program and whether it's on this Mac, looked up each
    /// time the popover shows the format (decision 108).
    @State private var signingPrograms: SigningPrograms.Found?

    static let width: CGFloat = 340
    private static let inset: CGFloat = 16

    /// - Parameter editor: The fields to start from, for drawing the popover
    ///   partway through a change, or nil to start from the repository's
    ///   identity.
    init(repository: ListedRepository, list: RepositoryList, editor: IdentityEditor? = nil, close: @escaping () -> Void) {
        self.repository = repository
        self.list = list
        self.close = close
        _editor = State(initialValue: editor ?? repository.identity.map {
            IdentityEditor(identity: $0, defaultIdentity: list.defaultIdentity)
        })
    }

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                Color.clear.frame(width: Self.width, height: 1)
            }
        }
        .onAppear {
            guard editor == nil, let identity = repository.identity else { return }
            editor = IdentityEditor(identity: identity, defaultIdentity: list.defaultIdentity)
        }
    }

    private func content(_ editor: IdentityEditor) -> some View {
        @Bindable var editor = editor
        let changes = editor.changes
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commit identity")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("For \(repository.name) and every worktree of it")
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
            }
            .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 12, trailing: Self.inset))
            VStack(alignment: .leading, spacing: 12) {
                field(.name, "Name", text: $editor.name, placeholder: "Your Name", editor: editor)
                field(.email, "Email", text: $editor.email, placeholder: "you@example.com", editor: editor)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        label(.signsCommits, "Sign commits", editor: editor)
                        Toggle("Sign commits", isOn: $editor.signs.animation(.snappy(duration: 0.15)))
                            .toggleStyle(.settings)
                            .labelsHidden()
                    }
                    if editor.signs {
                        SettingsSegments(
                            selection: $editor.format,
                            options: CommitIdentity.SigningFormat.allCases.map { ($0, $0.title) },
                            fillsWidth: true,
                            unavailable: { Self.unavailable($0, programs: signingPrograms, current: editor.identity.format) }
                        )
                        .accessibilityLabel("Format")
                        if let warning = signingPrograms?[editor.format].warning {
                            Text(warning)
                                .font(.system(size: 12))
                                .foregroundStyle(AgentColors.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            label(.signingKey, "Key", editor: editor)
                            SigningKeyField(
                                text: $editor.key,
                                format: editor.format,
                                listing: keyListings[editor.format],
                                email: editor.email,
                                hasDefaultKeyCommand: editor.identity.hasDefaultKeyCommand,
                                width: Self.width - 2 * Self.inset,
                                // No New Key… when the format's program isn't here.
                                maker: signingPrograms?[editor.format].isFound == false ? nil : KeyMaker(
                                    list: list,
                                    repository: repository,
                                    name: editor.name,
                                    savesAtOnce: false
                                ) { made in
                                    keyListings[made.format, default: SigningKeys.Listing(keys: [])].keys.append(made.key)
                                }
                            )
                            .onSubmit { if !editor.changes.isEmpty { save(editor.changes) } }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save to")
                        .font(.system(size: 12, weight: .medium))
                    SettingsSegments(selection: $editor.place, options: [(.repository, "This Repository"), (.everyRepository, "Every Repository")], fillsWidth: true)
                        .accessibilityLabel("Save to")
                }
                .padding(.top, 2)
                if let note = editor.shadowNote {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(AgentColors.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure {
                    Text(failure)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Self.inset)
            HStack(spacing: 8) {
                DialogActionButton(button: .cancel(close))
                DialogActionButton(button: DialogButton(title: "Save", kind: .primary, isEnabled: !changes.isEmpty && !isSaving) {
                    save(changes)
                })
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(EdgeInsets(top: 16, leading: Self.inset, bottom: 14, trailing: Self.inset))
            CommandBlock(lines: changes.isEmpty ? [.comment("Nothing to save yet")] : changes.map { .command($0.arguments) }, isCompact: true)
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .background(DialogColors.surface)
        // The keys are listed only while the Key field shows, once for each
        // format, since gpg can take a moment the first time.
        .task(id: editor.signs ? editor.format : nil) {
            guard editor.signs, editor.format != .x509, keyListings[editor.format] == nil else { return }
            let format = editor.format
            if let listing = await list.signingKeys(format, for: repository) { keyListings[format] = listing }
        }
        // In the background, with the formats it hasn't confirmed faded in
        // the meantime (decision 108).
        .task(id: editor.signs) {
            guard editor.signs, signingPrograms == nil else { return }
            signingPrograms = await list.signingPrograms(for: repository)
        }
    }

    /// Why a format can't be chosen, while its program is being looked for
    /// or once it isn't found, or nil when it can. The format git signs with
    /// now can always be chosen, so that the popover shows what's so.
    static func unavailable(
        _ format: CommitIdentity.SigningFormat,
        programs: SigningPrograms.Found?,
        current: CommitIdentity.SigningFormat
    ) -> String? {
        guard format != current else { return nil }
        guard let programs else { return "Looking for \(SigningPrograms.defaultName(format))…" }
        return programs[format].hint
    }

    /// A field's label, where its value comes from, and Use Global when the
    /// repository sets it itself.
    private func label(_ key: IdentityEditor.Key, _ title: String, editor: IdentityEditor) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
            Text(editor.originWords(key))
                .font(.system(size: 11.5))
                .foregroundStyle(editor.isChanged(key) ? Color.primary : DialogColors.note)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if editor.canUseGlobal(key) {
                Button("Use Global") { editor.useGlobal(key) }
                    .buttonStyle(.contextual)
                    .fixedSize()
                    .help(BranchModel.command(IdentityEditor.Change.unset(key, in: .repository).arguments))
            }
        }
    }

    private func field(
        _ key: IdentityEditor.Key,
        _ title: String,
        text: Binding<String>,
        placeholder: String,
        isMonospaced: Bool = false,
        editor: IdentityEditor
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            label(key, title, editor: editor)
            SettingsTextField(text: text, placeholder: placeholder, width: Self.width - 2 * Self.inset, isMonospaced: isMonospaced)
                .accessibilityLabel(title)
                .onSubmit { if !editor.changes.isEmpty { save(editor.changes) } }
        }
    }

    private func save(_ changes: [IdentityEditor.Change]) {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        Task {
            do {
                try await list.changeIdentity(changes, of: repository)
                close()
            } catch {
                failure = String(describing: error)
            }
            isSaving = false
        }
    }
}
