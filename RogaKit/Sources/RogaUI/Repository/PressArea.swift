import AppKit
import SwiftUI

extension View {
    /// Opens a popover as the mouse button goes down on the view, as Roga's own
    /// menus open (decision 111), where a button would wait for the button to
    /// come back up. Clicking it again while the popover is open closes it.
    ///
    /// Only a press with the mouse comes here, so the view keeps its own button
    /// or action for the keyboard and for VoiceOver's press. Hover, tooltips and
    /// right-clicks still reach it too. A disabled view does nothing on a press,
    /// and keeps its tooltip, which says why.
    ///
    /// - Parameters:
    ///   - isPresented: Whether the popover is open, which a press while it
    ///     is sets to false.
    ///   - isEnabled: Whether a press does anything, as well as the view's own
    ///     `disabled`.
    ///   - open: What a press does while the popover is closed, which is setting
    ///     `isPresented` unless it's given.
    func opensOnPress(_ isPresented: Binding<Bool>, isEnabled: Bool = true, open: (() -> Void)? = nil) -> some View {
        overlay {
            PressArea(isOpen: isPresented.wrappedValue, isEnabled: isEnabled) {
                if let open { open() } else { isPresented.wrappedValue = true }
            } close: {
                isPresented.wrappedValue = false
            }
        }
    }
}

/// Takes a press with the mouse on the view under it, and lets every other
/// event through, as `RefMenuArea` does. The view under it never sees the
/// press, so its own button doesn't act again as the mouse button comes up.
private struct PressArea: NSViewRepresentable {
    let isOpen: Bool
    let isEnabled: Bool
    let open: () -> Void
    let close: () -> Void

    func makeNSView(context: Context) -> PressAreaView {
        PressAreaView()
    }

    func updateNSView(_ view: PressAreaView, context: Context) {
        view.isEnabled = isEnabled && context.environment.isEnabled
        view.isOpen = isOpen
        view.open = open
        view.close = close
    }
}

final class PressAreaView: NSView {
    var isEnabled = true
    var isOpen = false
    var open: () -> Void = {}
    var close: () -> Void = {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, let event = NSApp.currentEvent, event.type == .leftMouseDown,
              // A Control-click is a right-click.
              !event.modifierFlags.contains(.control) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if isOpen { close() } else { open() }
    }
}
