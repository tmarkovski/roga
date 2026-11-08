import Combine
import Foundation
import RogaUI
import Sparkle

/// Sparkle, and RogaUI's `Updates` kept in step with it. It lives in the app
/// target because only the app target links Sparkle.
///
/// A check Sparkle runs by itself doesn't open Sparkle's window. It leaves a
/// notice in every window instead, through Sparkle's gentle reminders, and the
/// notice stays until the update installs or the person skips that version in
/// Sparkle's window. Clicking it brings up that window. When Sparkle downloads
/// updates by itself, the notice offers to restart instead, and installs the
/// download straight away.
final class SparkleUpdates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UpdaterControls {
    let updates: Updates
    private var controller: SPUStandardUpdaterController!
    /// What installs the downloaded update and relaunches, which Sparkle hands
    /// over once the download is ready to install when Roga quits.
    private var installsNow: (() -> Void)?
    private var subscriptions: Set<AnyCancellable> = []

    var updater: SPUUpdater { controller.updater }

    init(updates: Updates) {
        self.updates = updates
        super.init()
        // Sparkle starts only in Release builds that have the public key
        // updates are signed with. A development build never looks for
        // updates: its build number is 1, and a release's is the number of
        // commits, so every release would look newer and offer to replace it.
        #if DEBUG
        let canUpdate = false
        #else
        let canUpdate = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: canUpdate, updaterDelegate: self, userDriverDelegate: self)
        guard canUpdate else { return }
        updates.controls = self
        // Sparkle's own window can change these too, with its checkbox for
        // downloading and installing updates from now on.
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [updates] in updates.checksAutomatically = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [updates] in updates.downloadsAutomatically = $0 }
            .store(in: &subscriptions)
    }

    // MARK: UpdaterControls

    func setChecksAutomatically(_ checks: Bool) {
        updater.automaticallyChecksForUpdates = checks
    }

    func setDownloadsAutomatically(_ downloads: Bool) {
        updater.automaticallyDownloadsUpdates = downloads
    }

    func showUpdate() {
        updater.checkForUpdates()
    }

    func installNow() {
        if let installsNow {
            installsNow()
        } else {
            updater.checkForUpdates()
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Roga shows every update a scheduled check finds itself, so Sparkle's
    /// window never opens over someone's work.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        // Sparkle shows what someone checked for in its window, and the
        // notice comes only if they put it off.
        guard !handleShowingUpdate else { return }
        updates.pending = .found(version: update.displayVersionString)
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .skip:
            installsNow = nil
            updates.pending = nil
        case .dismiss:
            // Remind Me Later keeps the notice, so that it can be found again.
            if updates.pending?.version != updateItem.displayVersionString || installsNow == nil {
                updates.pending = .found(version: updateItem.displayVersionString)
            }
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installsNow = immediateInstallHandler
        updates.pending = .downloaded(version: item.displayVersionString)
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        installsNow = nil
        updates.pending = nil
    }
}
