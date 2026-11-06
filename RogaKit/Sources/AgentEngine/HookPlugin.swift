import GitRunner

/// The plugin that installs Roga's hooks in Claude Code and Codex, and the
/// launcher its hooks run (decision 41).
///
/// One folder serves both agents. It's a marketplace called `roga` with one
/// plugin, `roga-hooks`. Claude Code reads the plugin's `.claude-plugin`
/// manifest and `hooks/hooks.json`. Codex reads `.codex-plugin` before
/// `.claude-plugin`, and that manifest points it at `hooks/codex.json` instead,
/// so each agent's hooks say which agent sent them. It also means that when the
/// Codex app imports Claude Code's plugins, Codex still reports as Codex.
///
/// Every hook runs the launcher with the event's name. The launcher lives
/// outside the plugin and is the only file that knows where Roga.app is, so
/// moving the app rewrites the launcher and leaves the plugin alone. That
/// matters because Codex pins its trust in a plugin's hooks to a hash of the
/// plugin's contents: a plugin whose bytes change has to be trusted again.
/// So nothing here has a timestamp, keys are always in the same order, and the
/// bytes depend only on the launcher's path and `version`.
///
/// No hook is `async`, because Codex before 0.148 skips async hooks, and none
/// blocks: the helper exits as soon as it has passed the event on.
public enum HookPlugin {
    public static let marketplaceName = "roga"
    public static let pluginName = "roga-hooks"
    /// How both agents name the plugin, `<plugin>@<marketplace>`.
    public static let pluginID = "\(pluginName)@\(marketplaceName)"
    /// Raise this whenever a file in the plugin changes, so the agents copy the
    /// new one.
    public static let version = "1.0.0"
    /// Where Codex's hooks are, inside the plugin. Codex names its trust in each
    /// hook after it, as in `roga-hooks@roga:hooks/codex.json:stop:0:0`.
    public static let codexHooksPath = "hooks/codex.json"

    /// The Claude Code events Roga hears about. `WorktreeCreate` and
    /// `WorktreeRemove` are left out, because a hook on them replaces Claude
    /// Code's own way of making worktrees rather than watching it.
    public static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SubagentStart",
        "SubagentStop", "PreCompact", "PostCompact", "Elicitation", "ElicitationResult", "CwdChanged",
    ]

    /// The Codex events Roga hears about. Codex ignores the ones it doesn't
    /// know yet, such as `SessionEnd` before 0.145 and `Interrupt` before 0.150.
    public static let codexEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Interrupt",
    ]

    static let description = "Tells Roga when an agent is working, waiting for you or finished, so Roga can show it beside the worktree."

    /// One file of the plugin.
    public struct File: Sendable, Hashable {
        /// Where it goes, relative to the plugins folder.
        public var path: String
        public var contents: [UInt8]
    }

    /// Every file of the plugin folder, for hooks that run `launcher`.
    public static func files(launcher: String) -> [File] {
        [
            File(path: ".claude-plugin/marketplace.json", contents: render(.object([
                ("name", .string(marketplaceName)),
                ("description", .string("Roga's hooks, which tell Roga what Claude Code and Codex are doing.")),
                ("owner", .object([("name", .string("Roga"))])),
                ("plugins", .array([.object([
                    ("name", .string(pluginName)),
                    ("source", .string("./\(pluginName)")),
                    ("description", .string(description)),
                ])])),
            ]))),
            File(path: "\(pluginName)/.claude-plugin/plugin.json", contents: render(.object([
                ("name", .string(pluginName)),
                ("version", .string(version)),
                ("description", .string(description)),
                ("author", .object([("name", .string("Roga"))])),
            ]))),
            File(path: "\(pluginName)/.codex-plugin/plugin.json", contents: render(.object([
                ("name", .string(pluginName)),
                ("version", .string(version)),
                ("description", .string(description)),
                ("hooks", .string("./\(codexHooksPath)")),
            ]))),
            File(path: "\(pluginName)/hooks/hooks.json", contents: render(hooks(claudeEvents) { event in
                // Claude Code runs this form without a shell, so the path needs
                // no quoting and no shell startup file can print anything.
                [
                    ("type", .string("command")),
                    ("command", .string(launcher)),
                    ("args", .array(["hook", "--host", "claude", "--event", event].map(JSON.string))),
                    ("timeout", .int(5)),
                ]
            })),
            File(path: "\(pluginName)/\(codexHooksPath)", contents: render(hooks(codexEvents) { event in
                // Codex runs every hook through the login shell, so the path is
                // quoted. It gives SessionEnd and Interrupt 3 seconds at most.
                [
                    ("type", .string("command")),
                    ("command", .string("\(singleQuoted(launcher)) hook --host codex --event \(event)")),
                    ("timeout", .int(event == "SessionEnd" || event == "Interrupt" ? 3 : 5)),
                ]
            })),
        ]
    }

    /// The launcher: a shell script that hands the event to the helper inside
    /// Roga.app, or reads it and exits quietly when the helper isn't there,
    /// because Roga moved or was deleted. An agent shows an error for a hook
    /// that fails, and one that doesn't read its input can break the agent's
    /// pipe, so it always reads it and exits 0.
    public static func launcherScript(helperPath: String) -> [UInt8] {
        Array("""
            #!/bin/sh
            # Roga writes this file. Claude Code's and Codex's hooks run it, and it
            # passes each event to the helper inside Roga.app. When the helper isn't
            # there, it reads the event and exits quietly, so the agent carries on.
            helper=\(ShellQuoting.quoted(helperPath))
            if [ -x "$helper" ]; then
                exec "$helper" "$@"
            fi
            cat > /dev/null
            exit 0

            """.utf8)
    }

    private static func hooks(_ events: [String], handler: (String) -> [(String, JSON)]) -> JSON {
        .object([
            ("description", .string(description)),
            ("hooks", .object(events.map { event in
                (event, .array([.object([
                    ("matcher", .string("")),
                    ("hooks", .array([.object(handler(event))])),
                ])]))
            })),
        ])
    }

    /// Single quotes for `sh`, always, so the command reads the same whatever
    /// the path holds.
    static func singleQuoted(_ text: String) -> String {
        "'" + text.replacing("'", with: "'\\''") + "'"
    }

    // MARK: - Writing JSON the same way every time

    /// Just enough JSON for the plugin's files. Foundation's writer isn't used,
    /// because its spacing isn't promised to stay the same from one macOS to the
    /// next, and Codex's trust depends on every byte.
    indirect enum JSON {
        case string(String)
        case int(Int)
        case array([JSON])
        case object([(String, JSON)])
    }

    /// Writes `value` with two spaces of indentation, keys in the order of
    /// their UTF-8 bytes, everything outside ASCII escaped, and a line break at
    /// the end. That's the same text as Python's
    /// `json.dumps(value, indent=2, sort_keys=True)`.
    static func render(_ value: JSON) -> [UInt8] {
        var text = ""
        write(value, indent: 0, into: &text)
        text += "\n"
        return Array(text.utf8)
    }

    private static func write(_ value: JSON, indent: Int, into text: inout String) {
        let inner = String(repeating: " ", count: indent + 2)
        let outer = String(repeating: " ", count: indent)
        switch value {
        case .string(let string):
            text += quoted(string)
        case .int(let number):
            text += String(number)
        case .array(let items):
            guard !items.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (index, item) in items.enumerated() {
                text += inner
                write(item, indent: indent + 2, into: &text)
                text += index == items.count - 1 ? "\n" : ",\n"
            }
            text += outer + "]"
        case .object(let members):
            guard !members.isEmpty else { text += "{}"; return }
            let sorted = members.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
            text += "{\n"
            for (index, (key, item)) in sorted.enumerated() {
                text += inner + quoted(key) + ": "
                write(item, indent: indent + 2, into: &text)
                text += index == sorted.count - 1 ? "\n" : ",\n"
            }
            text += outer + "}"
        }
    }

    private static func quoted(_ string: String) -> String {
        var text = "\""
        for unit in string.utf16 {
            switch unit {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0x08: text += "\\b"
            case 0x0C: text += "\\f"
            case 0x20...0x7E: text.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: text += "\\u" + String(repeating: "0", count: 4 - String(unit, radix: 16).count) + String(unit, radix: 16)
            }
        }
        return text + "\""
    }
}
