import XCTest
@testable import SublineCore

final class TextFileTests: XCTestCase {
    var root: URL!
    let store = TextFileStore()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SublineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testUnicodeBOMAndEveryLineEndingRoundTrip() throws {
        for (index, ending) in [LineEnding.lf, .crlf, .cr].enumerated() {
            for bom in [false, true] {
                let text = "中文😀👩🏽‍💻e\u{301}\n第二行\n"
                var original = bom ? Data([0xef, 0xbb, 0xbf]) : Data()
                original.append(contentsOf: ending.encode(text).utf8)
                let url = try file("\(index)-\(bom).txt", original)
                let loaded = try store.load(url)
                XCTAssertEqual(loaded.text, text)
                XCTAssertEqual(loaded.lineEnding, ending)
                XCTAssertEqual(loaded.hasBOM, bom)
                let doc = EditorDocument(url: url, loaded: loaded)
                try doc.save(to: url, expecting: .existing(loaded.snapshot), using: store)
                XCTAssertEqual(try Data(contentsOf: url), original)
                doc.edit(text + "末尾💡\n")
                try doc.save(to: url, expecting: .existing(loaded.snapshot), using: store)
                var expected = bom ? Data([0xef, 0xbb, 0xbf]) : Data()
                expected.append(contentsOf: ending.encode(text + "末尾💡\n").utf8)
                XCTAssertEqual(try Data(contentsOf: url), expected)
                XCTAssertFalse(doc.isDirty)
            }
        }
    }

    func testMixedLineEndingsUseFirstNewline() throws {
        let url = try file("mixed.txt", Data("甲\r\n乙\n丙\r丁".utf8))
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        XCTAssertEqual(doc.text, "甲\n乙\n丙\n丁")
        try doc.save(to: url, expecting: .missing, using: store)
        XCTAssertEqual(try String(contentsOf: url), "甲\r\n乙\r\n丙\r\n丁")
    }

    func testInvalidUTF8UTF16BinaryAndDirectoriesAreRejectedWithoutMutation() throws {
        for (name, data, error) in [
            ("invalid", Data([0xc3, 0x28]), TextFileError.unsupportedEncoding),
            ("utf16", Data([0xff, 0xfe, 0x41, 0x00]), .unsupportedEncoding),
            ("nul", Data([0x61, 0x00, 0x62]), .binaryContent),
            ("binary", Data([0x61, 0x01, 0x62]), .binaryContent)
        ] {
            let url = try file(name, data)
            XCTAssertThrowsError(try store.load(url)) { XCTAssertEqual($0 as? TextFileError, error) }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
        XCTAssertThrowsError(try store.load(root)) { XCTAssertEqual($0 as? TextFileError, .notRegularFile) }
    }

    func testSizeBoundaryAndOversizedSparseInputRejectedBeforeDecode() throws {
        let limit = TextFileStore.maximumBytes
        let exact = try file("exact", Data(repeating: 0x61, count: limit))
        XCTAssertEqual(try store.load(exact).text.utf8.count, limit)
        let sparse = try file("oversize", Data())
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(limit + 1))
        try handle.close()
        // The sparse contents contain NUL: size rejection must win over decode.
        XCTAssertThrowsError(try store.load(sparse)) { XCTAssertEqual($0 as? TextFileError, .tooLarge) }
        let size = try FileManager.default.attributesOfItem(atPath: sparse.path)[.size] as? NSNumber
        XCTAssertEqual(size?.intValue, limit + 1)
    }

    func testExternalChangeSameSizeAndTimestampIsNotOverwritten() throws {
        let url = try file("external", Data("first".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        doc.edit("my changes")
        try Data("other".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: url.path)
        XCTAssertThrowsError(try doc.save(to: url, expecting: try store.expectation(at: url), using: store)) {
            XCTAssertEqual($0 as? TextFileError, .conflict)
        }
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.text, "my changes")
        XCTAssertEqual(try String(contentsOf: url), "other")
    }

    func testDeletionAndReplacementAreConflicts() throws {
        let url = try file("removed", Data("initial".utf8))
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        doc.edit("modified")
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try doc.save(to: url, expecting: .missing, using: store)) {
            XCTAssertEqual($0 as? TextFileError, .conflict)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(doc.isDirty)
        try Data("initial".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try doc.save(to: url, expecting: .missing, using: store))
    }

    func testFailedSaveDoesNotChangePathOrSavedState() throws {
        let doc = EditorDocument()
        doc.edit("草稿😀")
        let invalid = root.appendingPathComponent("missing/draft.txt")
        XCTAssertThrowsError(try doc.save(to: invalid, expecting: .missing, using: store))
        XCTAssertNil(doc.url)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(doc.savedText, "")
        XCTAssertEqual(doc.text, "草稿😀")
    }

    func testSaveAsAndDestinationRace() throws {
        let source = try file("source", Data("source".utf8))
        let doc = EditorDocument(url: source, loaded: try store.load(source))
        doc.edit("new 中文😀")
        let target = root.appendingPathComponent("target")
        let expectation = try store.expectation(at: target)
        try Data("external".utf8).write(to: target)
        XCTAssertThrowsError(try doc.save(to: target, expecting: expectation, using: store)) {
            XCTAssertEqual($0 as? TextFileError, .conflict)
        }
        XCTAssertEqual(doc.url, source)
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: target), "external")
        try doc.save(to: target, expecting: try store.expectation(at: target), using: store)
        XCTAssertEqual(doc.url, target)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: target), "new 中文😀")
        XCTAssertEqual(try String(contentsOf: source), "source")
    }

    func testOversizedOutputRefusesWithoutTouchingFile() throws {
        let url = try file("output", Data("safe".utf8))
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        doc.edit(String(repeating: "a", count: TextFileStore.maximumBytes + 1))
        XCTAssertThrowsError(try doc.save(to: url, expecting: .missing, using: store)) {
            XCTAssertEqual($0 as? TextFileError, .tooLarge)
        }
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try String(contentsOf: url), "safe")
    }

    func testCanonicallyEquivalentUnicodeStillMarksByteChangesDirty() throws {
        let url = try file("normalization", Data("e\u{301}".utf8))
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        doc.edit("é")
        XCTAssertTrue(doc.isDirty)
        try doc.save(to: url, expecting: .missing, using: store)
        XCTAssertEqual(try Data(contentsOf: url), Data("é".utf8))
    }

    func testAtomicSavePreservesPermissionsAndLeavesNoTemporaryFile() throws {
        let url = try file("private.txt", Data("old".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let doc = EditorDocument(url: url, loaded: try store.load(url))
        doc.edit("新文本😀")
        try doc.save(to: url, expecting: .missing, using: store)
        XCTAssertEqual(try Data(contentsOf: url), Data("新文本😀".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["private.txt"])
    }

    func testCanonicalAliasAndDirtyStateAreIndependent() throws {
        let url = try file("original", Data("内容".utf8))
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertEqual(store.canonicalURL(url), store.canonicalURL(alias))
        let a = EditorDocument(url: url, loaded: try store.load(alias))
        let b = EditorDocument()
        a.edit("a")
        b.edit("b")
        XCTAssertTrue(a.isDirty)
        XCTAssertTrue(b.isDirty)
        a.edit("内容")
        XCTAssertFalse(a.isDirty)
        XCTAssertTrue(b.isDirty)
    }
}
