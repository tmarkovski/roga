import AVFoundation
import CommitGraph
import Foundation
import GitCore
import RepositoryEngine
import SwiftUI
import TestSupport
import Testing
@testable import RogaUI

/// A replay of a made-up history: `flat` commits on the main line, then
/// `branches` branches of two commits each that merge back one at a time.
private func makeReplay(flat: Int = 8, branches: Int = 2, length: Double = 75) throws -> HistoryReplay {
    var newer: [CommitGraph.NewerCommit] = []
    var messages: [ObjectID: HistoryReplay.Message] = [:]
    var time: Int64 = 1_767_225_600

    func add(_ subject: String, parents: [ObjectID], body: String = "") throws -> ObjectID {
        let id = try #require(ObjectID(hex: String(format: "%040x", newer.count + 1)))
        time += 60
        newer.append(CommitGraph.NewerCommit(id: id, parents: parents, commitTime: time))
        messages[id] = HistoryReplay.Message(subject: subject, body: body)
        return id
    }

    var tip = try add("First", parents: [])
    for index in 0 ..< flat {
        tip = try add("Commit \(index)", parents: [tip])
    }
    for index in 0 ..< branches {
        let one = try add("Start \(index)", parents: [tip])
        let two = try add("Finish \(index)", parents: [one])
        tip = try add("Merge pull request #\(index + 1) from ana/topic-\(index)", parents: [tip, two], body: "Topic \(index)")
    }

    let graph = try CommitGraph(format: .sha1).adding(newer)
    let position = try #require(graph.position(of: tip))
    let positions = try HistoryReplay.commits(in: graph, from: position, range: .all)
    return try HistoryReplay(
        graph: graph,
        tip: position,
        positions: positions,
        messages: positions.map { messages[graph.id(at: $0)]! },
        mainLineName: "main",
        length: length
    )
}

/// Draws a frame and returns its pixels.
private func pixels(of map: MetroMap, at time: Double, colorScheme: ColorScheme = .light, size: CGSize = CGSize(width: 640, height: 360)) throws -> Data {
    let view = Canvas(opaque: true, rendersAsynchronously: false) { context, size in
        map.draw(in: context, size: size, at: time, colorScheme: colorScheme)
    }
    .frame(width: size.width, height: size.height)
    let image = try #require(ImageRenderer(content: view).cgImage)
    return try #require(image.dataProvider?.data as Data?)
}

/// Whether two frames look the same. While other tests draw, the same frame
/// can come out one level different in a few places along the edges of text.
private func looksTheSame(_ first: Data, _ second: Data) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
}

@Suite @MainActor
struct ReplayPlayerTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test func runsWithTheClockAtTheChosenSpeed() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        #expect(player.isPlaying)
        #expect(player.time(at: start.addingTimeInterval(2)) == 2)
        player.setSpeed(2, at: start.addingTimeInterval(2))
        #expect(player.time(at: start.addingTimeInterval(2)) == 2)
        #expect(player.time(at: start.addingTimeInterval(3)) == 4)
    }

    @Test func holdsStillWhilePausedAndCarriesOn() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        player.togglePlaying(at: start.addingTimeInterval(3))
        #expect(!player.isPlaying)
        #expect(player.time(at: start.addingTimeInterval(100)) == 3)
        player.togglePlaying(at: start.addingTimeInterval(100))
        #expect(player.time(at: start.addingTimeInterval(101)) == 4)
    }

    @Test func stopsAtTheEndAndPlaysFromTheStartAgain() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        let after = start.addingTimeInterval(20)
        #expect(player.time(at: after) == 10)
        player.stopIfFinished(at: after)
        #expect(!player.isPlaying)
        player.togglePlaying(at: after)
        #expect(player.time(at: after) == 0)
    }

    @Test func staysInsideTheReplayWhenJumping() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        player.jump(by: -5, at: start)
        #expect(player.time(at: start) == 0)
        player.jump(by: 50, at: start)
        #expect(player.time(at: start) == 10)
    }

    @Test func stepsThroughTheSpeedsAndStopsAtEitherEnd() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        player.stepSpeed(by: 1, at: start)
        #expect(player.speed == 2)
        player.stepSpeed(by: 5, at: start)
        #expect(player.speed == 4)
        player.stepSpeed(by: -9, at: start)
        #expect(player.speed == 0.5)
    }

    @Test func someoneWhoAskedForLessMotionStartsStillOnTheLastFrame() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: true, at: start)
        #expect(!player.isPlaying)
        #expect(player.time(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func keepsItsPlaceWhenTheReplayChangesLength() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        player.togglePlaying(at: start.addingTimeInterval(5))
        player.changeDuration(to: 20, at: start.addingTimeInterval(5))
        #expect(player.time(at: start.addingTimeInterval(5)) == 10)
    }

    @Test func keepsItsMomentWhenTheEndMoves() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        let later = start.addingTimeInterval(4)
        player.moveEnd(to: 12, at: later)
        #expect(player.duration == 12)
        #expect(player.time(at: later) == 4)
        #expect(player.time(at: later.addingTimeInterval(1)) == 5)
    }

    @Test func staysAtTheEndWhenTheEndMoves() {
        let player = ReplayPlayer()
        player.load(duration: 10, reducesMotion: false, at: start)
        let after = start.addingTimeInterval(20)
        player.stopIfFinished(at: after)
        player.moveEnd(to: 12, at: after)
        #expect(player.time(at: after) == 12)
    }

    @Test func namesTheSpeedsAndTheClock() {
        #expect(ReplayPlayer.speedTitle(0.5) == "0.5×")
        #expect(ReplayPlayer.speedTitle(2) == "2×")
        #expect(ReplayPlayer.clock(75) == "1:15")
        #expect(ReplayPlayer.clock(5) == "0:05")
    }
}

struct LabelStacksTests {
    private func item(_ start: Double, width: Double = 100, above: Bool = true, lowest: Int = 0, time: Double? = nil) -> LabelStacks.Item {
        LabelStacks.Item(start: start, width: width, isAbove: above, lowestTier: lowest, time: time ?? start)
    }

    private func tiers(_ moves: [LabelStacks.Move]) -> [Int] {
        moves.map(\.tier)
    }

    /// The moves that took a label closer to the main line.
    private func falls(_ moves: [LabelStacks.Move]) -> [Int] {
        moves.indices.dropFirst().filter { moves[$0].tier < moves[$0 - 1].tier }
    }

    /// A long run of labels whose widths vary, as subjects do.
    private var aRun: [LabelStacks.Item] {
        (0 ..< 300).map { (index: Int) -> LabelStacks.Item in
            let width = Double(90 + (index * 37) % 310)
            return item(Double(index) * 40, width: width, above: index % 3 != 0)
        }
    }

    @Test func aNewLabelSitsLowestAndPushesWhatItOverlapsUp() {
        let moves = LabelStacks.moves(of: [item(0), item(30), item(60)])
        #expect(tiers(moves[0]) == [0, 1, 2])
        #expect(tiers(moves[1]) == [0, 1])
        #expect(tiers(moves[2]) == [0])
    }

    @Test func aLabelIsLeftAloneByOneThatClearsIt() {
        let moves = LabelStacks.moves(of: [item(0), item(100 + LabelStacks.slack + 1)])
        #expect(tiers(moves[0]) == [0])
        #expect(tiers(moves[1]) == [0])
    }

    @Test func aLabelOnTopFallsBackOnceTheNextOneClearsItPlusSlack() {
        let end = 100 + LabelStacks.slack
        let notYet = LabelStacks.moves(of: [item(0), item(50), item(end - 1)])
        #expect(tiers(notYet[0]) == [0, 1, 2])
        let clear = LabelStacks.moves(of: [item(0), item(50), item(end + 1)])
        #expect(tiers(clear[0]) == [0, 1, 0])
    }

    @Test func aLabelThatHasFallenNeverMovesAgain() {
        let moves = LabelStacks.moves(of: aRun)
        #expect(moves.contains { !falls($0).isEmpty })
        for own in moves {
            if let fall = falls(own).first {
                #expect(fall == own.count - 1)
            }
        }
    }

    @Test func noTwoLabelsOnATierEverOverlap() {
        let items = aRun
        let moves = LabelStacks.moves(of: items)
        for landing in items.indices {
            let time = items[landing].time
            var seen: [[Int: [Int]]] = [[:], [:]]
            for index in 0 ... landing {
                guard let tier = moves[index].last(where: { $0.time <= time })?.tier else { continue }
                seen[items[index].isAbove ? 0 : 1][tier, default: []].append(index)
            }
            for side in seen {
                for labels in side.values {
                    for first in labels {
                        for second in labels where first < second {
                            #expect(items[first].end + LabelStacks.slack < items[second].start)
                        }
                    }
                }
            }
        }
    }

    @Test func aStackIsAsTallAsItsLabelsOverlap() {
        let moves = LabelStacks.moves(of: (0 ..< 40).map { item(Double($0)) })
        #expect(moves[0].last?.tier == 39)
    }

    @Test func aLongerLabelMakesATallerStack() {
        func tallest(_ width: Double) -> Int {
            LabelStacks.moves(of: (0 ..< 60).map { item(Double($0) * 40, width: width) }).flatMap { $0 }.map(\.tier).max() ?? 0
        }
        #expect(tallest(400) > tallest(100))
    }

    @Test func aLabelFallsThreeTimesAsSlowlyAsItRises() {
        #expect(LabelStacks.fallTime == LabelStacks.riseTime * 3)

        #expect(LabelStacks.remaining(of: 16, age: 0) == 16)
        #expect(LabelStacks.remaining(of: 16, age: LabelStacks.riseTime) == 0)

        #expect(LabelStacks.remaining(of: -48, age: 0) == -48)
        // A rise of the same time is over, and a fall isn't a third done.
        #expect(LabelStacks.remaining(of: -48, age: LabelStacks.riseTime) < -32)
        #expect(LabelStacks.remaining(of: -48, age: LabelStacks.fallTime) == 0)
    }

    @Test func eachSideStacksByItself() {
        let moves = LabelStacks.moves(of: [item(0, above: false), item(10, above: true)])
        #expect(tiers(moves[0]) == [0])
        #expect(tiers(moves[1]) == [0])
    }

    @Test func aBranchsLabelStaysPastItsLane() {
        let moves = LabelStacks.moves(of: [item(0), item(500, lowest: 3)])
        #expect(tiers(moves[1]) == [3])
    }
}

@Suite @MainActor
struct MetroMapTests {
    /// Scrubbing, playing and saving all rely on this.
    @Test func drawsTheSameFrameForTheSameMoment() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        let time = map.replay.commits[9].time + 0.1
        #expect(looksTheSame(try pixels(of: map, at: time), try pixels(of: map, at: time)))
        #expect(!looksTheSame(try pixels(of: map, at: time), try pixels(of: map, at: time + 0.5)))
    }

    @Test func drawsInBothAppearances() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        #expect(!looksTheSame(try pixels(of: map, at: 3, colorScheme: .light), try pixels(of: map, at: 3, colorScheme: .dark)))
    }

    @Test func holdsTheWholeHistoryAtTheEnd() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        #expect(map.duration == map.posterStart + MetroMap.posterIn + MetroMap.hold)
        #expect(looksTheSame(try pixels(of: map, at: map.duration), try pixels(of: map, at: map.duration - 0.1)))
    }

    @Test func toursWhatStoodOutOnceTheLinesAreCounted() throws {
        var replay = try makeReplay()
        let without = MetroMap(replay: replay, repositoryName: "app")
        #expect(!without.beats.contains { $0.eyebrow == "THE BIGGEST COMMIT" })
        replay.countLines([replay.commits[3].id: .init(added: 2000, removed: 34)])
        let with = MetroMap(replay: replay, repositoryName: "app")
        #expect(with.beats.first?.eyebrow == "THE BIGGEST COMMIT")
        #expect(with.beats.first?.value == "+\(2000.formatted()) −34")
        #expect(with.duration == without.duration + MetroMap.beat)
        #expect(with.flights == [3])
    }

    @Test func skipsTheTourWhenThereIsLittleToTour() throws {
        let map = MetroMap(replay: try makeReplay(flat: 2, branches: 1), repositoryName: "app")
        #expect(map.beats.isEmpty)
        #expect(map.posterStart == map.replay.playEnd + MetroMap.finale * 0.7)
    }

    @Test func drawsTheTourAndThePosterDifferently() throws {
        var replay = try makeReplay()
        replay.countLines([replay.commits[3].id: .init(added: 2000, removed: 34)])
        let map = MetroMap(replay: replay, repositoryName: "app")
        let tour = try pixels(of: map, at: map.tourStart + 1)
        #expect(!looksTheSame(tour, try pixels(of: map, at: map.zoomEnd - 0.2)))
        #expect(!looksTheSame(tour, try pixels(of: map, at: map.duration)))
    }

    @Test func drawsTheHouseOnlyWhenAskedTo() throws {
        let replay = try makeReplay()
        var map = MetroMap(replay: replay, repositoryName: "app")
        let time = replay.playEnd / 2
        let without = try pixels(of: map, at: time)
        map.showsHouse = true
        #expect(!looksTheSame(without, try pixels(of: map, at: time)))
        map.showsHouse = false
        #expect(looksTheSame(without, try pixels(of: map, at: time)))
    }

    @Test(arguments: [CGSize(width: 520, height: 300), CGSize(width: 700, height: 420), CGSize(width: 1100, height: 640), CGSize(width: 1280, height: 720)])
    func drawsEveryPartAtEverySize(size: CGSize) throws {
        var replay = try makeReplay(flat: 40, branches: 6)
        replay.countLines([replay.commits[3].id: .init(added: 2000, removed: 34)])
        let map = MetroMap(replay: replay, repositoryName: "a-repository-with-quite-a-long-name-for-its-band", showsHouse: true)
        for time in [0, replay.playEnd / 2, map.tourStart + 1, map.posterStart + 1, map.duration] {
            _ = try pixels(of: map, at: time, size: size)
        }
    }

    @Test func fitsTheBandToTheWidth() throws {
        var replay = try makeReplay()
        replay.countLines([replay.commits[3].id: .init(added: 2000, removed: 34)])
        let map = MetroMap(replay: replay, repositoryName: "app")
        #expect(map.bandFit(width: 1100)?.tiles.width == 26)
        #expect(map.bandFit(width: 1100)?.showsDate == true)
        #expect(map.bandFit(width: 300) == nil)
    }

    @Test func saysWhatItShowsForVoiceOver() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        #expect(map.summary.hasPrefix("main in app: 15 commits, 2 branches, 1 day."))
    }

    @Test func saysHowManyLinesChangedOnceTheyreCounted() throws {
        var replay = try makeReplay()
        replay.countLines([replay.commits[1].id: .init(added: 1200, removed: 34)])
        let map = MetroMap(replay: replay, repositoryName: "app")
        #expect(map.summary.hasPrefix("main in app: 15 commits, 2 branches, 1 day, \(1200.formatted()) lines added and 34 removed."))
    }

    @Test func drawsTheLinesOnceTheyreCounted() throws {
        var replay = try makeReplay()
        let without = MetroMap(replay: replay, repositoryName: "app")
        replay.countLines([replay.commits[9].id: .init(added: 12, removed: 3)])
        let with = MetroMap(replay: replay, repositoryName: "app")
        let time = replay.commits[9].time + 0.5
        #expect(!looksTheSame(try pixels(of: without, at: time), try pixels(of: with, at: time)))
        #expect(!looksTheSame(try pixels(of: without, at: with.duration), try pixels(of: with, at: with.duration)))
    }

    @Test func givesEachNumberTheWindowsItsLastCountNeeds() {
        #expect(RollingNumber.windows(for: 0) == 1)
        #expect(RollingNumber.windows(for: 9) == 1)
        #expect(RollingNumber.windows(for: 10) == 2)
        #expect(RollingNumber.windows(for: 999) == 3)
        #expect(RollingNumber.windows(for: 1000) == 4)
        #expect(RollingNumber.windows(for: 1_234_567) == 7)
    }

    @Test func drawsTheSameFrameForTheSameMomentWhileANumberRolls() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        let time = map.replay.commits[9].time + MetroMap.roll * 0.4
        #expect(looksTheSame(try pixels(of: map, at: time), try pixels(of: map, at: time)))
    }

    @Test func drawsEvenWithNoCommits() throws {
        let replay = try HistoryReplay(
            graph: CommitGraph(format: .sha1),
            tip: 0,
            positions: [],
            messages: [],
            mainLineName: "main",
            length: 75
        )
        _ = try pixels(of: MetroMap(replay: replay, repositoryName: "app"), at: 1)
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ReplayModelTests {
    /// Opens the replay of `main` in a fixture and waits for it to settle.
    private func started() async throws -> ReplayModel {
        let repository = try await Fixture.repository("replay")
        let session = try await RepositorySession.open(containing: repository, git: try await TestGit.make())
        var last: History?
        for try await history in session.history(sort: .date) { last = history }
        let history = try #require(last)
        let model = ReplayModel(
            session: session,
            graph: history.graph,
            tip: try #require(history.head),
            branchName: "main",
            tags: []
        )
        model.start(reducesMotion: true)
        while case .loading = model.phase {
            try await Task.sleep(for: .milliseconds(10))
        }
        await session.close()
        return model
    }

    @Test func startsOnTheLastWeekAtFortyFiveSeconds() async throws {
        let model = try await started()
        #expect(model.scope == .days(7))
        #expect(model.length == 45)
    }

    @Test func countsTheLinesOnceItsPlaying() async throws {
        let model = try await started()
        while model.isCountingLines {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .ready(let map) = model.phase else {
            Issue.record("The replay isn't ready")
            return
        }
        #expect(map.replay.hasLineCounts)
    }

    @Test func offersRangesByDaysAndByCommits() {
        #expect(ReplayModel.dayRanges == [3, 7, 14, 30, 90, 365])
        #expect(ReplayModel.commitRanges == [10, 25, 50, 100, 200])
        #expect(ReplayModel.scopeGroups.map { $0.map(\.title) } == [
            ["Last 3 days", "Last 7 days", "Last 14 days", "Last 30 days", "Last 90 days", "Last 365 days"],
            ["Last 10 commits", "Last 25 commits", "Last 50 commits", "Last 100 commits", "Last 200 commits"],
            ["Whole history"],
        ])
        #expect(ReplayModel.scopeGroups[0].contains(.days(ReplayModel.startingDays)))
        #expect(ReplayModel.lengths.contains(ReplayModel.startingLength))
    }
}

@Suite @MainActor
struct ReplaySavingTests {
    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "roga-replay-\(UUID().uuidString)-\(name)")
    }

    /// A video is as long as the replay at normal speed.
    @Test func writesAVideoAsLongAsTheReplay() async throws {
        let map = MetroMap(replay: try makeReplay(flat: 3, branches: 1, length: 2), repositoryName: "app")
        let url = temporaryFile("replay.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        var lastProgress = 0.0
        try await ReplaySaving.writeVideo(of: map, colorScheme: .dark, to: url) { lastProgress = $0 }
        #expect(lastProgress == 1)

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - map.duration) < 0.1)
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 1920, height: 1080))
    }

    /// The cover is what Finder shows for the file, rather than the first
    /// frame, which has nothing on the board yet.
    @Test func givesAVideoItsLastFrameAsItsCover() async throws {
        let map = MetroMap(replay: try makeReplay(flat: 3, branches: 1, length: 2), repositoryName: "app")
        let url = temporaryFile("cover.mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ReplaySaving.writeVideo(of: map, colorScheme: .light, to: url) { _ in }

        let metadata = try await AVURLAsset(url: url).load(.commonMetadata)
        let covers = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork)
        let data = try #require(try await covers.first?.load(.dataValue))
        let cover = try #require(NSBitmapImageRep(data: data))
        #expect(cover.pixelsWide == 1920)
        #expect(cover.pixelsHigh == 1080)
        // It's the picture at the end, not at the start.
        let shown = try smallPixels(of: try #require(cover.cgImage))
        let end = try smallPixels(of: try frame(of: map, at: map.duration))
        let start = try smallPixels(of: try frame(of: map, at: 0))
        #expect(difference(shown, end) < difference(shown, start) / 4)    }

    private func frame(of map: MetroMap, at time: Double) throws -> CGImage {
        let view = Canvas(opaque: true, rendersAsynchronously: false) { context, size in
            map.draw(in: context, size: size, at: time, colorScheme: .light)
        }
        .frame(width: ReplaySaving.pictureSize.width, height: ReplaySaving.pictureSize.height)
        return try #require(ImageRenderer(content: view).cgImage)
    }

    /// A picture's colors at a small size, for comparing pictures that came
    /// in different sizes and formats.
    private func smallPixels(of image: CGImage) throws -> [UInt8] {
        let width = 64, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func difference(_ first: [UInt8], _ second: [UInt8]) -> Int {
        zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    }

    @Test func leavesNoFileBehindWhenCancelled() async throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        let url = temporaryFile("cancelled.mp4")
        let task = Task { @MainActor in
            try await ReplaySaving.writeVideo(of: map, colorScheme: .light, to: url) { _ in }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    @Test func writesTheLastFrameAsAPNG() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        let url = temporaryFile("last.png")
        defer { try? FileManager.default.removeItem(at: url) }
        try ReplaySaving.writeImage(of: map, colorScheme: .light, to: url)
        let image = try #require(NSImage(contentsOf: url)?.representations.first)
        #expect(image.pixelsWide == 2560)
        #expect(image.pixelsHigh == 1440)
    }
}
