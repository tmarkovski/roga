import AppKit
import Testing
@testable import CommitGraph
@testable import HistoryUI

/// The row for the commit `HEAD` is on, which has a ring around its dot and bold
/// text, so that it's clear where the worktree is.
@Suite(.timeLimit(.minutes(1)))
struct CurrentCommitRowTests {
    typealias Badge = CommitRowContent.Badge

    static let currentBranch = Badge(title: "main", kind: .currentBranch, refName: "refs/heads/main")
    static let otherBranch = Badge(title: "main", kind: .branch, refName: "refs/heads/main")

    static let straightDown = LaneLayout.Row(column: 0, lines: [
        LaneLayout.Line(top: .column(0), bottom: .commit),
        LaneLayout.Line(top: .commit, bottom: .column(0)),
    ])

    /// Draws a row's graph at its size in the app, and says whether anything was
    /// drawn at a point, in points from the graph's top left corner.
    final class Drawing {
        static let scale = 2
        static let height = 28
        static let origin: CGFloat = 8
        let image: NSBitmapImageRep

        init(_ row: LaneLayout.Row, isHollow: Bool = false, isCurrent: Bool) throws {
            // Wide enough for the most columns a graph shows, and past them.
            let width = 160
            image = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width * Self.scale, pixelsHigh: Self.height * Self.scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            image.size = NSSize(width: width, height: Self.height)
            let context = try #require(NSGraphicsContext(bitmapImageRep: image))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // The row's view is flipped, like the context the renderer expects.
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: CGFloat(Self.height))
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
            LaneRenderer.draw(row, at: Self.origin, height: CGFloat(Self.height), isHollow: isHollow, isCurrent: isCurrent)
            NSGraphicsContext.restoreGraphicsState()
        }

        /// What was drawn at a point, in the color space the drawing used.
        func color(x: CGFloat, y: CGFloat) -> NSColor? {
            image.colorAt(x: Int(x * CGFloat(Self.scale)), y: Int(y * CGFloat(Self.scale)))
        }

        func isDrawn(x: CGFloat, y: CGFloat) -> Bool {
            let color = image.colorAt(x: Int(x * CGFloat(Self.scale)), y: Int(y * CGFloat(Self.scale)))
            return (color?.alphaComponent ?? 0) > 0.5
        }
    }

    /// The middle of the first column's dot, across the view.
    static let dotX = Drawing.origin + LaneRenderer.spacing / 2
    static let middle = CGFloat(Drawing.height) / 2

    // MARK: Which row

    @Test func theCurrentBranchAndADetachedHeadAreCurrent() {
        #expect(CommitRowContent(shortID: "a", badges: [Self.currentBranch]).isCurrent)
        #expect(CommitRowContent(shortID: "a", badges: [Badge(title: "HEAD", kind: .detachedHead)]).isCurrent)
    }

    @Test func otherRefsArentCurrent() {
        let others = [
            Self.otherBranch,
            Badge(title: "origin/main", kind: .remoteBranch, refName: "refs/remotes/origin/main"),
            Badge(title: "v1.0", kind: .tag, refName: "refs/tags/v1.0"),
        ]
        #expect(!CommitRowContent(shortID: "a", badges: others).isCurrent)
        #expect(!CommitRowContent(shortID: "a").isCurrent)
    }

    @Test func oneBadgeAmongOthersMakesTheRowCurrent() {
        #expect(CommitRowContent(shortID: "a", badges: [Self.otherBranch, Self.currentBranch]).isCurrent)
    }

    @Test func theRowForUncommittedChangesIsntCurrent() {
        #expect(!CommitRowContent(shortID: "", isWorkingTree: true).isCurrent)
    }

    @Test func voiceOverSaysWhichBranchIsCurrent() {
        let row = CommitRowContent(shortID: "abc", badges: [Self.currentBranch, Self.otherBranch], subject: "A subject")
        #expect(row.spokenText == "A subject, main, current branch, main, abc")
    }

    // MARK: The bold text

    @Test func theSubjectIsBoldOnlyOnTheCurrentRow() throws {
        let current = try #require(CommitCellView.Style.currentSubject.attributes[.font] as? NSFont)
        let other = try #require(CommitCellView.Style.subject.attributes[.font] as? NSFont)
        #expect(current.pointSize == other.pointSize)
        #expect(current.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(!other.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test func aBoldBadgeIsWideEnoughForItsTitle() throws {
        let size = NSSize(width: 1200, height: 28)
        let bold = try #require(CommitRowLayout(content: CommitRowContent(shortID: "a", badges: [Self.currentBranch]), size: size).badges.first)
        let regular = try #require(CommitRowLayout(content: CommitRowContent(shortID: "a", badges: [Self.otherBranch]), size: size).badges.first)
        // The current branch's also has room for its checkmark.
        #expect(bold.width > regular.width)
        let style = CommitCellView.BadgeLook.of(.currentBranch).style
        let title = (Self.currentBranch.title as NSString).size(withAttributes: style.attributes).width
        #expect(bold.width >= title + CommitRowLayout.badgePadding * 2)
    }

    // MARK: The ring

    @Test func aRingGoesAroundTheCurrentDot() throws {
        let plain = try Drawing(Self.straightDown, isCurrent: false)
        let current = try Drawing(Self.straightDown, isCurrent: true)
        // To the right of the dot, where no line runs.
        #expect(!plain.isDrawn(x: Self.dotX + LaneRenderer.ringRadius, y: Self.middle))
        #expect(current.isDrawn(x: Self.dotX + LaneRenderer.ringRadius, y: Self.middle))
        // The dot stays filled.
        #expect(plain.isDrawn(x: Self.dotX, y: Self.middle))
        #expect(current.isDrawn(x: Self.dotX, y: Self.middle))
    }

    @Test func linesStopAtTheRing() throws {
        let plain = try Drawing(Self.straightDown, isCurrent: false)
        let current = try Drawing(Self.straightDown, isCurrent: true)
        // In the gap between the dot and the ring's inner edge, above and below
        // the dot.
        let gap = (4 + LaneRenderer.ringRadius - 0.75) / 2
        #expect(plain.isDrawn(x: Self.dotX, y: Self.middle - gap))
        #expect(plain.isDrawn(x: Self.dotX, y: Self.middle + gap))
        #expect(!current.isDrawn(x: Self.dotX, y: Self.middle - gap))
        #expect(!current.isDrawn(x: Self.dotX, y: Self.middle + gap))
        // Outside the ring, the lines go on as before.
        #expect(current.isDrawn(x: Self.dotX, y: 2))
        #expect(current.isDrawn(x: Self.dotX, y: CGFloat(Drawing.height) - 2))
    }

    @Test func theRingIsntCutOffAtTheEdgesOfTheGraph() throws {
        let current = try Drawing(Self.straightDown, isCurrent: true)
        // A column is narrower than the ring with its line's width, so the outer
        // part of the line is outside the graph.
        let outer = LaneRenderer.ringRadius + 0.25
        #expect(Self.dotX - outer < Drawing.origin)
        #expect(Self.dotX + outer > Drawing.origin + LaneRenderer.width(columns: 1))
        #expect(current.isDrawn(x: Self.dotX - outer, y: Self.middle))
        #expect(current.isDrawn(x: Self.dotX + outer, y: Self.middle))
    }

    /// The middle of a column, across the view.
    static func x(ofColumn column: Int) -> CGFloat {
        Drawing.origin + LaneRenderer.spacing * (CGFloat(column) + 0.5)
    }

    static func straightLine(inColumn column: Int) -> LaneLayout.Line {
        LaneLayout.Line(top: .column(column), bottom: .column(column))
    }

    @Test func aRowDrawsAllOfItsOwnLines() throws {
        let last = LaneRenderer.maxColumns - 1
        let row = LaneLayout.Row(column: 0, lines: [Self.straightLine(inColumn: last)])
        let drawing = try Drawing(row, isCurrent: true)
        #expect(drawing.isDrawn(x: Self.x(ofColumn: last), y: Self.middle))
    }

    @Test func linesStillStopAtTheEdgeOfTheGraph() throws {
        let leavesTheGraph = LaneLayout.Row(column: 0, lines: [Self.straightLine(inColumn: LaneRenderer.maxColumns)])
        let drawing = try Drawing(leavesTheGraph, isCurrent: true)
        #expect(!drawing.isDrawn(x: Self.x(ofColumn: LaneRenderer.maxColumns), y: Self.middle))
    }

    @Test func aDotPastTheEdgeOfTheGraphIsDrawnAtTheEdge() throws {
        let row = LaneLayout.Row(column: LaneRenderer.maxColumns + 2, lines: [])
        let drawing = try Drawing(row, isCurrent: false)
        #expect(drawing.isDrawn(x: Self.x(ofColumn: LaneRenderer.maxColumns - 1), y: Self.middle))
        #expect(!drawing.isDrawn(x: Self.x(ofColumn: LaneRenderer.maxColumns), y: Self.middle))
    }

    @Test func aHollowDotHasNoRingOfItsOwn() throws {
        let row = LaneLayout.Row(column: 0, lines: [LaneLayout.Line(top: .commit, bottom: .column(0))])
        let drawing = try Drawing(row, isHollow: true, isCurrent: false)
        #expect(!drawing.isDrawn(x: Self.dotX, y: Self.middle))
        #expect(!drawing.isDrawn(x: Self.dotX + LaneRenderer.ringRadius, y: Self.middle))
    }
}

/// The lines between a dot and another column, which stay nearly flat along the
/// middle of the row and turn late, rather than sloping the whole way across.
@Suite(.timeLimit(.minutes(1)))
struct LaneCurveTests {
    typealias Drawing = CurrentCommitRowTests.Drawing
    typealias Line = LaneLayout.Line

    static let height = CGFloat(Drawing.height)
    static let middle = height / 2

    static func x(_ column: Int) -> CGFloat {
        CurrentCommitRowTests.x(ofColumn: column)
    }

    /// A line four columns long, halfway and three quarters of the way across.
    /// `turn` is which way the row's middle is from the line.
    func expectFlatThenTurning(_ drawing: Drawing, halfway: CGFloat, threeQuarters: CGFloat, turn: CGFloat) {
        #expect(drawing.isDrawn(x: halfway, y: Self.middle + turn * 0.5))
        #expect(!drawing.isDrawn(x: halfway, y: Self.middle + turn * 3))
        #expect(drawing.isDrawn(x: threeQuarters, y: Self.middle + turn * 2))
        #expect(!drawing.isDrawn(x: threeQuarters, y: Self.middle + turn * 5))
    }

    @Test func aLineLeavingTheDotToTheRightRunsFlatAndTurnsDownLate() throws {
        let row = LaneLayout.Row(column: 0, lines: [Line(top: .commit, bottom: .column(4))])
        let drawing = try Drawing(row, isCurrent: false)
        expectFlatThenTurning(drawing, halfway: Self.x(2), threeQuarters: Self.x(3), turn: 1)
        // It meets the next row's line going straight down.
        #expect(drawing.isDrawn(x: Self.x(4), y: Self.height - 1))
        #expect(!drawing.isDrawn(x: Self.x(4) - 2, y: Self.height - 1))
    }

    @Test func aLineLeavingTheDotToTheLeftDoesTheSame() throws {
        let row = LaneLayout.Row(column: 4, lines: [Line(top: .commit, bottom: .column(0))])
        let drawing = try Drawing(row, isCurrent: false)
        expectFlatThenTurning(drawing, halfway: Self.x(2), threeQuarters: Self.x(1), turn: 1)
        #expect(drawing.isDrawn(x: Self.x(0), y: Self.height - 1))
        #expect(!drawing.isDrawn(x: Self.x(0) + 2, y: Self.height - 1))
    }

    @Test func aLineArrivingAtTheDotIsTheSameCurveUpsideDown() throws {
        let row = LaneLayout.Row(column: 0, lines: [Line(top: .column(4), bottom: .commit)])
        let drawing = try Drawing(row, isCurrent: false)
        expectFlatThenTurning(drawing, halfway: Self.x(2), threeQuarters: Self.x(3), turn: -1)
        #expect(drawing.isDrawn(x: Self.x(4), y: 1))
        #expect(!drawing.isDrawn(x: Self.x(4) - 2, y: 1))
    }

    @Test func aLaneMovingOverCrossesTheMiddleOfTheRowHalfway() throws {
        // No line touches the dot, so it doesn't turn the way those do.
        let row = LaneLayout.Row(column: 0, lines: [Line(top: .column(4), bottom: .column(1))])
        let drawing = try Drawing(row, isCurrent: false)
        let halfway = (Self.x(4) + Self.x(1)) / 2
        #expect(drawing.isDrawn(x: halfway, y: Self.middle))
        #expect(!drawing.isDrawn(x: Self.x(3) + 4, y: Self.middle))
        #expect(drawing.isDrawn(x: Self.x(4), y: 1))
        #expect(drawing.isDrawn(x: Self.x(1), y: Self.height - 1))
    }

    @Test func arrowsStopShortOfALineAlongTheMiddleOfTheRow() throws {
        let run = Line(top: .commit, bottom: .column(4))
        let pointingDown = LaneLayout.Row(column: 0, lines: [Line(top: .column(2), bottom: .cut(2)), run])
        let down = try Drawing(pointingDown, isCurrent: false)
        #expect(down.isDrawn(x: Self.x(2), y: Self.middle - 4))
        #expect(!down.isDrawn(x: Self.x(2), y: Self.middle - 1.5))

        let pointingUp = LaneLayout.Row(column: 0, lines: [Line(top: .cut(2), bottom: .column(2)), run])
        let up = try Drawing(pointingUp, isCurrent: false)
        #expect(up.isDrawn(x: Self.x(2), y: Self.middle + 4))
        #expect(!up.isDrawn(x: Self.x(2), y: Self.middle + 2))
    }

    @Test func aLineLeavingACurrentDotStopsAtTheRing() throws {
        let row = LaneLayout.Row(column: 0, lines: [Line(top: .commit, bottom: .column(3))])
        let plain = try Drawing(row, isCurrent: false)
        let current = try Drawing(row, isCurrent: true)
        let gap = (4 + LaneRenderer.ringRadius - 0.75) / 2
        #expect(plain.isDrawn(x: Self.x(0) + gap, y: Self.middle))
        #expect(!current.isDrawn(x: Self.x(0) + gap, y: Self.middle))
        #expect(current.isDrawn(x: Self.x(0) + LaneRenderer.ringRadius + 3, y: Self.middle))
    }
}
