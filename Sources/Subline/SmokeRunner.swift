import AppKit
import SublineCore
import Darwin

private enum SmokeFailure: Error, CustomStringConvertible {
    case assertion(String)
    var description: String { if case .assertion(let text) = self { return text }; return "failure" }
}

private final class ScriptedInteractions: EditorInteractions {
    var opens: [URL] = []
    var destinations: [URL?] = []
    var choices: [CloseChoice] = []
    var errors: [Error] = []
    func openURLs() -> [URL] { opens }
    func saveURL(for document: EditorTab) -> URL? { destinations.isEmpty ? nil : destinations.removeFirst() }
    func closeChoice(for document: EditorTab) -> CloseChoice { choices.isEmpty ? .cancel : choices.removeFirst() }
    func showError(_ error: Error) { errors.append(error) }
}

final class SmokeRunner {
    let editor: EditorWindowController
    let root: URL
    private var count = 0
    private let scripted = ScriptedInteractions()

    init(editor: EditorWindowController, root: URL) { self.editor = editor; self.root = root }

    private func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw SmokeFailure.assertion(name) }
        count += 1
        print("PASS \(count): \(name)")
        fflush(stdout)
    }

    private func type(_ text: String, in tab: EditorTab) {
        editor.select(tab)
        let undo = tab.textView.undoManager!
        undo.groupsByEvent = false
        tab.textView.breakUndoCoalescing()
        undo.beginUndoGrouping()
        tab.textView.insertText(text, replacementRange: NSRange(location: tab.textView.string.utf16.count, length: 0))
        tab.textView.breakUndoCoalescing()
        undo.endUndoGrouping()
    }

    private func menuAction(_ selector: Selector) -> Bool {
        func find(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.action == selector { return item }
                if let submenu = item.submenu, let found = find(submenu) { return found }
            }
            return nil
        }
        guard let item = NSApp.mainMenu.flatMap({ find($0) }) else { return false }
        return NSApp.sendAction(selector, to: item.target, from: item)
    }

    func run() {
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("recovery"), withIntermediateDirectories: true)
            editor.interactions = scripted
            try check(editor.window?.isVisible == true && editor.window?.contentView?.window != nil,
                      "real AppKit window is visible and attached")
            try check(editor.tabs.count == 1 && editor.activeTab?.textView.isEditable == true,
                      "startup contains an editable blank tab")
            try check(URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBLINE_RECOVERY_ROOT"] ?? "/")
                .resolvingSymlinksInPath() == root.appendingPathComponent("recovery"),
                      "test files and future recovery root are isolated")
            try check(ProcessInfo.processInfo.environment["HOME"] == ProcessInfo.processInfo.environment["SUBLINE_SMOKE_EXPECTED_HOME"],
                      "smoke preserves the original HOME environment")
            try check(URL(fileURLWithPath: ProcessInfo.processInfo.environment["SUBLINE_SMOKE_PREFERENCES_ROOT"] ?? "/")
                .resolvingSymlinksInPath() == root.appendingPathComponent("preferences"),
                      "test preference root is isolated without replacing HOME")
            try check(UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["ApplePersistenceIgnoreState"] as? Bool == true
                      && editor.window?.isRestorable == false,
                      "smoke uses volatile defaults and disables AppKit state restoration")
            try boundaryChecks()
            let first = editor.activeTab!
            let content = "中文😀👩🏽‍💻e\u{301}\n第二行\n"
            type(content, in: first)
            try check(first.textView.string == content && first.document.text == content && first.document.isDirty,
                      "NSTextView Unicode input updates document and dirty marker")
            try check(editor.window?.isDocumentEdited == true && editor.tabView.selectedTabViewItem!.label.hasPrefix("●"),
                      "window and tab display modification state")
            try check(menuAction(#selector(EditorWindowController.newDocument(_:))), "New menu action reaches window controller")
            let second = editor.activeTab!
            type("独立标签🐈", in: second)
            editor.select(first)
            try check(first.textView.string == content && second.textView.string == "独立标签🐈",
                      "real tab switching retains independent buffers")
            try check(menuAction(#selector(EditorWindowController.undoDocument(_:))), "Undo menu reaches active text view undo manager")
            try check(first.textView.string.isEmpty && !first.document.isDirty && second.document.text == "独立标签🐈",
                      "per-tab undo restores clean baseline without touching another tab")
            try check(menuAction(#selector(EditorWindowController.redoDocument(_:))), "Redo menu reaches active text view undo manager")
            try check(first.document.text == content && first.document.isDirty, "redo restores Unicode content and dirty state")
            let saved = root.appendingPathComponent("roundtrip.txt")
            scripted.destinations = [saved]
            try check(menuAction(#selector(EditorWindowController.saveDocument(_:))), "Save menu action reaches controller")
            try check(try Data(contentsOf: saved) == Data(content.utf8), "real file save preserves Unicode and LF bytes")
            try check(!first.document.isDirty && editor.window?.isDocumentEdited == false, "successful save clears dirty marker")
            let countBeforeOpen = editor.tabs.count
            scripted.opens = [saved]
            editor.openDocument(nil)
            try check(editor.tabs.count == countBeforeOpen && editor.activeTab === first, "duplicate Open focuses the existing tab")
            let alias = root.appendingPathComponent("alias.txt")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: saved)
            _ = editor.openFile(alias)
            try check(editor.tabs.count == countBeforeOpen && editor.activeTab === first, "symlink duplicate also focuses existing tab")
            let copied = root.appendingPathComponent("save-as.txt")
            scripted.destinations = [copied]
            editor.saveDocumentAs(nil)
            try check(first.document.url == copied && (try Data(contentsOf: copied)) == Data(content.utf8), "Save As writes real file and changes tab identity")
            try check(try Data(contentsOf: saved) == Data(content.utf8), "Save As does not change the original file")
            type("追加", in: first)
            scripted.destinations = [nil]
            try check(!editor.save(first, saveAs: true) && first.document.isDirty && first.document.url == copied,
                      "Save As cancellation retains text, path, and dirty state")
            let crlf = root.appendingPathComponent("crlf.txt")
            let original = Data([0xef, 0xbb, 0xbf]) + Data("甲😀\r\n乙\r\n".utf8)
            try original.write(to: crlf)
            scripted.opens = [crlf]
            editor.openDocument(nil)
            let crlfTab = editor.activeTab!
            try check(crlfTab.textView.string == "甲😀\n乙\n", "CRLF is normalized only inside editor")
            type("丙\n", in: crlfTab)
            try check(editor.save(crlfTab), "CRLF edited file saves successfully")
            try check(try Data(contentsOf: crlf) == Data([0xef, 0xbb, 0xbf]) + Data("甲😀\r\n乙\r\n丙\r\n".utf8),
                      "edited CRLF file retains BOM and CRLF on disk")
            type("本地", in: crlfTab)
            try Data("外部内容".utf8).write(to: crlf)
            let errorsBefore = scripted.errors.count
            try check(!editor.save(crlfTab) && crlfTab.document.isDirty, "external change cancels save and retains local dirty content")
            try check(scripted.errors.count == errorsBefore + 1 && (try String(contentsOf: crlf)) == "外部内容",
                      "conflict produces an error and never overwrites external content")
            scripted.destinations = [crlf]
            try check(!editor.save(crlfTab, saveAs: true), "Save As to original path cannot bypass conflict protection")
            scripted.choices = [.cancel]
            let beforeClose = editor.tabs.count
            try check(!editor.close(crlfTab) && editor.tabs.count == beforeClose && crlfTab.document.text.hasSuffix("本地"),
                      "close Cancel keeps the actual tab and text")
            scripted.choices = [.save]
            try check(!editor.close(crlfTab) && editor.tabs.contains { $0 === crlfTab } && crlfTab.document.isDirty,
                      "close Save failure keeps tab and dirty marker")
            scripted.choices = [.discard]
            try check(editor.close(crlfTab) && !editor.tabs.contains { $0 === crlfTab }, "close Discard removes the intended tab only")
            try check(try String(contentsOf: crlf) == "外部内容", "discard never writes the discarded buffer to disk")
            editor.select(second)
            scripted.choices = [.save]
            scripted.destinations = [nil]
            try check(!editor.close(second) && second.document.text == "独立标签🐈", "close Save followed by save-panel Cancel retains unnamed tab")
            scripted.destinations = [root.appendingPathComponent("missing/draft.txt")]
            try check(!editor.save(second) && second.document.isDirty && second.document.url == nil,
                      "failed destination preserves unnamed dirty document")
            // Quit traverses multiple real tabs; earlier Discard choices must not
            // destroy buffers if a later decision cancels the transaction.
            scripted.choices = [.discard, .cancel]
            let quitCount = editor.tabs.count
            let delegate = NSApp.delegate as! AppDelegate
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,
                      "application delegate returns terminateCancel for quit cancellation")
            try check(editor.tabs.count == quitCount && first.document.isDirty && second.document.isDirty,
                      "quit Cancel retains even earlier-discarded tabs")
            scripted.choices = [.discard, .save]
            scripted.destinations = [nil]
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,
                      "quit Save with save-panel Cancel aborts termination")
            let secondPath = root.appendingPathComponent("second.txt")
            scripted.choices = [.discard, .save]
            scripted.destinations = [secondPath]
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateNow && !second.document.isDirty,
                      "quit Save/Discard returns terminateNow only after successful save")
            try check(try String(contentsOf: secondPath) == "独立标签🐈", "quit Save writes the selected document")
            // Preserve a dirty first tab and exercise native modal cancellation.
            try nativeCancellationChecks(tab: first)
            editor.interactions = scripted
            scripted.choices = [.discard]
            try check(editor.close(first), "close Discard succeeds after native cancellation checks")
            editor.newDocument(nil)
            let closingSave = editor.activeTab!
            type("关闭时保存😀", in: closingSave)
            let closePath = root.appendingPathComponent("close-save.txt")
            scripted.choices = [.save]
            scripted.destinations = [closePath]
            try check(editor.close(closingSave) && (try String(contentsOf: closePath)) == "关闭时保存😀",
                      "close Save writes and removes the dirty tab")
            try aclProtectionChecks()
            // Reject invalid input through the UI controller, not only the core.
            let invalid = root.appendingPathComponent("invalid.bin")
            try Data([0xff, 0xfe, 0x00, 0x41]).write(to: invalid)
            let beforeInvalid = editor.tabs.count
            try check(!editor.openFile(invalid) && editor.tabs.count == beforeInvalid,
                      "invalid encoding is rejected by UI without creating a tab")
            try check(!editor.openFile(root) && editor.tabs.count == beforeInvalid, "directory input is rejected by UI")
            try check(try Data(contentsOf: invalid) == Data([0xff, 0xfe, 0x00, 0x41]), "rejected input remains byte-identical")
            for tab in Array(editor.tabs) { _ = editor.close(tab) }
            try check(editor.tabs.count == 1 && editor.activeTab!.document.text.isEmpty,
                      "closing all tabs leaves a usable blank editor")
            let success = "SUCCESS: \(count) real AppKit/file assertions\n"
            try success.write(to: root.appendingPathComponent("SUCCESS"), atomically: false, encoding: .utf8)
            print(success, terminator: "")
            fflush(stdout)
            exit(0)
        } catch {
            fputs("SMOKE FAILED: \(error)\n", stderr)
            exit(1)
        }
    }

    private func boundaryChecks() throws {
        let store = editor.store
        let binary = root.appendingPathComponent("nul.bin")
        let binaryBytes = Data([0x61, 0x00, 0x62])
        try binaryBytes.write(to: binary)
        try check(!editor.openFile(binary), "binary control bytes are refused through real open controller")
        try check(try Data(contentsOf: binary) == binaryBytes, "binary rejection leaves source unchanged")
        let large = root.appendingPathComponent("too-large.txt")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(TextFileStore.maximumBytes + 1))
        try handle.close()
        let oldErrors = scripted.errors.count
        try check(!editor.openFile(large), "over-20-MiB sparse input is refused through real open controller")
        try check(scripted.errors.count == oldErrors + 1 && scripted.errors.last as? TextFileError == .tooLarge,
                  "size check rejects oversized NUL contents before decoding")
        let attrs = try FileManager.default.attributesOfItem(atPath: large.path)
        try check((attrs[.size] as? NSNumber)?.intValue == TextFileStore.maximumBytes + 1,
                  "oversized rejected file length is unchanged")
        let exact = root.appendingPathComponent("at-limit.txt")
        try Data(repeating: 0x61, count: TextFileStore.maximumBytes).write(to: exact)
        try check(try store.load(exact).text.utf8.count == TextFileStore.maximumBytes,
                  "exactly 20 MiB of valid UTF-8 is accepted")
        let canonical = root.appendingPathComponent("normalization.txt")
        try Data("e\u{301}".utf8).write(to: canonical)
        let doc = EditorDocument(url: canonical, loaded: try store.load(canonical))
        doc.edit("é")
        try check(doc.isDirty, "canonically equivalent but byte-different Unicode remains dirty")
        try doc.save(to: canonical, expecting: .missing, using: store)
        try check(try Data(contentsOf: canonical) == Data("é".utf8), "Unicode normalization edits save exact new bytes")
        doc.edit("local")
        let stamp = try FileManager.default.attributesOfItem(atPath: canonical.path)[.modificationDate]!
        try Data("xy".utf8).write(to: canonical)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: canonical.path)
        var conflict = false
        do { try doc.save(to: canonical, expecting: try store.expectation(at: canonical), using: store) }
        catch TextFileError.conflict { conflict = true }
        try check(conflict && doc.isDirty && (try String(contentsOf: canonical)) == "xy",
                  "same-size same-timestamp external edit is rejected by content fingerprint")
        let deleted = root.appendingPathComponent("deleted.txt")
        try Data("before".utf8).write(to: deleted)
        let removed = EditorDocument(url: deleted, loaded: try store.load(deleted))
        removed.edit("local")
        try FileManager.default.removeItem(at: deleted)
        conflict = false
        do { try removed.save(to: deleted, expecting: .missing, using: store) }
        catch TextFileError.conflict { conflict = true }
        try check(conflict && removed.isDirty && !FileManager.default.fileExists(atPath: deleted.path),
                  "external deletion is a conflict, not permission to recreate the file")
        doc.edit(String(repeating: "a", count: TextFileStore.maximumBytes + 1))
        var refused = false
        do { try doc.save(to: canonical, expecting: .missing, using: store) }
        catch TextFileError.tooLarge { refused = true }
        try check(refused && doc.isDirty && (try String(contentsOf: canonical)) == "xy",
                  "oversized output refuses without writing or clearing dirty state")
    }

    private func aclProtectionChecks() throws {
        func fixtureACL(_ url: URL) throws -> String {
            guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
                throw SmokeFailure.assertion("real ACL fixture must be readable")
            }
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            guard let text = acl_to_text(acl, nil) else {
                throw SmokeFailure.assertion("real ACL fixture must be serializable")
            }
            defer { acl_free(text) }
            return String(cString: text)
        }
        for (index, entry) in ["user:nobody deny read", "user:nobody allow read"].enumerated() {
            let target = root.appendingPathComponent("protected-\(index).txt")
            try Data("protected original".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: index == 0 ? 0o644 : 0o600], ofItemAtPath: target.path)
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", entry, target.path]
            try chmod.run()
            chmod.waitUntilExit()
            try check(chmod.terminationStatus == 0, "real deny/grant ACL fixture is created inside smoke root")
            let acl = try fixtureACL(target)
            let original = try editor.store.load(target).snapshot
            try check(editor.openFile(target), "ACL-protected UTF-8 file opens in real tab")
            let tab = editor.activeTab!
            type("local draft 中文😀", in: tab)
            let text = tab.document.text
            try check(!editor.save(tab) && scripted.errors.last as? TextFileError == .unsafeAccessControl,
                      "ACL save returns explicit access-control error through controller")
            try check(tab.document.text == text && tab.textView.string == text
                      && tab.document.url == target && tab.document.baseline == original
                      && tab.document.savedText == "protected original" && tab.document.isDirty,
                      "ACL refusal preserves live buffer, path, baseline and dirty state")
            try check(editor.window?.isDocumentEdited == true && editor.tabView.selectedTabViewItem!.label.hasPrefix("●"),
                      "ACL refusal keeps visible window and tab modification markers")
            try check(try editor.store.load(target).snapshot == original && fixtureACL(target) == acl,
                      "ACL refusal retains original file bytes, inode and exact ACL")
            scripted.choices = [.save]
            try check(!editor.close(tab) && editor.tabs.contains { $0 === tab } && tab.document.isDirty,
                      "close Save cannot discard draft after ACL refusal")
            scripted.choices = [.save]
            let delegate = NSApp.delegate as! AppDelegate
            try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && tab.document.text == text,
                      "quit Save is cancelled after ACL refusal")
            scripted.destinations = [nil]
            try check(!editor.save(tab, saveAs: true) && tab.document.url == target && tab.document.isDirty,
                      "Save As Cancel after ACL refusal keeps protected path and draft")
            let rescued = root.appendingPathComponent("rescued-\(index).txt")
            scripted.destinations = [rescued]
            try check(editor.save(tab, saveAs: true) && tab.document.url == rescued && !tab.document.isDirty
                      && (try Data(contentsOf: rescued)) == Data(text.utf8),
                      "Save As to a new ordinary file safely rescues ACL-blocked draft")
            try check(try fixtureACL(target) == acl && editor.store.load(target).snapshot == original,
                      "rescuing draft does not remove original deny/grant ACL or bytes")
            try check(!(try FileManager.default.contentsOfDirectory(atPath: root.path))
                .contains { $0.hasPrefix(".subline-save-") }, "ACL paths leave no atomic-save temporary file")
            try check(editor.close(tab), "rescued clean tab closes normally")
        }
    }

    private func nativeCancellationChecks(tab: EditorTab) throws {
        let native = NativeInteractions()
        native.isolatedDirectory = root
        editor.interactions = native
        editor.select(tab)
        var openSeen = false
        native.panelObserver = { panel in
            if let open = panel as? NSOpenPanel { openSeen = open.isVisible && open.directoryURL?.resolvingSymlinksInPath() == self.root
                open.cancel(nil) }
        }
        let count = editor.tabs.count
        editor.openDocument(nil)
        try check(openSeen && editor.tabs.count == count && tab.document.isDirty,
                  "real NSOpenPanel Cancel changes no document")
        var saveSeen = false
        native.panelObserver = { panel in
            if let save = panel as? NSSavePanel { saveSeen = save.isVisible && save.directoryURL?.resolvingSymlinksInPath() == self.root
                save.cancel(nil) }
        }
        let text = tab.document.text
        try check(!editor.save(tab, saveAs: true) && saveSeen && tab.document.text == text && tab.document.isDirty,
                  "real NSSavePanel Cancel preserves current document")
        var alertSeen = false
        native.panelObserver = { panel in
            alertSeen = panel.isVisible
            // Drive the real NSAlert button instead of faking a close result.
            func buttons(_ view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
            }
            if let cancel = panel.contentView.flatMap({ buttons($0).first { $0.title == "取消" } }) {
                cancel.performClick(nil)
            } else {
                NSApp.abortModal()
            }
        }
        try check(!editor.close(tab) && alertSeen && tab.document.text == text && editor.tabs.contains { $0 === tab },
                  "real unsaved NSAlert Cancel retains tab content")
        try check(!editor.windowShouldClose(editor.window!) && editor.tabs.count == count,
                  "real unsaved alert Cancel vetoes window close")
        let delegate = NSApp.delegate as! AppDelegate
        try check(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && tab.document.text == text,
                  "real unsaved alert Cancel vetoes application quit")
    }
}
