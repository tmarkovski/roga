import AppKit
import SwiftUI

extension View {
    /// Opens a popover as the mouse button goes down on the view, as Roga's own
    /// menus open, where a button would wait for the button to come back up. A
    /// press while the popover is open closes it.
    ///
    /// Only a press with the mouse comes here, so the view keeps its own button
    /// or action for the keyboard and for VoiceOver's press. Hover, tooltips and
    /// right-clicks still reach it too. A disabled view does nothing on a press,
    /// and keeps its tooltip, which says why.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the popover is open, which a press while it is
    ///     sets to false.
    ///   - isEnabled: Whether a press does anything, as well as the view's own
    ///     `disabled`.
    ///   - open: What a press does while the popover is closed, which is setting
    ///     `isPresented` unless it's given.
    func opensOnPress(_ isPresented: Binding<Bool>, isEnabled: Bool = true, open: (() -> Void)? = nil) -> some View {
        overlay {
            GeometryReader { proxy in
                PressArea(size: proxy.size, isOpen: isPresented.wrappedValue, isEnabled: isEnabled) {
                    if let open { open() } else { isPresented.wrappedValue = true }
                } close: {
                    isPresented.wrappedValue = false
                }
                // Only a corner, at the view's top left, so the view stays the
                // only thing under the pointer. In the title row, a drag that
                // starts on a button doesn't move the window, while one that
                // starts on an AppKit view over it can, as one over a tab does.
                .frame(width: 0, height: 0)
            }
        }
    }
}

/// Finds a press with the mouse on the view whose corner it's at, as it
/// arrives, before anything in the window sees it, and opens or closes the
/// popover. The press goes on to the view, the drag after it doesn't, and the
/// release goes on far away from the view.
private struct PressArea: NSViewRepresentable {
    let size: CGSize
    let isOpen: Bool
    let isEnabled: Bool
    let open: () -> Void
    let close: () -> Void

    func makeNSView(context: Context) -> PressAreaView {
        PressAreaView()
    }

    func updateNSView(_ view: PressAreaView, context: Context) {
        view.size = size
        view.isEnabled = isEnabled && context.environment.isEnabled
        view.isOpen = isOpen
        view.open = open
        view.close = close
    }
}

final class PressAreaView: NSView {
    /// The size of the view whose top left corner this one is at.
    var size: CGSize = .zero
    var isEnabled = true
    /// Whether the popover was open when the view last heard.
    var isOpen = false
    var open: () -> Void = {}
    var close: () -> Void = {}
    private var monitor: Any?
    /// Whether the mouse button is down after a press the view took.
    private var isHoldingPress = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isHoldingPress = false
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return handle(event)
        }
    }

    /// What goes on in place of `event`, if anything.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            guard isPressed(by: event) else { return event }
            isHoldingPress = true
            if isOpen { close() } else { open() }
            // The press itself goes on to the window, which has to see it.
            // Kept back, macOS takes it in the title row for the start of
            // moving the window.
            return event
        case .leftMouseDragged:
            // Nothing in the window follows a press the view already acted on.
            return isHoldingPress ? nil : event
        case .leftMouseUp:
            guard isHoldingPress else { return event }
            isHoldingPress = false
            // The window has to see the release too, or it holds on to the
            // keyboard and the popover doesn't take Escape. It gets one far
            // away from the view, so the view's own button doesn't act again,
            // as a button released outside itself doesn't.
            return NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: -100_000, y: -100_000),
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                eventNumber: event.eventNumber,
                clickCount: event.clickCount,
                pressure: event.pressure
            )
        default:
            return event
        }
    }

    /// Whether `event` is a press on the view this one is at the corner of.
    /// While another popover is open, it's the key window, and a press on the
    /// window only closes that popover, as one on a button does. While this
    /// view's own popover is open, a press on the view closes it.
    private func isPressed(by event: NSEvent) -> Bool {
        guard isEnabled, size.width > 0, size.height > 0,
              let window, event.window === window, !isHiddenOrHasHiddenAncestor,
              // A Control-click is a right-click.
              !event.modifierFlags.contains(.control),
              window.isKeyWindow || isOpen
        else { return false }
        let corner = convert(NSPoint.zero, to: nil)
        let frame = NSRect(x: corner.x, y: corner.y - size.height, width: size.width, height: size.height)
        guard frame.contains(event.locationInWindow),
              // Nothing else is in front at that point.
              let frameView = window.contentView?.superview ?? window.contentView,
              let hit = frameView.hitTest(event.locationInWindow)
        else { return false }
        return isDescendant(of: hit)
    }
}
