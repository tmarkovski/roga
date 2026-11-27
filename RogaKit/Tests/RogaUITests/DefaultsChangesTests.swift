import Foundation
import Testing
@testable import RogaUI

/// Following a setting from the main actor never makes the thread that
/// changed the defaults wait for the main thread. When it did, AppKit's text
/// classes registering their defaults on another thread, while the main
/// thread laid out text, left both threads waiting for each other.
///
/// Other tests change defaults while these run, so each test only asks that
/// its own change was heard, not how many were.
@MainActor
@Suite(.serialized)
struct DefaultsChangesTests {
    @MainActor
    final class Heard {
        var count = 0
    }

    @Test func aChangeOnAnotherThreadDoesntWaitForTheMainThread() async {
        let heard = Heard()
        let observer = DefaultsChanges.observe { heard.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(Self.postElsewhereWhileTheMainThreadIsBusy())
        // Then it runs on the main actor once the main thread is free.
        #expect(await AgentTestSupport.eventually { heard.count >= 1 })
    }

    @Test func aChangeOnTheMainThreadIsHeardBeforeItReturns() {
        let heard = Heard()
        let observer = DefaultsChanges.observe { heard.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(heard.count >= 1)
    }

    /// Posts that the defaults changed from another thread while the main
    /// thread waits, as it does while it lays out text, and says whether the
    /// post came back. An observer that waited for the main thread would keep
    /// it from coming back until the wait gave up.
    private static func postElsewhereWhileTheMainThreadIsBusy() -> Bool {
        let posted = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
            posted.signal()
        }
        return posted.wait(timeout: .now() + 5) == .success
    }
}
