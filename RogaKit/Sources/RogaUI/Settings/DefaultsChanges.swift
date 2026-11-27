import Foundation

/// Hears that the user's defaults changed, for a model on the main actor that
/// follows a setting, such as whether the house plays or which agent is the
/// default.
///
/// An observer added with `queue: .main` makes whatever thread changed the
/// defaults wait until the main thread has run it. AppKit's text classes
/// register their own defaults the first time they're used, which can be on
/// another thread, as when a diff's metrics are measured away from the main
/// actor. If the main thread is waiting for that same class to finish
/// starting up at that moment, as it is when it lays out text, neither thread
/// can go on. So this hears the change on the thread that made it, and asks
/// the main actor to run `changed` without waiting for it. A change made on
/// the main thread still runs `changed` before the change returns.
enum DefaultsChanges {
    /// Starts hearing changes. Remove what it returns from the default
    /// notification center to stop.
    static func observe(_ changed: @escaping @MainActor @Sendable () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated(changed)
            } else {
                Task { @MainActor in changed() }
            }
        }
    }
}
