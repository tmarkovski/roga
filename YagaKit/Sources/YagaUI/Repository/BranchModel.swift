import Foundation
import GitCore
import GitRunner
import Observation
import RepositoryEngine

/// A worktree's branch in the title row: where it stands against its upstream,
/// and fetching, pulling, pushing and starting a new branch (decisions 19 and
/// 20). All of this acts on the branch the worktree has checked out, whatever is
/// selected in history.
@Observable
final class BranchModel {
    /// What git is doing because someone asked it to. Nothing else runs until
    /// it finishes.
    enum Action: Equatable {
        case pulling
        case pushing
        case forcePushing
        case fetching
        case undoingPull

        var title: String {
            switch self {
            case .pulling: "Pulling…"
            case .pushing: "Pushing…"
            case .forcePushing: "Force pushing…"
            case .fetching: "Fetching…"
            case .undoingPull: "Undoing…"
            }
        }
    }

    /// Which way the commits go, for a count in the title row.
    enum Direction: Equatable {
        case pull
        case push
    }

    /// Something git refused, and what it said about that.
    struct Failure: Equatable {
        var title: String
        var message: String
    }

    /// A pull that hit a conflict, which yaga can't resolve, so it asks whether
    /// to undo the pull or leave it for the command line.
    struct Conflict: Equatable {
        var pull: StoppedPull
        /// The files in conflict. git prints these to its standard output, which
        /// a failure doesn't keep, so they come from asking it again.
        var files: [String]
    }

    /// A force push that's waiting for someone to agree to what it overwrites.
    struct ForcePush: Equatable {
        var branch: String
        var upstream: String
        /// How many commits it overwrites, and the subjects of the first few.
        var count: Int
        var subjects: [String]
    }

    /// The most subjects to list before a force push.
    private static let overwrittenLimit = 5
    /// The most commits to tint in history while the pointer is over a count.
    private static let previewLimit = 1000
    /// How long what happened stays in the title row.
    private static let finishedDuration = Duration.seconds(3)

    let session: RepositorySession
    /// The worktree's folder.
    let worktree: String
    /// Where the branch stands, or nil when the worktree isn't on a branch, or
    /// its branch has no commits yet.
    private(set) var status: BranchStatus?
    /// What became of the repository's latest fetch.
    private(set) var fetchRecord = FetchRecord()
    /// Whether yaga is fetching by itself, which only the branch's menu mentions.
    private(set) var isFetchingByItself = false
    /// What git is doing because someone asked it to.
    private(set) var action: Action?
    /// What just happened, as in `Pulled 3`, for a moment.
    private(set) var finished: String?
    /// What to tell the user about something that didn't work, until they've
    /// seen it.
    var failure: Failure?
    /// A pull that stopped on a conflict, until the user has said what to do.
    var conflict: Conflict?
    /// A force push that's waiting for someone to agree to it.
    var forcePush: ForcePush?
    /// Whether the popover for a new branch shows.
    var isCreatingBranch = false

    /// Whether the user wants yaga to fetch by itself.
    @ObservationIgnored private let fetchesByItself: () -> Bool
    /// Says that the worktree or its branches changed, because of something yaga
    /// did, and returns once the sidebar knows.
    @ObservationIgnored private let reportBranchChange: () async -> Void
    /// Whether a checkout is running, which nothing here may run alongside.
    @ObservationIgnored var isCheckingOut: () -> Bool = { false }
    /// Asks the worktree's model to look at what a fetch or a pull may have moved.
    @ObservationIgnored var lookAgain: () -> Void = {}
    /// Asks history to tint these commits, or none.
    @ObservationIgnored var showPreview: ([ObjectID]) -> Void = { _ in }
    @ObservationIgnored private(set) var running: Task<Void, Never>?
    @ObservationIgnored private(set) var quietFetch: Task<Void, Never>?
    @ObservationIgnored private(set) var previewing: Task<Void, Never>?
    @ObservationIgnored private var finishedNote: Task<Void, Never>?

    init(
        session: RepositorySession,
        worktree: String,
        fetchesByItself: @escaping () -> Bool = { UserDefaults.standard.fetchesByItself },
        reportBranchChange: @escaping () async -> Void = {}
    ) {
        self.session = session
        self.worktree = worktree
        self.fetchesByItself = fetchesByItself
        self.reportBranchChange = reportBranchChange
    }

    /// Reads where the branch stands. When git can't say, it keeps what it knew.
    func refresh() async {
        guard let status = try? await session.branchStatus(in: worktree) as BranchStatus??, !Task.isCancelled else { return }
        self.status = status
        if fetchRecord == FetchRecord() { fetchRecord = await session.lastFetch() }
    }

    /// The branch's short name.
    private var branchName: String { status.map { Ref.shortName($0.branch) } ?? "" }

    /// The upstream's short name, or nil when there's none.
    private var upstreamName: String? { status?.upstream.map(Ref.shortName) }

    /// Whether anything that someone asks for has to wait.
    var isBusy: Bool { action != nil || isCheckingOut() }

    // MARK: Fetching

    /// Fetches because yaga became active or a window started showing the
    /// repository, unless the user turned that off (decision 20). Nothing shows
    /// while it runs or if it fails, except in the branch's menu. The session
    /// decides whether it's been long enough since the last one.
    func fetchByItself() {
        guard fetchesByItself(), action == nil, quietFetch == nil, let remote = status?.remote else { return }
        isFetchingByItself = true
        quietFetch = Task {
            let before = fetchRecord
            let record = await session.fetchQuietly(from: remote)
            fetchRecord = record
            isFetchingByItself = false
            quietFetch = nil
            if record != before { lookAgain() }
        }
    }

    /// Fetches because someone asked to.
    func fetch() {
        guard let remote = status?.remote else { return }
        run(.fetching, failure: "Can't Fetch from \(remote)") { [session, worktree] in
            try await session.fetch(from: remote, in: worktree)
            return "Fetched"
        }
    }

    // MARK: Pulling

    /// Pulls the way clicking `↓` does, which needs the user's configuration to
    /// say how when the branch has diverged.
    func pull() {
        if let pull = status?.pull { self.pull(pull) }
    }

    func pull(_ pull: Pull) {
        let count = status?.behind ?? 0
        run(.pulling, failure: "Can't Pull \(branchName)") { [session, worktree] in
            let wasStopped = (try? await session.stoppedPull(in: worktree)) != nil
            do {
                try await session.pull(pull, in: worktree)
            } catch {
                // git hit a conflict just now, so this is the pull's own mess to
                // clean up, rather than one that was there already.
                if !wasStopped, let stopped = try? await session.stoppedPull(in: worktree) {
                    let status = try? await session.status(in: worktree)
                    self.conflict = Conflict(pull: stopped, files: status?.conflicted.map(\.path) ?? [])
                    return nil
                }
                throw error
            }
            return count > 0 ? "Pulled \(count.formatted())" : "Pulled"
        }
    }

    /// Goes back to before the pull that stopped on a conflict.
    func undoPull() {
        guard let conflict else { return }
        self.conflict = nil
        run(.undoingPull, failure: "Can't Undo the Pull") { [session, worktree] in
            try await session.undo(conflict.pull, in: worktree)
            return "Undid the pull"
        }
    }

    // MARK: Pushing

    /// Pushes the way clicking `↑` does.
    func push() {
        guard let push = status?.push else { return }
        let count = status?.ahead ?? 0
        run(.pushing, failure: "Can't Push \(branchName)", fetchesAfterFailing: true) { [session, worktree] in
            try await session.push(push, in: worktree)
            return count > 0 ? "Pushed \(count.formatted())" : "Pushed"
        }
    }

    /// Finds out what a force push would overwrite, and asks about that.
    func askToForcePush() {
        guard !isBusy, let status, let upstream = status.upstream else { return }
        preview(nil)
        Task {
            let overwritten = (try? await session.commits(from: "HEAD", to: upstream, limit: Self.overwrittenLimit, in: worktree)) ?? []
            let commits = (try? await session.commits(overwritten)) ?? []
            forcePush = ForcePush(
                branch: Ref.shortName(status.branch),
                upstream: Ref.shortName(upstream),
                count: status.behind,
                subjects: commits.compactMap { $0?.subject }
            )
        }
    }

    /// Runs the force push that was asked about.
    func confirmForcePush() {
        forcePush = nil
        run(.forcePushing, failure: "Can't Force Push \(branchName)", fetchesAfterFailing: true) { [session, worktree] in
            try await session.push(.forceWithLease, in: worktree)
            return "Pushed"
        }
    }

    // MARK: New branches

    /// Makes a new branch, and shows its worktree if it gets one.
    ///
    /// - Returns: What git said if it refused, which the popover shows.
    func create(_ branch: NewBranch, showWorktree: @escaping (String, ObjectID?) -> Void) async -> String? {
        guard !isBusy else { return nil }
        do {
            try await session.create(branch, in: worktree)
        } catch {
            return (error as? GitError)?.message ?? String(describing: error)
        }
        isCreatingBranch = false
        // The window can only show a worktree the sidebar knows about.
        await reportBranchChange()
        lookAgain()
        if branch.inNewWorktree,
           let created = try? await session.worktrees().first(where: { $0.branch == Ref.branchPrefix + branch.name }) {
            showWorktree(created.path, created.head)
        }
        return nil
    }

    // MARK: Running

    /// Runs what someone asked for, unless something's running already, and
    /// looks at what it changed.
    ///
    /// - Parameters:
    ///   - title: What an alert says when git refuses.
    ///   - fetchesAfterFailing: Whether a refusal may mean the counts were stale,
    ///     as a rejected push does, so a fetch should correct them.
    ///   - work: Returns what to say when it's done, if anything.
    private func run(
        _ action: Action,
        failure title: String,
        fetchesAfterFailing: Bool = false,
        work: @escaping () async throws -> String?
    ) {
        guard !isBusy else { return }
        // The count under the pointer is about to go, and it won't say the
        // pointer has left.
        preview(nil)
        self.action = action
        finished = nil
        running = Task {
            do {
                if let message = try await work() { show(finished: message) }
            } catch {
                failure = Failure(title: title, message: (error as? GitError)?.message ?? String(describing: error))
                if fetchesAfterFailing, fetchesByItself(), let remote = status?.remote {
                    fetchRecord = await session.fetchQuietly(from: remote, minimumInterval: .zero)
                }
            }
            fetchRecord = await session.lastFetch()
            self.action = nil
            running = nil
            lookAgain()
            await reportBranchChange()
        }
    }

    private func show(finished message: String) {
        finished = message
        finishedNote?.cancel()
        finishedNote = Task {
            guard (try? await Task.sleep(for: Self.finishedDuration)) != nil else { return }
            finished = nil
        }
    }

    // MARK: Previewing

    /// Tints the commits that a count would move while the pointer is over it, or
    /// none once it has left.
    func preview(_ direction: Direction?) {
        previewing?.cancel()
        guard let direction, let upstream = status?.upstream else {
            showPreview([])
            return
        }
        let (base, tip) = direction == .pull ? ("HEAD", upstream) : (upstream, "HEAD")
        previewing = Task {
            let ids = (try? await session.commits(from: base, to: tip, limit: Self.previewLimit, in: worktree)) ?? []
            if !Task.isCancelled { showPreview(ids) }
        }
    }

    // MARK: What the title row says

    /// The tooltip of `↓`, which says what clicking it would do.
    var pullHelp: String {
        guard let status else { return "" }
        let upstream = upstreamName ?? ""
        guard let pull = status.pull else {
            return "\(branchName) has diverged from \(upstream). Click to choose whether to rebase or merge."
        }
        return "\(Self.commits(status.behind, "Pull")) from \(upstream) into \(branchName)\n\(Self.command(pull.arguments))"
    }

    /// The tooltip of `↑`, which says what clicking it would do.
    var pushHelp: String {
        guard let status else { return "" }
        guard let push = status.push else {
            return "\(branchName) is behind \(upstreamName ?? "its upstream"), so git would reject a push. Click for what you can do."
        }
        if case .firstTime(let remote) = push {
            return "Push \(branchName) to \(remote) for the first time\n\(Self.command(push.arguments))"
        }
        return "\(Self.commits(status.ahead, "Push")) from \(branchName) to \(upstreamName ?? "")\n\(Self.command(push.arguments))"
    }

    private static func commits(_ count: Int, _ verb: String) -> String {
        count == 1 ? "\(verb) 1 commit" : "\(verb) \(count.formatted()) commits"
    }

    /// A command as someone would type it.
    static func command(_ arguments: [String]) -> String {
        "git " + arguments.joined(separator: " ")
    }

    /// The first line of the branch's menu: its upstream, how far the branch is
    /// from it, and when yaga last fetched.
    func summary(now: Date = Date()) -> String {
        var parts: [String] = []
        if let failure = fetchRecord.failure, !failure.isEmpty, !isFetchingByItself, action != .fetching, let remote = status?.remote {
            parts.append("couldn't reach \(remote)")
        } else if let status {
            if let upstream = status.upstream {
                parts.append(Ref.shortName(upstream))
                switch (status.behind, status.ahead) {
                case (0, 0): parts.append("up to date")
                case (let behind, 0): parts.append("\(behind.formatted()) behind")
                case (0, let ahead): parts.append("\(ahead.formatted()) ahead")
                case (let behind, let ahead): parts.append("\(behind.formatted()) behind, \(ahead.formatted()) ahead")
                }
            } else if status.upstreamIsGone {
                parts.append("its upstream is gone")
            } else if status.pushRemote != nil {
                parts.append("not pushed yet")
            } else {
                parts.append("no remote")
            }
        }
        if isFetchingByItself || action == .fetching {
            parts.append("fetching…")
        } else if let date = fetchRecord.lastFetched {
            parts.append("fetched " + Self.age(of: date, now: now))
        }
        return parts.joined(separator: " · ")
    }

    /// As in `4 min ago`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86400: return "\(seconds / 3600) h ago"
        default: return "\(seconds / 86400) d ago"
        }
    }
}
