import CryptoKit
import Foundation
import Testing
@testable import AgentEngine

@Suite(.timeLimit(.minutes(1)))
struct HookPluginTests {
    let launcher = "/Users/me/Library/Application Support/sh.roga.app/bin/roga-hook"

    func file(_ path: String, launcher: String? = nil) throws -> String {
        let files = HookPlugin.files(launcher: launcher ?? self.launcher)
        let file = try #require(files.first { $0.path == path })
        return String(decoding: file.contents, as: UTF8.self)
    }

    func digest(_ path: String, launcher: String? = nil) throws -> String {
        let files = HookPlugin.files(launcher: launcher ?? self.launcher)
        let file = try #require(files.first { $0.path == path })
        return SHA256.hash(data: Data(file.contents)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func writesOneMarketplaceWithOnePluginForBothAgents() {
        #expect(HookPlugin.files(launcher: launcher).map(\.path) == [
            ".claude-plugin/marketplace.json",
            "roga-hooks/.claude-plugin/plugin.json",
            "roga-hooks/.codex-plugin/plugin.json",
            "roga-hooks/hooks/hooks.json",
            "roga-hooks/hooks/codex.json",
        ])
        #expect(HookPlugin.pluginID == "roga-hooks@roga")
    }

    @Test func writesTheManifests() throws {
        #expect(try file(".claude-plugin/marketplace.json") == """
            {
              "description": "Roga's hooks, which tell Roga what Claude Code and Codex are doing.",
              "name": "roga",
              "owner": {
                "name": "Roga"
              },
              "plugins": [
                {
                  "description": "Tells Roga when an agent is working, waiting for you or finished, so Roga can show it beside the worktree.",
                  "name": "roga-hooks",
                  "source": "./roga-hooks"
                }
              ]
            }

            """)
        #expect(try file("roga-hooks/.claude-plugin/plugin.json") == """
            {
              "author": {
                "name": "Roga"
              },
              "description": "Tells Roga when an agent is working, waiting for you or finished, so Roga can show it beside the worktree.",
              "name": "roga-hooks",
              "version": "\(HookPlugin.version)"
            }

            """)
        #expect(try file("roga-hooks/.codex-plugin/plugin.json") == """
            {
              "description": "Tells Roga when an agent is working, waiting for you or finished, so Roga can show it beside the worktree.",
              "hooks": "./hooks/codex.json",
              "name": "roga-hooks",
              "version": "\(HookPlugin.version)"
            }

            """)
    }

    @Test func runsTheLauncherWithoutAShellForClaudeCode() throws {
        let text = try file("roga-hooks/hooks/hooks.json")
        #expect(text.contains("""
                "Stop": [
                  {
                    "hooks": [
                      {
                        "args": [
                          "hook",
                          "--host",
                          "claude",
                          "--event",
                          "Stop"
                        ],
                        "command": "/Users/me/Library/Application Support/sh.roga.app/bin/roga-hook",
                        "timeout": 5,
                        "type": "command"
                      }
                    ],
                    "matcher": ""
                  }
                ],
            """))
        let hooks = try events(in: text)
        #expect(hooks.keys.sorted() == HookPlugin.claudeEvents.sorted())
        for (event, handler) in hooks {
            #expect(handler["command"] as? String == launcher)
            #expect(handler["args"] as? [String] == ["hook", "--host", "claude", "--event", event])
            #expect(handler["timeout"] as? Int == 5)
            #expect(handler["async"] == nil)
        }
    }

    @Test func quotesTheLauncherForCodexsShell() throws {
        let text = try file("roga-hooks/hooks/codex.json")
        #expect(text.contains("""
                "Interrupt": [
                  {
                    "hooks": [
                      {
                        "command": "'/Users/me/Library/Application Support/sh.roga.app/bin/roga-hook' hook --host codex --event Interrupt",
                        "timeout": 3,
                        "type": "command"
                      }
                    ],
                    "matcher": ""
                  }
                ],
            """))
        let hooks = try events(in: text)
        #expect(hooks.keys.sorted() == HookPlugin.codexEvents.sorted())
        for (event, handler) in hooks {
            #expect(handler["command"] as? String == "'\(launcher)' hook --host codex --event \(event)")
            #expect(handler["timeout"] as? Int == (["SessionEnd", "Interrupt"].contains(event) ? 3 : 5))
        }

        let quoted = try events(in: file("roga-hooks/hooks/codex.json", launcher: "/Users/o'neil/bin/roga-hook"))
        #expect(quoted["Stop"]?["command"] as? String == "'/Users/o'\\''neil/bin/roga-hook' hook --host codex --event Stop")
    }

    @Test func listensToTheEventsThatTellWhatAnAgentIsDoing() {
        #expect(HookPlugin.claudeEvents == [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure", "SubagentStart",
            "SubagentStop", "PreCompact", "PostCompact", "Elicitation", "ElicitationResult", "CwdChanged",
        ])
        #expect(HookPlugin.codexEvents == [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
            "Stop", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "Interrupt",
        ])
        // These replace Claude Code's own worktree handling.
        #expect(!HookPlugin.claudeEvents.contains("WorktreeCreate"))
        #expect(!HookPlugin.claudeEvents.contains("WorktreeRemove"))
    }

    /// These are the digests of the files that were checked with
    /// `claude plugin validate`, installed in Claude Code 2.1.318 and Codex
    /// 0.166.0, and that Codex listed as twelve hooks from `hooks/codex.json`
    /// (written by Python's `json.dumps(indent=2, sort_keys=True)`). Codex
    /// trusts a plugin's hooks by a hash of its contents, so a change here asks
    /// everyone to trust Roga's hooks again: raise `HookPlugin.version` with it.
    @Test func writesTheSameBytesItWasCheckedWith() throws {
        #expect(HookPlugin.version == "1.0.0")
        #expect(try digest(".claude-plugin/marketplace.json") == "cc8f2c06d8bc1201d49486a53f6ef8fa873d183469cc9666085517872ebd215d")
        #expect(try digest("roga-hooks/.claude-plugin/plugin.json") == "44176ced593169520366bdf614e1a5ab7e80c9002892f6d6b7287f0e5e7c4715")
        #expect(try digest("roga-hooks/.codex-plugin/plugin.json") == "09171ec51adf15919d01e54c9f01ab5d537248e357c78fa41f075b25ddf07b18")
        #expect(try digest("roga-hooks/hooks/hooks.json") == "1af7a59e026065437e36babb90c9efaaa5f10e289272fd0c8b59ee84d73fa80a")
        #expect(try digest("roga-hooks/hooks/codex.json") == "5209782814b6c27462d3624f9475b370aa73432e7c8492a6b6e486f8a5be5fca")

        let oneil = "/Users/o'neil/Library/Application Support/sh.roga.app/bin/roga-hook"
        #expect(try digest("roga-hooks/hooks/hooks.json", launcher: oneil) == "bebc605e77b15085200b5227b97eaa81aee2d0bba4b89aedac37c3c949cf1e89")
        #expect(try digest("roga-hooks/hooks/codex.json", launcher: oneil) == "ac56bf6be6f91adb8e4e83bf631316f4ef6ab7dbd5a915c90c41a7f0696d474e")
        #expect(HookPlugin.files(launcher: launcher) == HookPlugin.files(launcher: launcher))
    }

    @Test func escapesEverythingOutsideASCII() {
        let text = String(decoding: HookPlugin.render(.object([
            ("b", .string("José \"quoted\" back\\slash\ttab\u{1}\u{7F}/")),
            ("a", .array([.int(1), .string("😀")])),
            ("c", .array([])),
            ("d", .object([])),
        ])), as: UTF8.self)
        #expect(text == """
            {
              "a": [
                1,
                "\\ud83d\\ude00"
              ],
              "b": "Jos\\u00e9 \\"quoted\\" back\\\\slash\\ttab\\u0001\\u007f/",
              "c": [],
              "d": {}
            }

            """)
    }

    @Test func writesALauncherThatRunsTheHelperWhenItsThere() {
        let script = String(decoding: HookPlugin.launcherScript(helperPath: "/Applications/Roga.app/Contents/Helpers/roga"), as: UTF8.self)
        #expect(script == """
            #!/bin/sh
            # Roga writes this file. Claude Code's and Codex's hooks run it, and it
            # passes each event to the helper inside Roga.app. When the helper isn't
            # there, it reads the event and exits quietly, so the agent carries on.
            helper=/Applications/Roga.app/Contents/Helpers/roga
            if [ -x "$helper" ]; then
                exec "$helper" "$@"
            fi
            cat > /dev/null
            exit 0

            """)
        let spaced = String(decoding: HookPlugin.launcherScript(helperPath: "/Users/me/Apps/Roga 2.app/Contents/Helpers/roga"), as: UTF8.self)
        #expect(spaced.contains("\nhelper='/Users/me/Apps/Roga 2.app/Contents/Helpers/roga'\n"))
    }

    /// Each event's one handler, from a hooks file.
    func events(in text: String) throws -> [String: [String: Any]] {
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["description"] is String)
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        var handlers: [String: [String: Any]] = [:]
        for (event, groups) in hooks {
            #expect(groups.count == 1)
            #expect(groups.first?["matcher"] as? String == "")
            let inner = try #require(groups.first?["hooks"] as? [[String: Any]])
            #expect(inner.count == 1)
            #expect(inner.first?["type"] as? String == "command")
            handlers[event] = inner.first
        }
        return handlers
    }
}
