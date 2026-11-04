import AppKit
import SwiftUI

extension Icon {
    /// The icon as a symbol, which takes its size, weight and color from the font
    /// and style around it, as an SF Symbol does. It's decorative, because the text
    /// beside an icon says what it means, and a file's name wouldn't help VoiceOver.
    public var image: Image {
        Image(decorative: rawValue, bundle: .module)
    }

    /// The same symbol for drawing with AppKit. Give it a size, a weight and a color
    /// with `withSymbolConfiguration(_:)`.
    public var nsImage: NSImage? {
        NSImage(symbolName: rawValue, bundle: .module, variableValue: 1)
    }
}

// What each thing in yaga looks like, so that it looks the same everywhere. Use
// these rather than an icon's own name, and change one here to change it everywhere.
extension Icon {
    // Branches and commits. Fetch and tag are called that already.
    public static let branch = gitBranch
    public static let newBranch = gitBranchPlus
    public static let deleteBranch = gitBranchMinus
    public static let commit = gitCommitHorizontal
    public static let graph = gitGraph
    public static let compare = gitCompare
    public static let merge = gitMerge
    public static let conflict = gitMergeConflict
    public static let squash = combine
    public static let cherryPick = cherry
    public static let revert = undo2
    public static let reset = listRestart
    public static let reorder = gripVertical

    // The arrow lands on the branch's node for a pull and leaves it for a push
    // (decision 19). Fetch has its own icon, with a hollow node.
    public static let pull = arrowDownToDot
    public static let push = arrowUpFromDot

    // Where commits live.
    public static let repository = folderGit
    public static let worktree = folderGit2
    public static let remote = cloud
    public static let clone = bookCopy
    public static let fileHistory = fileClock

    // Stashes.
    public static let stash = archive
    public static let createStash = archiveArrowDown
    public static let applyStash = archiveArrowUp
    public static let dropStash = archiveX

    // What's changed in a file.
    public static let added = filePlus
    public static let modified = filePen
    public static let deleted = fileMinus
    public static let stage = squarePlus
    public static let unstage = squareMinus

    // Commands and states that aren't only about git.
    public static let warning = triangleAlert
    public static let filter = listFilter
    public static let sort = arrowUpDown
    public static let newWindow = appWindow
    public static let slow = turtle
    public static let agent = bot
    public static let organization = buildingComplex

    /// The chevron beside something that folds, drawn pointing down, which is how it
    /// looks while what it folds is showing.
    public static let disclosure = chevronDown

    /// The chevron on a control that opens a menu.
    public static let dropdown = chevronDown
}

extension Label where Title == Text, Icon == Image {
    /// A label with one of yaga's icons, which reads like SwiftUI's own for an SF Symbol.
    public init(_ title: some StringProtocol, icon: IconUI.Icon) {
        self.init {
            Text(title)
        } icon: {
            icon.image
        }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    /// A button with one of yaga's icons, which reads like SwiftUI's own for an SF Symbol.
    public init(_ title: some StringProtocol, icon: Icon, role: ButtonRole? = nil, action: @escaping @MainActor () -> Void) {
        self.init(role: role, action: action) {
            SwiftUI.Label(title, icon: icon)
        }
    }
}
