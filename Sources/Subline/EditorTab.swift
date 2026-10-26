import AppKit
import SublineCore

final class EditorTab: NSObject, NSTextViewDelegate {
    let document: EditorDocument
    let scrollView = NSScrollView()
    let textView: NSTextView
    var onChange: (() -> Void)?
    // NSTextView otherwise falls back to the window's shared undo manager,
    // which would undo another tab after switching editors.
    private let bufferUndoManager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { bufferUndoManager }

    init(document: EditorDocument) {
        self.document = document
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = true
        textView = NSTextView(frame: .zero, textContainer: container)
        super.init()
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = document.text
        textView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
    }

    func textDidChange(_ notification: Notification) {
        document.edit(textView.string)
        onChange?()
    }
}
