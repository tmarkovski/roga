import Foundation
import Testing
@testable import GitCore

/// Reading the keys that can sign from `.pub` files, `ssh-add -L`,
/// `~/.ssh/config` and `gpg --list-secret-keys` (decision 106).
struct SigningKeyParserTests {
    // MARK: SSH

    @Test func readsAPublicKeyWithTheFingerprintSSHKeygenPrints() throws {
        let key = try #require(SSHPublicKeyParser.parse(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp sam@rivera.dev\n"
        ))
        #expect(key.type == "ssh-ed25519")
        #expect(key.typeName == "ED25519")
        #expect(key.comment == "sam@rivera.dev")
        // What `ssh-keygen -l -f` printed for this key.
        #expect(key.fingerprint == "SHA256:dTN2I5PqIERxt1Q5XUaOShsVC3P19WcFTUUImtv1RPI")
        #expect(key.literal == "key::ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp sam@rivera.dev")
        #expect(!key.isSecurityKey)
    }

    @Test func keepsACommentWithSpaces() throws {
        let key = try #require(SSHPublicKeyParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp Sam's work laptop"))
        #expect(key.comment == "Sam's work laptop")
    }

    @Test func leavesOutWhatIsntAKeyItCanSignWith() {
        #expect(SSHPublicKeyParser.parse("The agent has no identities.") == nil)
        #expect(SSHPublicKeyParser.parse("ssh-ed25519 not-base64!") == nil)
        #expect(SSHPublicKeyParser.parse("ssh-ed25519-cert-v01@openssh.com AAAAC3NzaC1lZDI1NTE5 cert") == nil)
        #expect(SSHPublicKeyParser.parseLines("The agent has no identities.\n").isEmpty)
    }

    @Test func marksASecurityKey() throws {
        let key = try #require(SSHPublicKeyParser.parse("sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t yubikey"))
        #expect(key.isSecurityKey)
        #expect(key.typeName == "ED25519-SK")
    }

    @Test func findsTheAgentSSHConfigNames() {
        let config = """
        # 1Password
        Host *
          IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
        """
        #expect(SSHConfigParser.identityAgent(in: config, home: "/Users/sam") == "/Users/sam/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
        #expect(SSHConfigParser.identityAgent(in: "identityagent=/tmp/agent.sock", home: "/Users/sam") == "/tmp/agent.sock")
        #expect(SSHConfigParser.identityAgent(in: "Host github.com\n  IdentityAgent none\n", home: "/Users/sam") == nil)
        #expect(SSHConfigParser.identityAgent(in: "#IdentityAgent /tmp/a\nHost *\n  User git\n", home: "/Users/sam") == nil)
    }

    @Test func findsTheEmailsInAComment() {
        #expect(KeyEmails.find(in: "Sam Rivera <sam@rivera.dev>") == ["sam@rivera.dev"])
        #expect(KeyEmails.find(in: "sam@laptop") == [])
        #expect(KeyEmails.find(in: "work, sam.rivera@acme.com") == ["sam.rivera@acme.com"])
    }

    // MARK: Allowed signers

    @Test func knowsWhetherTheAllowedSignersFileListsAKey() throws {
        let key = try #require(SSHPublicKeyParser.parse("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp sam@rivera.dev"))
        let file = """
        # Who signs what
        other@example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp
        "Sam@Rivera.dev,sam@acme.com" namespaces="git,file" valid-after="20260101" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp
        """
        #expect(AllowedSignersFile.lists(key, for: "sam@rivera.dev", in: file))
        #expect(AllowedSignersFile.lists(key, for: "sam@acme.com", in: file))
        #expect(AllowedSignersFile.lists(key, for: "other@example.com", in: file))
        #expect(!AllowedSignersFile.lists(key, for: "new@example.com", in: file))
        #expect(AllowedSignersFile.line(email: "sam@rivera.dev", key: key)
            == "sam@rivera.dev namespaces=\"git\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEl5c7+FTBhBHYT9TKz61AWx/U3+VjN1Mh2idso8ynyp")
    }

    @Test func findsACommitsSignatureInItsHeaders() {
        let commit = """
        tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        author T <t@example.com> 1764000000 +0000
        committer T <t@example.com> 1764000000 +0000
        gpgsig -----BEGIN SSH SIGNATURE-----
         U1NIU0lH
         -----END SSH SIGNATURE-----

        Signed
        """
        #expect(SSHSignatureParser.signature(inCommit: commit) == "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----")
        #expect(SSHSignatureParser.signature(inCommit: "tree 4b82\n\nUnsigned\ngpgsig in the message") == nil)
        // A signature too short to hold a key.
        #expect(SSHSignatureParser.publicKey(inSignature: "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----") == nil)
    }

    // MARK: Which key signed, before it's checked (decision 109)

    /// A signature gpg 2.5 made with an Ed25519 key whose fingerprint is
    /// 720096CD67EE2F537B73D7E068586E81E4F27998.
    static let openPGPSignature = """
    -----BEGIN PGP SIGNATURE-----

    iJEEABYKADkWIQRyAJbNZ+4vU3tz1+BoWG6B5PJ5mAUCawcGtBsUgAAAAAAEAA5t
    YW51MiwyLjUrMS4xMiwwLDMACgkQaFhugeTyeZi8LwD8DqCJic5a6Y++UDUk4Qcp
    hcd1Xu/KQ8OlhyPwqTKf2LQBAL8OEzyKBLnsk6Cl6ajaE5JOPjxV5fg7u7kuLrAC
    LEAN
    =b9UO
    -----END PGP SIGNATURE-----
    """

    @Test func readsWhichOpenPGPKeySignedAsGitWouldNameIt() {
        // The key ID that %GK prints: the fingerprint's last 16 digits.
        #expect(OpenPGPSignatureParser.keyID(inSignature: Self.openPGPSignature) == "68586E81E4F27998")
        // In a commit's header, whose lines after the first start with a
        // space, as the armor's blank line does.
        let header = Self.openPGPSignature.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: "\n ")
        let commit = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\ncommitter T <t@example.com> 1764000000 +0000\ngpgsig \(header)\n\nSigned"
        #expect(CommitSignatureParser.key(inCommit: commit) == "68586E81E4F27998")
        #expect(CommitSignatureParser.key(inCommit: "tree 4b82\n\nUnsigned") == nil)
        #expect(OpenPGPSignatureParser.keyID(inSignature: "-----BEGIN PGP SIGNATURE-----\nAAAA\n-----END PGP SIGNATURE-----") == nil)
    }

    @Test func readsTheKeyIDFromTheIssuersFingerprintAlone() {
        // A version 4 signature whose only subpacket is the issuer's
        // fingerprint, 33, for a version 4 key, whose ID ends it.
        let fingerprint = (0..<20).map { UInt8($0) }
        let body: [UInt8] = [4, 0x00, 22, 10, 0, 23, 22, 33, 4] + fingerprint + [0, 0]
        #expect(OpenPGPSignatureParser.keyID(inSignatureBody: body[...]) == fingerprint.suffix(8)[...])
        // A version 6 key's ID starts its 32-byte fingerprint, and version 6
        // signatures count their subpackets with four bytes.
        let long = (100..<132).map { UInt8($0) }
        let v6: [UInt8] = [6, 0x00, 27, 10, 0, 0, 0, 35, 34, 33, 6] + long + [0, 0, 0, 0]
        #expect(OpenPGPSignatureParser.keyID(inSignatureBody: v6[...]) == long.prefix(8)[...])
    }

    // MARK: OpenPGP

    /// A key that signs, then one that has expired, one that was revoked, one
    /// that only encrypts, one whose signing subkey is on a card, and one
    /// whose secret is only a stub.
    static let gpgOutput = """
    sec:u:255:22:4B5A69784F1E2D3C:1732500000:::u:::scESC:::+::ed25519:::0:
    fpr:::::::::9A8B7C6D5E4F30211A2B3C4D4B5A69784F1E2D3C:
    grp:::::::::0123456789ABCDEF0123456789ABCDEF01234567:
    uid:u::::1732500000::0123456789ABCDEF0123456789ABCDEF01234567::Sam Rivera (work\\x3a laptop) <sam@rivera.dev>::::::::::0:
    uid:r::::1732500000::1123456789ABCDEF0123456789ABCDEF01234567::Old Name <old@example.com>::::::::::0:
    sec:e:255:22:1111222233334444:1500000000:1600000000::u:::sc:::+::ed25519:::0:
    fpr:::::::::AAAA000011112222333344445555666611112222:
    uid:e::::1500000000::2123456789ABCDEF0123456789ABCDEF01234567::Expired <expired@example.com>::::::::::0:
    sec:r:255:22:5555666677778888:1500000000:::u:::sc:::+::ed25519:::0:
    fpr:::::::::BBBB000011112222333344445555666677778888:
    uid:r::::1500000000::3123456789ABCDEF0123456789ABCDEF01234567::Revoked <revoked@example.com>::::::::::0:
    sec:u:255:22:9999AAAABBBBCCCC:1732500000:::u:::cC:::+::ed25519:::0:
    fpr:::::::::CCCC0000111122223333444455559999AAAABBBB:
    uid:u::::1732500000::4123456789ABCDEF0123456789ABCDEF01234567::Encrypts <enc@example.com>::::::::::0:
    ssb:u:255:18:DDDDEEEEFFFF0000:1732500000::::::e:::+::cv25519::
    fpr:::::::::DDDD00001111222233334444DDDDEEEEFFFF0000:
    sec:u:4096:1:0123456789ABCDEF:1732500000:::u:::cSC:::#:::23::0:
    fpr:::::::::EEEE00001111222233334444000123456789ABCDEF:
    uid:u::::1732500000::5123456789ABCDEF0123456789ABCDEF01234567::Card <card@example.com>::::::::::0:
    ssb:u:4096:1:FEDCBA9876543210:1732500000::::::s:::D2760001240103040006123456780000:::23:
    fpr:::::::::FFFF0000111122223333FEDCBA9876543210FFFF:
    sec:u:255:22:ABCDABCDABCDABCD:1732500000:::u:::scSC:::#::ed25519:::0:
    fpr:::::::::ABCD0000111122223333ABCDABCDABCDABCDABCD:
    uid:u::::1732500000::6123456789ABCDEF0123456789ABCDEF01234567::Stub <stub@example.com>::::::::::0:
    """

    @Test func listsOnlyTheKeysThatCanSignNow() {
        let keys = OpenPGPKeyParser.parse(Self.gpgOutput, now: Date(timeIntervalSince1970: 1_764_000_000))
        #expect(keys.map(\.fingerprint) == [
            "9A8B7C6D5E4F30211A2B3C4D4B5A69784F1E2D3C",
            "EEEE00001111222233334444000123456789ABCDEF",
        ])
    }

    @Test func readsAKeysUserIDsAndAlgorithm() throws {
        let key = try #require(OpenPGPKeyParser.parse(Self.gpgOutput, now: Date(timeIntervalSince1970: 1_764_000_000)).first)
        // The revoked user ID is left out, and `\x3a` is a colon.
        #expect(key.userIDs == ["Sam Rivera (work: laptop) <sam@rivera.dev>"])
        #expect(key.algorithm == "ED25519")
        #expect(key.keyID == "4B5A69784F1E2D3C")
        #expect(!key.isOnCard)
    }

    @Test func marksAKeyWhoseSigningSubkeyIsOnACard() throws {
        let keys = OpenPGPKeyParser.parse(Self.gpgOutput, now: Date(timeIntervalSince1970: 1_764_000_000))
        let card = try #require(keys.last)
        #expect(card.isOnCard)
        #expect(card.algorithm == "RSA 4096")
    }

    @Test func leavesOutAKeyThatExpiresBeforeNow() {
        let soon = """
        sec:u:255:22:4B5A69784F1E2D3C:1732500000:1764000000::u:::scESC:::+::ed25519:::0:
        fpr:::::::::9A8B7C6D5E4F30211A2B3C4D4B5A69784F1E2D3C:
        uid:u::::1732500000::0123::Sam <sam@rivera.dev>::::::::::0:
        """
        #expect(OpenPGPKeyParser.parse(soon, now: Date(timeIntervalSince1970: 1_763_000_000)).count == 1)
        #expect(OpenPGPKeyParser.parse(soon, now: Date(timeIntervalSince1970: 1_765_000_000)).isEmpty)
    }
}
