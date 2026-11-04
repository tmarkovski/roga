/// The hash function a repository uses for its object IDs. Most repositories
/// use SHA-1, and git 3.0 makes SHA-256 the default for new ones.
public enum ObjectFormat: String, Sendable, CaseIterable {
    case sha1
    case sha256

    /// The number of bytes in an object ID.
    public var byteCount: Int {
        switch self {
        case .sha1: 20
        case .sha256: 32
        }
    }

    /// The number of hexadecimal digits in a full object ID.
    public var hexLength: Int { byteCount * 2 }

    /// The ID of a tree with nothing in it, which is what a repository without
    /// commits compares its index with. git knows it without having it stored.
    public var emptyTree: ObjectID {
        switch self {
        case .sha1: ObjectID(hex: "4b825dc642cb6eb9a060e54bf8d69288fbee4904")!
        case .sha256: ObjectID(hex: "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321")!
        }
    }
}

/// The ID of a git object, either a 20-byte SHA-1 hash or a 32-byte SHA-256
/// hash.
///
/// The bytes are stored inline in four words, so an ID never allocates. The
/// words are big-endian, which makes comparing them the same as comparing the
/// bytes, and unused bytes of a SHA-1 ID are zero.
public struct ObjectID: Hashable, Comparable, Sendable {
    public let format: ObjectFormat
    private let w0, w1, w2, w3: UInt64

    /// Creates an ID from its raw bytes, such as the ones in a commit-graph
    /// file. The number of bytes decides the format.
    public init?(bytes: some Collection<UInt8>) {
        switch bytes.count {
        case ObjectFormat.sha1.byteCount: format = .sha1
        case ObjectFormat.sha256.byteCount: format = .sha256
        default: return nil
        }
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        for (index, byte) in bytes.enumerated() {
            Self.add(UInt64(byte) << (56 - 8 * UInt64(index % 8)), toWord: index / 8, of: &words)
        }
        (w0, w1, w2, w3) = words
    }

    /// Creates an ID from the raw bytes at `pointer`, such as an ID in a
    /// mapped commit-graph file. The format says how many bytes to read.
    public init(loading pointer: UnsafeRawPointer, format: ObjectFormat) {
        func word(_ offset: Int) -> UInt64 {
            UInt64(bigEndian: pointer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
        self.format = format
        w0 = word(0)
        w1 = word(8)
        switch format {
        case .sha1:
            let last = UInt32(bigEndian: pointer.loadUnaligned(fromByteOffset: 16, as: UInt32.self))
            w2 = UInt64(last) << 32
            w3 = 0
        case .sha256:
            w2 = word(16)
            w3 = word(24)
        }
    }

    /// Creates an ID from its full hexadecimal form, as git prints it. Both
    /// lowercase and uppercase digits are accepted.
    public init?(hex: some StringProtocol) {
        self.init(hexDigits: hex.utf8)
    }

    /// Creates an ID from the UTF-8 bytes of its full hexadecimal form, such
    /// as an ID in git's output, without making a string first.
    public init?(hexDigits digits: some Collection<UInt8>) {
        switch digits.count {
        case ObjectFormat.sha1.hexLength: format = .sha1
        case ObjectFormat.sha256.hexLength: format = .sha256
        default: return nil
        }
        var words: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        for (index, digit) in digits.enumerated() {
            guard let nibble = Self.nibble(digit) else { return nil }
            Self.add(UInt64(nibble) << (60 - 4 * UInt64(index % 16)), toWord: index / 16, of: &words)
        }
        (w0, w1, w2, w3) = words
    }

    /// The full ID in lowercase hexadecimal.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: format.hexLength) { buffer in
            for index in 0..<format.byteCount {
                let byte = self.byte(at: index)
                buffer[2 * index] = digits[Int(byte >> 4)]
                buffer[2 * index + 1] = digits[Int(byte & 0x0f)]
            }
            return format.hexLength
        }
    }

    public static func < (lhs: ObjectID, rhs: ObjectID) -> Bool {
        if lhs.format != rhs.format { return lhs.format == .sha1 }
        return (lhs.w0, lhs.w1, lhs.w2, lhs.w3) < (rhs.w0, rhs.w1, rhs.w2, rhs.w3)
    }

    /// The byte at `index`, which is less than the format's byte count.
    public func byte(at index: Int) -> UInt8 {
        precondition(index >= 0 && index < format.byteCount, "Byte \(index) is outside a \(format) ID")
        let word = switch index / 8 {
        case 0: w0
        case 1: w1
        case 2: w2
        default: w3
        }
        return UInt8(truncatingIfNeeded: word >> (56 - 8 * UInt64(index % 8)))
    }

    private static func add(_ bits: UInt64, toWord index: Int, of words: inout (UInt64, UInt64, UInt64, UInt64)) {
        switch index {
        case 0: words.0 |= bits
        case 1: words.1 |= bits
        case 2: words.2 |= bits
        default: words.3 |= bits
        }
    }

    private static func nibble(_ digit: UInt8) -> UInt8? {
        switch digit {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension ObjectID: CustomStringConvertible {
    public var description: String { hex }
}
