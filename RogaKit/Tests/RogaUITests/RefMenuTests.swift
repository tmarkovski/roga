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

    @Test func aMenuHasARoomyWidthEvenWithShortTitles() {
        #expect(widths(RefMenu.make([.header("main"), .command("Copy Name") {}])) == [264])
    }

    @Test func aLongNameWidensEveryRowUpToALimit() throws {
        let medium = RefMenu.make([.header(String(repeating: "m", count: 30)), .command("Copy Name") {}])
        let width = try #require(widths(medium).first)
        #expect(widths(medium).count == 1)
        #expect(width > 264 && width < 480)

        let long = RefMenu.make([.header(String(repeating: "m", count: 200)), .command("Copy Name") {}])
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

    @Test func aChoiceIsAsWideAsItsSecondLineUpToTheLimit() throws {
        let short = RefMenu.make([choice("main")])
        #expect(widths(short) == [264])
        let folder = "~/" + String(repeating: "m", count: 24)
        let medium = RefMenu.make([choice("main", details: [RefMenu.Detail(folder)])])
        let width = try #require(widths(medium).first)
        #expect(width > 264 && width < 480)
        let long = RefMenu.make([choice("main", details: [RefMenu.Detail(String(repeating: "m", count: 200))])])
        #expect(widths(long) == [480])
    }

    @Test func aChoicesSecondLineReadsAsOnePieceOfText() {
        let choice = RefMenu.Choice(title: "agent/add-tests", details: [RefMenu.Detail("Rebasing main · 2 conflicts", color: .red), RefMenu.Detail("~/agents/add-tests")]) {}
        #expect(choice.detailText == "Rebasing main · 2 conflicts · ~/agents/add-tests")
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
