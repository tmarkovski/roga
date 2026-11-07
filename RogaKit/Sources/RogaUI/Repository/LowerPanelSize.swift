import IconUI
import SwiftUI

/// How much of the middle of the window the panels under history take. It's one
/// setting for each window, like whether the refs panel shows, so it stays as it
/// is from one worktree to the next.
enum LowerPanelSize: String {
    /// The height someone dragged them to, under history.
    case regular
    /// All of the middle, over history and where the refs panel goes.
    case maximized
    /// Only their headers, which leaves history the rest.
    case minimized

    /// What Maximize does: it covers history, or puts back panels that were
    /// minimized. Pressed again, it puts them back.
    var maximizeToggled: LowerPanelSize { self == .maximized ? .regular : .maximized }

    /// What Minimize does, which is the same the other way.
    var minimizeToggled: LowerPanelSize { self == .minimized ? .regular : .minimized }

    /// One step taller, for the menu's Control-Command-Up Arrow: from minimized
    /// back to regular, and from regular to maximized.
    var taller: LowerPanelSize? {
        switch self {
        case .minimized: .regular
        case .regular: .maximized
        case .maximized: nil
        }
    }

    /// One step shorter, for Control-Command-Down Arrow.
    var shorter: LowerPanelSize? {
        switch self {
        case .maximized: .regular
        case .regular: .minimized
        case .minimized: nil
        }
    }

    /// The menu's title for going one step taller.
    var tallerTitle: String { self == .minimized ? "Restore Panels" : "Maximize Panels" }

    /// The menu's title for going one step shorter.
    var shorterTitle: String { self == .maximized ? "Restore Panels" : "Minimize Panels" }

    static let tallerShortcut = KeyboardShortcut(.upArrow, modifiers: [.control, .command])
    static let shorterShortcut = KeyboardShortcut(.downArrow, modifiers: [.control, .command])

    /// The shortcut that goes from this size to another in one step, if one does,
    /// for a button's tooltip. Going between maximized and minimized takes two.
    func shortcut(to target: LowerPanelSize) -> KeyboardShortcut? {
        if taller == target { return Self.tallerShortcut }
        if shorter == target { return Self.shorterShortcut }
        return nil
    }
}

/// How tall history and the panels under it are, in a split of a given height.
struct PanelSplitLayout: Equatable {
    /// The panel at the top, which is history. It's 0 while the lower one covers it.
    var upper: Double
    var lower: Double

    /// The shortest each panel gets while both show.
    static let minimumHeight = 100.0
    /// The height of a panel's header, which is all a minimized panel shows.
    static let headerHeight = 40.0
}

extension PanelSplitLayout {
    init(height: Double, lowerHeight: Double, upperHeightUntilDragged: Double, size: LowerPanelSize) {
        switch size {
        case .maximized:
            upper = 0
            lower = height
        case .minimized:
            lower = min(Self.headerHeight, height)
            upper = max(0, height - lower - 1)
        case .regular:
            lower = Self.regularHeight(lowerHeight > 0 ? lowerHeight : height - upperHeightUntilDragged - 1, in: height)
            upper = max(0, height - lower - 1)
        }
    }

    /// The lower panel's height, kept between the shortest it can be and the
    /// tallest that leaves the upper one its shortest.
    static func regularHeight(_ wanted: Double, in height: Double) -> Double {
        let tallest = max(minimumHeight, height - minimumHeight - 1)
        return min(max(wanted, minimumHeight), tallest)
    }

    /// Where dragging the line leaves the lower panel, from how tall it wants to
    /// be. Below halfway between its header and its shortest, it folds down to its
    /// header, and the height it had stays for when it comes back. Dragging the
    /// line of a minimized panel up brings it back the same way.
    static func dragged(to wanted: Double, in height: Double) -> (size: LowerPanelSize, height: Double?) {
        if wanted < (headerHeight + minimumHeight) / 2 { return (.minimized, nil) }
        return (.regular, regularHeight(wanted, in: height))
    }
}

/// The buttons at the right of the diff panel's header that maximize and
/// minimize the panels under history, and put them back. Each keeps its place,
/// so pressing one twice gets back to where it started.
struct LowerPanelSizeButtons: View {
    @Binding var size: LowerPanelSize

    var body: some View {
        button(size == .minimized ? "Restore Panels" : "Minimize Panels", icon: size == .minimized ? .unminimize : .minimize, to: size.minimizeToggled)
        button(size == .maximized ? "Restore Panels" : "Maximize Panels", icon: size == .maximized ? .unmaximize : .maximize, to: size.maximizeToggled)
    }

    private func button(_ title: String, icon: Icon, to target: LowerPanelSize) -> some View {
        Button(title, icon: icon) { size = target }
            .labelStyle(.iconOnly)
            .buttonStyle(.icon)
            .help(size.shortcut(to: target).map { "\(title) (\($0.symbols))" } ?? title)
    }
}

extension FocusedValues {
    /// How much room the focused window gives the panels under history, for the
    /// View menu. It's nil while the window shows no history.
    @Entry var lowerPanelSize: Binding<LowerPanelSize>?
}
