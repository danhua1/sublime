import AppKit

enum CloseChoice { case save, discard, cancel }

protocol EditorInteractions: AnyObject {
    func openURLs() -> [URL]
    func saveURL(for document: EditorTab) -> URL?
    func closeChoice(for document: EditorTab) -> CloseChoice
    func showError(_ error: Error)
}

final class NativeInteractions: EditorInteractions {
    // Only used by the explicit smoke entry to cancel real modal panels.
    var panelObserver: ((NSWindow) -> Void)?
    var isolatedDirectory: URL?

    func openURLs() -> [URL] {
        let panel = NSOpenPanel()
        panel.directoryURL = isolatedDirectory
        panel.title = "打开 UTF-8 文本（最大 20 MiB）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        observe(panel)
        return panel.runModal() == .OK ? panel.urls : []
    }

    func saveURL(for document: EditorTab) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存 UTF-8 文本"
        panel.nameFieldStringValue = document.document.title == "未命名" ? "未命名.txt" : document.document.title
        panel.directoryURL = isolatedDirectory ?? document.document.url?.deletingLastPathComponent()
        panel.canCreateDirectories = true
        observe(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }

    func closeChoice(for document: EditorTab) -> CloseChoice {
        let alert = NSAlert()
        alert.messageText = "要保存对“\(document.document.title)”的修改吗？"
        alert.informativeText = "不保存将丢弃此标签的修改。取消会保留标签与正文。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        observe(alert.window)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "操作未完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func observe(_ panel: NSWindow) {
        guard let observer = panelObserver else { return }
        // Modal panels run a nested event loop; a queued main-dispatch block
        // cannot re-enter a smoke assertion already executing on that queue.
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard panel.isVisible else { return }
            timer.invalidate()
            observer(panel)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
}
