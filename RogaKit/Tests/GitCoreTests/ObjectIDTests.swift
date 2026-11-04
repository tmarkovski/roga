import GitCore
import Testing

struct ObjectIDTests {
    // The IDs of the empty tree in each format.
    let sha1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    let sha256 = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

    @Test func readsSHA1() throws {
        let id = try #require(ObjectID(hex: sha1))
        #expect(id.format == .sha1)
        #expect(id.hex == sha1)
    }

    @Test func readsSHA256() throws {
        let id = try #require(ObjectID(hex: sha256))
        #expect(id.format == .sha256)
        #expect(id.hex == sha256)
    }

    @Test func acceptsUppercaseDigits() {
        #expect(ObjectID(hex: sha1.uppercased()) == ObjectID(hex: sha1))
    }

    @Test(arguments: [
        "",
        "4b825dc",
        "4b825dc642cb6eb9a060e54bf8d69288fbee490",
        "4b825dc642cb6eb9a060e54bf8d69288fbee49040",
        "4b825dc642cb6eb9a060e54bf8d69288fbee490g",
        "4b825dc642cb6eb9a060e54bf8d69288fbee490 ",
    ])
    func rejectsMalformedHex(_ text: String) {
        #expect(ObjectID(hex: text) == nil)
    }

    @Test func readsBytes() throws {
        let id = try #require(ObjectID(bytes: (0..<32).map { UInt8($0 * 8) }))
        #expect(id.format == .sha256)
        #expect(id.hex == "0008101820283038404850586068707880889098a0a8b0b8c0c8d0d8e0e8f0f8")
        #expect(ObjectID(bytes: [UInt8](repeating: 0, count: 21)) == nil)
    }

    @Test(arguments: ObjectFormat.allCases)
    func loadsRawBytes(_ format: ObjectFormat) throws {
        // One byte more than the ID, so that reading too far would show.
        let bytes = (0...format.byteCount).map { UInt8(255 - $0) }
        let id = bytes.withUnsafeBytes { ObjectID(loading: $0.baseAddress!, format: format) }
        #expect(id == ObjectID(bytes: bytes.prefix(format.byteCount)))
        #expect(id.byte(at: 0) == 255)
        #expect(id.byte(at: format.byteCount - 1) == UInt8(256 - format.byteCount))
    }

    @Test func ordersLikeTheBytes() throws {
        let low = try #require(ObjectID(hex: "00ffffffffffffffffffffffffffffffffffffff"))
        let high = try #require(ObjectID(hex: "0100000000000000000000000000000000000000"))
        #expect(low < high)
        #expect(!(high < low))
    }
}
