import GitCore
import SwiftUI

/// Starts a new branch in a new worktree from a worktree in the sidebar, and
/// shows the exact command as it's typed (decision 82). It hangs from the row it
/// was asked for on, which says which repository and branch it starts from, so
/// the window doesn't have to show that worktree first. It's New Branch's
/// popover with In a new worktree always on, so it has no switch, and the new
/// worktree goes next to the one it starts from, as there.
struct NewWorktreePopover: View {
    /// What the new branch starts from, as in `main`, or nil when the worktree
    /// has neither a branch nor a commit yet.
    let start: String?
    /// Makes the worktree and shows it.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    let create: (String) async -> String?
    let close: () -> Void
    @State private var name = ""
    @State private var refusal: String?
    @State private var isCreating = false

    /// What the button that opens the popover says in its tooltip.
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
        NewRefForm(
            title: "New worktree",
            subtitle: start.map { "From \($0)" },
            name: $name,
            placeholder: "Branch name",
            action: "Create Worktree",
            commands: [newBranch.arguments],
            emptyNote: "Type the new branch's name",
            refusal: refusal,
            isCreating: isCreating,
            create: submit,
            close: close
        ) {
            EmptyView()
        }
        .onChange(of: name) { refusal = nil }
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
            NewWorktreePopover(start: start, create: create) { isPresented = false }
        }
    }
}
