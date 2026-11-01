/// The four kinds of object that git stores.
public enum ObjectType: String, Sendable, Hashable, CaseIterable {
    case commit
    case tree
    case blob
    case tag
}
