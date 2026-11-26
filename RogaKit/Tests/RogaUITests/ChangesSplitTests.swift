import Testing
@testable import RogaUI

/// How the panel for uncommitted changes divides its height between the files
/// and the commit box.
@Suite
struct ChangesSplitTests {
    @Test func theBoxTakesAFifth() {
        #expect(ChangesSplit.box(in: 800, needs: 146) == 160)
    }

    @Test func theBoxTakesWhatItNeedsWhenAFifthIsTooShort() {
        #expect(ChangesSplit.box(in: 500, needs: 146) == 146)
    }

    @Test func theBoxIsNeverTallerThanThePanel() {
        #expect(ChangesSplit.box(in: 60, needs: 146) == 60)
    }
}
