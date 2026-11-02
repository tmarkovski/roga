import GitRunner
import Observation

/// Finds the git that yaga runs, once, when yaga launches. Every window uses
/// the same one.
@Observable
public final class GitProvider {
    public enum State {
        case locating
        case ready(Git)
        case failed(GitInstallationError)
    }

    public private(set) var state = State.locating

    public init() {
        Task { await locate() }
    }

    public var git: Git? {
        if case .ready(let git) = state { git } else { nil }
    }

    private func locate() async {
        do {
            state = .ready(Git(installation: try await GitInstallation.locate()))
        } catch {
            state = .failed(error)
        }
    }
}
