import AppKit
import MenuUI
import SwiftUI

/// Shows a popover at the place a menu opened from, such as a row in history or
/// in the refs panel, rather than under the view it's attached to (decision 83).
/// SwiftUI's own popover can only hang from the view it's on, and a row in
/// history is an AppKit table's row.
///
/// It follows `isPresented` both ways: it shows and closes as that changes, and
/// sets it to false when the popover closes by itself, as for a click elsewhere
/// or Escape. It shows its content as it is when it opens, so the content reads
/// anything that changes from a model rather than from its own arguments.
struct AnchoredPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let place: MenuAnchor.Place?
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let isPresented = $isPresented
        coordinator.closedByItself = { isPresented.wrappedValue = false }
        if self.isPresented, let place, let anchor = place.view, anchor.window != nil {
            coordinator.show(content(), at: place, in: anchor)
        } else {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        /// Whether the popover is closing because `isPresented` turned false, which
        /// mustn't be set again from inside an update.
        private var isClosing = false
        var closedByItself: () -> Void = {}

        func show(_ content: Content, at place: MenuAnchor.Place, in anchor: NSView) {
            guard popover == nil else { return }
            let controller = NSHostingController(rootView: content)
            // The popover follows the content's size, as when a refusal appears
            // under the field.
            controller.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.delegate = self
            self.popover = popover
            popover.show(relativeTo: place.rect, of: anchor, preferredEdge: place.edge ?? place.edgeTowardMiddle)
        }

        func close() {
            guard let popover else { return }
            isClosing = true
            popover.close()
            isClosing = false
            self.popover = nil
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            if !isClosing { closedByItself() }
        }
    }
}
