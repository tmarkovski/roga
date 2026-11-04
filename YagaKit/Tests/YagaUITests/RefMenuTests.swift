import AppKit
import MenuUI
import Testing

/// The menu for right-clicking a ref: how much room its rows get, and that its
/// items keep the titles and kinds that macOS reads, such as for typing to select.
@Suite(.timeLimit(.minutes(1)))
struct RefMenuTests {
    private func heights(_ menu: NSMenu) -> [CGFloat?] {
        menu.items.map { item in item.view.map(\.frame.height) }
    }

    private func widths(_ menu: NSMenu) -> Set<CGFloat> {
        Set(menu.items.compactMap { item in item.view.map(\.frame.width) })
    }

    @Test func aHeaderIsShorterThanTheCommandsUnderIt() {
        let menu = RefMenu.make([.header("main"), .command("Copy Name") {}, .divider, .command("Delete Branch") {}])
        #expect(heights(menu) == [24, 28, nil, 28])
    }

    @Test func itemsKeepTheirTitlesAndKinds() {
        let menu = RefMenu.make([.header("main"), .command("Copy Name") {}, .divider])
        #expect(menu.items.map(\.title) == ["main", "Copy Name", ""])
        #expect(menu.items.map(\.isSectionHeader) == [true, false, false])
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, true])
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
        menu.performActionForItem(at: 1)
        #expect(runs == 1)
    }

    @Test func aDisabledCommandSaysSo() {
        let menu = RefMenu.make([.command("Delete Branch", isEnabled: false) {}, .command("Copy Name") {}])
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.isEnabled) == [false, true])
    }
}
