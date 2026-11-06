import Observation

/// What `Updates` needs from Sparkle. Only the app target links Sparkle, so it
/// provides this, the way `CheckForUpdatesButton` reaches Sparkle for the menu.
public protocol UpdaterControls: AnyObject {
    func setChecksAutomatically(_ checks: Bool)
    func setDownloadsAutomatically(_ downloads: Bool)
    /// Brings up Sparkle's window for the update that was found, with its
    /// release notes and Install button.
    func showUpdate()
    /// Installs the update that was downloaded, and relaunches Roga.
    func installNow()
}

/// New versions of Roga, as the windows and Settings see them. Sparkle finds
/// them once a day and, rather than opening its own window, leaves a notice
/// above the gear at the bottom of the rail, or at the bottom of the sidebar's
/// list while the rail is hidden. The app target keeps this up to date from
/// Sparkle.
@Observable public final class Updates {
    /// A new version that's waiting for the person.
    public enum Pending: Equatable {
        /// Found, and Sparkle's window can show it.
        case found(version: String)
        /// Downloaded, and set to install when Roga quits, or straight away
        /// from the notice.
        case downloaded(version: String)

        public var version: String {
            switch self {
            case .found(let version), .downloaded(let version): version
            }
        }

        /// What the notice says, and what its tooltip and VoiceOver say on the
        /// rail.
        var title: String {
            switch self {
            case .found(let version): "Update to \(version)"
            case .downloaded: "Restart to Update"
            }
        }
    }

    /// The version waiting, or nil when Roga is up to date as far as it knows.
    public var pending: Pending?
    /// Whether Sparkle looks for updates by itself, once a day.
    public var checksAutomatically = false
    /// Whether Sparkle downloads what it finds, to install when Roga quits.
    public var downloadsAutomatically = false

    /// Sparkle, while it runs. Development builds don't start it, because only
    /// releases have the key that updates are checked against.
    @ObservationIgnored public weak var controls: UpdaterControls? {
        didSet { canUpdate = controls != nil }
    }

    /// Whether this copy of Roga updates itself at all.
    public private(set) var canUpdate = false

    public init() {}

    /// Turns the daily check on or off, from Settings.
    func setChecksAutomatically(_ checks: Bool) {
        checksAutomatically = checks
        controls?.setChecksAutomatically(checks)
    }

    /// Turns downloading on or off, from Settings.
    func setDownloadsAutomatically(_ downloads: Bool) {
        downloadsAutomatically = downloads
        controls?.setDownloadsAutomatically(downloads)
    }

    /// What clicking the notice does: shows a found update in Sparkle's window,
    /// or installs a downloaded one and relaunches.
    func open() {
        switch pending {
        case .found: controls?.showUpdate()
        case .downloaded: controls?.installNow()
        case nil: break
        }
    }
}
