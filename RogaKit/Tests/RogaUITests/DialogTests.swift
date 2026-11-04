import CoreGraphics
import GitCore
import GitRunner
import Testing
@testable import RogaUI

/// What dialogs say, and the commands they show.
@Suite struct DialogTests {
    // MARK: Commands

    @Test func colorsTheOptionsThatCanLoseSomething() {
        let tokens = ShellCommand.tokens(["push", "--force-with-lease", "--force-if-includes"])
        #expect(tokens.map(\.text) == ["git", "push", "--force-with-lease", "--force-if-includes"])
        #expect(tokens.map(\.kind) == [.command, .command, .dangerousOption, .dangerousOption])
    }

    @Test func tellsOptionsAndValuesApart() {
        let tokens = ShellCommand.tokens(["push", "--set-upstream", "origin", "HEAD"])
        #expect(tokens.map(\.kind) == [.command, .command, .option, .value, .value])
    }

    @Test func aSubcommandCanHaveAVerb() {
        let tokens = ShellCommand.tokens(["worktree", "remove", "--force", "/tmp/a"])
        #expect(tokens.map(\.kind) == [.command, .command, .command, .dangerousOption, .value])
    }

    @Test func aBranchCalledLikeASubcommandIsStillAValue() {
        #expect(ShellCommand.tokens(["branch", "-D", "worktree"]).last?.kind == .value)
    }

    @Test func quotesWhatAShellWouldSplit() {
        #expect(ShellCommand.text(["worktree", "remove", "/tmp/My Work"]) == "git worktree remove '/tmp/My Work'")
        #expect(ShellCommand.text(["branch", "-D", "it's"]) == "git branch -D 'it'\\''s'")
        #expect(ShellCommand.text(["switch", "--create=tm/fix-1"]) == "git switch --create=tm/fix-1")
        #expect(ShellCommand.text(["config", ""]) == "git config ''")
    }

    @Test func copyingGivesOnlyWhatWillRun() {
        let lines: [TerminalLine] = [
            .ran(["pull", "--rebase"]),
            .gap,
            .comment("Undo the pull runs"),
            .command(["rebase", "--abort"]),
        ]
        #expect(CommandBlock.copied(lines) == "git rebase --abort")
    }

    @Test func copyingEveryCommandInOrder() {
        let lines: [TerminalLine] = [.command(["branch", "-D", "a"]), .command(["push", "--delete", "origin", "refs/heads/a"])]
        #expect(CommandBlock.copied(lines) == "git branch -D a\ngit push --delete origin refs/heads/a")
    }

    @Test func copyingWhatHappenedKeepsItAsItReads() {
        let lines: [TerminalLine] = [.ran(["switch", "main"]), .output("error: no")]
        #expect(CommandBlock.copied(lines) == "$ git switch main\nerror: no")
    }

    // MARK: Words

    @Test func namesCanBeSetApartFromWords() {
        let name = "main"
        let text: DialogText = "Delete \(code: name) for \("everyone")."
        #expect(text.parts == [.words("Delete "), .code("main"), .words(" for "), .words("everyone"), .words(".")])
        #expect(text.plain == "Delete main for everyone.")
    }

    @Test func sentencesGoOneAfterTheOther() {
        #expect(DialogText.sentences([]) == nil)
        #expect(DialogText.sentences(["One.", "Two."])?.plain == "One. Two.")
    }

    @Test func listsCommitsAndSaysHowManyMore() {
        let commits = [ListedCommit(hash: "abc", subject: "One")]
        #expect(DialogContent.commitRows(commits, total: 1) == [.commit(hash: "abc", subject: "One")])
        #expect(DialogContent.commitRows(commits, total: 13) == [.commit(hash: "abc", subject: "One"), .more("and 12 more")])
    }

    @Test func aRefusalPutsWhatGitSaidUnderTheCommand() {
        var dismissed = false
        let dialog = DialogContent.refusal(id: "a", title: "No", command: ["switch", "main"], said: "error: no") { dismissed = true }
        #expect(dialog.terminal == [.ran(["switch", "main"]), .output("error: no")])
        #expect(dialog.message == nil)
        #expect(dialog.buttons.map(\.title) == ["OK"])
        dialog.buttons[0].action()
        #expect(dismissed)
    }

    @Test func aRefusalWithNoCommandIsOnlyWords() {
        let dialog = DialogContent.refusal(id: "a", title: "No", command: nil, said: "That folder isn't a repository.") {}
        #expect(dialog.terminal.isEmpty)
        #expect(dialog.message?.plain == "That folder isn't a repository.")
    }

    @Test func anErrorFromGitSaysWhatRan() {
        let command = GitCommand(["switch", "main"], in: "/tmp")
        let error: any Error = GitError.failed(command, .exited(1), errorOutput: "error: no\n")
        #expect(error.gitArguments == ["switch", "main"])
        #expect(error.dialogMessage == "error: no")
    }

    // MARK: Pictures of a pull

    private func choice(behind: Int, ahead: Int) -> PullChoice {
        PullChoice(branch: "main", upstream: "origin/main", behind: behind, ahead: ahead)
    }

    @Test func eachCommitGetsADotUpToALimit() {
        #expect(PullPicture.dots(for: 1).count == 1)
        #expect(PullPicture.dots(for: PullPicture.dotLimit).count == PullPicture.dotLimit)
        #expect(PullPicture.dots(for: PullPicture.dotLimit).isCollapsed == false)
        #expect(PullPicture.dots(for: PullPicture.dotLimit + 1).count == 1)
        #expect(PullPicture.dots(for: PullPicture.dotLimit + 1).isCollapsed)
    }

    @Test func aRebaseIsOneLine() {
        let layout = PullPicture.layout(of: .rebase, choice: choice(behind: 3, ahead: 1))
        #expect(layout.dots.count == 5)
        #expect(layout.dots.first?.kind == .tip)
        #expect(layout.strokes.allSatisfy { !$0.isSecondLine && !$0.isDotted && !$0.isCurve })
        #expect(layout.labels.map(\.text) == ["main, your commit", "origin/main"])
    }

    @Test func aMergeIsTwoLinesThatJoin() {
        let layout = PullPicture.layout(of: .merge, choice: choice(behind: 3, ahead: 1))
        #expect(layout.dots.count == 6)
        #expect(layout.strokes.contains { $0.isSecondLine })
        #expect(layout.strokes.filter(\.isCurve).count == 2)
        #expect(layout.labels.map(\.text) == ["main, merge commit", "origin/main", "your commit"])
    }

    @Test func aLongHistoryBecomesADottedLineThatSaysHowMany() {
        for result in [PullPicture.Result.rebase, .merge] {
            let layout = PullPicture.layout(of: result, choice: choice(behind: 40, ahead: 12))
            #expect(layout.strokes.contains { $0.isDotted })
            #expect(layout.labels.contains { $0.text.contains("origin/main") })
            #expect(layout.labels.contains { $0.text.contains("40 commits") })
            #expect(layout.labels.contains { $0.text.contains("your 12 commits") })
        }
    }

    @Test(arguments: [(1, 1), (4, 4), (1, 4), (4, 1), (5, 5), (40, 12), (1, 100), (100, 1)])
    func everythingStaysInsideThePicture(behind: Int, ahead: Int) {
        for result in [PullPicture.Result.rebase, .merge] {
            let layout = PullPicture.layout(of: result, choice: choice(behind: behind, ahead: ahead))
            for dot in layout.dots {
                #expect(dot.point.y >= 0 && dot.point.y <= 100)
            }
            for stroke in layout.strokes {
                #expect(stroke.to.y >= stroke.from.y)
                #expect(stroke.to.y <= 100)
            }
            let ys = layout.dots.map(\.point.y)
            let distinct = Set(ys.map { Int($0 * 10) })
            // Nothing lands on top of something else on the same line.
            #expect(distinct.count >= ys.count - 1)
        }
    }

    @Test func wordsFollowHowManyAreYours() {
        #expect(PullPicture.summary(of: .rebase, yours: 1) == "A straight line, and your commit gets a new hash.")
        #expect(PullPicture.summary(of: .rebase, yours: 2) == "A straight line, and your commits get new hashes.")
        #expect(PullPicture.summary(of: .merge, yours: 1) == "A merge commit joins them, and your commit keeps its hash.")
        #expect(PullPicture.summary(of: .merge, yours: 2) == "A merge commit joins them, and your commits keep their hashes.")
    }
}
