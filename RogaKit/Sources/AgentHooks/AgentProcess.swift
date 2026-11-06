import Darwin

/// A process as the kernel describes it: enough to walk up from the helper
/// to the agent that ran it, and to tell that process apart from a later one
/// that's given the same ID.
struct ProcessEntry: Sendable, Hashable {
    var pid: pid_t
    var parent: pid_t
    /// The name of the program it runs, cut to 16 bytes by the kernel.
    var name: String
    /// When it started, in seconds since 1970.
    var start: Double

    /// Asks the kernel about a process, or returns nil when there's no such
    /// process.
    init?(pid: pid_t) {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // When there's no such process, sysctl succeeds and returns nothing.
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else {
            return nil
        }
        self.pid = pid
        parent = info.kp_eproc.e_ppid
        name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let started = info.kp_proc.p_un.__p_starttime
        start = Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
    }

    init(pid: pid_t, parent: pid_t, name: String, start: Double) {
        self.pid = pid
        self.parent = parent
        self.name = name
        self.start = start
    }
}

enum AgentProcess {
    /// The programs that stand between an agent and the helper without being
    /// the agent: Codex runs every hook in a login shell, and the launcher in
    /// Application Support is a shell script.
    static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "login", "roga-hook"]

    /// How many wrappers the walk skips before it gives up.
    static let wrappersSkipped = 8

    /// Walks up from `pid`, usually the helper's parent, past shells and
    /// wrappers, to the agent's process.
    ///
    /// It gives up, rather than settle for a wrapper, after too many of them,
    /// and when it reaches launchd, which adopts a process whose parent has
    /// exited. Watching either would end the session at the wrong time, or
    /// never.
    static func find(above pid: pid_t, lookup: (pid_t) -> ProcessEntry? = { ProcessEntry(pid: $0) }) -> ProcessEntry? {
        var current = pid
        for _ in 0...wrappersSkipped {
            guard current > 1, let entry = lookup(current) else { return nil }
            // A login shell can call itself "-zsh".
            let name = entry.name.hasPrefix("-") ? String(entry.name.dropFirst()) : entry.name
            guard wrappers.contains(name) else { return entry }
            current = entry.parent
        }
        return nil
    }
}
