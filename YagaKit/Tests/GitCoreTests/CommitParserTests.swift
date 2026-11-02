import Testing
@testable import GitCore

struct CommitParserTests {
    let id = ObjectID(hex: "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5")!
    let tree = "407153ae6640b677b6d83c08329048174e634843"
    let parent = "ef4cfd964ac0378cb3723640730be1b46724b795"
    let otherParent = "b07dd8d5b4878ff9b1874af39742374879add7e1"

    func parse(_ text: String) throws -> CommitInfo {
        try CommitParser.parse(Array(text.utf8), id: id)
    }

    @Test func readsACommit() throws {
        let commit = try parse("""
            tree \(tree)
            parent \(parent)
            author Ana Kovač <ana@example.com> 1767261600 +0100
            committer Sam Lee <sam@example.com> 1767265200 -0530

            Change the app

            The body says why.

            """)
        #expect(commit.id == id)
        #expect(commit.tree == ObjectID(hex: tree))
        #expect(commit.parents == [ObjectID(hex: parent)])
        #expect(commit.author == Signature(name: "Ana Kovač", email: "ana@example.com", time: 1767261600, timeZoneOffset: 3600))
        #expect(commit.committer == Signature(name: "Sam Lee", email: "sam@example.com", time: 1767265200, timeZoneOffset: -19800))
        #expect(commit.message == "Change the app\n\nThe body says why.\n")
        #expect(commit.subject == "Change the app")
        #expect(commit.body == "The body says why.")
    }

    @Test func readsEveryParentAndSkipsSignatures() throws {
        let commit = try parse("""
            tree \(tree)
            parent \(parent)
            parent \(otherParent)
            author Ana Kovac <ana@example.com> 1767261600 +0000
            committer Ana Kovac <ana@example.com> 1767261600 +0000
            gpgsig -----BEGIN PGP SIGNATURE-----
             author Not Someone <not@example.com> 0 +0000
             -----END PGP SIGNATURE-----

            Merge the feature

            """)
        #expect(commit.parents == [ObjectID(hex: parent), ObjectID(hex: otherParent)])
        #expect(commit.author.name == "Ana Kovac")
        #expect(commit.subject == "Merge the feature")
    }

    @Test func joinsTheFirstParagraphLikeGit() throws {
        let commit = try parse("""
            tree \(tree)
            author Ana Kovac <ana@example.com> 1767261600 +0000
            committer Ana Kovac <ana@example.com> 1767261600 +0000


            A subject that   \n  goes on to a second line
            \t
            And a body.
            """)
        #expect(commit.subject == "A subject that   goes on to a second line")
        #expect(commit.body == "And a body.")
    }

    @Test func keepsTheBodysParagraphs() throws {
        let commit = try parse("tree \(tree)\n\nSubject\n\n\nFirst\nlines\n\nSecond\n\n\n")
        #expect(commit.body == "First\nlines\n\nSecond")
    }

    @Test func readsAMessageWithWindowsLineEndings() throws {
        let commit = try parse("tree \(tree)\n\nSubject\r\n\r\nThe body\r\ngoes on\r\n")
        #expect(commit.subject == "Subject")
        #expect(commit.body == "The body\ngoes on")
    }

    @Test func hasNoBodyWithOnlyASubject() throws {
        #expect(try parse("tree \(tree)\n\nSubject\n").body == "")
        #expect(try parse("tree \(tree)\n\n").body == "")
    }

    @Test func convertsTheCommitsEncoding() throws {
        var contents = Array("""
            tree \(tree)
            author Ana Kova
            """.utf8)
        // "č" isn't in Latin-1, so this name uses "é" instead.
        contents += [0xE9]
        contents += Array("""
             <ana@example.com> 1767261600 +0000
            committer Ana Kovac <ana@example.com> 1767261600 +0000
            encoding ISO-8859-1

            Caf
            """.utf8)
        contents += [0xE9, 0x0A]
        let commit = try CommitParser.parse(contents, id: id)
        #expect(commit.author.name == "Ana Kovaé")
        #expect(commit.message == "Café\n")
    }

    @Test func acceptsDamagedSignatures() throws {
        let commit = try parse("""
            tree \(tree)
            author Nobody
            committer Ana Kovac <ana@example.com> soon +01

            Message
            """)
        #expect(commit.author == Signature(name: "Nobody", email: "", time: 0, timeZoneOffset: 0))
        #expect(commit.committer == Signature(name: "Ana Kovac", email: "ana@example.com", time: 0, timeZoneOffset: 0))
    }

    @Test func readsACommitWithoutAMessage() throws {
        let commit = try parse("""
            tree \(tree)
            author Ana Kovac <ana@example.com> 1767261600 +0000
            committer Ana Kovac <ana@example.com> 1767261600 +0000
            """)
        #expect(commit.message == "")
        #expect(commit.subject == "")
    }

    @Test func rejectsAnObjectWithoutATree() {
        #expect(throws: ParseError.self) {
            try parse("object \(tree)\ntype commit\ntag v1.0\n\nA tag\n")
        }
    }
}
