import Testing
@testable import AgentEngine

/// Each rule for turning an agent's reply into a commit message.
@Suite(.timeLimit(.minutes(1)))
struct CommitMessageCleanupTests {
    func clean(_ reply: String, draft: String? = nil) -> String {
        CommitMessageCleanup.clean(reply, draft: draft)
    }

    @Test func leavesAGoodMessageAsItIs() {
        let message = "Add the sidebar\n\nIt lists every worktree, so switching takes one click.\n\n- Rows show the branch\n- # stays, since git commit -F keeps it"
        #expect(clean(message) == message)
        #expect(clean("feat(ui): add the sidebar") == "feat(ui): add the sidebar")
    }

    // MARK: Terminal output

    @Test func removesEscapeSequencesAndCarriageReturns() {
        #expect(clean("\u{1B}[1;32mAdd the sidebar\u{1B}[0m\r\n\r\nIt lists worktrees.\r\n") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("\u{1B}]0;claude\u{07}Add the sidebar") == "Add the sidebar")
        #expect(clean("\u{1B}]8;;https://example.com\u{1B}\\Add the sidebar\u{1B}]8;;\u{1B}\\") == "Add the sidebar")
        #expect(clean("Add\u{1B}7 the sidebar") == "Add the sidebar")
    }

    // MARK: Thinking

    @Test func removesThinking() {
        #expect(clean("<think>\nThe diff adds a sidebar.\n</think>\n\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("<thinking>hmm</thinking>Add the sidebar") == "Add the sidebar")
        #expect(clean("Thinking...\nThe diff adds a sidebar.\n...done thinking.\n\nAdd the sidebar") == "Add the sidebar")
        // Reasoning that never ends leaves no message.
        #expect(clean("<think>\nThe diff adds a sidebar, so") == "")
        // Blocks one after another, after blank lines.
        #expect(clean("\n  <think>a</think>\n\n<thinking>b</thinking>\nThinking...\nc\n...done thinking.\nAdd the sidebar") == "Add the sidebar")
    }

    @Test func keepsAMessageThatMentionsThinkingTags() {
        // Only reasoning that starts the reply is reasoning. A message about
        // the tags, such as one for this very feature, keeps them.
        for message in [
            "Remove <think> blocks from Ollama's replies",
            "Strip <think> blocks from replies\n\nThe reasoning ends at </think>, and the message follows it.",
            "Read <thinking> tags\n\nClaude's extended thinking prints them.",
            "Add the sidebar\n\nThinking... was the old progress text.",
        ] {
            #expect(clean(message) == message)
        }
        #expect(clean("<think>The diff strips tags.</think>\nStrip <think> blocks from replies") == "Strip <think> blocks from replies")
    }

    // MARK: Fences and tags

    @Test func keepsTheFirstFencedBlocksContents() {
        #expect(clean("```\nAdd the sidebar\n\nIt lists worktrees.\n```") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("```text\nAdd the sidebar\n```\n\n```\nSomething else\n```") == "Add the sidebar")
        #expect(clean("Here's the commit message:\n\n```\nAdd the sidebar\n```\n\nLet me know if you want changes.") == "Add the sidebar")
        #expect(clean("~~~\nAdd the sidebar\n~~~") == "Add the sidebar")
        #expect(clean("```\nAdd the sidebar") == "Add the sidebar", "a fence that never closes")
    }

    @Test func keepsAFenceInTheBody() {
        let message = "Add the sidebar\n\nIt's built like this:\n\n```\nSidebar(rows)\n```"
        #expect(clean(message) == message)
    }

    @Test func takesTheMessageOutOfTags() {
        #expect(clean("<summary>Add the sidebar</summary>\n<body>It lists worktrees.</body>") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("<summary>Add the sidebar\n<body>It lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.", "closing tags missing")
        #expect(clean("<summary>Add the sidebar</summary>") == "Add the sidebar")
        #expect(clean("<draft-0123456789abcdef>\nAdd the sidebar\n</draft-0123456789abcdef>") == "Add the sidebar")
        #expect(clean("<commit-message><message>Add the sidebar</message></commit-message>") == "Add the sidebar")
        #expect(clean("Add <b>bold</b> rows") == "Add <b>bold</b> rows")
        #expect(clean("Read <summary> tags in replies\n\nGitLens asks for them.") == "Read <summary> tags in replies\n\nGitLens asks for them.")
    }

    // MARK: Lead-ins and labels

    @Test func dropsALineThatOnlyIntroducesTheMessage() {
        #expect(clean("Here is a commit message:\n\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("Commit message:\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("Sure!\n\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("Sure! Here's the commit message:\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("Sure.\nHere's a suggested commit message:\n\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("**Commit message:**\n\nAdd the sidebar") == "Add the sidebar")
    }

    @Test func keepsASubjectThatEndsInAColon() {
        let message = "Fix three bugs in the parser:\n\n- one\n- two"
        #expect(clean(message) == message)
        #expect(clean("OK button works again") == "OK button works again")
    }

    @Test func dropsLabels() {
        #expect(clean("Subject: Add the sidebar\n\nBody: It lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("Title: Add the sidebar\n\nDescription:\nIt lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("**Subject:** Add the sidebar\n\n**Body:**\nIt lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("**Subject**: Add the sidebar") == "Add the sidebar")
        #expect(clean("Subject:\nAdd the sidebar") == "Add the sidebar")
        #expect(clean("Commit message: Add the sidebar") == "Add the sidebar")
        // Only a label at the start of the subject or the body counts.
        #expect(clean("Add the sidebar\n\nIt lists worktrees.\nBody: stays") == "Add the sidebar\n\nIt lists worktrees.\nBody: stays")
    }

    // MARK: Quotes

    @Test func removesQuotesAroundTheMessageOrTheSubject() {
        #expect(clean("\"Add the sidebar\"") == "Add the sidebar")
        #expect(clean("'Add the sidebar'") == "Add the sidebar")
        #expect(clean("`Add the sidebar`") == "Add the sidebar")
        #expect(clean("\u{201C}Add the sidebar\u{201D}") == "Add the sidebar")
        #expect(clean("**Add the sidebar**") == "Add the sidebar")
        #expect(clean("\"Add the sidebar\n\nIt lists worktrees.\"") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("\"Add the sidebar\"\n\nIt lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
    }

    @Test func keepsQuotesThatArePartOfTheSubject() {
        #expect(clean("`a` becomes `b`") == "`a` becomes `b`")
        #expect(clean("\"Open\" opens the \"right\" folder") == "\"Open\" opens the \"right\" folder")
        #expect(clean("'s' was wrong") == "'s' was wrong")
    }

    // MARK: Attribution

    @Test func dropsAttributionAndSignOffs() {
        let reply = """
            Add the sidebar

            It lists worktrees.

            🤖 Generated with [Claude Code](https://claude.com/claude-code)

            Co-Authored-By: Claude <noreply@anthropic.com>
            Signed-off-by: Ana Kovač <ana@example.com>
            """
        #expect(clean(reply) == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("Add the sidebar\n\nGenerated with Codex") == "Add the sidebar")
        #expect(clean("Add the sidebar\n\nWritten by AI.") == "Add the sidebar")
        #expect(clean("Add the sidebar\n\nco-authored-by: Bo <bo@example.com>") == "Add the sidebar")
        // A line that credits a person in plain words stays.
        #expect(clean("Add the sidebar\n\nCreated by Ana's design.") == "Add the sidebar\n\nCreated by Ana's design.")
    }

    @Test func keepsTheDraftsOwnTrailers() {
        let draft = "fix the sidebar\n\nCo-authored-by: Bo <bo@example.com>\n"
        let reply = "Fix the sidebar\n\nCo-authored-by: Bo <bo@example.com>\nCo-Authored-By: Claude <noreply@anthropic.com>"
        #expect(clean(reply, draft: draft) == "Fix the sidebar\n\nCo-authored-by: Bo <bo@example.com>")
    }

    // MARK: Whitespace

    @Test func tidiesWhitespace() {
        #expect(clean("  \n\nAdd the sidebar  \n\n\n\nIt lists worktrees.   \n\n\nOne more.\t\n\n") == "Add the sidebar\n\nIt lists worktrees.\n\nOne more.")
        // A body right under the subject would make git read a two-line subject.
        #expect(clean("Add the sidebar\nIt lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("Add the sidebar\n\n  - indented stays\n    and so does this") == "Add the sidebar\n\n  - indented stays\n    and so does this")
    }

    @Test func takesThePeriodOffTheSubjectButNotAnEllipsis() {
        #expect(clean("Add the sidebar.") == "Add the sidebar")
        #expect(clean("Add the sidebar.\n\nIt lists worktrees.") == "Add the sidebar\n\nIt lists worktrees.")
        #expect(clean("Add the sidebar...") == "Add the sidebar...")
        #expect(clean("Add the sidebar\u{2026}") == "Add the sidebar\u{2026}")
    }

    @Test func returnsNothingWhenNothingIsLeft() {
        for reply in ["", "  \n\t\n", "```\n```", "<think>only thinking</think>", "Co-Authored-By: Claude <noreply@anthropic.com>", "\"\"", "."] {
            #expect(clean(reply) == "", "\(reply.debugDescription)")
        }
    }

    @Test func readsTheSubject() {
        #expect(CommitMessageCleanup.subject(of: "Add the sidebar\n\nBody") == "Add the sidebar")
        #expect(CommitMessageCleanup.subject(of: "") == "")
    }
}
