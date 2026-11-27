import AppKit
import GitCore
import IconUI
import MenuUI
import RepositoryEngine
import SwiftUI

/// The branch at the start of the branch's row, under the tabs, as its name
/// over how far it is from the main branch on the remote, and after it the
/// counts that pull and push (decisions 19, 95 and 119). The counts show only
/// when there's something to do, and the row reads as a sentence:
/// `agent/fix-login ↑2`.
struct BranchControl: View {
    let branch: BranchModel
    let worktree: Worktree
    /// The repository's name, for the popover's subtitle.
    let repositoryName: String
    /// Goes to the refs panel's filter, or nil when the refs panel doesn't fit.
    let switchBranch: (() -> Void)?
    /// Takes the worktree's lock off.
    let unlock: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            BranchBlock(branch: branch, worktree: worktree, repositoryName: repositoryName, switchBranch: switchBranch, unlock: unlock)
                .layoutPriority(1)
            BranchCounts(branch: branch, switchBranch: switchBranch)
                .fixedSize()
                .layoutPriority(2)
        }
    }
}

/// The branch's name, with the branch's icon before it, over how far the
/// branch is from the main branch on the remote, as in `4 ahead, 12 behind
/// origin/main` (decision 120). A click opens the popover about the checkout,
/// on the press (decision 111), and its tooltip has the worktree's folder.
///
/// The icon is the branch's even for a detached `HEAD`, as the chip before
/// it drew, since the commit's ID and `detached` already say what it is.
private struct BranchBlock: View {
    let branch: BranchModel
    let worktree: Worktree
    let repositoryName: String
    let switchBranch: (() -> Void)?
    let unlock: () -> Void
    @State private var isHovering = false
    @State private var showsDetail = false

    /// How wide it gets, so that a long name leaves the agent room.
    private static let widest: CGFloat = 300

    var body: some View {
        // Often enough to keep `fetched 4 min ago` right, for the main branch.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let line = Self.secondLine(branch: branch, worktree: worktree, now: context.date)
            Button {
                showsDetail.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Icon.branch.image
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        name
                    }
                    .font(.system(size: 13))
                    HStack(spacing: 0) {
                        if worktree.isLocked {
                            Icon.lock.image
                                .font(.system(size: 9.5))
                                .padding(.trailing, 3)
                        }
                        // A space while there's nothing to say yet, so that the
                        // name doesn't move when the line arrives.
                        Text(line.words.isEmpty ? " " : line.words)
                            .truncationMode(.tail)
                        if let conflicts = line.conflicts {
                            Text(" · \(conflicts)")
                                .foregroundStyle(Palette.action)
                                .fixedSize()
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .modifier(WidthCap(width: Self.widest))
                .frame(height: BranchBar.controlHeight)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovering || showsDetail ? Palette.buttonHover : .clear)
                }
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .opensOnPress($showsDetail)
            .help(help(now: context.date))
            .accessibilityLabel("Branch \(worktree.title)")
            .accessibilityValue([line.words, line.conflicts].compactMap(\.self).joined(separator: ", "))
            .accessibilityHint("Shows the worktree's folder and how far the branch is from main")
            .popover(isPresented: $showsDetail, arrowEdge: .bottom) {
                CheckoutPopover(branch: branch, worktree: worktree, repositoryName: repositoryName, switchBranch: switchBranch, unlock: unlock) {
                    showsDetail = false
                }
            }
            // Views of their own, since one view shows one popover. Renaming
            // hangs from here when it comes from the popover about the
            // checkout or the menu bar, and from the row whose menu asked
            // for it otherwise.
            .background {
                Color.clear
                    .popover(isPresented: renameBinding(atRow: false), arrowEdge: .bottom) {
                        if let start = branch.renameStart {
                            RenameBranchPopover(branch: branch, start: start, close: branch.closeRename)
                        }
                    }
            }
            .background {
                AnchoredPopover(isPresented: renameBinding(atRow: true), place: branch.renamePlace) {
                    if let start = branch.renameStart {
                        RenameBranchPopover(branch: branch, start: start, close: branch.closeRename)
                    }
                }
            }
        }
    }

    /// Whether the popover for renaming shows here or at a row, which follows
    /// the model both ways.
    private func renameBinding(atRow: Bool) -> Binding<Bool> {
        Binding {
            branch.renameStart != nil && (branch.renamePlace != nil) == atRow
        } set: { isShown in
            if !isShown { branch.closeRename() }
        }
    }

    @ViewBuilder private var name: some View {
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
                .frame(minWidth: Self.shortestNameWidth(worktree.title), alignment: .leading)
        }
    }

    /// What the line under the name says: how far the branch is from the
    /// main branch on the remote, or for the main branch itself, its upstream
    /// and when Roga last fetched.
    static func secondLine(branch: BranchModel, worktree: Worktree, now: Date) -> (words: String, conflicts: String?) {
        if worktree.branch == nil { return ("Not on a branch", nil) }
        if worktree.head == nil { return ("No commits yet", nil) }
        return branch.mainLine(now: now)
    }

    /// The worktree's folder, then the branch's upstream and when Roga last
    /// fetched.
    private func help(now: Date) -> String {
        [CheckoutPopover.folder(of: worktree), branch.summary(now: now)].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// How narrow the branch's name can get: all of a short one, and otherwise
    /// about two letters, an ellipsis and two letters.
    private static func shortestNameWidth(_ name: String) -> Double {
        let width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width.rounded(.up)
        return min(width, 40)
    }
}

/// What a click on the branch opens, in place of the menu that had Pull, Push,
/// Fetch and New Branch, which are on the row and in the menu bar's Branch menu
/// (decision 120). It says what the row has no room for: whose worktree this
/// is, its folder and what can be done there, its lock, its upstream, and how
/// far the branch is from the main branch on the remote, with Rebase and Merge
/// while that has commits the branch doesn't. Switch Branch… and Rename
/// Branch… are at its foot, or New Branch Here… for a detached `HEAD`.
struct CheckoutPopover: View {
    let branch: BranchModel
    let worktree: Worktree
    let repositoryName: String
    let switchBranch: (() -> Void)?
    let unlock: () -> Void
    let close: () -> Void
    @State private var copied: Copied?

    static let width: CGFloat = 400
    /// How wide the column of headings is, from the longest, `Upstream`.
    private static let headingWidth: CGFloat = 64

    private enum Copied { case name, path }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                section("Folder") {
                    Text(Self.folder(of: worktree))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    buttons {
                        Button("Show in Finder", icon: .folderOpen) {
                            reveal(worktree.path)
                            close()
                        }
                        Button("Open in Terminal", icon: .terminal) {
                            openInTerminal(worktree.path)
                            close()
                        }
                        Button(copied == .path ? "Copied" : "Copy Path", icon: copied == .path ? .check : .copy) {
                            copy(worktree.path, as: .path)
                        }
                    }
                }
                if worktree.isLocked {
                    Divider()
                    section("Locked") {
                        Text(worktree.lockReason ?? "No reason given")
                        detail("Unlock this worktree before deleting it.")
                        buttons {
                            Button("Unlock") {
                                close()
                                unlock()
                            }
                        }
                    }
                }
                if worktree.branch != nil, let upstream = branch.upstreamDetail(now: context.date) {
                    Divider()
                    section("Upstream") {
                        Text(upstream.value)
                        if let more = upstream.detail { detail(more) }
                    }
                }
                if worktree.branch != nil, let main = branch.mainDetail(now: context.date), let distance = branch.mainDistance {
                    Divider()
                    section("Main") {
                        Text(main.value)
                        Text(main.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(main.conflicts ? AnyShapeStyle(Palette.action) : AnyShapeStyle(.secondary))
                            .fixedSize(horizontal: false, vertical: true)
                        if distance.behind > 0 {
                            buttons {
                                Button("Rebase onto \(distance.baseName)") {
                                    after(close, branch.rebaseOntoMain)
                                }
                                Button("Merge \(distance.baseName)") {
                                    after(close, branch.mergeMain)
                                }
                            }
                            .disabled(branch.isBusy)
                        }
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button("Switch Branch…") {
                        close()
                        switchBranch?()
                    }
                    .disabled(switchBranch == nil)
                    // Only once it has commits, since that's when there's a
                    // status to say what becomes of its upstream.
                    if worktree.branch != nil, branch.status != nil {
                        Button("Rename Branch…") {
                            after(close) { branch.startRename() }
                        }
                        .disabled(branch.isBusy)
                    }
                    if worktree.branch == nil {
                        Button("New Branch Here…") {
                            after(close) { branch.startNewBranch() }
                        }
                        .disabled(branch.isBusy)
                    }
                }
                .buttonStyle(OutlinedButtonStyle(height: 28, isOutlined: false))
                .padding(6)
            }
            .font(.system(size: 13))
            .frame(width: Self.width, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Icon.branch.image
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if worktree.branch == nil, let head = worktree.head {
                    Text(head.hex.prefix(8))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Text("Detached HEAD")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(worktree.title)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(worktree.isMain ? "The main worktree of \(repositoryName)" : "A worktree of \(repositoryName)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let copyable {
                let label = worktree.branch == nil ? "Copy Commit ID" : "Copy Branch Name"
                Button {
                    copy(copyable, as: .name)
                } label: {
                    (copied == .name ? Icon.check : Icon.copy).image
                        .font(.system(size: 13))
                }
                .buttonStyle(.icon(size: 24))
                .help(label)
                .accessibilityLabel(copied == .name ? "Copied" : label)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The branch's name, or the commit a detached `HEAD` is on.
    private var copyable: String? {
        if let name = worktree.branch { return Ref.shortName(name) }
        return worktree.head?.hex
    }

    private func section(_ heading: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(heading)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: Self.headingWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A section's buttons, which go on to another line when they don't fit
    /// on one.
    private func buttons(@ViewBuilder content: () -> some View) -> some View {
        WrappingRow(spacing: 6) {
            content()
        }
        .buttonStyle(.outlined)
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12))
        .padding(.top, 5)
    }

    private func copy(_ text: String, as what: Copied) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
        Task {
            guard (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            if copied == what { copied = nil }
        }
    }

    /// Closes the popover, then does what was asked once it has gone, since
    /// a dialog or another popover can't open while this one is closing.
    private func after(_ close: () -> Void, _ action: @escaping () -> Void) {
        close()
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            action()
        }
    }

    /// The worktree's folder, with the home folder as `~`.
    static func folder(of worktree: Worktree) -> String {
        (worktree.path as NSString).abbreviatingWithTildeInPath
    }
}

/// Fetch and New Branch, as icons at the right end of the branch's row, before
/// history's commands (decisions 45 and 95), as tall as everything else in the
/// row (decision 120). They stay where they are while the branch's name and
/// counts change. The menu bar's Branch menu has both as well.
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
            .buttonStyle(.icon(size: BranchBar.controlHeight))
            .disabled(branch.status?.remote == nil)
            .help(branch.fetchHelp(now: context.date))
            .accessibilityLabel("Fetch")
            .accessibilityValue(branch.isFetching ? "Fetching" : "")
        }
    }
}

/// Opens the popover for a new branch, which hangs from this button when it's
/// asked for here, from the menu bar, from the branch's popover for a detached
/// `HEAD`, or with Shift-Command-B. Asked for
/// from a row's menu, such as Create in history or New branch from stash… in the
/// refs panel, the same popover hangs from that row instead (decision 83), and a
/// new worktree starts from its tab or its row in the sidebar (decisions 82 and
/// 95). The button shows all of these, so that they follow the branch's model.
private struct NewBranchButton: View {
    @Bindable var branch: BranchModel
    let worktree: Worktree
    let showWorktree: (String, ObjectID?) -> Void

    var body: some View {
        let isAtRow = branch.newRefPlace != nil
        let isOpenHere = Binding {
            branch.isCreatingBranch && !isAtRow
        } set: { isShown in
            if !isShown { branch.isCreatingBranch = false }
        }
        Button {
            branch.startNewBranch()
        } label: {
            Icon.newBranch.image
        }
        .buttonStyle(IconButtonStyle(size: BranchBar.controlHeight, isOn: isOpenHere.wrappedValue))
        .opensOnPress(isOpenHere, open: branch.startNewBranch)
        .help(help)
        .accessibilityLabel("New Branch")
        .popover(isPresented: isOpenHere, arrowEdge: .bottom) {
            NewBranchPopover(branch: branch, start: start, showWorktree: showWorktree, close: closeNewBranch)
        }
        // On views of their own, because a view is only sure of showing one popover.
        .background {
            Color.clear.popover(isPresented: Binding {
                branch.newTagStart != nil && !isAtRow
            } set: { isShown in
                if !isShown { branch.newTagStart = nil }
            }, arrowEdge: .bottom) {
                if let start = branch.newTagStart {
                    NewTagPopover(branch: branch, start: start, close: closeNewTag)
                }
            }
        }
        .background {
            AnchoredPopover(isPresented: Binding {
                branch.isCreatingBranch && isAtRow
            } set: { isShown in
                if !isShown {
                    branch.isCreatingBranch = false
                    branch.newRefPlace = nil
                }
            }, place: branch.newRefPlace) {
                NewBranchPopover(branch: branch, start: start, showWorktree: showWorktree, close: closeNewBranch)
            }
        }
        .background {
            AnchoredPopover(isPresented: Binding {
                branch.newTagStart != nil && isAtRow
            } set: { isShown in
                if !isShown {
                    branch.newTagStart = nil
                    branch.newRefPlace = nil
                }
            }, place: branch.newRefPlace) {
                if let start = branch.newTagStart {
                    NewTagPopover(branch: branch, start: start, close: closeNewTag)
                }
            }
        }
    }

    /// What a new branch starts from, as in `main`.
    private var start: String? {
        NewWorktreePopover.start(of: worktree)
    }

    /// Where the new branch starts, as in `New Branch from main`.
    private var help: String {
        start.map { "New Branch from \($0)" } ?? "New Branch"
    }

    /// Cancel in the popover for a new branch, wherever it hangs.
    private func closeNewBranch() {
        branch.isCreatingBranch = false
        branch.newRefPlace = nil
    }

    /// Cancel in the popover for a new tag.
    private func closeNewTag() {
        branch.newTagStart = nil
        branch.newRefPlace = nil
    }
}

/// What clicking a count opens when a click can't run straight away, and the
/// commands in the menu bar's Branch menu. The branch's own menu had them too,
/// until its popover replaced it (decision 120).
struct BranchMenuItems: View {
    let branch: BranchModel
    let switchBranch: (() -> Void)?
    /// Whether this is the menu bar's Branch menu, which has New Worktree… after
    /// New Branch…, since the branch's own menu leaves worktrees to the sidebar
    /// (decision 82). Its rows are in title case, as macOS's own are, where the
    /// menus in the window are in sentence case.
    var isInMenuBar = false
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
                    item(isInMenuBar ? "Force Push with Lease…" : "Force push with lease…", icon: .push, action: branch.askToForcePush)
                        .disabled(status.upstream == nil || branch.isBusy)
                }
            item("Fetch", icon: .fetch, action: branch.fetch)
                .keyboardShortcut(RepositoryCommands.fetchShortcut)
                .disabled(status.remote == nil || branch.isBusy)
            Divider()
        }
        item(isInMenuBar ? "New Branch…" : "New branch…", icon: .newBranch) { branch.startNewBranch() }
            .keyboardShortcut(RepositoryCommands.newBranchShortcut)
            .disabled(branch.isBusy)
        if isInMenuBar {
            item("New Worktree…", icon: .worktree) { newWorktree?() }
                .keyboardShortcut(RepositoryCommands.newWorktreeShortcut)
                .disabled(newWorktree == nil)
        }
        item(isInMenuBar ? "Switch Branch…" : "Switch branch…", icon: nil) { switchBranch?() }
            .disabled(switchBranch == nil)
        // The menu bar's only, since the menus in the window that open from a
        // count are about pulling and pushing (decision 120).
        if isInMenuBar {
            item("Rename Branch…", icon: nil) { branch.startRename() }
                .disabled(branch.status == nil || branch.isBusy)
        }
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

/// `↓3` and `↑1`, then what git is doing or just did. A pull or a push goes in
/// steps: the house zooms in where the counts were, then the words come out
/// beside it and move what's to their right along. When git is done the words
/// change to what happened while the house keeps going, and when those words
/// have had their moment, the house zooms out and the words close up as the
/// counts come back, all at once (decision 93). A commit or a
/// discard has no house, so its words open after the counts, which stay, so that
/// `↑` can push what was just committed while `Committed 9f2c1ab` and its Undo
/// are still showing (decision 76). With the house off in Settings, a push or a
/// pull does the same (decision 112). A fetch shows nothing here, because the
/// house drops through the Fetch button instead (decisions 45 and 55).
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
        /// The action, and its house, if it has one.
        case running(BranchModel.Action, house: HouseAnimation?)
        /// The words, and the house of the action they're about, if it had one.
        case finished(String, house: HouseAnimation?)
    }

    let branch: BranchModel
    let switchBranch: (() -> Void)?
    @State private var shown = Shown()
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @AppStorage(UserDefaults.animatesHouseKey) private var animatesHouse = true

    private var activity: Activity {
        if let action = branch.action, action != .fetching { .running(action, house: house(action)) }
        else if let finished = branch.finished { .finished(finished, house: branch.finishedAction.flatMap(house)) }
        else { .idle }
    }

    /// The house for an action, unless it's off in Settings, now or when the
    /// action started (decision 112).
    private func house(_ action: BranchModel.Action) -> HouseAnimation? {
        animatesHouse && branch.playsHouse ? action.houseAnimation : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            // Before the words, so that they stay where they always are, and so
            // that Undo and `↑` aren't side by side, where a slip would push the
            // commit that was meant to be taken back.
            if shown.showsCounts {
                counts
            }
            // It takes no room without a house, and its room opens and closes
            // along with the zoom, so that the words never run into the house.
            ZStack {
                if let house = shown.house {
                    HouseAnimationView(animation: house, height: 21)
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
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .task(id: activity) { await show(activity) }
    }

    @ViewBuilder private var counts: some View {
        // A worktree that's stuck comes before anything else it could do, and
        // during a rebase it isn't on a branch to have counts.
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

    /// Their room opens a frame at a time, as the house's room closes, or for a
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
        case .finished(let words, let house):
            // The house keeps going beside what it did, so that it's still
            // there to see after a quick push, and the counts wait for it to
            // go. Words that something else announced take it away, as a
            // discard does just after a push.
            move(Motion.words) {
                shown.house = house
                shown.words = words
                shown.showsWords = true
                shown.showsCounts = house == nil
            }
        case .running(let action, let house):
            guard let house else {
                // Outside the animation, because turning what just happened into
                // these moves what's to the right past where it ends up.
                shown.words = action.title
                shown.arrival = .fade
                // The counts stay, as they do while a fetch runs, and clicking
                // one does nothing until git is done.
                move(Motion.words) {
                    shown.house = nil
                    shown.showsWords = true
                    shown.showsCounts = true
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
                Button("Resolve conflicts", action: branch.showConflicts)
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
                        .font(.system(size: 15))
                }
                Text(unfinished.title)
                    .monospacedDigit()
                    .fontWeight(unfinished.hasConflicts ? .semibold : .regular)
            }
            .accessibilityElement(children: .ignore)
            .foregroundStyle(unfinished.hasConflicts ? AnyShapeStyle(Palette.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 6)
            .frame(minHeight: BranchBar.controlHeight)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Palette.buttonHover : .clear)
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
        case .waddle, .run: self = .fade
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
/// Keeps its content no wider than `width`, while letting it be as narrow as
/// it is. A frame's `maxWidth` would stretch it to that width whenever there's
/// room, and take the room from the agent's words.
private struct WidthCap: ViewModifier {
    let width: CGFloat

    func body(content: Content) -> some View {
        CappedWidth(width: width) { content }
    }

    private struct CappedWidth: Layout {
        let width: CGFloat

        private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
            ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height)
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// Buttons in a row, which go on to the next line when they run out of room,
/// as a line of words does.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = lines[lines.count - 1].isEmpty ? size.width : used + spacing + size.width
            if needed > width, !lines[lines.count - 1].isEmpty {
                lines.append([(index, size)])
                used = size.width
            } else {
                lines[lines.count - 1].append((index, size))
                used = needed
            }
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(subviews, width: proposal.width ?? .infinity)
        let widths = lines.map { line in line.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(line.count - 1, 0)) }
        let heights = lines.map { line in line.map(\.size.height).max() ?? 0 }
        return CGSize(width: widths.max() ?? 0, height: heights.reduce(0, +) + spacing * CGFloat(max(lines.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, width: bounds.width) {
            var x = bounds.minX
            let height = line.map(\.size.height).max() ?? 0
            for (index, size) in line {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += height + spacing
        }
    }
}

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
                .font(.system(size: 15))
            Text(text)
                .monospacedDigit()
                .fontWeight(isOrange ? .semibold : .regular)
                .contentTransition(.numericText())
                .animation(.snappy, value: text)
        }
        .accessibilityElement(children: .ignore)
        .foregroundStyle(isOrange ? AnyShapeStyle(Palette.action) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 6)
        .frame(minWidth: BranchBar.controlHeight, minHeight: BranchBar.controlHeight)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Palette.buttonHover : .clear)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 && isEnabled }
    }
}

/// Starts a new branch from the worktree's branch, here or in a new worktree, and
/// shows the exact command as it's typed.
private struct NewBranchPopover: View {
    let branch: BranchModel
    /// What the branch starts from when no commit or stash was chosen: the
    /// worktree's branch, or its short hash with `HEAD` detached.
    let start: String?
    let showWorktree: (String, ObjectID?) -> Void
    let close: () -> Void
    @State private var name = ""
    @State private var inNewWorktree = false
    @State private var refusal: String?
    @State private var isCreating = false

    private var newBranch: NewBranch {
        NewBranch(name: name.trimmingCharacters(in: .whitespaces), inNewWorktree: inNewWorktree, startPoint: branch.newBranchStart?.commit)
    }

    /// A branch from a stash is made where the stash was, in this worktree,
    /// since `git stash branch` can't make a worktree (decision 81).
    private var fromStash: StashDetails? { branch.newBranchStash }

    private var subtitle: String? {
        if let fromStash { return "Starts at the original commit for \(fromStash.name) and applies its changes." }
        return (branch.newBranchStart?.label ?? start).map { "From \($0)" }
    }

    private var arguments: [String] {
        guard let fromStash else { return newBranch.arguments }
        return Stashes.branchArguments(name: newBranch.name, ref: fromStash.name)
    }

    var body: some View {
        NewRefForm(
            title: "New branch",
            subtitle: subtitle,
            subtitleLineLimit: fromStash == nil ? 1 : 2,
            name: $name,
            action: inNewWorktree ? "Create Worktree" : "Create Branch",
            commands: [arguments],
            emptyNote: "Type the branch's name",
            refusal: refusal,
            isCreating: isCreating,
            create: create,
            close: close
        ) {
            if fromStash == nil {
                NewRefSwitch(title: "Create in a new worktree", isOn: $inNewWorktree)
            }
        }
        .onChange(of: name) { refusal = nil }
        .onChange(of: inNewWorktree) { refusal = nil }
        .onAppear {
            if branch.startsInNewWorktree {
                inNewWorktree = true
                branch.startsInNewWorktree = false
            }
        }
        // Only here, because this is what tells it to start from where the worktree
        // is again, once it has gone.
        .onDisappear {
            branch.newBranchStart = nil
            branch.newBranchStash = nil
        }
    }

    private func create() {
        guard !newBranch.name.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            if let fromStash {
                refusal = await branch.create(branch: newBranch.name, fromStash: fromStash)
            } else {
                refusal = await branch.create(newBranch, showWorktree: showWorktree)
            }
            isCreating = false
        }
    }
}

/// Renames a local branch here and nowhere else (decision 120), and shows the
/// exact command as it's typed. It says what becomes of the branch's
/// upstream, which is nothing: the branch keeps tracking it, and it keeps its
/// name on the remote.
private struct RenameBranchPopover: View {
    let branch: BranchModel
    let start: BranchModel.RenameStart
    let close: () -> Void
    @State private var name: String
    @State private var refusal: String?
    @State private var isRenaming = false

    init(branch: BranchModel, start: BranchModel.RenameStart, close: @escaping () -> Void) {
        self.branch = branch
        self.start = start
        self.close = close
        _name = State(initialValue: start.name)
    }

    private var rename: BranchRename {
        BranchRename(branch: start.name, name: name.trimmingCharacters(in: .whitespaces))
    }

    var body: some View {
        NewRefForm(
            title: "Rename branch",
            subtitle: "Only the local branch is renamed.",
            name: $name,
            action: "Rename Branch",
            commands: [rename.arguments],
            emptyNote: "Type the branch's new name",
            refusal: refusal,
            isCreating: isRenaming,
            create: perform,
            close: close
        ) {
            if let note = branch.renameNote(for: start) {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(DialogColors.note)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: name) { refusal = nil }
    }

    private func perform() {
        guard !rename.name.isEmpty, !isRenaming else { return }
        isRenaming = true
        Task {
            refusal = await branch.rename(start, to: rename.name)
            isRenaming = false
            if refusal == nil { close() }
        }
    }
}

/// Puts a new tag on a commit someone chose in a menu, and shows the exact command
/// as it's typed. It can push the tag too, which starts off every time,
/// because pushing a tag can start a release.
private struct NewTagPopover: View {
    let branch: BranchModel
    let start: BranchModel.NewRefStart
    let close: () -> Void
    @State private var name = ""
    @State private var pushes = false
    @State private var refusal: String?
    @State private var isCreating = false

    private var newTag: NewTag {
        NewTag(name: name.trimmingCharacters(in: .whitespaces), commit: start.commit)
    }

    /// Where the tag goes once it's made, if it's to be pushed.
    private var pushRemote: String? {
        pushes ? branch.tagRemote : nil
    }

    var body: some View {
        NewRefForm(
            title: "New tag",
            subtitle: "On \(start.label)",
            name: $name,
            action: "Create Tag",
            commands: [newTag.arguments] + (pushRemote.map { [Push.tag(newTag.name, remote: $0).arguments] } ?? []),
            emptyNote: "Type the tag's name",
            refusal: refusal,
            isCreating: isCreating,
            create: create,
            close: close
        ) {
            if let remote = branch.tagRemote {
                NewRefSwitch(title: "Push to \(remote)", isOn: $pushes)
            }
        }
        .onChange(of: name) { refusal = nil }
    }

    private func create() {
        guard !newTag.name.isEmpty, !isCreating else { return }
        isCreating = true
        Task {
            refusal = await branch.create(newTag, pushingTo: pushRemote)
            isCreating = false
        }
    }
}
