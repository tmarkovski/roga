import Foundation

/// A long-running `git cat-file --batch` process that returns commit metadata on request.
final class CatFileBatch {
    private let process: GitProcess
    private var buffer: [UInt8] = []
    private var start = 0

    init(repo: String) throws {
        process = try GitProcess(["cat-file", "--batch"], in: repo, withInput: true)
    }

    deinit { _ = process.wait() }

    /// Requests a window of commits at once and parses the replies in order.
    func commits(_ oids: [OID]) throws -> [CommitMeta] {
        var request = ""
        request.reserveCapacity(oids.count * 41)
        for oid in oids { request += oid.hex + "\n" }
        var bytes = Array(request.utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeMutableBytes { write(process.input!, $0.baseAddress! + written, $0.count - written) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw BenchError("cat-file closed its input") }
            written += count
        }
        return try oids.map { _ in try readCommit() }
    }

    private func readCommit() throws -> CommitMeta {
        let header = try readLine()
        guard header.hasSuffix(" commit") || header.contains(" commit ") else {
            throw BenchError("cat-file replied \(header)")
        }
        guard let size = Int(header.split(separator: " ").last ?? "") else {
            throw BenchError("cat-file header without a size: \(header)")
        }
        try fill(size + 1)
        defer { start += size + 1 }
        return buffer.withUnsafeBufferPointer { all in
            parseCommit(UnsafeBufferPointer(rebasing: all[start..<start + size]))
        }
    }

    private func readLine() throws -> String {
        while true {
            if let newline = buffer[start...].firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[start..<newline], as: UTF8.self)
                start = newline + 1
                return line
            }
            try readMore()
        }
    }

    private func fill(_ count: Int) throws {
        while buffer.count - start < count { try readMore() }
    }

    private func readMore() throws {
        if start > 0 && start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { read(process.output, $0.baseAddress, $0.count) }
        guard count > 0 else { throw BenchError("cat-file closed its output") }
        buffer.append(contentsOf: chunk[0..<count])
    }
}

/// Parses the author and subject out of a raw commit object.
func parseCommit(_ body: UnsafeBufferPointer<UInt8>) -> CommitMeta {
    var meta = CommitMeta(author: "", email: "", time: 0, subject: "")
    var cursor = FieldCursor(body)
    while true {
        let line = cursor.next(0x0A)
        if line.isEmpty { break }
        guard line.starts(with: "author ".utf8) else { continue }
        let text = String(decoding: line.dropFirst(7), as: UTF8.self)
        if let open = text.firstIndex(of: "<"), let close = text.lastIndex(of: ">") {
            meta.author = String(text[..<open].dropLast())
            meta.email = String(text[text.index(after: open)..<close])
            meta.time = Int64(text[text.index(close, offsetBy: 2)...].split(separator: " ").first ?? "") ?? 0
        }
    }
    meta.subject = String(decoding: cursor.next(0x0A), as: UTF8.self)
    return meta
}
