import AppKit
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
    /// What the Sign commits choice says: nil for Off, or the format commits
    /// are signed with. Off leaves the format as it is, so choosing it again
    /// changes nothing.
    var signing: CommitIdentity.SigningFormat? {
        get { signs ? format : nil }
        set {
            if let newValue { format = newValue }
            signs = newValue != nil
        }
    }
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

    /// The settings the Sign commits choice shows: whether commits are
    /// signed and, while they are, the format.
    var signingKeys: [Key] {
        signs ? [.signsCommits, .signingFormat] : [.signsCommits]
    }

    /// Whether a field says something other than what was read.
    func isChanged(_ key: Key) -> Bool {
        value(key) != value(key, in: identity)
    }

    /// What Save runs, in order. A field that's emptied is removed from
    /// where Save writes. Use Global's removals run even when their field no
    /// longer shows, as the format doesn't once Use Global turns signing off.
    var changes: [Change] {
        let shown = shownKeys
        return Key.allCases.compactMap { key in
            if usingGlobal.contains(key) { return .unset(key, in: .repository) }
            guard shown.contains(key), isChanged(key) else { return nil }
            let value = value(key)
            return value.isEmpty ? .unset(key, in: place) : .set(key, value, in: place)
        }
    }

    /// Where a field's value comes from, as it was read.
    func originWords(_ key: Key) -> String {
        guard let setting = setting(key) else { return key == .signingFormat ? "git's default" : "not set" }
        return IdentityWords.origin(setting.origin, globalFiles: globalFiles)
    }

    /// What a field's label says after its name: where its value comes from,
    /// when that isn't the global config file, as in `set in this
    /// repository` beside Use Global. A global value is the usual case, so
    /// it says nothing. Neither does a value that isn't set, which the empty
    /// field or Off already shows, or a field once it changes, since Save to
    /// and the block along the bottom show what Save will do. So choosing
    /// Off or a format never adds words beside Sign commits.
    func labelWords(_ key: Key) -> String? {
        guard !isChanged(key), !usingGlobal.contains(key), setting(key) != nil, !isFromGlobalFile(key) else { return nil }
        return originWords(key)
    }

    /// Whether a field's value was read from the file `git config --global`
    /// writes to.
    private func isFromGlobalFile(_ key: Key) -> Bool {
        guard let origin = setting(key)?.origin, origin.scope == .global, let file = origin.file else { return false }
        return globalFiles.abbreviated(file) == globalFiles.shownFile
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
/// (decision 103). It has three parts with room between them: Name and
/// Email; Sign commits, one choice of Off or a format, with the key under it
/// while commits are signed; and Save to beside the buttons, which chooses
/// the repository's own
/// config, the default, or the global config. A field says where its value
/// comes from only when that isn't the global config file, as in `set in
/// this repository` beside Use Global. The block along its bottom shows the exact
/// commands that Save runs (decision 29). No field is selected when it
/// opens, so that nothing is highlighted until someone clicks or presses
/// Tab.
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
    /// Whether the keys or New Key… are open over the Key field.
    @State private var isShowingKeyPopover = false
    /// How tall the popover's content is.
    @State private var height: CGFloat = 0
    /// The height the popover keeps while the keys or New Key… are open.
    @State private var heldHeight: CGFloat?

    /// Wide enough for Sign commits' four choices, each as wide as OpenPGP.
    static let width: CGFloat = 380
    private static let inset: CGFloat = 16
    /// The room between two parts, more than twice that between two fields
    /// of one part.
    private static let partSpacing: CGFloat = 32

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
                // Which repository, since Settings opens it from a list of
                // them as well as from the repository's own window.
                Text("For \(repository.name) and its worktrees")
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(EdgeInsets(top: 13, leading: Self.inset, bottom: 14, trailing: Self.inset))
            // Who: the name and the email.
            VStack(alignment: .leading, spacing: 12) {
                field(.name, "Name", text: $editor.name, placeholder: "Your Name", editor: editor)
                field(.email, "Email", text: $editor.email, placeholder: "you@example.com", editor: editor)
            }
            .padding(.horizontal, Self.inset)
            partGap
            // How commits are signed: one choice, with Off first, so that
            // the formats read as the answer to Sign commits rather than as
            // three things to set up.
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    label(editor.signingKeys, "Sign commits", editor: editor)
                    // Without an animation, so the popover takes its new
                    // height in one step. Animated, it grew or shrank around
                    // its content, which moved toward the middle and back.
                    SettingsSegments(
                        selection: $editor.signing,
                        options: Self.signingChoices,
                        fillsWidth: true,
                        unavailable: { choice in
                            choice.flatMap {
                                Self.unavailable($0, programs: signingPrograms, current: editor.identity.signs ? editor.identity.format : nil)
                            }
                        }
                    )
                    .accessibilityLabel("Sign commits")
                }
                if editor.signs {
                    if let warning = signingPrograms?[editor.format].warning {
                        Text(warning)
                            .font(.system(size: 12))
                            .foregroundStyle(AgentColors.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                        },
                        label: label([.signingKey], "Key", editor: editor),
                        isShowingPopover: $isShowingKeyPopover
                    )
                    .onSubmit { if !editor.changes.isEmpty { save(editor.changes) } }
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, Self.inset)
            partGap
            // Where Save writes, and what's in the way.
            VStack(alignment: .leading, spacing: 12) {
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
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("Save to")
                            .font(.system(size: 12))
                            .foregroundStyle(DialogColors.note)
                            .fixedSize()
                        SettingsPopup(selection: $editor.place, options: [(.repository, "This Repository"), (.everyRepository, "Every Repository")])
                            .accessibilityLabel("Save to")
                    }
                    Spacer(minLength: 0)
                    DialogActionButton(button: .cancel(close))
                    DialogActionButton(button: DialogButton(title: "Save", kind: .primary, isEnabled: !changes.isEmpty && !isSaving) {
                        save(changes)
                    })
                }
            }
            .padding(EdgeInsets(top: 0, leading: Self.inset, bottom: 14, trailing: Self.inset))
            CommandBlock(lines: changes.isEmpty ? [.comment("Nothing to save yet")] : changes.map { .command($0.arguments) }, isCompact: true)
        }
        .frame(width: Self.width)
        .font(.system(size: 13))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // While the keys or New Key… are open over the Key field, the
        // popover keeps its height, and what would make it taller is cut
        // off at its bottom until they've gone. A popover with another one
        // open over it takes a new height only once that one has finished
        // closing, and until then its content grew out of its top, so that
        // the whole popover seemed to jump up toward its button and back.
        .frame(height: heldHeight, alignment: .top)
        .clipped()
        .background(DialogColors.surface)
        .background(NoFirstField())
        .onChange(of: isShowingKeyPopover) {
            heldHeight = isShowingKeyPopover ? height : nil
        }
        // The keys are listed only while the Key field shows, once for each
        // format, since gpg can take a moment the first time.
        .task(id: editor.signs ? editor.format : nil) {
            guard editor.signs, editor.format != .x509, keyListings[editor.format] == nil else { return }
            let format = editor.format
            if let listing = await list.signingKeys(format, for: repository) { keyListings[format] = listing }
        }
        // Each time the popover opens, since Sign commits always shows the
        // formats, in the background, with the formats it hasn't confirmed
        // faded in the meantime (decision 108).
        .task {
            guard signingPrograms == nil else { return }
            signingPrograms = await list.signingPrograms(for: repository)
        }
    }

    /// Sign commits' choices: Off, then each format.
    private static let signingChoices: [(value: CommitIdentity.SigningFormat?, title: String)] =
        [(nil, "Off")] + CommitIdentity.SigningFormat.allCases.map { ($0, $0.title) }

    /// Why a format can't be chosen, while its program is being looked for
    /// or once it isn't found, or nil when it can. The format git signs with
    /// now can always be chosen, so that the popover shows what's so. When
    /// commits aren't signed, there's no such format, so git's default isn't
    /// offered without gpg.
    static func unavailable(
        _ format: CommitIdentity.SigningFormat,
        programs: SigningPrograms.Found?,
        current: CommitIdentity.SigningFormat?
    ) -> String? {
        guard format != current else { return nil }
        guard let programs else { return "Looking for \(SigningPrograms.defaultName(format))…" }
        return programs[format].hint
    }

    /// The room between two of the popover's parts, which sets them apart
    /// without a line.
    private var partGap: some View {
        Color.clear.frame(height: Self.partSpacing)
    }

    /// A field's label, where its value comes from when that isn't the
    /// global config file, and Use Global when the repository sets it itself.
    /// Sign commits' label covers two settings, whether commits are signed
    /// and the format, so it says the first one's words, and its Use Global
    /// removes every one the repository sets.
    private func label(_ keys: [IdentityEditor.Key], _ title: String, editor: IdentityEditor) -> some View {
        let own = keys.filter(editor.canUseGlobal)
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
            if let words = keys.lazy.compactMap(editor.labelWords).first {
                Text(words)
                    .font(.system(size: 11.5))
                    .foregroundStyle(DialogColors.note)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if !own.isEmpty {
                Button("Use Global") { own.forEach(editor.useGlobal) }
                    .buttonStyle(.contextual)
                    .fixedSize()
                    .help(own.map { BranchModel.command(IdentityEditor.Change.unset($0, in: .repository).arguments) }.joined(separator: "\n"))
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
        VStack(alignment: .leading, spacing: 6) {
            label([key], title, editor: editor)
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

/// Takes the popover's first focus, so that it doesn't select the Name
/// field's text and highlight it when it opens. Tab still goes to the first
/// field, and Escape still closes the popover.
private struct NoFirstField: NSViewRepresentable {
    final class Holder: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
        }
    }

    func makeNSView(context: Context) -> Holder { Holder() }
    func updateNSView(_ view: Holder, context: Context) {}
}
