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
private func pixels(of map: MetroMap, at time: Double, colorScheme: ColorScheme = .light) throws -> Data {
    let view = Canvas(opaque: true, rendersAsynchronously: false) { context, size in
        map.draw(in: context, size: size, at: time, colorScheme: colorScheme)
    }
    .frame(width: 640, height: 360)
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

    @Test func namesTheSpeedsAndTheClock() {
        #expect(ReplayPlayer.speedTitle(0.5) == "0.5×")
        #expect(ReplayPlayer.speedTitle(2) == "2×")
        #expect(ReplayPlayer.clock(75) == "1:15")
        #expect(ReplayPlayer.clock(5) == "0:05")
    }
}

struct LabelStacksTests {
    private func item(_ start: Double, width: Double = 100, above: Bool = true, lowest: Int = 0) -> LabelStacks.Item {
        LabelStacks.Item(start: start, width: width, isAbove: above, lowestTier: lowest)
    }

    private func tiers(_ items: [LabelStacks.Item], room: Int = 50) -> [Int?] {
        LabelStacks.tiers(of: items, tiersAbove: room, tiersBelow: room)
    }

    @Test func theNewestSitsLowestAndPushesWhatItOverlapsUp() {
        #expect(tiers([item(0), item(50)]) == [1, 0])
        #expect(tiers([item(0), item(30), item(60)]) == [2, 1, 0])
    }

    @Test func aLabelOnTopFallsBackOnceTheNextClearsItPlusSlack() {
        let end = 100 + LabelStacks.slack
        #expect(tiers([item(0), item(end - 1)]) == [1, 0])
        #expect(tiers([item(0), item(end + 1)]) == [0, 0])
        #expect(tiers([item(0), item(50), item(120)]) == [0, 1, 0])
    }

    @Test func aStackIsAsTallAsItsLabelsOverlap() {
        let items = (0 ..< 40).map { item(Double($0)) }
        #expect(tiers(items) == (0 ..< 40).reversed().map(Optional.some))
    }

    @Test func aLabelWithNoRoomLeftIsLeftOut() {
        #expect(tiers([item(0), item(10), item(20)], room: 2) == [nil, 1, 0])
    }

    @Test func eachSideStacksByItself() {
        #expect(tiers([item(0, above: false), item(10, above: true)]) == [0, 0])
    }

    @Test func aBranchsLabelStaysPastItsLane() {
        #expect(tiers([item(0), item(500, lowest: 3)]) == [0, 3])
        #expect(tiers([item(0, lowest: 2), item(10, lowest: 2)]) == [3, 2])
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
        #expect(map.duration == map.replay.playEnd + MetroMap.finale + MetroMap.hold)
        #expect(looksTheSame(try pixels(of: map, at: map.duration), try pixels(of: map, at: map.duration - 0.1)))
    }

    @Test func saysWhatItShowsForVoiceOver() throws {
        let map = MetroMap(replay: try makeReplay(), repositoryName: "app")
        #expect(map.summary == "main in app: 15 commits, 2 branches, 1 day.")
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

    @Test func offersEveryRangeFromAWeekUp() {
        #expect(ReplayModel.dayRanges == [7, 14, 30, 90, 365])
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
