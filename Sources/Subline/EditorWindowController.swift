import AppKit
import SublineCore

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {
    let store = TextFileStore()
    let tabView = NSTabView()
    private(set) var tabs: [EditorTab] = []
    var interactions: EditorInteractions
    var activeTab: EditorTab? {
        guard let id = tabView.selectedTabViewItem?.identifier as? UUID else { return nil }
        return tabs.first { $0.document.id == id }
    }

    init(interactions: EditorInteractions = NativeInteractions()) {
        self.interactions = interactions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Subline"
        window.minSize = NSSize(width: 480, height: 320)
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        tabView.tabViewType = .topTabsBezelBorder
        tabView.delegate = self
        tabView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)
        ])
        newDocument(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc func newDocument(_ sender: Any?) { add(EditorDocument()) }

    @discardableResult private func add(_ document: EditorDocument) -> EditorTab {
        let tab = EditorTab(document: document)
        tab.onChange = { [weak self] in self?.refreshTitles() }
        tabs.append(tab)
        let item = NSTabViewItem(identifier: document.id)
        item.label = document.title
        item.view = tab.scrollView
        tabView.addTabViewItem(item)
        tabView.selectTabViewItem(item)
        focusEditor()
        refreshTitles()
        return tab
    }

    func select(_ tab: EditorTab) {
        if let item = tabView.tabViewItems.first(where: { ($0.identifier as? UUID) == tab.document.id }) {
            tabView.selectTabViewItem(item)
            focusEditor()
            refreshTitles()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        for url in interactions.openURLs() { _ = openFile(url) }
    }

    @discardableResult func openFile(_ url: URL) -> Bool {
        let canonical = store.canonicalURL(url)
        if let existing = tabs.first(where: { $0.document.url == canonical }) {
            select(existing)
            return true
        }
        do {
            let loaded = try store.load(canonical)
            add(EditorDocument(url: canonical, loaded: loaded))
            return true
        } catch {
            interactions.showError(error)
            return false
        }
    }

    @objc func undoDocument(_ sender: Any?) { activeTab?.textView.undoManager?.undo() }
    @objc func redoDocument(_ sender: Any?) { activeTab?.textView.undoManager?.redo() }

    @objc func saveDocument(_ sender: Any?) { if let tab = activeTab { _ = save(tab) } }
    @objc func saveDocumentAs(_ sender: Any?) { if let tab = activeTab { _ = save(tab, saveAs: true) } }

    @discardableResult func save(_ tab: EditorTab, saveAs: Bool = false) -> Bool {
        do {
            let target: URL
            let expected: FileExpectation
            if saveAs || tab.document.url == nil {
                guard let selected = interactions.saveURL(for: tab) else { return false }
                target = store.canonicalURL(selected)
                // Never permit two live buffers to own the same destination.
                if tabs.contains(where: { $0 !== tab && $0.document.url == target }) {
                    throw TextFileError.io("该文件已在其他标签打开。请切换到该标签或另选路径。")
                }
                expected = try store.expectation(at: target)
            } else {
                target = tab.document.url!
                expected = tab.document.baseline.map { .existing($0) } ?? .missing
            }
            try tab.document.save(to: target, expecting: expected, using: store)
            refreshTitles()
            return true
        } catch {
            interactions.showError(error)
            refreshTitles()
            return false
        }
    }

    private func resolveDirty(_ tab: EditorTab) -> Bool {
        guard tab.document.isDirty else { return true }
        switch interactions.closeChoice(for: tab) {
        case .save: return save(tab)
        case .discard: return true
        case .cancel: return false
        }
    }

    @objc func closeDocument(_ sender: Any?) {
        if let tab = activeTab { _ = close(tab) }
    }

    @discardableResult func close(_ tab: EditorTab) -> Bool {
        guard resolveDirty(tab) else { return false }
        remove(tab)
        if tabs.isEmpty { newDocument(nil) }
        return true
    }

    private func remove(_ tab: EditorTab) {
        if let item = tabView.tabViewItems.first(where: { ($0.identifier as? UUID) == tab.document.id }) {
            tabView.removeTabViewItem(item)
        }
        tabs.removeAll { $0 === tab }
        refreshTitles()
        focusEditor()
    }

    // No tab is removed until every close decision succeeds. Cancelling quit
    // after discarding an earlier tab therefore still leaves all buffers intact.
    func prepareToTerminate() -> Bool {
        for tab in tabs where !resolveDirty(tab) { return false }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard prepareToTerminate() else { return false }
        for tab in Array(tabs) { remove(tab) }
        return true
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        focusEditor()
        refreshTitles()
    }

    func focusEditor() { window?.makeFirstResponder(activeTab?.textView) }

    func refreshTitles() {
        for tab in tabs {
            let item = tabView.tabViewItems.first { ($0.identifier as? UUID) == tab.document.id }
            item?.label = (tab.document.isDirty ? "● " : "") + tab.document.title
        }
        if let doc = activeTab?.document {
            window?.title = "\(doc.title) — Subline"
            window?.isDocumentEdited = doc.isDirty
            window?.representedURL = doc.url
        } else {
            window?.title = "Subline"
            window?.isDocumentEdited = false
            window?.representedURL = nil
        }
    }
}
