import AppKit
import SwiftUI

/// The row along the top of the window, which Roga draws itself rather than
/// leaving to a toolbar, so that it's as tall as the Claude app's (decision 96).
/// The window has no title bar of its own to speak of: its traffic lights sit
/// in this row, in its middle.
enum TitleBar {
    /// How tall the row is, as tall as a panel's header.
    static let height = PanelSplitLayout.headerHeight
    /// Where the close button starts, from the window's leading edge.
    static let trafficLightsLeading: CGFloat = 16
    /// How much of the row the traffic lights take from its leading edge,
    /// with the room after them, where the sidebar's button goes.
    static let trafficLightsRoom: CGFloat = 78
    /// The room at the row's trailing end, after the button that hides the
    /// refs panel, the same in the middle's row and in the panel's header,
    /// so that the button doesn't move when it's clicked (decision 85).
    static let trailingInset: CGFloat = 6
}

/// Puts the window's traffic lights in the middle of the title row, and keeps
/// them there. macOS places them for a title bar of its own height, and puts
/// them back as it lays the title bar out again: as the window resizes or
/// becomes key, and sometimes as one of them is moved. So this watches the
/// title bar and the buttons, and places them again on the next turn of the
/// run loop each time one of them moves. In full screen they're in a title bar
/// that slides down over the window, and they're left alone.
///
/// It also says whether the window is in full screen, where the row doesn't
/// keep room for them.
struct TrafficLightsPlacement: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeNSView(context: Context) -> PlacementView {
        PlacementView()
    }

    func updateNSView(_ view: PlacementView, context: Context) {
        view.fullScreenChanged = { isFullScreen = $0 }
    }

    final class PlacementView: NSView {
        var fullScreenChanged: (Bool) -> Void = { _ in }
        private var observers: [NSObjectProtocol] = []
        /// Whether the window is on its way into or out of full screen, while
        /// macOS moves the title bar between windows.
        private var isChangingFullScreen = false
        /// Whether the buttons are being placed, since moving them is noticed
        /// here too.
        private var isPlacing = false
        /// How far apart macOS puts the buttons, from the first time they're
        /// seen where it put them, since they're moved one at a time.
        private var pitch: CGFloat?
        /// Whether placing them again is waiting for the next turn of the run
        /// loop.
        private var isPlaceAgainPending = false
        /// How many times in a row they've been placed again without staying
        /// put, which stops at a few, so that this and AppKit can't move them
        /// back and forth forever.
        private var placementsInARow = 0

        isolated deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            let placeAgain: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeBackingPropertiesNotification,
            ]
            for name in placeAgain {
                observers.append(center.addObserver(forName: name, object: window, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.place() }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isChangingFullScreen = true
                    self?.fullScreenChanged(true)
                }
            })
            observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.isChangingFullScreen = false }
            })
            observers.append(center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.isChangingFullScreen = true }
            })
            observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isChangingFullScreen = false
                    self?.fullScreenChanged(false)
                    self?.place()
                }
            })
            // AppKit lays the title bar out again at times no notification
            // says, such as when the window's appearance changes.
            if let titleBar = window.standardWindowButton(.closeButton)?.superview {
                let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
                for view in [titleBar, titleBar.superview].compactMap(\.self) + buttons {
                    view.postsFrameChangedNotifications = true
                    observers.append(center.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: nil) { [weak self] _ in
                        MainActor.assumeIsolated { self?.placeAgain() }
                    })
                }
            }
            fullScreenChanged(window.styleMask.contains(.fullScreen))
            place()
        }

        /// Places the buttons again on the next turn of the run loop, once
        /// whatever moved them is done, unless that's already waiting.
        private func placeAgain() {
            guard !isPlacing, !isPlaceAgainPending else { return }
            guard placementsInARow < 4 else { return }
            isPlaceAgainPending = true
            placementsInARow += 1
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaceAgainPending = false
                    self.place()
                    // Once they've stayed put for a moment, a later move
                    // starts the count again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        MainActor.assumeIsolated { self?.placementsInARow = 0 }
                    }
                }
            }
        }

        /// Makes the title bar as tall as the row, and puts the buttons in its
        /// middle, `TitleBar.trafficLightsLeading` from the window's edge and as
        /// far apart as macOS puts them. Each change is made only when something
        /// isn't where it goes.
        private func place() {
            guard let window, !isPlacing, !isChangingFullScreen, !window.styleMask.contains(.fullScreen) else { return }
            isPlacing = true
            defer { isPlacing = false }
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            guard buttons.count == 3, let titleBar = buttons[0].superview,
                  let container = titleBar.superview, let frameView = container.superview else { return }
            let height = TitleBar.height
            var frame = container.frame
            let top = frameView.isFlipped ? 0 : frameView.bounds.height - height
            if frame.height != height || frame.minY != top {
                frame.size.height = height
                frame.origin.y = top
                container.frame = frame
            }
            if titleBar.frame != container.bounds {
                titleBar.frame = container.bounds
            }
            let pitch = self.pitch ?? buttons[1].frame.minX - buttons[0].frame.minX
            self.pitch = pitch
            for (index, button) in buttons.enumerated() {
                let origin = NSPoint(
                    x: TitleBar.trafficLightsLeading + CGFloat(index) * pitch,
                    y: ((height - button.frame.height) / 2).rounded()
                )
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                }
            }
        }
    }
}
