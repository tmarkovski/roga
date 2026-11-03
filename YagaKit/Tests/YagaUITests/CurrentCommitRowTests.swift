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

        init(_ row: LaneLayout.Row, columns: Int = 1, isHollow: Bool = false, isCurrent: Bool) throws {
            let width = 60
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
            LaneRenderer.draw(row, columns: columns, at: Self.origin, height: CGFloat(Self.height), isHollow: isHollow, isCurrent: isCurrent)
            NSGraphicsContext.restoreGraphicsState()
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
        let bold = try #require(CommitRowLayout(content: CommitRowContent(shortID: "a", badges: [Self.currentBranch]), graphColumns: 0, size: size).badges.first)
        let regular = try #require(CommitRowLayout(content: CommitRowContent(shortID: "a", badges: [Self.otherBranch]), graphColumns: 0, size: size).badges.first)
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

    @Test func linesStillStopAtTheEdgeOfTheGraph() throws {
        let leavesTheGraph = LaneLayout.Row(column: 0, lines: [LaneLayout.Line(top: .column(1), bottom: .column(1))])
        let drawing = try Drawing(leavesTheGraph, columns: 1, isCurrent: true)
        #expect(!drawing.isDrawn(x: Drawing.origin + LaneRenderer.spacing * 1.5, y: Self.middle))
    }

    @Test func aHollowDotHasNoRingOfItsOwn() throws {
        let row = LaneLayout.Row(column: 0, lines: [LaneLayout.Line(top: .commit, bottom: .column(0))])
        let drawing = try Drawing(row, isHollow: true, isCurrent: false)
        #expect(!drawing.isDrawn(x: Self.dotX, y: Self.middle))
        #expect(!drawing.isDrawn(x: Self.dotX + LaneRenderer.ringRadius, y: Self.middle))
    }
}
