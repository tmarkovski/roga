import AppKit
@testable import MenuUI
import Testing

/// The menu for right-clicking a ref: how much room its rows get, and that its
/// items keep the titles and kinds that macOS reads, such as for typing to select.
@Suite(.timeLimit(.minutes(1)))
struct RefMenuTests {
    private func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items
    }

    private func heights(_ menu: NSMenu) -> [CGFloat?] {
        rows(menu).map { item in item.view.map(\.frame.height) }
    }

    private func widths(_ menu: NSMenu) -> Set<CGFloat> {
        Set(rows(menu).compactMap { item in item.view.map(\.frame.width) })
    }

    /// Chooses a row the way a click would. `performActionForItem(at:)` sends the
    /// action through `NSApp`, which is nil until something in the process asks for
    /// `NSApplication.shared`, and then it does nothing. A test run that has already
    /// made a window has the application; one that runs these alone doesn't.
    private func choose(at index: Int, in menu: NSMenu) {
        _ = NSApplication.shared
        menu.performActionForItem(at: index)
    }

    @Test func aRowThatSaysWhatsChosenMakesRoomForItAndVoiceOverHearsIt() throws {
        let plain = RefMenu.make([.submenu("Sort by", entries: [.option("Name", isChecked: true) {}])])
        let chosen = RefMenu.make([.submenu("Sort by", value: "Uncommitted changes", entries: [.option("Name", isChecked: true) {}])])
        #expect(chosen.items[0].title == "Sort by, Uncommitted changes")
        #expect(try #require(chosen.items[0].view).frame.width > (try #require(plain.items[0].view)).frame.width)
    }

    @Test func aBranchNameTakesRoomForItsIconAndIsReadWithoutIt() throws {
        let title: RefMenu.Title = "Merge \(branch: "feature") into \(branch: "main")…"
        #expect(title.plain == "Merge feature into main…")
        let withIcons = RefMenu.make([.command(title) {}])
        let withoutIcons = RefMenu.make([.command(RefMenu.Title(title.plain)) {}])
        #expect(withIcons.items[0].title == "Merge feature into main…")
        #expect(try #require(withIcons.items[0].view).frame.width > (try #require(withoutIcons.items[0].view)).frame.width)
    }

    @Test func macOSAddsNothingOfItsOwnToAMenu() throws {
        let menu = RefMenu.make([.submenu("Create", entries: [.command("Branch Here…") {}])])
        let inner = try #require(menu.items[0].submenu)
        for level in [menu, inner] {
            #expect(!level.allowsContextMenuPlugIns)
            #expect(!level.automaticallyInsertsWritingToolsItems)
        }
    }

    @Test func aSubmenuHoldsItsRowsAndLeavesRoomForItsArrow() throws {
        var runs = 0
        let menu = RefMenu.make([
            .command("Revert…") {},
            .submenu("Create", entries: [.command("Branch Here…") { runs += 1 }, .command("Tag Here…") {}]),
        ])
        let item = menu.items[1]
        let inner = try #require(item.submenu)
        #expect(item.title == "Create")
        #expect(inner.items.map(\.title) == ["Branch Here…", "Tag Here…"])
        inner.performActionForItem(at: 0)
        #expect(runs == 1)
    }

    @Test func aSubmenuCanBeDisabled() {
        let menu = RefMenu.make([.submenu("Create", isEnabled: false, entries: [.command("Branch Here…") {}])])
        #expect(!menu.items[0].isEnabled)
    }

    @Test func returnLeavesARowWithASubmenuToOpen() throws {
        let menu = RefMenu.make([.submenu("Create", entries: [.command("Branch Here…") {}])])
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))
        #expect(RefMenu.itemToChoose(after: event, highlighted: menu.items[0]) == nil)
    }

    @Test func aHeaderIsShorterThanTheCommandsUnderIt() {
        let menu = RefMenu.make([.header("main"), .command("Copy Name") {}, .divider, .command("Delete Branch") {}])
        #expect(heights(menu) == [24, 28, nil, 28])
    }

    @Test func itemsKeepTheirTitlesAndKinds() {
        let menu = RefMenu.make([.header("main"), .command("Copy Name") {}, .divider])
        #expect(rows(menu).map(\.title) == ["main", "Copy Name", ""])
        #expect(rows(menu).map(\.isSectionHeader) == [true, false, false])
        #expect(rows(menu).map(\.isSeparatorItem) == [false, false, true])
    }

    @Test func itLeavesOutTheColumnForCheckmarks() {
        #expect(!RefMenu.make([.command("Copy Name") {}]).showsStateColumn)
    }

    private func textWidth(_ text: String) -> Double {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    }

    @Test func aMenuIsAsWideAsItsRowsNeed() throws {
        let menu = RefMenu.make([.command("Open in New Window") {}, .command("Show in Finder") {}])
        let width = try #require(widths(menu).first)
        #expect(widths(menu).count == 1)
        #expect(Double(width) == (16 + textWidth("Open in New Window")).rounded(.up) + 16)
    }

    @Test func aMenuOfAWordOrTwoIsntASliver() {
        #expect(widths(RefMenu.make([.command("Revert…") {}, .command("Delete…") {}])) == [120])
        #expect(widths(RefMenu.make([.header("v1"), .command("Copy Name") {}])) == [120])
    }

    @Test func aLongNameWidensEveryRowUpToALimit() throws {
        let medium = RefMenu.make([.header(RefMenu.Title(String(repeating: "m", count: 30))), .command("Copy Name") {}])
        let width = try #require(widths(medium).first)
        #expect(widths(medium).count == 1)
        #expect(width > 120 && width < 480)

        let long = RefMenu.make([.header(RefMenu.Title(String(repeating: "m", count: 200))), .command("Copy Name") {}])
        #expect(widths(long) == [480])
    }

    @Test func choosingACommandRunsItsAction() {
        var runs = 0
        let menu = RefMenu.make([.header("main"), .command("Copy Name") { runs += 1 }])
        choose(at: 1, in: menu)
        #expect(runs == 1)
    }

    @Test func aDisabledCommandSaysSo() {
        let menu = RefMenu.make([.command("Delete Branch", isEnabled: false) {}, .command("Copy Name") {}])
        #expect(!menu.autoenablesItems)
        #expect(rows(menu).map(\.isEnabled) == [false, true])
    }

    // MARK: Choices

    private func choice(_ title: String, details: [RefMenu.Detail] = [], isCurrent: Bool = false, isEnabled: Bool = true, action: @escaping () -> Void = {}) -> RefMenu.Entry {
        .choice(RefMenu.Choice(title: title, details: details, isCurrent: isCurrent, isEnabled: isEnabled, action: action))
    }

    @Test func aChoiceTakesTwoLines() {
        let menu = RefMenu.make([choice("main"), choice("agent/fix-login"), .divider, .command("Show in Finder") {}])
        #expect(heights(menu) == [44, 44, nil, 28])
    }

    @Test func aChoiceKeepsItsTitleForTypingToSelectAndSaysWhetherItsCurrent() {
        let menu = RefMenu.make([choice("main", isCurrent: true), choice("agent/fix-login")])
        #expect(rows(menu).map(\.title) == ["main", "agent/fix-login"])
        #expect(rows(menu).map(\.state) == [.on, .off])
    }

    @Test func choosingAChoiceRunsItsAction() {
        var chosen: [String] = []
        let menu = RefMenu.make([choice("main") { chosen.append("main") }, choice("agent/fix-login") { chosen.append("agent/fix-login") }])
        choose(at: 1, in: menu)
        #expect(chosen == ["agent/fix-login"])
    }

    @Test func anOptionSaysWhetherItsChosenAndRunsItsAction() {
        var chosen: [String] = []
        let menu = RefMenu.make([
            .header("Sort By"),
            .option("Name", isChecked: true) { chosen.append("Name") },
            .option("Uncommitted Changes", isChecked: false) { chosen.append("Uncommitted Changes") },
        ])
        #expect(rows(menu).map(\.title) == ["Sort By", "Name", "Uncommitted Changes"])
        #expect(rows(menu).map(\.state) == [.off, .on, .off])
        #expect(heights(menu) == [24, 28, 28])
        choose(at: 2, in: menu)
        #expect(chosen == ["Uncommitted Changes"])
    }

    @Test func anOptionLeavesRoomForItsCheckmark() throws {
        let options = RefMenu.make([.option("Name", isChecked: true) {}, .option("None", isChecked: false) {}])
        #expect(widths(options) == [120])
        let command = try #require(widths(RefMenu.make([.command("Uncommitted Changes") {}])).first)
        let option = try #require(widths(RefMenu.make([.option("Uncommitted Changes", isChecked: true) {}])).first)
        #expect(option == command + 30)
        // A long option still leaves room for its checkmark after it.
        let long = RefMenu.make([.option(RefMenu.Title(String(repeating: "Uncommitted Changes ", count: 8)), isChecked: true) {}])
        #expect(widths(long) == [480])
    }

    @Test func aChoiceIsAsWideAsItsSecondLineUpToTheLimit() throws {
        let short = RefMenu.make([choice("main")])
        #expect(widths(short) == [120])
        let folder = "~/" + String(repeating: "m", count: 24)
        let medium = RefMenu.make([choice("main", details: [RefMenu.Detail(folder)])])
        let width = try #require(widths(medium).first)
        #expect(width > 120 && width < 480)
        let long = RefMenu.make([choice("main", details: [RefMenu.Detail(String(repeating: "m", count: 200))])])
        #expect(widths(long) == [480])
    }

    @Test func aChoicesSecondLineReadsAsOnePieceOfText() {
        let choice = RefMenu.Choice(title: "agent/add-tests", details: [RefMenu.Detail("Rebasing main · 2 conflicts", color: .red), RefMenu.Detail("~/agents/add-tests")]) {}
        #expect(choice.detailText == "Rebasing main · 2 conflicts · ~/agents/add-tests")
        #expect(choice.details.allSatisfy { !$0.canBeCutShort })
    }

    // MARK: Shortcuts

    private let showInFinder = RefMenu.Shortcut("r", modifiers: [.option, .command])

    @Test func aShortcutReadsTheWayMacOSShowsIt() {
        #expect(showInFinder.modifierSymbols + showInFinder.keySymbol == "⌥⌘R")
        let newWorktree = RefMenu.Shortcut("b", modifiers: [.command, .shift, .option])
        #expect(newWorktree.modifierSymbols + newWorktree.keySymbol == "⌥⇧⌘B")
        let terminal = RefMenu.Shortcut("`", modifiers: .control)
        #expect(terminal.modifierSymbols + terminal.keySymbol == "⌃`")
        #expect(RefMenu.Shortcut("1").modifierSymbols + RefMenu.Shortcut("1").keySymbol == "⌘1")
        #expect(RefMenu.Shortcut("\u{8}").keySymbol == "⌫")
        #expect(RefMenu.Shortcut("\r").keySymbol == "↩")
    }

    @Test func aShortcutTakesRoomAtTheRightOfItsRow() throws {
        let plain = try #require(widths(RefMenu.make([.command("Show in Finder") {}])).first)
        let withShortcut = try #require(widths(RefMenu.make([.command("Show in Finder", shortcut: showInFinder) {}])).first)
        #expect(withShortcut > plain + 24 + textWidth("⌥⌘R") - 1)
    }

    @Test func anItemKeepsItsShortcutForVoiceOverAndTheKeyboard() throws {
        var runs = 0
        let menu = RefMenu.make([
            .command("Show in Finder") {},
            .command("Copy Name") {},
            .choice(RefMenu.Choice(title: "main", shortcut: RefMenu.Shortcut("1")) { runs += 1 }),
        ])
        #expect(rows(menu).map(\.keyEquivalent) == ["", "", "1"])
        #expect(rows(menu)[2].keyEquivalentModifierMask == .command)
        // Pressing it while the menu is open chooses the row.
        _ = NSApplication.shared
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18
        ))
        #expect(menu.performKeyEquivalent(with: event))
        #expect(runs == 1)
    }

    @Test func aChoiceWithoutAShortcutKeepsRoomForTheColumnSoTheCountsLineUp() throws {
        let count = RefMenu.Count("12", color: .orange)
        let without = RefMenu.Choice(title: "agent/fix-login", count: count) {}
        let with = RefMenu.Choice(title: "agent/fix-login", count: count, shortcut: RefMenu.Shortcut("9")) {}
        let alone = try #require(widths(RefMenu.make([.choice(without)])).first)
        let beside = try #require(widths(RefMenu.make([.choice(without), .choice(with)])).first)
        #expect(beside > alone + 24 + textWidth("⌘9") - 1)
        #expect(RefMenu.textRoom(inRow: 300, count: count, shortcutRoom: 40) == RefMenu.textRoom(inRow: 300, count: count) - 40)
    }

    // MARK: Cutting the second line short

    /// With parts as wide as they say, and separators 10 wide.
    private func widths(_ parts: [(Double, Bool)], in room: Double) -> [Double]? {
        RefMenu.detailWidths(of: parts.map { (width: $0.0, canBeCutShort: $0.1) }, separator: 10, in: room)
    }

    @Test func aLineThatFitsIsDrawnAsAlways() {
        // The folder gets what's left, even when a part before it could be cut.
        #expect(widths([(200, true), (30, false), (99, false)], in: 391) == nil)
        // With nothing that can be cut, a line too long is drawn as always too.
        #expect(widths([(400, false), (30, false), (99, false)], in: 391) == nil)
        #expect(widths([(400, true)], in: 391) == nil)
        #expect(widths([], in: 391) == nil)
    }

    @Test func onlyThePartsThatCanBeCutGetShorter() {
        // What can't be cut takes 265 with its separators, the folder keeps 80,
        // and the words get the 46 that's left.
        #expect(widths([(700, true), (56, false), (152, false), (17, false), (300, false)], in: 391) == [46, 56, 152, 17, 80])
        // Words that fit, but leave the folder less than its room, are cut too.
        #expect(widths([(250, true), (30, false), (99, false)], in: 360) == [230, 30, 80])
        // A short folder keeps only what it needs.
        #expect(widths([(400, true), (40, false)], in: 300) == [250, 40])
        // Several parts that can be cut share what's left by their widths.
        #expect(widths([(300, true), (100, true), (99, false)], in: 300) == [150, 50, 80])
    }

    @Test func whatCantBeCutComesBeforeTheFolder() {
        // The words keep a few characters, and the folder gets what's left.
        #expect(widths([(300, true), (330, false), (99, false)], in: 391) == [24, 330, 17])
        // When even that doesn't fit, the line is drawn as always.
        #expect(widths([(300, true), (350, false), (99, false)], in: 391) == nil)
        #expect(widths([(300, true), (400, false), (99, false)], in: 391) == nil)
    }

    // MARK: Return

    private func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code
        ))
    }

    @Test func returnChoosesTheHighlightedRow() throws {
        let menu = RefMenu.make([choice("main"), choice("agent/fix-login"), .divider, .command("Show in Finder") {}])
        #expect(RefMenu.itemToChoose(after: try key(36), highlighted: menu.items[1]) === menu.items[1])
        // Enter on the number pad does the same.
        #expect(RefMenu.itemToChoose(after: try key(76), highlighted: menu.items[1]) === menu.items[1])
        #expect(RefMenu.itemToChoose(after: try key(36), highlighted: menu.items[3]) === menu.items[3])
    }

    @Test func otherKeysOrNothingHighlightedChooseNothing() throws {
        let menu = RefMenu.make([choice("main"), choice("agent/fix-login")])
        #expect(RefMenu.itemToChoose(after: try key(36), highlighted: nil) == nil)
        // Escape, and the down arrow.
        #expect(RefMenu.itemToChoose(after: try key(53), highlighted: menu.items[0]) == nil)
        #expect(RefMenu.itemToChoose(after: try key(125), highlighted: menu.items[0]) == nil)
    }

    /// The menu hands the keys to the highlighted row's view only when it takes
    /// them, and that's how a row hears Return.
    @Test func everyRowCanTakeTheKeyboard() {
        let menu = RefMenu.make([.header("main"), choice("agent/fix-login", isCurrent: true), .divider, .command("Delete…", isDestructive: true) {}])
        #expect(menu.items.map { $0.view?.acceptsFirstResponder } == [true, true, nil, true])
    }

    @Test func returnDoesntChooseADisabledRowOrAHeader() throws {
        let menu = RefMenu.make([.header("main"), choice("agent/old-spike", isEnabled: false)])
        for item in menu.items {
            #expect(RefMenu.itemToChoose(after: try key(36), highlighted: item) == nil)
        }
    }
}
