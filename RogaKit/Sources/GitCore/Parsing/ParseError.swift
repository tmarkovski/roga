/// Output from git that a parser couldn't read.
public struct ParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public var description: String

    public init(_ description: String) {
        self.description = description
    }
}
