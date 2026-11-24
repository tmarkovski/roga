import Testing
@testable import GitCore

struct CommitIdentityParserTests {
    /// One setting as `git config -z --show-scope --show-origin` prints it.
    func setting(_ scope: String, _ origin: String, _ key: String, _ value: String?) -> [UInt8] {
        Array((scope + "\0" + origin + "\0" + key + (value.map { "\n" + $0 } ?? "") + "\0").utf8)
    }

    @Test func readsEachSettingWithWhereItComesFrom() throws {
        let output = setting("global", "file:/Users/sam/.gitconfig", "user.name", "Sam Rivera")
            + setting("global", "file:/Users/sam/.gitconfig", "user.email", "sam@rivera.dev")
            + setting("global", "file:/Users/sam/.gitconfig", "gpg.format", "ssh")
            + setting("global", "file:/Users/sam/.gitconfig", "user.signingkey", "~/.ssh/id_ed25519.pub")
            + setting("global", "file:/Users/sam/.gitconfig", "commit.gpgsign", "true")
        let identity = try CommitIdentityParser.parse(output)

        #expect(identity.shownName == "Sam Rivera")
        #expect(identity.shownEmail == "sam@rivera.dev")
        #expect(identity.email?.origin == ConfigOrigin(scope: .global, file: "/Users/sam/.gitconfig"))
        #expect(identity.signs)
        #expect(identity.format == .ssh)
        #expect(identity.key == "~/.ssh/id_ed25519.pub")
        #expect(identity.problem == nil)
        #expect(identity.initials == "SR")
    }

    @Test func aLaterSettingCounts() throws {
        let output = setting("global", "file:/Users/sam/.gitconfig", "user.email", "sam@rivera.dev")
            + setting("global", "file:/Users/sam/.gitconfig-work", "user.email", "sam.rivera@acme.com")
            + setting("local", "file:config", "user.name", "Sam R.")
        let identity = try CommitIdentityParser.parse(output)

        #expect(identity.shownEmail == "sam.rivera@acme.com")
        #expect(identity.email?.origin.file == "/Users/sam/.gitconfig-work")
        #expect(identity.name?.origin == ConfigOrigin(scope: .local, file: "config"))
    }

    @Test func readsAKeyWithNoValueAsTrue() throws {
        let identity = try CommitIdentityParser.parse(
            setting("global", "file:/Users/sam/.gitconfig", "commit.gpgsign", nil)
        )
        #expect(identity.signsCommits?.value == nil)
        #expect(identity.signs)
    }

    @Test func readsASettingFromTheCommandLine() throws {
        let identity = try CommitIdentityParser.parse(setting("command", "command line:", "user.email", "ci@example.com"))
        #expect(identity.email?.origin == ConfigOrigin(scope: .command, file: nil))
    }

    @Test func readsNothingAsNoIdentity() throws {
        let identity = try CommitIdentityParser.parse([])
        #expect(identity == CommitIdentity())
        #expect(identity.problem == .noEmail)
        #expect(identity.initials == "?")
    }

    @Test func refusesWhatItCantRead() {
        #expect(throws: ParseError.self) { try CommitIdentityParser.parse(Array("global\0file:/a\0".utf8)) }
        #expect(throws: ParseError.self) { try CommitIdentityParser.parse(setting("global", "nowhere", "user.name", "Sam")) }
        #expect(throws: ParseError.self) { try CommitIdentityParser.parse(setting("global", "file:/a", "core.editor", "vi")) }
    }
}

struct CommitIdentityTests {
    func identity(email: String? = "sam@rivera.dev", signs: String? = nil, format: String? = nil, key: String? = nil) -> CommitIdentity {
        let origin = ConfigOrigin(scope: .global, file: "/Users/sam/.gitconfig")
        return CommitIdentity(
            name: CommitIdentity.Setting("Sam Rivera", origin: origin),
            email: email.map { CommitIdentity.Setting($0, origin: origin) },
            signingKey: key.map { CommitIdentity.Setting($0, origin: origin) },
            signsCommits: signs.map { CommitIdentity.Setting($0, origin: origin) },
            signingFormat: format.map { CommitIdentity.Setting($0, origin: origin) }
        )
    }

    @Test func readsBooleansAsGitDoes() {
        for value in ["true", "yes", "On", "1", "-1"] {
            #expect(identity(signs: value).signs, "\(value)")
        }
        for value in ["false", "no", "off", "0", "", "maybe"] {
            #expect(!identity(signs: value).signs, "\(value)")
        }
        #expect(!identity().signs)
    }

    @Test func saysWhatWouldGoWrong() {
        #expect(identity(email: nil).problem == .noEmail)
        #expect(identity(email: "  ").problem == .noEmail)
        #expect(identity(signs: "true", format: "ssh").problem == .noSigningKey)
        #expect(identity(signs: "true", format: "ssh", key: "~/.ssh/id.pub").problem == nil)
        // OpenPGP and X.509 find a key from the email.
        #expect(identity(signs: "true").problem == nil)
        #expect(identity(signs: "true", format: "x509").problem == nil)
        #expect(identity(signs: "false", format: "ssh").problem == nil)

        var withCommand = identity(signs: "true", format: "ssh")
        withCommand.defaultKeyCommand = CommitIdentity.Setting("ssh-add -L", origin: ConfigOrigin(scope: .global))
        #expect(withCommand.problem == nil)
    }

    @Test func comparesTheNameAndTheEmailWithoutCase() {
        #expect(identity(email: "Sam@Rivera.dev").commitsAsSame(as: identity()))
        #expect(!identity(email: "sam@acme.com").commitsAsSame(as: identity()))
        #expect(identity(signs: "true").commitsAsSame(as: identity()))
    }

    @Test func makesInitials() {
        var one = identity()
        one.name = CommitIdentity.Setting("sam", origin: ConfigOrigin(scope: .global))
        #expect(one.initials == "S")
        one.name = CommitIdentity.Setting("Ana María de la Cruz", origin: ConfigOrigin(scope: .global))
        #expect(one.initials == "AM")
        one.name = nil
        #expect(one.initials == "S")
    }
}
