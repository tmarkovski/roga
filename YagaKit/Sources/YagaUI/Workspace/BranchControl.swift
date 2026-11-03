import GitCore
import SwiftUI

/// The branch in the title row, as a chip with a menu, and after it the counts
/// that pull and push (decision 19). The counts show only when there's something
/// to do, and the row reads as a sentence: `agents-demo main ↓3 ↑1`.
struct BranchControl: View {
    let branch: BranchModel
    let worktree: Worktree
    /// Goes to the refs panel's filter, or nil when the refs panel doesn't fit.
    let switchBranch: (() -> Void)?
    /// Shows one of the repository's worktrees in the window.
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            BranchChip(branch: branch, worktree: worktree, switchBranch: switchBranch, showWorktree: showWorktree)
                .layoutPriority(1)
            BranchCounts(branch: branch, switchBranch: switchBranch)
                .fixedSize()
                .layoutPriority(2)
        }
    }
}

/// The branch's name, which opens the menu with everything that can be done.
private struct BranchChip: View {
    @Bindable var branch: BranchModel
    let worktree: Worktree
    let switchBranch: (() -> Void)?
    let showWorktree: (String, ObjectID?) -> Void
    @State private var isHovering = false

    var body: some View {
        Menu {
            BranchMenuItems(branch: branch, switchBranch: switchBranch)
        } label: {
            HStack(spacing: 5) {
                BranchIcon.branch.image
                    .foregroundStyle(.secondary)
                if worktree.branch == nil, let head = worktree.head {
                    Text(head.hex.prefix(8))
                        .font(.system(size: 13, design: .monospaced))
                    Text("detached")
                        .foregroundStyle(.secondary)
                } else {
                    Text(worktree.title)
                        .truncationMode(.middle)
                }
                Triangle(pointsDown: true)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(branch.isCreatingBranch ? Palette.selection : isHovering ? Palette.hover : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(branch.summary())
        .accessibilityLabel("Branch \(worktree.title)")
        .popover(isPresented: $branch.isCreatingBranch, arrowEdge: .bottom) {
            NewBranchPopover(branch: branch, showWorktree: showWorktree)
        }
    }
}

/// What the branch's menu lists. It's also what clicking a count opens when a
/// click can't run straight away, and the commands in the menu bar.
struct BranchMenuItems: View {
    let branch: BranchModel
    let switchBranch: (() -> Void)?

    var body: some View {
        if let status = branch.status {
            Text(branch.summary())
            Divider()
            if status.hasDiverged, status.pullRebase == nil, let upstream = status.upstream {
                let name = Ref.shortName(status.branch)
                let other = Ref.shortName(upstream)
                item("Rebase \(name) onto \(other)", icon: .pull) { branch.pull(.rebase) }
                    .disabled(branch.isBusy)
                item("Merge \(other) into \(name)", icon: .pull) { branch.pull(.merge) }
                    .disabled(branch.isBusy)
            } else {
                item("Pull", icon: .pull, action: branch.pull)
                    .keyboardShortcut(RepositoryCommands.pullShortcut)
                    .disabled(status.pull == nil || branch.isBusy)
            }
            item("Push", icon: .push, action: branch.push)
                .keyboardShortcut(RepositoryCommands.pushShortcut)
                .disabled(status.push == nil || branch.isBusy)
                .modifierKeyAlternate(.option) {
                    item("Force Push with Lease…", icon: .push, action: branch.askToForcePush)
                        .disabled(status.upstream == nil || branch.isBusy)
                }
            item("Fetch", icon: .fetch, action: branch.fetch)
                .keyboardShortcut(RepositoryCommands.fetchShortcut)
                .disabled(status.remote == nil || branch.isBusy)
            Divider()
        }
        item("New Branch…", icon: .branch) { branch.isCreatingBranch = true }
            .keyboardShortcut(RepositoryCommands.newBranchShortcut)
            .disabled(branch.isBusy)
        item("Switch Branch…", icon: .blank) { switchBranch?() }
            .disabled(switchBranch == nil)
    }

    /// A menu item with its icon, which menus leave out unless told otherwise.
    private func item(_ title: String, icon: BranchIcon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { icon.image }
                .labelStyle(.titleAndIcon)
        }
    }
}

/// `↓3` and `↑1`, or what git is doing in their place.
private struct BranchCounts: View {
    let branch: BranchModel
    let switchBranch: (() -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            if let action = branch.action {
                HStack(spacing: 5) {
                    HouseAnimationView(animation: action.houseAnimation)
                        .id(action.houseAnimation)
                    Text(action.title)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            } else if let finished = branch.finished {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                    Text(finished)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            } else if let status = branch.status {
                if status.behind > 0 {
                    pullCount(status)
                }
                if status.ahead > 0 {
                    pushCount(status)
                } else if status.upstream == nil, status.push != nil {
                    firstPush
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    @ViewBuilder private func pullCount(_ status: BranchStatus) -> some View {
        let label = BranchCount(icon: .pull, text: status.behind.formatted(), isOrange: true)
        Group {
            if status.pull != nil {
                Button(action: branch.pull) { label }
                    .buttonStyle(.plain)
            } else {
                Menu {
                    BranchMenuItems(branch: branch, switchBranch: switchBranch)
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .help(branch.pullHelp)
        .accessibilityLabel("Pull \(status.behind.formatted())")
        .onHover { branch.preview($0 ? .pull : nil) }
    }

    @ViewBuilder private func pushCount(_ status: BranchStatus) -> some View {
        let label = BranchCount(icon: .push, text: status.ahead.formatted(), isOrange: status.push != nil)
        Group {
            if status.push != nil {
                Button(action: branch.push) { label }
                    .buttonStyle(.plain)
            } else {
                // git would reject the push, so this says what can be done.
                Menu {
                    BranchMenuItems(branch: branch, switchBranch: switchBranch)
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
        }
        .fixedSize()
        .help(branch.pushHelp)
        .accessibilityLabel("Push \(status.ahead.formatted())")
        .onHover { branch.preview($0 ? .push : nil) }
    }

    /// For a branch that's never been pushed, which stays gray, because agent
    /// branches live like that and the orange would never go away.
    private var firstPush: some View {
        Button(action: branch.push) {
            BranchCount(icon: .push, text: "Push", isOrange: false)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(branch.pushHelp)
        .accessibilityLabel("Push for the First Time")
    }
}

/// An icon and a number. Orange means a click runs right now.
private struct BranchCount: View {
    let icon: BranchIcon
    let text: String
    let isOrange: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 3) {
            icon.image
            Text(text)
                .monospacedDigit()
                .fontWeight(isOrange ? .semibold : .regular)
                .contentTransition(.numericText())
                .animation(.snappy, value: text)
        }
        .accessibilityElement(children: .ignore)
        .foregroundStyle(isOrange ? AnyShapeStyle(Palette.action) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .frame(minWidth: 28, minHeight: 28)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.hover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 && isEnabled }
    }
}

/// Starts a new branch from the worktree's branch, here or in a new worktree, and
/// shows the exact command as it's typed.
private struct NewBranchPopover: View {
    let branch: BranchModel
    let showWorktree: (String, ObjectID?) -> Void
    @State private var name = ""
    @State private var inNewWorktree = false
    @State private var refusal: String?
    @State private var isCreating = false
    @FocusState private var isNameFocused: Bool

    private var newBranch: NewBranch {
        NewBranch(name: name.trimmingCharacters(in: .whitespaces), inNewWorktree: inNewWorktree)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New Branch")
                .font(.system(size: 13, weight: .medium))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onSubmit(create)
                .onChange(of: name) { refusal = nil }
            Toggle("In a new worktree", isOn: $inNewWorktree)
                .toggleStyle(.checkbox)
                .onChange(of: inNewWorktree) { refusal = nil }
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

    private func create() {
        guard !newBranch.name.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            refusal = await branch.create(newBranch, showWorktree: showWorktree)
            isCreating = false
        }
    }
}
