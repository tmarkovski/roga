import Testing
@testable import AgentEngine

/// Finding the MCP servers in Codex's `config.toml`, which Generate turns
/// off one by one.
@Suite(.timeLimit(.minutes(1)))
struct CodexConfigurationTests {
    @Test func findsTheServersCodexMcpAddWrites() {
        let text = """
            model = "gpt-6-astra"

            [mcp_servers.node_repl]
            command = "node"
            startup_timeout_sec = 120

            [mcp_servers.node_repl.env]
            NODE_ENV = "production"

            [mcp_servers.docs-search] # added by hand
            url = "https://example.com/mcp"

            [profiles.work]
            model = "o5"
            """
        #expect(CodexConfiguration.mcpServers(in: text) == ["node_repl", "docs-search"])
    }

    @Test func findsServersWrittenAsKeys() {
        let table = """
            [mcp_servers]
            docs = { command = "docs-server" }
            github.url = "https://example.com/github"
            """
        #expect(CodexConfiguration.mcpServers(in: table) == ["docs", "github"])
        let dotted = """
            mcp_servers.docs.command = "docs-server"
            mcp_servers."search".command = "search-server"

            [features]
            mcp_servers.not_here = true
            """
        #expect(CodexConfiguration.mcpServers(in: dotted) == ["docs", "search"])
    }

    @Test func leavesOutWhatCodexCantBeToldToTurnOff() {
        // Codex's -c splits its key at every dot, and refuses to start when
        // it names a server that isn't there, so these are never guessed at.
        let text = """
            # [mcp_servers.commented]
            [mcp_servers."has.dots"]
            command = "x"
            [mcp_servers."has space"]
            command = "x"
            [[mcp_servers.array]]
            [mcp_servers]
            "args=1" = "x"
            """
        #expect(CodexConfiguration.mcpServers(in: text).isEmpty)
        #expect(CodexConfiguration.mcpServers(in: "").isEmpty)
        #expect(CodexConfiguration.mcpServers(inFile: "/nonexistent/config.toml") == nil)
    }
}
