import GitCore
import IconUI
import SwiftUI

/// Starts a new branch in a new worktree from a worktree in the sidebar, and
/// shows the exact command as it's typed (decision 82). It hangs from the row it
/// was asked for on, which says which repository and branch it starts from, so
/// the window doesn't have to show that worktree first. It's New Branch's
/// popover with In a new worktree always on, so it has no checkbox, and the new
/// worktree goes next to the one it starts from, as there.
struct NewWorktreePopover: View {
    /// What the new branch starts from, as in `main`, or nil when the worktree
    /// has neither a branch nor a commit yet.
    let start: String?
    /// Makes the worktree and shows it.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    let create: (String) async -> String?
    @State private var name = ""
    @State private var refusal: String?
    @State private var isCreating = false
    @FocusState private var isNameFocused: Bool

    /// What the popover's title and the + button's tooltip say.
    static func title(startingFrom start: String?) -> String {
        start.map { "New Worktree from \($0)" } ?? "New Worktree"
    }

    /// What a worktree's new branch starts from, by its branch's short name, or
    /// the short hash with `HEAD` detached, as New Branch's tooltip says.
    static func start(of worktree: Worktree) -> String? {
        if let branch = worktree.branch { return Ref.shortName(branch) }
        return worktree.head.map { String($0.hex.prefix(8)) }
    }

    private var newBranch: NewBranch {
        NewBranch(name: name.trimmingCharacters(in: .whitespaces), inNewWorktree: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title(startingFrom: start))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(submit)
                .onChange(of: name) { refusal = nil }
            Text(BranchModel.command(newBranch.arguments))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isNameFocused = true }
    }

    private func submit() {
        guard !newBranch.name.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            refusal = await create(newBranch.name)
            isCreating = false
        }
    }
}

/// Hangs the popover for a new worktree from a sidebar row, at the row's right
/// edge, so that it opens into the window as Add Repositories' does.
struct NewWorktreePopoverModifier: ViewModifier {
    @Binding var isPresented: Bool
    let start: String?
    let create: (String) async -> String?

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: .trailing) {
            NewWorktreePopover(start: start, create: create)
        }
    }
}

/// The + that a repository's row shows on hover, before its menu's button,
/// which opens the popover for a new worktree from its main worktree
/// (decision 82). A repository's row is where its worktrees are listed, so
/// making one starts there.
struct NewWorktreeButton: View {
    let start: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoverIcon(size: 24) { Icon.plus.image }
        }
        .buttonStyle(.plain)
        .help(NewWorktreePopover.title(startingFrom: start))
        .accessibilityLabel("New Worktree")
    }
}
