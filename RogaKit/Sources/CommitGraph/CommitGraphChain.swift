import Darwin
import GitCore

extension CommitGraph {
    /// Opens the commit-graph in a repository's objects folder the way git
    /// finds it: the single file `info/commit-graph` if there is one, and
    /// otherwise the split chain that `info/commit-graphs/commit-graph-chain`
    /// lists. Returns nil when there's neither.
    ///
    /// Every file has to use `format`, the repository's hash function. git
    /// also looks for chain layers in alternate object folders, which this
    /// doesn't do yet.
    public init?(objectsFolder: String, format: ObjectFormat) throws(CommitGraphError) {
        let singlePath = objectsFolder + "/info/commit-graph"
        if let file = try Self.openIfPresent(singlePath, format: format) {
            guard file.baseLayerCount == 0 else {
                throw .invalid(path: singlePath, reason: "The file says it has base layers, but it isn't in a chain.")
            }
            self.init(format: format, layers: [file])
            return
        }

        let folder = objectsFolder + "/info/commit-graphs"
        let chainPath = folder + "/commit-graph-chain"
        guard let chain = try Self.contentsIfPresent(chainPath) else { return nil }
        var checksums: [ObjectID] = []
        for (number, line) in chain.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard let checksum = ObjectID(hex: String(decoding: line, as: UTF8.self)), checksum.format == format else {
                throw .invalid(path: chainPath, reason: "Line \(number + 1) isn't a \(format) hash.")
            }
            checksums.append(checksum)
        }
        // git treats a chain without layers as no commit-graph at all.
        guard !checksums.isEmpty else { return nil }
        // The header counts the layers below a file in a single byte.
        guard checksums.count <= 256 else { throw .invalid(path: chainPath, reason: "The chain has too many layers.") }

        // Each layer has to be the file the chain names, and has to list the
        // layers below it in the same order as the chain.
        var layers: [CommitGraphFile] = []
        for (index, checksum) in checksums.enumerated() {
            let path = folder + "/graph-\(checksum.hex).graph"
            let layer = try CommitGraphFile(path: path, format: format)
            guard layer.checksum == checksum else {
                throw .invalid(path: path, reason: "Its checksum doesn't match its name in the chain.")
            }
            guard layer.baseLayerCount == index, layer.baseChecksums == Array(checksums[..<index]) else {
                throw .invalid(path: path, reason: "The layers it's based on don't match the chain.")
            }
            layers.append(layer)
        }
        self.init(format: format, layers: layers)
    }

    private static func openIfPresent(_ path: String, format: ObjectFormat) throws(CommitGraphError) -> CommitGraphFile? {
        do {
            return try CommitGraphFile(path: path, format: format)
        } catch .cannotRead(_, ENOENT) {
            return nil
        }
    }

    private static func contentsIfPresent(_ path: String) throws(CommitGraphError) -> [UInt8]? {
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw .cannotRead(path: path, errorNumber: errno)
        }
        defer { Darwin.close(descriptor) }
        var contents: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return contents }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw .cannotRead(path: path, errorNumber: errno)
            }
            contents.append(contentsOf: buffer[..<count])
        }
    }
}
