import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// Who a repository's commits go out as, drawn as a person (decision 105).
/// The global identity is a person in gray, like the icon buttons around it,
/// anyone else's is in the email's tint, and an identity whose next commit
/// would go wrong is amber. None of them has a circle, whose faint fill would
/// turn muddy on a hovered button's or a selected row's gray. In the title
/// row, a small shield at the person's lower right says commits are signed,
/// and a triangle there says a commit would go wrong.
struct IdentityPerson: View {
    enum Look: Equatable {
        /// The global identity, with nothing wrong.
        case plain
        /// Someone other than the global identity, in the email's tint, or
        /// gray without one.
        case tinted(Color?)
        /// A commit would go wrong.
        case warning

        init(_ exception: IdentityException?) {
            switch exception {
            case nil: self = .plain
            case .someoneElse(let someone): self = .tinted(IdentityTint.color(for: someone))
            case .problem: self = .warning
            }
        }
    }

    /// What sits at the person's lower right.
    enum Mark: Equatable {
        /// Commits are signed.
        case shield
        /// A commit would go wrong, which matters more than how it'd be
        /// signed.
        case warning

        init?(_ look: Look, signs: Bool) {
            switch look {
            case .warning: self = .warning
            case .plain, .tinted:
                guard signs else { return nil }
                self = .shield
            }
        }
    }

    /// Where the person is drawn.
    enum Style {
        /// In the title row's button, as large as the row's other icons, with
        /// the mark.
        case button
        /// Beside a repository's count in the sidebar or its name in
        /// Settings › Git's list, as large as the message box's line draws
        /// it. It has no mark, since a second line says what would go wrong,
        /// and a shield on every repository that signs would say one thing
        /// many times over.
        case inline
    }

    let look: Look
    /// Whether commits are signed, which puts the shield on the person.
    var signs = false
    var style = Style.button

    private static let markSize: CGFloat = 14
    private static let markOffset = CGSize(width: 5, height: 4)

    /// How wide the person is.
    private var size: CGFloat { style == .button ? 22 : 18 }

    var body: some View {
        let mark = style == .button ? Mark(look, signs: signs) : nil
        person
            .frame(width: size, height: size)
            // The mark's circle is cut out of the person rather than filled
            // with the row's color, so that the button's gray shows through
            // it under the pointer.
            .mask {
                Rectangle()
                    .overlay(alignment: .bottomTrailing) {
                        if mark != nil {
                            Circle()
                                .frame(width: Self.markSize, height: Self.markSize)
                                .offset(Self.markOffset)
                                .blendMode(.destinationOut)
                        }
                    }
                    .compositingGroup()
            }
            .overlay(alignment: .bottomTrailing) {
                if let mark {
                    markIcon(mark)
                        .font(.system(size: 9 / 1.128, weight: .bold))
                        .frame(width: Self.markSize, height: Self.markSize)
                        .offset(Self.markOffset)
                }
            }
            .accessibilityHidden(true)
    }

    /// The mark in the person's color.
    private func markIcon(_ mark: Mark) -> some View {
        inked((mark == .warning ? Icon.warning : Icon.shield).image)
    }

    @ViewBuilder private var person: some View {
        switch style {
        case .button:
            // The icon button's own size.
            inked(Icon.user.image)
        case .inline:
            inked(Icon.user.image.font(.system(size: 13 / 1.128, weight: .semibold)))
        }
    }

    /// In the person's color. The global identity's takes the button's gray,
    /// which turns to ink under the pointer.
    @ViewBuilder private func inked(_ image: some View) -> some View {
        switch look {
        case .plain: image
        case .tinted(let tint): image.foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
        case .warning: image.foregroundStyle(AgentColors.warn)
        }
    }
}

/// Who the repository's commits go out as, at the end of the title row, for
/// the repository and every worktree and agent in it (decision 105). Commits,
/// merges, rebases, cherry-picks and reverts all go out as it, so it shows
/// whatever the panels show, with the shield while commits are signed, since
/// a rebase or a cherry-pick signs each commit again. Its tooltip has the
/// name and the email, where they come from and how commits are signed, and a
/// click opens the identity popover. Nothing shows until git config has
/// answered.
struct IdentityButton: View {
    let repository: ListedRepository
    let list: RepositoryList
    @State private var isEditing = false

    var body: some View {
        if let identity = repository.identity {
            let words = IdentityWords(identity: identity)
            Button {
                isEditing = true
            } label: {
                IdentityPerson(look: .init(IdentityException(identity, defaultIdentity: list.defaultIdentity)),
                               signs: identity.signs)
            }
            .buttonStyle(.icon(isOn: isEditing))
            .help(words.tooltip)
            .accessibilityLabel("Commit Identity")
            .accessibilityValue(words.spoken)
            .popover(isPresented: $isEditing, arrowEdge: .bottom) {
                IdentityPopover(repository: repository, list: list) { isEditing = false }
            }
            .transition(.opacity)
        }
    }
}

/// What's worth saying about who a repository's commits go out as
/// (decision 103): what would go wrong, or that it's someone other than the
/// global identity. The repository's row in the sidebar says it, and so does
/// Settings › Git's list, while the title row and the message box draw it
/// differently from the global identity (decision 105).
enum IdentityException: Equatable {
    case problem(CommitIdentity.Problem)
    case someoneElse(CommitIdentity)

    /// What there is to say, or nil when there's nothing.
    init?(_ identity: CommitIdentity?, defaultIdentity: CommitIdentity?) {
        guard let identity else { return nil }
        if let problem = identity.problem {
            self = .problem(problem)
            return
        }
        // Until the global identity has been read, nothing says this one
        // differs from it.
        guard let defaultIdentity, !identity.commitsAsSame(as: defaultIdentity) else { return nil }
        self = .someoneElse(identity)
    }

    var problem: CommitIdentity.Problem? {
        if case .problem(let problem) = self { problem } else { nil }
    }

    var someoneElse: CommitIdentity? {
        if case .someoneElse(let identity) = self { identity } else { nil }
    }
}

/// What the top of the message box says about who the commit goes out as
/// (decision 105). It always says who, and warns instead when the commit
/// would go wrong.
enum CommitBoxIdentity: Equatable {
    /// git config hasn't answered yet, so the box keeps the line's room, and
    /// the message doesn't move down when the line arrives.
    case unread
    /// The line, which stands out when it's someone other than the global
    /// identity.
    case line(CommitIdentity, isSomeoneElse: Bool)
    case warning(CommitIdentity.Problem)

    init(_ identity: CommitIdentity?, defaultIdentity: CommitIdentity?) {
        guard let identity else {
            self = .unread
            return
        }
        switch IdentityException(identity, defaultIdentity: defaultIdentity) {
        case .problem(let problem): self = .warning(problem)
        case .someoneElse: self = .line(identity, isSomeoneElse: true)
        case nil: self = .line(identity, isSomeoneElse: false)
        }
    }
}

/// The line at the top of the message box with the name and the email the
/// commit goes out as, and whether it will be signed (decision 105). It's
/// gray for the global identity. For anyone else, as for a repository in
/// `~/work/` that a file included for it gives a work email, the person
/// takes the email's tint and the name is in ink. A click opens the identity
/// popover.
struct CommitBoxIdentityLine: View {
    let identity: CommitIdentity
    let isSomeoneElse: Bool
    let repository: ListedRepository
    let list: RepositoryList
    @State private var isEditing = false
    @State private var isHovering = false

    /// How tall the line is, which the box keeps until git config answers.
    static let height: CGFloat = 22

    var body: some View {
        let words = IdentityWords(identity: identity)
        Button {
            isEditing = true
        } label: {
            // The words for signing go before the email is cut short, since
            // the shield says it, and the tooltip says it in words.
            ViewThatFits(in: .horizontal) {
                line(showsSigningWords: true)
                line(showsSigningWords: false)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: Self.height)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering || isEditing ? Palette.buttonHover : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(words.tooltip)
        .accessibilityLabel("Commit Identity")
        .accessibilityValue(words.spoken)
        .popover(isPresented: $isEditing, arrowEdge: .top) {
            IdentityPopover(repository: repository, list: list) { isEditing = false }
        }
    }

    private func line(showsSigningWords: Bool) -> some View {
        HStack(spacing: 6) {
            Icon.user.image
                .font(.system(size: 12 / 1.128, weight: .medium))
                .foregroundStyle(tint)
            who
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                (identity.signs ? Icon.shield : Icon.shieldOff).image
                    .font(.system(size: 12 / 1.128, weight: .medium))
                if showsSigningWords {
                    Text(identity.signs ? "Signed" : "Not signed")
                }
            }
            .fixedSize()
        }
    }

    /// The person's color: the email's tint for someone other than the global
    /// identity, as in the title row, and otherwise the line's gray.
    private var tint: AnyShapeStyle {
        guard isSomeoneElse, let tint = IdentityTint.color(for: identity) else { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(tint)
    }

    /// The name, in ink for someone other than the global identity, then the
    /// email in the line's gray. It's built as an attributed string, since a
    /// localized string would take the email in angle brackets for a link.
    private var who: Text {
        var words = AttributedString()
        if let name = identity.shownName {
            var styled = AttributedString(name + " ")
            styled.font = .system(size: 12, weight: .medium)
            if isSomeoneElse { styled.foregroundColor = .primary }
            words += styled
        }
        if let email = identity.shownEmail {
            words += AttributedString("<\(email)>")
        }
        return Text(words)
    }
}

/// What the top of the message box says before a commit that would go wrong:
/// with no email, git refuses or makes one up, and SSH signing with no key
/// stops the commit at signing. Each has its own way on.
struct CommitBoxIdentityWarning: View {
    let problem: CommitIdentity.Problem
    let repository: ListedRepository
    let list: RepositoryList
    @State private var isEditing = false
    @State private var failure: String?

    var body: some View {
        let words = IdentityWords.problem(problem)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Icon.warning.image
                    .font(.system(size: 12 / 1.128, weight: .semibold))
                Text(words.title)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AgentColors.warn)
            Text(words.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button(problem == .noEmail ? "Set Identity…" : "Set Key…") { isEditing = true }
                if problem == .noSigningKey {
                    Button("Stop Signing", action: stopSigning)
                        .help(BranchModel.command(Self.stopSigning.arguments))
                }
            }
            .buttonStyle(.contextual)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IdentityColors.warningFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .popover(isPresented: $isEditing, arrowEdge: .top) {
            IdentityPopover(repository: repository, list: list) { isEditing = false }
        }
    }

    /// Turns signing off for this repository alone.
    static let stopSigning = CommitIdentityCommands.Change.set(.signsCommits, "false", in: .repository)

    private func stopSigning() {
        failure = nil
        Task {
            do {
                try await list.changeIdentity([Self.stopSigning], of: repository)
            } catch {
                failure = String(describing: error)
            }
        }
    }
}

enum IdentityColors {
    /// Behind a warning about the identity, the amber of an agent that waits
    /// for you, faint.
    static let warningFill = DialogColors.appearanceColor(light: 0xFBF0E1, dark: 0x3A2C19)
}
