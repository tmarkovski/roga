/// How a file's diff is laid out (decision 74).
public enum DiffLayout: String, Sendable, CaseIterable {
    /// Only the hunks: each change with a few lines around it, under a header
    /// that says where in the file it is.
    case hunks
    /// The whole file, with its changes where they are in it, and no headers.
    case inline
}
