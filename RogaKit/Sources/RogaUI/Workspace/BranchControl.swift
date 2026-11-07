import AppKit
import GitCore
import IconUI
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
    let branch: BranchModel
    let worktree: Worktree
    let switchBranch: (() -> Void)?
    let showWorktree: (String, ObjectID?) -> Void
    @State private var isHovering = false

    var body: some View {
        Menu {
            BranchMenuItems(branch: branch, switchBranch: switchBranch)
        } label: {
            HStack(spacing: 5) {
                Icon.branch.image
                    .foregroundStyle(.secondary)
                if worktree.branch == nil, let head = worktree.head {
                    Text(head.hex.prefix(8))
                        .font(.system(size: 13, design: .monospaced))
                    Text("detached")
                        .foregroundStyle(.secondary)
                } else {
                    Text(worktree.title)
                        .truncationMode(.middle)
                        // A few letters at each end, so that the repository's
                        // name truncates before this goes altogether.
                        .frame(minWidth: Self.shortestNameWidth(worktree.title))
                }
                Icon.dropdown.image
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .frame(height: 26)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovering ? Palette.hover : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(branch.summary())
        .accessibilityLabel("Branch \(worktree.title)")
    }

    /// How narrow the branch's name can get: all of a short one, and otherwise
    /// about two letters, an ellipsis and two letters.
    private static func shortestNameWidth(_ name: String) -> Double {
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
        return min(width, 40)
    }
}

/// Fetch and New Branch, as icons at the right end of the title row, before
/// history's commands (decision 45). They stay where they are while the branch's
/// name and counts change. The branch's menu has both as well.
struct BranchButtons: View {
    let branch: BranchModel
    let worktree: Worktree
    /// Shows one of the repository's worktrees in the window.
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        HStack(spacing: 2) {
            FetchButton(branch: branch)
            NewBranchButton(branch: branch, worktree: worktree, showWorktree: showWorktree)
        }
    }
}

/// Fetches from the branch's remote. The house drops through it while any fetch
/// runs, the one Roga starts by itself included, so that nothing opens in the
/// title row for a fetch. Clicking it during one Roga started stops that and
/// fetches again, so that anything that goes wrong is reported.
private struct FetchButton: View {
    let branch: BranchModel

    var body: some View {
        // Often enough to keep "Last fetched 4 min ago" right in the tooltip.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Button(action: branch.fetch) {
                FetchDrop(isFetching: branch.isFetching)
            }
            .buttonStyle(.icon)
            .disabled(branch.status?.remote == nil)
            .help(branch.fetchHelp(now: context.date))
            .accessibilityLabel("Fetch")
            .accessibilityValue(branch.isFetching ? "Fetching" : "")
        }
    }
}

/// Opens the popover for a new branch, which hangs from this button however it
/// was asked for: here, from the branch's menu, with Shift-Command-B, or from
/// New Worktree… in the menu of the repository's worktrees.
private struct NewBranchButton: View {
    @Bindable var branch: BranchModel
    let worktree: Worktree
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        Button {
            branch.isCreatingBranch = true
        } label: {
            Icon.newBranch.image
        }
        .buttonStyle(.icon(isOn: branch.isCreatingBranch))
        .help(help)
        .accessibilityLabel("New Branch")
        .popover(isPresented: $branch.isCreatingBranch, arrowEdge: .bottom) {
            NewBranchPopover(branch: branch, showWorktree: showWorktree)
        }
    }

    /// Where the new branch starts, as in `New Branch from main`.
    private var help: String {
        if let name = worktree.branch { return "New Branch from \(Ref.shortName(name))" }
        if let head = worktree.head { return "New Branch from \(head.hex.prefix(8))" }
        return "New Branch"
    }
}

/// What the branch's menu lists. It's also what clicking a count opens when a
/// click can't run straight away, and the commands in the menu bar.
struct BranchMenuItems: View {
    let branch: BranchModel
    let switchBranch: (() -> Void)?
    /// Whether New Worktree… follows New Branch…, which only the menu bar's
    /// Branch menu has, since the branch's own menu leaves worktrees to the
    /// menu of the repository's worktrees.
    var listsNewWorktree = false
    /// What New Worktree… does, or nil while it can't start.
    var newWorktree: (() -> Void)?

    var body: some View {
        if let status = branch.status {
            Text(branch.summary())
            Divider()
            // With nothing in the git config to say how, a pull asks first.
            let asks = status.pull == nil && status.hasDiverged
            item(asks ? "Pull…" : "Pull", icon: .pull, action: branch.pull)
                .keyboardShortcut(RepositoryCommands.pullShortcut)
                .disabled((status.pull == nil && !asks) || branch.isBusy)
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
        item("New Branch…", icon: .newBranch) { branch.isCreatingBranch = true }
            .keyboardShortcut(RepositoryCommands.newBranchShortcut)
            .disabled(branch.isBusy)
        if listsNewWorktree {
            item("New Worktree…", icon: .worktree) { newWorktree?() }
                .keyboardShortcut(RepositoryCommands.newWorktreeShortcut)
                .disabled(newWorktree == nil)
        }
        item("Switch Branch…", icon: nil) { switchBranch?() }
            .disabled(switchBranch == nil)
    }

    /// A menu item with its icon, which menus leave out unless told otherwise.
    private func item(_ title: String, icon: Icon?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { Text(title) } icon: { icon?.image ?? Self.noIcon }
                .labelStyle(.titleAndIcon)
        }
    }

    /// Nothing to see, for a menu item that lines up with the ones that have an icon.
    private static let noIcon = Image(nsImage: NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in true })
}

/// `↓3` and `↑1`, or what git is doing in their place. That goes in steps: the
/// house zooms in, then the words come out beside it and move what's to their
/// right along. When git is done the words change to what happened and the house
/// zooms out, and when those words have had their moment, they close up again.
/// A commit has no house, so only its words come and go. A fetch shows nothing
/// here, because the house drops through the Fetch button instead (decisions 45
/// and 55).
private struct BranchCounts: View {
    /// How the title row moves from one step to the next.
    private enum Motion {
        static let zoom = Animation.spring(duration: 0.24, bounce: 0.25)
        /// How long the house gets to zoom in before the words start.
        static let zoomTime = Duration.milliseconds(160)
        static let words = Animation.snappy(duration: 0.3)
    }

    /// What's on screen, which follows the branch's activity a step at a time.
    private struct Shown: Equatable {
        var house: HouseAnimation?
        /// These stay after they stop showing, so that they can close up.
        var words = ""
        var arrival = WordsArrival.fade
        var showsWords = false
        var showsCounts = true
    }

    /// What git is doing, or what it just did. The note about what it did can
    /// start before the action ends, and the action comes first.
    private enum Activity: Equatable {
        case idle
        case running(BranchModel.Action)
        case finished(String)
    }

    let branch: BranchModel
    let switchBranch: (() -> Void)?
    @State private var shown = Shown()
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    private var activity: Activity {
        if let action = branch.action, action != .fetching { .running(action) }
        else if let finished = branch.finished { .finished(finished) }
        else { .idle }
    }

    var body: some View {
        HStack(spacing: 0) {
            // It takes no room without a house, and its room opens and closes
            // along with the zoom, so that the words never run into the house.
            ZStack {
                if let house = shown.house {
                    HouseAnimationView(animation: house)
                        .id(house)
                        .padding(.leading, 4)
                        // From its leading edge, which is where the room for it
                        // opens and closes, so that the words can't run into it.
                        .transition(.scale(scale: 0.2, anchor: .leading).combined(with: .opacity))
                }
            }
            Text(shown.words)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
                .padding(.leading, 5)
                .padding(.trailing, 4)
                .modifier(WordsReveal(isShown: shown.showsWords, arrival: shown.arrival))
                .accessibilityHidden(!shown.showsWords)
            if shown.showsWords, let undo = branch.undoFinished {
                Button("Undo", action: undo.perform)
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .foregroundStyle(Palette.action)
                    .padding(.trailing, 4)
                    .help(undo.help)
            }
            if shown.showsCounts {
                // A worktree that's stuck comes before anything else it could
                // do, and during a rebase it isn't on a branch to have counts.
                if let unfinished = branch.unfinished {
                    UnfinishedWorkControl(branch: branch, unfinished: unfinished)
                        .transition(Self.countsTransition)
                } else if let status = branch.status {
                    HStack(spacing: 2) {
                        if status.behind > 0 {
                            pullCount(status)
                        }
                        if status.ahead > 0 {
                            pushCount(status)
                        } else if status.upstream == nil, status.push != nil {
                            firstPush
                        }
                    }
                    .transition(Self.countsTransition)
                }
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .task(id: activity) { await show(activity) }
    }

    /// Their room opens a frame at a time, as the words' room closes, or for a
    /// moment they'd have room for both, and what's to their right would jump.
    private static var countsTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: CountsOpening(amount: 0), identity: CountsOpening(amount: 1))
                .combined(with: .opacity),
            removal: .opacity
        )
    }

    private func show(_ activity: Activity) async {
        switch activity {
        case .idle:
            move(Motion.words) {
                shown.house = nil
                shown.showsWords = false
                shown.showsCounts = true
            }
        case .finished(let words):
            move(Motion.words) {
                shown.house = nil
                shown.words = words
                shown.showsWords = true
                shown.showsCounts = false
            }
        case .running(let action):
            guard let house = action.houseAnimation else {
                // Outside the animation, because turning what just happened into
                // these moves what's to the right past where it ends up.
                shown.words = action.title
                shown.arrival = .fade
                // On one curve, so that what's to the right moves steadily rather
                // than following the counts out and then the words back.
                move(Motion.words) {
                    shown.house = nil
                    shown.showsWords = true
                    shown.showsCounts = false
                }
                return
            }
            move(Motion.zoom) {
                shown.house = house
                shown.showsWords = false
                shown.showsCounts = false
            }
            if !reducesMotion {
                guard (try? await Task.sleep(for: Motion.zoomTime)) != nil else { return }
            }
            shown.words = action.title
            shown.arrival = WordsArrival(house)
            move(Motion.words) { shown.showsWords = true }
        }
    }

    /// Someone who asked for less motion gets each step straight away.
    private func move(_ animation: Animation, _ change: () -> Void) {
        withAnimation(reducesMotion ? nil : animation, change)
    }

    private func pullCount(_ status: BranchStatus) -> some View {
        Button(action: branch.pull) {
            BranchCount(icon: .pull, text: status.behind.formatted(), isOrange: true)
        }
        .buttonStyle(.plain)
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

/// Says what the worktree is stuck partway through, in place of the counts, and
/// opens a menu of what can be done about it (decision 28). It's red with a
/// triangle only while there are conflicts. With none left, nothing is wrong, but
/// it still isn't finished, so it stays in gray.
private struct UnfinishedWorkControl: View {
    let branch: BranchModel
    let unfinished: UnfinishedWork
    @State private var isHovering = false

    var body: some View {
        Menu {
            if unfinished.hasConflicts {
                Button("Show Conflicts", action: branch.showChanges)
            }
            if let work = unfinished.work {
                if unfinished.hasConflicts { Divider() }
                Button(work.abortTitle, action: branch.askToAbort)
                    .disabled(branch.isBusy)
            }
        } label: {
            HStack(spacing: 4) {
                if unfinished.hasConflicts {
                    Icon.warning.image
                }
                Text(unfinished.title)
                    .monospacedDigit()
                    .fontWeight(unfinished.hasConflicts ? .semibold : .regular)
            }
            .accessibilityElement(children: .ignore)
            .foregroundStyle(unfinished.hasConflicts ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.hover : .clear)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(unfinished.help)
        .accessibilityLabel(unfinished.title)
    }
}

/// How the words in the title row arrive, which says which way the commits are
/// going, the way the house's lean does.
enum WordsArrival: Equatable {
    /// Out from behind the house, moving what's to their right along.
    case fromLeft
    /// In from the right, toward the house that's pulling them.
    case fromRight
    /// In place, for what has no direction to show.
    case fade

    init(_ house: HouseAnimation) {
        switch house {
        case .push: self = .fromLeft
        case .heave, .tugOfWar: self = .fromRight
        case .waddle: self = .fade
        }
    }
}

/// Opens room for the words and moves them in, or does the reverse.
private struct WordsReveal: ViewModifier {
    /// How far the words travel when they come in from the right.
    private static let travel: CGFloat = 24
    /// This outlasts the room opening. Most of the way would otherwise go by
    /// while they're still faint and clipped, and what's to their right would be
    /// moving the opposite way for all of it.
    private static let glide = Animation.easeOut(duration: 0.45)

    let isShown: Bool
    let arrival: WordsArrival
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    func body(content: Content) -> some View {
        PartWidth(amount: isShown ? 1 : 0, keepsTrailingEnd: arrival == .fromLeft) {
            content
                .offset(x: !isShown && arrival == .fromRight ? Self.travel : 0)
                .animation(reducesMotion ? nil : Self.glide, value: isShown)
                .opacity(isShown ? 1 : 0)
        }
        .clipped()
    }
}

/// Opens room for the counts as they come back.
private struct CountsOpening: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        PartWidth(amount: amount, keepsTrailingEnd: false) { content }
            .clipped()
    }
}

/// Takes up a part of its content's width, keeping one end of the content against
/// its edge. The part is animated by laying out again on every frame, so what's
/// beside this moves exactly with that end, rather than animating on its own and
/// drifting ahead of it.
private struct PartWidth: Layout {
    var amount: Double
    let keepsTrailingEnd: Bool

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        // In whole points, or the title row's width passes through fractions of
        // a pixel on the way, and the text at its other end wobbles.
        return CGSize(width: (size.width * amount).rounded(.up), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: keepsTrailingEnd ? bounds.maxX : bounds.minX, y: bounds.midY),
            anchor: keepsTrailingEnd ? .trailing : .leading,
            proposal: .unspecified
        )
    }
}

/// An icon and a number. Orange means a click runs right now.
private struct BranchCount: View {
    let icon: Icon
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
        .onAppear {
            isNameFocused = true
            if branch.startsInNewWorktree {
                inNewWorktree = true
                branch.startsInNewWorktree = false
            }
        }
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
