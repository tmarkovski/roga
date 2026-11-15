import AppKit

/// Where the last menu opened from a view, such as a row in history or in the
/// refs panel, so that a command in it that opens a popover can open it there
/// rather than across the window (decision 83). Create › Branch and New branch
/// from stash… are such commands.
///
/// The view that opens a menu says where with `opened(in:at:edge:)` and that it
/// closed with `closed()`. A command runs as its menu closes, or a moment
/// later after a key, so the place stays for a second after that. A command run
/// any other way, such as from VoiceOver's list of a row's actions, finds no
/// place, and its popover opens where it always has.
public enum MenuAnchor {
    /// A rectangle in a view, and the side of it a popover goes on.
    public struct Place {
        public weak var view: NSView?
        /// In `view`'s coordinates.
        public var rect: NSRect
        /// The side of `rect` the popover goes on, or nil for the side that faces
        /// the middle of the window.
        public var edge: NSRectEdge?

        public init(view: NSView, rect: NSRect, edge: NSRectEdge? = nil) {
            self.view = view
            self.rect = rect
            self.edge = edge
        }

        /// The side that faces the middle of the window: left of something in its
        /// right half, such as the refs panel, and right of anything else, such as
        /// the sidebar.
        public var edgeTowardMiddle: NSRectEdge {
            guard let view, let window = view.window else { return .maxX }
            let frame = view.convert(rect, to: nil)
            return frame.midX > window.frame.width / 2 ? .minX : .maxX
        }
    }

    private static var place: Place?
    private static var closedAt: Date?

    /// How long after its menu closes a place still counts.
    static let lifetime: TimeInterval = 1

    /// Says that a menu opened from `rect` in `view`.
    public static func opened(in view: NSView, at rect: NSRect, edge: NSRectEdge? = nil) {
        place = Place(view: view, rect: rect, edge: edge)
        closedAt = nil
    }

    /// Says that the menu closed.
    public static func closed() {
        closedAt = .now
    }

    /// The place the menu opened from, while it's open and for a moment after,
    /// as long as its view is still in a window.
    public static var current: Place? {
        current(at: .now)
    }

    static func current(at now: Date) -> Place? {
        guard let place, place.view?.window != nil else { return nil }
        if let closedAt, now.timeIntervalSince(closedAt) > lifetime { return nil }
        return place
    }
}
