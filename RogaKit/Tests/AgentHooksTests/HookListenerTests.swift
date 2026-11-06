import Darwin
import Dispatch
import Foundation
import Testing
@testable import AgentHooks

private func event(_ session: String, _ name: String = "Stop", time: Double = 1) -> HookEvent {
    HookEvent(host: .claude, event: name, session: session, cwd: "/w", time: time)
}

private func line(_ event: HookEvent) -> [UInt8] {
    HookHelper.line(for: event) ?? []
}

private func permissions(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
}

/// Sends an event for each of `count` sessions from as many threads at once
/// as the system gives, and returns when every helper has tried, whether or
/// not it got through.
private func sendAtOnce(_ count: Int, to path: String) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: count) { index in
                _ = HookHelper.send(event("s\(index)"), toSocketAt: path)
            }
            continuation.resume()
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HookListenerTests {
    @Test func receivesWhatTheHelperSends() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let sent = [event("a", "SessionStart"), event("a", "UserPromptSubmit", time: 2), event("b", time: 3)]
        for event in sent {
            #expect(HookHelper.send(event, toSocketAt: listener.socketPath))
        }
        #expect(await eventually { received.all.count == 3 })
        #expect(Set(received.all) == Set(sent))
    }

    @Test func makesAFolderAndASocketForTheUserAlone() throws {
        let folder = try makeTemporaryFolder().appending(path: "sh.roga.test", directoryHint: .isDirectory)
        let listener = try HookListener(supportFolder: folder)
        defer { listener.stop() }
        #expect(listener.socketPath == HookSocket.path(supportFolder: folder))
        #expect(permissions(folder.path(percentEncoded: false)) == 0o700)
        #expect(permissions(listener.socketPath) == 0o600)
        #expect(permissions(HookSocket.lockPath(supportFolder: folder)) == 0o600)
    }

    @Test func leavesAFolderThatsAlreadyThereAsItIs() throws {
        let folder = try makeTemporaryFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
        let listener = try HookListener(supportFolder: folder)
        defer { listener.stop() }
        #expect(permissions(folder.path(percentEncoded: false)) == 0o755)
    }

    @Test func refusesASecondListenerInTheSameFolder() async throws {
        let folder = try makeTemporaryFolder()
        let first = try HookListener(supportFolder: folder)
        defer { first.stop() }
        let received = Received(from: first)
        #expect(throws: HookListenerError.inUse(first.socketPath)) {
            try HookListener(supportFolder: folder)
        }
        // The first one still has the socket.
        #expect(HookHelper.send(event("a"), toSocketAt: first.socketPath))
        #expect(await eventually { received.all == [event("a")] })
    }

    @Test func replacesASocketLeftByACopyThatQuit() async throws {
        let folder = try makeTemporaryFolder()
        let path = HookSocket.path(supportFolder: folder)
        makeAbandonedSocket(at: path)
        #expect(!HookHelper.send(event("a"), toSocketAt: path))
        let listener = try HookListener(supportFolder: folder)
        defer { listener.stop() }
        let received = Received(from: listener)
        #expect(HookHelper.send(event("a"), toSocketAt: path))
        #expect(await eventually { received.all == [event("a")] })
    }

    @Test func stoppingRemovesTheSocketAndEndsTheEvents() async throws {
        let folder = try makeTemporaryFolder()
        let listener = try HookListener(supportFolder: folder)
        let ended = Task {
            for await _ in listener.events {}
            return true
        }
        listener.stop()
        #expect(await ended.value)
        #expect(!FileManager.default.fileExists(atPath: listener.socketPath))
        #expect(!HookHelper.send(event("a"), toSocketAt: listener.socketPath))
        listener.stop()

        // Another copy can listen now.
        let next = try HookListener(supportFolder: folder)
        defer { next.stop() }
        let received = Received(from: next)
        #expect(HookHelper.send(event("b"), toSocketAt: next.socketPath))
        #expect(await eventually { received.all == [event("b")] })
    }

    @Test func stoppingLeavesASocketThatAnotherListenerMade() throws {
        let folder = try makeTemporaryFolder()
        let first = try HookListener(supportFolder: folder)
        // Someone removes the folder while Roga runs, and another copy
        // starts in its place.
        try FileManager.default.removeItem(at: folder)
        let second = try HookListener(supportFolder: folder)
        defer { second.stop() }
        first.stop()
        #expect(FileManager.default.fileExists(atPath: second.socketPath))
    }

    @Test func readsEveryLineOfAConnection() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let connection = try connectToSocket(at: listener.socketPath)
        // The last line has no newline, and the connection's end finishes it.
        let lastLine = line(event("c")).dropLast()
        #expect(writeAll(line(event("a")) + line(event("b")) + lastLine, to: connection))
        close(connection)
        #expect(await eventually { received.all.count == 3 })
        #expect(received.all == [event("a"), event("b"), event("c")])
    }

    @Test func putsTogetherALineThatArrivesInPieces() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let connection = try connectToSocket(at: listener.socketPath)
        defer { close(connection) }
        let whole = line(event("a"))
        writeAll(Array(whole.prefix(10)), to: connection)
        try await Task.sleep(for: .milliseconds(100))
        writeAll(Array(whole.dropFirst(10)), to: connection)
        #expect(await eventually { received.all == [event("a")] })
    }

    @Test func skipsLinesThatArentEvents() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let connection = try connectToSocket(at: listener.socketPath)
        let junk = Array("not json\n\n{\"version\":1,\"host\":\"claude\"}\n{\"version\":1,\"host\":\"cursor\",\"event\":\"Stop\",\"time\":1}\n".utf8)
        #expect(writeAll(junk + line(event("a")), to: connection))
        close(connection)
        #expect(await eventually { !received.all.isEmpty })
        try await Task.sleep(for: .milliseconds(100))
        #expect(received.all == [event("a")])
    }

    @Test func closesAConnectionThatSendsALineTooLong() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        let flooding = try connectToSocket(at: listener.socketPath)
        defer { close(flooding) }
        // The listener stops reading partway, so the write may fail.
        writeAll([UInt8](repeating: UInt8(ascii: "x"), count: 70 * 1024) + line(event("a")), to: flooding)
        #expect(HookHelper.send(event("b"), toSocketAt: listener.socketPath))
        #expect(await eventually { !received.all.isEmpty })
        try await Task.sleep(for: .milliseconds(200))
        #expect(received.all == [event("b")])
    }

    @Test func takesManyHelpersAtOnce() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        await sendAtOnce(40, to: listener.socketPath)
        #expect(await eventually { received.all.count == 40 })
        #expect(Set(received.all.compactMap(\.session)) == Set((0..<40).map { "s\($0)" }))
    }

    @Test func helpersBeyondTheLimitWaitTheirTurn() async throws {
        let listener = try HookListener(supportFolder: try makeTemporaryFolder())
        defer { listener.stop() }
        let received = Received(from: listener)
        // Helpers that have connected but not written yet, one more than the
        // listener holds open at once, the way a burst looks when the
        // listener's queue has fallen behind.
        let count = HookListener.connectionLimit + 1
        var connections: [Int32] = []
        for _ in 0..<count {
            connections.append(try connectToSocket(at: listener.socketPath))
        }
        #expect(await eventually { listener.openConnections == HookListener.connectionLimit })
        try await Task.sleep(for: .milliseconds(100))
        #expect(listener.openConnections == HookListener.connectionLimit)

        // The last one waits in the socket's backlog, and its event arrives
        // once another connection closes.
        for (index, connection) in connections.enumerated() {
            #expect(writeAll(line(event("s\(index)")), to: connection))
            close(connection)
        }
        #expect(await eventually { received.all.count == count })
        #expect(Set(received.all.compactMap(\.session)) == Set((0..<count).map { "s\($0)" }))
        #expect(await eventually { listener.openConnections == 0 })
        #expect(HookHelper.send(event("after"), toSocketAt: listener.socketPath))
        #expect(await eventually { received.all.count == count + 1 })
    }

    @Test func stoppingWhileHelpersConnect() async throws {
        let folder = try makeTemporaryFolder()
        for round in 0..<40 {
            let listener = try HookListener(supportFolder: folder)
            let ended = Task {
                for await _ in listener.events {}
                return true
            }
            async let sent: Void = sendAtOnce(64, to: listener.socketPath)
            // Stopping at a different moment each round lands it on every
            // step of accepting a connection sooner or later.
            try await Task.sleep(for: .microseconds(200 * (round % 8)))
            listener.stop()
            await sent
            #expect(await ended.value)
        }
        // The folder still works for the next copy.
        let listener = try HookListener(supportFolder: folder)
        defer { listener.stop() }
        let received = Received(from: listener)
        #expect(HookHelper.send(event("a"), toSocketAt: listener.socketPath))
        #expect(await eventually { received.all == [event("a")] })
    }

    @Test func stoppingWhileHelpersWaitForRoom() async throws {
        let folder = try makeTemporaryFolder()
        let listener = try HookListener(supportFolder: folder)
        let ended = Task {
            for await _ in listener.events {}
            return true
        }
        var connections: [Int32] = []
        defer {
            for connection in connections {
                close(connection)
            }
        }
        // Accepting is suspended with a helper waiting, and stopping resumes
        // it before it cancels it.
        for _ in 0...HookListener.connectionLimit {
            connections.append(try connectToSocket(at: listener.socketPath))
        }
        #expect(await eventually { listener.openConnections == HookListener.connectionLimit })
        listener.stop()
        #expect(await ended.value)
        #expect(listener.openConnections == 0)

        let next = try HookListener(supportFolder: folder)
        defer { next.stop() }
        let received = Received(from: next)
        #expect(HookHelper.send(event("a"), toSocketAt: next.socketPath))
        #expect(await eventually { received.all == [event("a")] })
    }

    @Test func refusesAFolderWhoseSocketPathIsTooLong() throws {
        let folder = try makeTemporaryFolder().appending(path: String(repeating: "f", count: 80), directoryHint: .isDirectory)
        #expect(throws: HookListenerError.pathTooLong(HookSocket.path(supportFolder: folder))) {
            try HookListener(supportFolder: folder)
        }
    }
}
