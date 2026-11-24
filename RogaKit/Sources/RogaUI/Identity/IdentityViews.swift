import GitCore
import IconUI
import RepositoryEngine
import SwiftUI

/// An identity's initials in a circle tinted by its email, the way history's
/// author column shows people, with a small shield when commits are signed
/// and a triangle when a commit would go wrong (decision 103). An identity
/// with no email is gray.
struct IdentityBadge: View {
    let identity: CommitIdentity
    /// How wide the circle is: 22 points in the branch row, and 18 in the
    /// sidebar, where it sits beside a count.
    var size: CGFloat = 22
    /// Whether it has the shield or the triangle. The sidebar's doesn't,
    /// since a selected or hovered row's fill would show around the mark's
    /// circle, and the second line already says what would go wrong.
    var showsMark = true
    /// What's behind the badge, which the mark's circle cuts out of it.
    var background = Palette.surface

    var body: some View {
        let tint = IdentityTint.color(for: identity)
        Text(identity.initials)
            .font(.system(size: size * 9.5 / 22, weight: .semibold))
            .kerning(0.2)
            .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background {
                Circle().fill(tint.map { $0.opacity(0.16) } ?? DialogColors.card)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsMark, let mark {
                    mark.icon.image
                        .font(.system(size: 9 / 1.128, weight: .bold))
                        .foregroundStyle(mark.color)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(background))
                        .offset(x: 5, y: 4)
                }
            }
            .accessibilityHidden(true)
    }

    private var mark: (icon: Icon, color: Color)? {
        if identity.problem != nil { return (.warning, AgentColors.warn) }
        if identity.signs { return (.shield, .primary) }
        return nil
    }
}

/// Who the worktree's commits go out as, as initials before Fetch in the
/// branch row (decision 103). Its tooltip has the name and the email, where
/// they come from and how commits are signed, and a click opens the identity
/// popover. Nothing shows until git config has answered.
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
                IdentityBadge(identity: identity)
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
/// global identity. The top of the message box says it, and so does the
/// repository's row in the sidebar. With the global identity and nothing
/// wrong, neither says anything, since the branch row's initials do.
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

/// The line at the top of the message box with the name and the email the
/// commit goes out as, and whether it will be signed, while that's someone
/// other than the global identity, as for a repository in `~/work/` that a
/// file included for it gives a work email. A click opens the identity
/// popover.
struct CommitBoxIdentityLine: View {
    let identity: CommitIdentity
    let repository: ListedRepository
    let list: RepositoryList
    @State private var isEditing = false
    @State private var isHovering = false

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
            .frame(height: 22)
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

    /// The name in ink, then the email in the line's gray. It's built as an
    /// attributed string, since a localized string would take the email in
    /// angle brackets for a link.
    private var who: Text {
        var words = AttributedString()
        if let name = identity.shownName {
            var styled = AttributedString(name + " ")
            styled.font = .system(size: 12, weight: .medium)
            styled.foregroundColor = .primary
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
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.action)
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
