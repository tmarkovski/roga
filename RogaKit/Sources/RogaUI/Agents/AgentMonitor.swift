import AgentEngine
import AgentHooks
import AppKit
import Dispatch
import Foundation
import GitCore
import Observation

/// What agents are doing, from what their hooks tell Roga, for the marks on the
/// sidebar's rows (decision 41).
///
/// There's one for the whole app. It listens on Roga's socket, feeds the events
/// to `AgentSessions`, and clears what the hooks leave stale in the two ways
/// decision 41 allows: it watches each agent's process and ends its sessions
/// when it exits, and it asks `claude agents --json` about Claude Code's
/// sessions at launch and whenever one has said it's working for a while
/// without a word since. A session that only that answer told Roga about,
/// with no hook event since, is also asked about at every check while it
/// waits, because it may never send one. It never guesses from files changing.
///
/// While this copy of Roga can't hear the hooks, because another copy has the
/// socket or it couldn't be opened, it asks Claude Code nothing, so no marks
/// show: Settings says why instead.
@MainActor @Observable
public final class AgentMonitor {
    /// Whether Roga hears from agents' hooks.
    enum Listening: Equatable {
        case starting
        case listening
        /// Another copy of Roga with the same bundle ID has the socket, so this
        /// copy can't show marks.
        case anotherCopy
        /// The socket couldn't be opened, for this reason.
        case failed(String)
    }

    /// Roga's folder in Application Support, where the socket is.
    let supportFolder: URL
    private(set) var listening = Listening.starting
    /// Every session Roga knows about. It changes with nearly every event, so
    /// views draw from `summary(forWorktree:in:)`, which changes only when a
    /// mark would.
    private(set) var sessions: [SessionKey: AgentSession] = [:]
    /// The latest event from each agent, for Settings to say when Roga last
    /// heard from it and in which folder the session that sent it is. That's
    /// the session's own folder, as `AgentSessions` keeps it, rather than the
    /// event's, since Codex's tool events name the folder the command runs in.
    private(set) var lastHeard: [AgentHost: AgentProvider.Heard] = [:]
    /// The latest event's time from each agent, which `lastHeard` can be
    /// behind, so that a late event is still told apart.
    @ObservationIgnored private var latestHeard: [AgentHost: Date] = [:]

    /// What the marks need of each session: it changes far less often than the
    /// sessions do, since every tool an agent runs moves its `lastEvent`, and
    /// the sidebar's rows read only this, so that they don't redraw for each one.
    private var marks: [SessionKey: Mark] = [:]
    /// When someone last looked at each worktree, by its folder as git lists it.
    /// It's kept in memory only: after a relaunch, what finished before is old
    /// news.
    private var seen: [String: Date] = [:]

    @ObservationIgnored private var state = AgentSessions()
    @ObservationIgnored private var agents: AgentProvider?
    @ObservationIgnored private var listener: HookListener?
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// What asks Claude Code what's running each time Roga can keep its
    /// sessions current.
    @ObservationIgnored private var seeding: Task<Void, Never>?
    /// What asks about quiet sessions.
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private let checkInterval: Duration?
    @ObservationIgnored private var isAskingClaude = false
    /// Whether Roga still has to ask what's running, because it became able to
    /// keep Claude Code's sessions while a question about quiet ones was under
    /// way.
    @ObservationIgnored private var seedingIsDue = false
    /// Whether the loop that asks what's running last saw that Roga could
    /// keep Claude Code's sessions, so that it asks again only once that
    /// stops and comes true anew. Tests wait on it.
    @ObservationIgnored private(set) var couldSeed = false
    /// The quiet sessions that asking Claude Code said nothing about, by the
    /// time of their last event then: it didn't list them, or gave them a
    /// status Roga doesn't read. Asking again wouldn't say more, so Roga waits
    /// for their next event first.
    @ObservationIgnored private var unanswered: [SessionKey: Date] = [:]
    @ObservationIgnored private var termination: (any NSObjectProtocol)?
    /// The processes Roga watches, by their IDs.
    @ObservationIgnored private var watchers: [Int32: ProcessWatcher] = [:]
    /// Which worktree each mark is in, worked out once for the list's
    /// worktrees as they are, since every row asks.
    @ObservationIgnored private var placement: Placement?
    @ObservationIgnored private var marksVersion = 0
    /// Folders as they compare, with symbolic links resolved, by how agents
    /// and git spell them.
    @ObservationIgnored private var comparableFolders: [String: String] = [:]
    @ObservationIgnored private var foldersBeingResolved: Set<String> = []
    /// Goes up each time a folder resolves to something other than how it's
    /// spelled, so that the rows place their marks again.
    private var foldersVersion = 0
    /// The clock, which tests set.
    @ObservationIgnored var now: () -> Date = Date.init
    /// How a folder is resolved to compare it with the worktrees' folders,
    /// away from the main actor, which tests count.
    @ObservationIgnored var resolvePath: @Sendable (String) -> String = RepositoryList.comparablePath

    /// How long a Claude Code session can say it's working with no event before
    /// Roga asks whether it is. Long tools are quiet, and so is a session after
    /// someone pressed Esc, which sends nothing.
    static let quietLimit = Duration.seconds(90)

    public convenience init(supportFolder: URL) {
        self.init(supportFolder: supportFolder, checkInterval: .seconds(30))
    }

    /// - Parameter checkInterval: How often to look for quiet sessions, or nil
    ///   for never, which tests use to ask when they choose. With nil, Roga
    ///   doesn't ask what's running by itself either.
    init(supportFolder: URL, checkInterval: Duration?) {
        self.supportFolder = supportFolder
        self.checkInterval = checkInterval
    }

    // MARK: Starting and stopping

    /// Starts listening for hooks and reading every event in one place, asks
    /// Claude Code what's running once Roga has found it with its hooks
    /// installed, and keeps asking about quiet sessions. Calling it again tries
    /// the socket again if it couldn't be opened, and otherwise does nothing.
    func start(agents: AgentProvider) {
        self.agents = agents
        if listener == nil { listen() }
        if checking == nil, let checkInterval { keepChecking(every: checkInterval) }
        if termination == nil {
            // So the socket's file goes when Roga quits, rather than waiting
            // for the next launch to clear it.
            termination = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }
        }
    }

    /// Stops listening and watching, and lets go of the socket. `start` starts
    /// it all again.
    func stop() {
        letGo()
        listening = .starting
    }

    /// A monitor nobody holds stops, rather than leaving its loops waiting
    /// and its observer with the notification center.
    isolated deinit {
        letGo()
    }

    /// Ends everything `start` began. It touches nothing that views observe,
    /// so that `deinit` can call it too.
    private func letGo() {
        reading?.cancel()
        reading = nil
        seeding?.cancel()
        seeding = nil
        checking?.cancel()
        checking = nil
        seedingIsDue = false
        couldSeed = false
        listener?.stop()
        listener = nil
        for watcher in watchers.values { watcher.source.cancel() }
        watchers = [:]
        if let termination { NotificationCenter.default.removeObserver(termination) }
        termination = nil
    }

    /// Whether it stops by itself when Roga quits, which it does from `start`
    /// until `stop`.
    var isWatchingForTermination: Bool { termination != nil }

    private func listen() {
        do {
            let listener = try HookListener(supportFolder: supportFolder)
            self.listener = listener
            listening = .listening
            // Every copy of Roga with this bundle ID shares the launcher, and
            // the one that hears the hooks is the one it should run.
            agents?.pointTheHooksHere()
            let events = listener.events
            reading = Task { [weak self] in
                for await event in events {
                    self?.receive(event)
                }
            }
        } catch HookListenerError.inUse {
            listening = .anotherCopy
        } catch {
            listening = .failed(String(describing: error))
        }
    }

    private func keepChecking(every interval: Duration) {
        // What's running shows the sessions that started while Roga couldn't
        // hear them. Roga asks at launch, once it has found Claude Code and
        // knows its hooks are installed, and again whenever that comes true
        // anew, as after Look Again or Install. It asks once each time, even
        // when the question fails, so that a claude that can't answer isn't
        // run every half a minute.
        seeding = Task { [weak self] in
            for await canSeed in Observations({ @MainActor [weak self] in self?.canSeed ?? false }) {
                guard let monitor = self else { return }
                if canSeed, !monitor.couldSeed {
                    monitor.couldSeed = true
                    monitor.seedingIsDue = true
                    await monitor.askClaude()
                } else if !canSeed {
                    monitor.couldSeed = false
                    monitor.seedingIsDue = false
                }
            }
        }
        // Both loops hold the monitor only while they ask, and not while they
        // wait, so that a monitor nobody else holds goes away.
        checking = Task { [weak self] in
            while (try? await Task.sleep(for: interval)) != nil {
                guard let monitor = self else { return }
                await monitor.askClaude()
            }
        }
    }

    /// Whether asking Claude Code what's running would show sessions that
    /// Roga can keep current: Roga hears the hooks, and Claude Code runs them.
    /// Without them, no session the answer showed would ever send an event,
    /// and Roga would have to ask about each one again and again.
    private var canSeed: Bool {
        guard listening == .listening, let agents else { return false }
        return agents.installation(.claude) != nil && agents.hookStatus[.claude] == .installed
    }

    // MARK: Events

    /// Applies one hook event. The listener's reader calls it, and so do tests.
    func receive(_ event: HookEvent) {
        let key = event.session.flatMap { $0.isEmpty ? nil : SessionKey(host: event.host, id: $0) }
        let folderBefore = key.flatMap { state.sessions[$0]?.cwd }
        let changed = state.apply(event)
        // The session's folder, which follows the rules for an event's, or
        // for its end, where it was. An event Roga ignores has only its own.
        let folder = key.flatMap { state.sessions[$0]?.cwd } ?? folderBefore
            ?? (AgentSessions.movesTheFolder(event) ? event.cwd : nil)
        hear(from: event.host, at: Date(timeIntervalSince1970: event.time), in: folder)
        if changed { publish() }
    }

    /// Notes when an agent was last heard from, unless a later event already
    /// said, since events can arrive out of order.
    ///
    /// Settings says it in whole minutes, so `lastHeard`, which it observes,
    /// changes only with the folder or once what it holds is
    /// `heardRefreshInterval` old. Otherwise every tool an agent runs would
    /// redraw the hooks rows. What it shows can be that much behind.
    private func hear(from host: AgentHost, at date: Date, in folder: String?) {
        if let latest = latestHeard[host], AgentSessions.isLate(date, after: latest) { return }
        latestHeard[host] = date
        if let shown = lastHeard[host], shown.cwd == folder,
           date.timeIntervalSince(shown.date) < Self.heardRefreshInterval {
            return
        }
        lastHeard[host] = AgentProvider.Heard(date: date, cwd: folder)
    }

    /// How old `lastHeard` gets before an event in the same folder moves it.
    static let heardRefreshInterval: TimeInterval = 30

    /// Asks Claude Code about its sessions, when one has shown working for
    /// `quietLimit` with no event, or what's running, as at launch, when
    /// `always` is set. Roga asks nothing while it can't hear the hooks, and
    /// what's running only while Claude Code runs them. Only one question
    /// runs at a time.
    ///
    /// A quiet session that the answer says nothing about isn't asked about
    /// again until its next event, since Claude Code lists only interactive
    /// sessions, and not a `claude -p` that another tool runs, or one with
    /// another `CLAUDE_CONFIG_DIR`. Its process exiting ends it. One with no
    /// process to watch would never end, so it becomes idle, and if it's
    /// working after all, its next event says so.
    ///
    /// A session that Roga knows only from an answer, which no hook event has
    /// come from, is asked about at every check while it waits, and while it
    /// works, once it has been quiet as long as any other. It may have
    /// started before the hooks were installed, and such a session never
    /// loads them, so the answer is all that can end its wait. Once the
    /// answer no longer lists it, or Claude Code can't answer, nothing can
    /// keep it current, and it becomes idle.
    func askClaude(always: Bool = false) async {
        guard !isAskingClaude, listening == .listening, let agents, let claude = agents.installation(.claude), let programs = agents.programs else { return }
        let asked = now()
        let seeds = (always || seedingIsDue) && agents.hookStatus[.claude] == .installed
        // A session that has sent an event since is quiet anew.
        unanswered = unanswered.filter { state.sessions[$0.key]?.lastEvent == $0.value }
        var quiet: [SessionKey: Date] = [:]
        var hookless: [SessionKey] = []
        for key in state.quietWorking(for: Self.quietLimit, now: asked) where key.host == .claude {
            if !state.heardFromHooks(key) {
                hookless.append(key)
            } else if unanswered[key] == nil {
                quiet[key] = state.sessions[key]?.lastEvent
            }
        }
        for session in state.sessions.values where session.key.host == .claude && !state.heardFromHooks(session.key) {
            if case .waiting = session.phase { hookless.append(session.key) }
        }
        guard seeds || !quiet.isEmpty || !hookless.isEmpty else { return }
        if seeds { seedingIsDue = false }
        isAskingClaude = true
        defer { isAskingClaude = false }
        let listed = await ClaudeSessionList.list(executable: claude.executable, programs: programs)
        var changed = false
        var named: Set<SessionKey> = []
        var answered: Set<SessionKey> = []
        for session in listed ?? [] {
            guard let id = session.sessionId, !id.isEmpty else { continue }
            let key = SessionKey(host: .claude, id: id)
            named.insert(key)
            guard let observed = Self.observed(session.status) else { continue }
            answered.insert(key)
            if state.observe(key, observed, cwd: session.cwd, pid: session.pid, at: asked) {
                changed = true
            }
        }
        for (key, lastEvent) in quiet where !answered.contains(key) {
            if listed != nil, !named.contains(key), let session = state.sessions[key], session.pid == nil {
                if state.observe(key, .idle, cwd: nil, pid: nil, at: asked) { changed = true }
            } else {
                unanswered[key] = lastEvent
            }
        }
        // A hook that came while Roga asked speaks for the session from now
        // on, and one that ended meanwhile stays ended. One listed with a
        // status Roga doesn't read is asked about again.
        for key in hookless where !named.contains(key) && !state.heardFromHooks(key) && state.sessions[key] != nil {
            if state.observe(key, .idle, cwd: nil, pid: nil, at: asked) { changed = true }
        }
        if changed { publish() }
    }

    private static func observed(_ status: String?) -> AgentSessions.Observed? {
        switch status {
        case "busy": .busy
        case "waiting": .waiting
        case "idle": .idle
        default: nil
        }
    }

    /// Makes what changed in `state` show: ends the sessions whose process
    /// is gone, and updates what views read when it differs, since every
    /// assignment to an observed property redraws whatever reads it.
    private func publish() {
        watchProcesses()
        if state.sessions != sessions { sessions = state.sessions }
        let marks = state.sessions.mapValues(Mark.init)
        if marks != self.marks {
            self.marks = marks
            marksVersion &+= 1
        }
    }

    // MARK: Processes

    private struct ProcessWatcher {
        /// When the process started, which tells it apart from a later process
        /// with the same ID.
        var start: Double
        var source: any DispatchSourceProcess
    }

    /// Watches the process of every session that has one, and ends the
    /// sessions whose process is already gone, or whose process ID now
    /// belongs to a process that started at another time.
    private func watchProcesses() {
        var gone: [(pid: Int32, start: Double?)] = []
        for session in state.sessions.values {
            guard let pid = session.pid else { continue }
            let live = watchers[pid]?.start ?? startWatching(pid)
            if live == nil || (session.processStart != nil && session.processStart != live) {
                gone.append((pid, session.processStart))
            }
        }
        for (pid, start) in gone {
            state.processEnded(pid: pid, processStart: start)
        }
        let watched = Set(state.sessions.values.compactMap(\.pid))
        for pid in watchers.keys where !watched.contains(pid) {
            watchers.removeValue(forKey: pid)?.source.cancel()
        }
    }

    /// Starts watching a process, and returns when it started, or nil when
    /// it's gone.
    private func startWatching(_ pid: Int32) -> Double? {
        guard let start = AgentProcess.startTime(of: pid) else { return nil }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.processExited(pid, start: start)
            }
        }
        source.activate()
        // It may have exited before the source could see it.
        guard AgentProcess.startTime(of: pid) == start else {
            source.cancel()
            return nil
        }
        watchers[pid] = ProcessWatcher(start: start, source: source)
        return start
    }

    private func processExited(_ pid: Int32, start: Double) {
        guard let watcher = watchers[pid], watcher.start == start else { return }
        watchers[pid] = nil
        watcher.source.cancel()
        if state.processEnded(pid: pid, processStart: start) { publish() }
    }

    // MARK: Summaries

    /// What a mark needs of a session.
    private struct Mark: Equatable {
        var host: AgentHost
        var cwd: String?
        var phase: AgentPhase
        var since: Date

        init(_ session: AgentSession) {
            host = session.key.host
            cwd = session.cwd
            phase = session.phase
            since = session.phaseSince
        }
    }

    /// Which worktree each mark is in, for one version of the marks, of the
    /// folders resolved, and of the worktrees' folders.
    private struct Placement {
        var marksVersion: Int
        var foldersVersion: Int
        /// The folders of the worktrees that can hold a session, in the
        /// list's order. That's all placing reads of the worktrees, so a
        /// commit or a checkout in one of them leaves the placement as it is.
        var worktrees: [String]
        var byWorktree: [String: [Mark]]
    }

    /// The most urgent state among the sessions working in this worktree, or
    /// nil when no session there needs a mark.
    func summary(forWorktree path: String, in list: RepositoryList) -> AgentSummary? {
        summary(forWorktrees: [path], in: list)
    }

    /// The same across several worktrees, for the row that stands for the
    /// ones a collapsed repository hides.
    func summary(forWorktrees paths: [String], in list: RepositoryList) -> AgentSummary? {
        let byWorktree = placedMarks(in: list)
        let seen = seen
        var shown: [Mark] = []
        for path in paths {
            guard let placed = byWorktree[path] else { continue }
            let seenAt = seen[path]
            shown += placed.filter { mark in
                if case .finished = mark.phase { seenAt.map { mark.since > $0 } ?? true } else { true }
            }
        }
        return AgentSummary(shown.map { (host: $0.host, phase: $0.phase, since: $0.since) })
    }

    /// Someone looked at the worktree, so the sessions that finished in it
    /// stop showing their dot.
    ///
    /// Every row with a mark reads what's been seen, and a worktree is looked
    /// at each time it's selected, so this changes it only when a dot there
    /// would go. It can tell once the rows have placed the marks as they are;
    /// until then it notes the look anyway.
    func markSeen(worktree path: String) {
        let seenAt = seen[path]
        if let placement, placement.marksVersion == marksVersion, placement.foldersVersion == foldersVersion {
            let hasDot = placement.byWorktree[path, default: []].contains { mark in
                if case .finished = mark.phase { seenAt.map { mark.since > $0 } ?? true } else { false }
            }
            guard hasDot else { return }
        }
        seen[path] = now()
    }

    /// Someone selected the worktree a window shows, and so looked at it.
    func selected(worktree path: String?) {
        if let path { markSeen(worktree: path) }
    }

    /// A window shows the worktree at `path`, and either what agents do
    /// there changed, or the window came to the front or went back. While
    /// the window is in front, what finishes there is seen as it finishes,
    /// and what finished while it was behind is seen once it comes to the
    /// front.
    func showing(worktree path: String?, appearsActive: Bool, in list: RepositoryList) {
        guard appearsActive, let path, summary(forWorktree: path, in: list)?.state == .finished else { return }
        markSeen(worktree: path)
    }

    /// The marks by the worktree each is in. Each call reads `marks`, the
    /// folders resolved and the list's worktrees, so that a view that asks
    /// redraws when any of them changes.
    private func placedMarks(in list: RepositoryList) -> [String: [Mark]] {
        let marks = marks
        let foldersVersion = foldersVersion
        let worktrees = list.repositories.flatMap { repository in
            repository.worktrees.lazy.filter { !$0.isBare && !$0.isPrunable }.map(\.path)
        }
        if let placement, placement.marksVersion == marksVersion, placement.foldersVersion == foldersVersion, placement.worktrees == worktrees {
            return placement.byWorktree
        }
        // A session is in the deepest worktree that holds its folder, as
        // `RepositoryList.worktree(containing:)` finds it, with the folders
        // as they compare: the worktrees' only once some mark needs them.
        var places: [(folder: String, value: String)]?
        var byWorktree: [String: [Mark]] = [:]
        var placed: [String: String?] = [:]
        for mark in marks.values {
            guard let cwd = mark.cwd else { continue }
            let worktree: String?
            if let known = placed[cwd] {
                worktree = known
            } else {
                let candidates = places ?? worktrees.map { (folder: comparable($0), value: $0) }
                places = candidates
                worktree = RepositoryList.deepest(holding: comparable(cwd), in: candidates)
                placed[cwd] = worktree
            }
            if let worktree { byWorktree[worktree, default: []].append(mark) }
        }
        placement = Placement(marksVersion: marksVersion, foldersVersion: foldersVersion, worktrees: worktrees, byWorktree: byWorktree)
        forgetFolders(keeping: worktrees + marks.values.compactMap(\.cwd))
        return byWorktree
    }

    // MARK: Folders

    /// A folder as it compares with the worktrees' folders: with symbolic
    /// links resolved once Roga has resolved it, and until then only
    /// standardized, which for nearly every folder is the same.
    ///
    /// Resolving a path asks the file system about each folder in it, which
    /// takes a while on a slow volume and forever on a stalled one, and rows
    /// ask for their marks as they draw, on the main actor. So each spelling
    /// is resolved once, away from the main actor, and the marks are placed
    /// again when that changes where one goes.
    private func comparable(_ folder: String) -> String {
        if let known = comparableFolders[folder] { return known }
        let spelled = RepositoryList.standardizedPath(folder)
        if foldersBeingResolved.insert(folder).inserted {
            let resolve = resolvePath
            Task { [weak self] in
                let resolved = await Self.resolve(folder, with: resolve)
                self?.finishResolving(folder, as: resolved, spelled: spelled)
            }
        }
        return spelled
    }

    @concurrent
    private static func resolve(_ folder: String, with resolve: @Sendable (String) -> String) async -> String {
        resolve(folder)
    }

    private func finishResolving(_ folder: String, as resolved: String, spelled: String) {
        foldersBeingResolved.remove(folder)
        comparableFolders[folder] = resolved
        if resolved != spelled { foldersVersion &+= 1 }
    }

    /// Keeps the folders resolved from growing without end as agents move
    /// around, by forgetting those that nothing places any more, once there
    /// are many.
    private func forgetFolders(keeping used: [String]) {
        guard comparableFolders.count > 256 else { return }
        let used = Set(used)
        comparableFolders = comparableFolders.filter { used.contains($0.key) }
    }
}

/// What a sidebar row's mark stands for: the most urgent state among the
/// agent sessions in its worktrees (decision 41).
struct AgentSummary: Equatable {
    enum State: Equatable {
        /// An agent can't go on until the person does something.
        case waiting(WaitReason)
        case working
        /// An agent's turn ended since someone last looked.
        case finished
    }

    var state: State
    /// When the longest-running session in that state got there.
    var since: Date
    /// The agents in that state, each once, in `AgentHost.allCases` order.
    var hosts: [AgentHost]
    /// How many sessions are in that state.
    var sessions: Int

    init(state: State, since: Date, hosts: [AgentHost], sessions: Int) {
        self.state = state
        self.since = since
        self.hosts = hosts
        self.sessions = sessions
    }

    /// The summary of some sessions, by their agents' phases, or nil when none
    /// of them needs a mark: waiting beats working, and working beats
    /// finished, because that's the order in which they need the person.
    /// Idle sessions have no mark.
    init?(_ sessions: [(host: AgentHost, phase: AgentPhase, since: Date)]) {
        let waiting = sessions.filter { if case .waiting = $0.phase { true } else { false } }
        let working = sessions.filter { $0.phase == .working }
        let finished = sessions.filter { if case .finished = $0.phase { true } else { false } }
        let chosen: [(host: AgentHost, phase: AgentPhase, since: Date)]
        if !waiting.isEmpty {
            chosen = waiting
        } else if !working.isEmpty {
            chosen = working
        } else if !finished.isEmpty {
            chosen = finished
        } else {
            return nil
        }
        // The one that has been at it longest says how long, and when they
        // wait for different things, what for.
        let longest = chosen.min { $0.since < $1.since }!
        switch longest.phase {
        case .waiting(let reason): state = .waiting(reason)
        case .working: state = .working
        default: state = .finished
        }
        since = longest.since
        let present = Set(chosen.map(\.host))
        hosts = AgentHost.allCases.filter(present.contains)
        self.sessions = chosen.count
    }

    /// What the mark means, for its tooltip and for VoiceOver, such as
    /// "Claude Code is working" or "2 agents are working".
    var description: String {
        let agent = sessions == 1 ? hosts.first?.name ?? "An agent" : "\(sessions) agents"
        switch state {
        case .working:
            return sessions == 1 ? "\(agent) is working" : "\(agent) are working"
        case .waiting(let reason):
            guard sessions == 1 else { return "\(agent) are waiting for you" }
            switch reason {
            case .permission: return "\(agent) is waiting for you to allow a tool"
            case .question: return "\(agent) is waiting for your answer"
            }
        case .finished:
            return "\(agent) finished"
        }
    }

    /// The tooltip, which says for how long from a minute on, as in "Claude
    /// Code is working, for 6 minutes".
    func help(now: Date) -> String {
        guard state != .finished else { return description }
        let minutes = Self.minutes(from: since, to: now)
        guard minutes > 0 else { return description }
        return "\(description), for \(Self.longDuration(minutes: minutes))"
    }

    /// The second line of the worktree menu's row, such as "Agent working · 6
    /// min", "2 agents working · 6 min", "Agent waiting for you · 2 min" or
    /// "Agent finished". It leaves the time out under a minute, and for
    /// what's finished.
    func menuDetail(now: Date) -> String {
        let agents = sessions == 1 ? "Agent" : "\(sessions) agents"
        let words: String
        switch state {
        case .working: words = "\(agents) working"
        case .waiting: words = "\(agents) waiting for you"
        case .finished: return "\(agents) finished"
        }
        let minutes = Self.minutes(from: since, to: now)
        return minutes > 0 ? "\(words) · \(Self.shortDuration(minutes: minutes))" : words
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// "6 min", or "1 hr 5 min" from an hour on.
    private static func shortDuration(minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(rest) min"
    }

    /// "6 minutes", or "1 hour and 5 minutes" from an hour on.
    private static func longDuration(minutes: Int) -> String {
        func count(_ number: Int, _ unit: String) -> String { number == 1 ? "1 \(unit)" : "\(number) \(unit)s" }
        guard minutes >= 60 else { return count(minutes, "minute") }
        let rest = minutes % 60
        return rest == 0 ? count(minutes / 60, "hour") : "\(count(minutes / 60, "hour")) and \(count(rest, "minute"))"
    }
}

extension AgentHost {
    /// What people call the agent.
    var name: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
