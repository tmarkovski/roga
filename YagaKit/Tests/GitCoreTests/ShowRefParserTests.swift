import Testing
@testable import GitCore

struct ShowRefParserTests {
    let commit = "da9ff97390adfc8a4a4b4c0f0a1481c9084145d5"
    let tag = "a29ac133f920c06cbb0d2c96475d9067ace72ca7"
    let first = "ca732cfef503594e47855777e758bd0539fcecbd"

    @Test func readsHeadAndWhatTagsLeadTo() throws {
        let output = """
            \(commit) HEAD
            \(tag) refs/tags/v0.1
            \(first) refs/tags/v0.1^{}
            \(commit) refs/tags/light

            """
        let result = try ShowRefParser.parse(Array(output.utf8))
        #expect(result.head == ObjectID(hex: commit))
        #expect(result.peeled == ["refs/tags/v0.1": try #require(ObjectID(hex: first))])
    }

    @Test func readsNothing() throws {
        let result = try ShowRefParser.parse([])
        #expect(result.head == nil)
        #expect(result.peeled.isEmpty)
    }

    @Test func rejectsOtherOutput() {
        #expect(throws: ParseError.self) {
            try ShowRefParser.parse(Array("refs/tags/v0.1 \(tag)\n".utf8))
        }
    }
}
