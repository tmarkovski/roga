import AppKit
import SwiftUI

/// The row along the top of the window, which Roga draws itself rather than
/// leaving to a toolbar, so that it's as tall as the Claude app's (decision 96).
/// The window has no title bar of its own to speak of: the traffic lights are
/// Roga's own, in this row's middle.
enum TitleBar {
    /// How tall the row is, as tall as a panel's header.
    static let height = PanelSplitLayout.headerHeight
    /// Where the close button starts, from the window's leading edge, as in
    /// the Claude app.
    static let trafficLightsLeading: CGFloat = 17
    /// Where the sidebar's button starts, from the window's leading edge, after
    /// the traffic lights. They end 77 points in, and the Claude app leaves 7
    /// points between them and the fill of its sidebar's button.
    static let sidebarButtonAfterLights: CGFloat = 84
    /// The room at the row's trailing end, after the button that hides the
    /// refs panel, the same in the middle's row and in the panel's header,
    /// so that the button doesn't move when it's clicked (decision 85).
    static let trailingInset: CGFloat = 6

    /// Where the sidebar's button starts: after the traffic lights, or in full
    /// screen, where they slide down with the menu bar, where they'd start.
    static func sidebarButtonLeading(isFullScreen: Bool) -> CGFloat {
        isFullScreen ? trafficLightsLeading : sidebarButtonAfterLights
    }

    /// How far from the window's leading edge the traffic lights and the
    /// sidebar's button reach, which the middle's part of the row keeps clear
    /// of wherever it is.
    static func cornerWidth(isFullScreen: Bool) -> CGFloat {
        sidebarButtonLeading(isFullScreen: isFullScreen) + IconButtonStyle().size
    }
}

/// Puts its content in the title row, at the window's top leading corner, over
/// whatever is there, wherever the view it's on starts.
struct TitleRowCorner<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: TitleBar.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .top)
    }
}

/// The window's traffic lights, as buttons of Roga's own in the title row.
///
/// The window's own are in a title bar of macOS's height, and macOS puts them
/// back in its corner each time it lays that out again: as the window's title
/// changes, as the sidebar shows or hides, as the window becomes key. Moving
/// them back after it does leaves a frame or two drawn with them in the
/// corner. So they stay hidden, and macOS makes these, the same buttons, which
/// close, minimize and zoom the window, gray out when it isn't key, and show
/// their symbols when the pointer is over any of them. macOS takes them for
/// the window's own once they're in it.
///
/// macOS's own title bar is still there, 32 points tall, across the top of the
/// row, where it moves the window and takes double-clicks. In full screen, the
/// window's own buttons show in the title bar that slides down with the menu
/// bar, and these don't, and it says so.
struct TrafficLights: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> ButtonsView {
        ButtonsView()
    }

    func updateNSView(_ view: ButtonsView, context: Context) {
        view.fullScreenChanged = { isFullScreen = $0 }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: ButtonsView, context: Context) -> CGSize? {
        view.intrinsicContentSize
    }

    final class ButtonsView: NSView {
        /// Each window's own buttons, which macOS made with its title bar, as
        /// it answered with them before any of these were in the window. Once
        /// these are, it answers with these, even after they've gone, so
        /// another of these views in the same window finds them here.
        private static let windowsOwnByWindow = NSMapTable<NSWindow, NSArray>.weakToStrongObjects()

        var fullScreenChanged: (Bool) -> Void = { _ in }
        private var buttons: [NSButton] = []
        /// The window's own buttons, hidden but in full screen.
        private var windowsOwn: [NSButton] = []
        /// How far apart macOS puts the window's own buttons.
        private var pitch: CGFloat = 23
        private var observers: [NSObjectProtocol] = []
        private var trackingArea: NSTrackingArea?
        /// Whether the pointer is over the buttons, where they show their
        /// symbols, all three together. The buttons ask `_mouseInGroup(_:)`
        /// only when they're told the pointer came or went, which the window's
        /// title bar does for its own with a method of theirs. Without it,
        /// they'd just never show their symbols.
        private var isPointerInside = false {
            didSet {
                guard isPointerInside != oldValue else { return }
                let changed = NSSelectorFromString("mouseEnteredOrExited")
                for button in buttons where button.responds(to: changed) {
                    button.perform(changed)
                }
            }
        }

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override var intrinsicContentSize: NSSize {
            guard let first = buttons.first else { return NSSize(width: 60, height: 14) }
            return NSSize(width: pitch * CGFloat(buttons.count - 1) + first.frame.width, height: first.frame.height)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            for button in buttons { button.removeFromSuperview() }
            buttons = []
            windowsOwn = []
            isPointerInside = false
            guard let window else { return }
            let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            if let known = Self.windowsOwnByWindow.object(forKey: window) as? [NSButton] {
                windowsOwn = known
            } else {
                windowsOwn = types.compactMap { window.standardWindowButton($0) }
                Self.windowsOwnByWindow.setObject(windowsOwn as NSArray, forKey: window)
            }
            if windowsOwn.count == types.count, windowsOwn[1].frame.minX > windowsOwn[0].frame.minX {
                pitch = windowsOwn[1].frame.minX - windowsOwn[0].frame.minX
            }
            buttons = types.compactMap { NSWindow.standardWindowButton($0, for: window.styleMask) }
            for button in buttons { addSubview(button) }
            invalidateIntrinsicContentSize()
            needsLayout = true
            observe(window)
            let isFullScreen = window.styleMask.contains(.fullScreen)
            fullScreenChanged(isFullScreen)
            showsWindowsOwn(isFullScreen)
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            // In case macOS shows the window's own again as it lays the title
            // bar out.
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window else { return }
                        self.showsWindowsOwn(window.styleMask.contains(.fullScreen))
                    }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fullScreenChanged(true)
                    self?.showsWindowsOwn(true)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fullScreenChanged(false)
                    self?.showsWindowsOwn(false)
                }
            })
        }

        /// Shows the window's own buttons, in full screen, and these
        /// otherwise.
        private func showsWindowsOwn(_ shows: Bool) {
            for button in windowsOwn where button.isHidden == shows {
                button.isHidden = !shows
            }
            for button in buttons where button.isHidden != shows {
                button.isHidden = shows
            }
        }

        override func layout() {
            super.layout()
            for (index, button) in buttons.enumerated() {
                let origin = NSPoint(x: CGFloat(index) * pitch, y: ((bounds.height - button.frame.height) / 2).rounded())
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
            if let window {
                let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
                isPointerInside = bounds.contains(pointer)
            }
        }

        override func mouseEntered(with event: NSEvent) {
            isPointerInside = true
        }

        override func mouseExited(with event: NSEvent) {
            isPointerInside = false
        }

        /// What the buttons ask their superview, to know whether to show their
        /// symbols. The window's title bar answers it for its own; without an
        /// answer here, they'd never show them.
        @objc func _mouseInGroup(_ button: NSButton) -> Bool {
            isPointerInside
        }
    }
}
