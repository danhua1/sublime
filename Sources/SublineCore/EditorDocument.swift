import Foundation

public final class EditorDocument {
    public let id = UUID()
    public private(set) var url: URL?
    public private(set) var text: String
    public private(set) var savedText: String
    public private(set) var lineEnding: LineEnding
    public private(set) var hasBOM: Bool
    public private(set) var baseline: FileSnapshot?
    public var isDirty: Bool { !text.utf8.elementsEqual(savedText.utf8) }
    public var title: String { url?.lastPathComponent ?? "未命名" }

    public init() {
        text = ""
        savedText = ""
        lineEnding = .lf
        hasBOM = false
    }

    public init(url: URL, loaded: LoadedText) {
        self.url = url
        text = loaded.text
        savedText = loaded.text
        lineEnding = loaded.lineEnding
        hasBOM = loaded.hasBOM
        baseline = loaded.snapshot
    }

    public func edit(_ newText: String) { text = newText }

    public func save(to target: URL, expecting: FileExpectation, using store: TextFileStore) throws {
        let canonical = store.canonicalURL(target)
        // A caller cannot accidentally bypass conflict protection by using Save As
        // with the original path and a freshly captured destination fingerprint.
        let expected: FileExpectation
        if canonical == url, let baseline = baseline { expected = .existing(baseline) }
        else { expected = expecting }
        let snapshot = try store.save(text: text, to: canonical, lineEnding: lineEnding,
                                      hasBOM: hasBOM, expecting: expected)
        url = canonical
        baseline = snapshot
        savedText = text
    }
}
