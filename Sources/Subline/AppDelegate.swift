import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: EditorWindowController!
    let smokeRoot: URL?

    init(smokeRoot: URL?) { self.smokeRoot = smokeRoot }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if editor == nil { editor = EditorWindowController() }
        buildMenu()
        editor.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let root = smokeRoot {
            DispatchQueue.main.async { SmokeRunner(editor: self.editor, root: root).run() }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if editor == nil { editor = EditorWindowController() }
        let results = filenames.map { editor.openFile(URL(fileURLWithPath: $0)) }
        editor.showWindow(nil)
        sender.reply(toOpenOrPrint: results.allSatisfy { $0 } ? .success : .failure)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        editor == nil || editor.prepareToTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationShouldSaveApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            main.addItem(item)
            return submenu
        }
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                  shift: Bool = false, target: AnyObject? = nil) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: key)
            value.keyEquivalentModifierMask = shift ? [.command, .shift] : [.command]
            value.target = target
            menu.addItem(value)
        }
        let app = menu("Subline")
        item(app, "关于 Subline", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp)
        app.addItem(.separator())
        item(app, "退出 Subline", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = menu("文件")
        item(file, "新建", #selector(EditorWindowController.newDocument(_:)), "n", target: editor)
        item(file, "打开…", #selector(EditorWindowController.openDocument(_:)), "o", target: editor)
        file.addItem(.separator())
        item(file, "保存", #selector(EditorWindowController.saveDocument(_:)), "s", target: editor)
        item(file, "另存为…", #selector(EditorWindowController.saveDocumentAs(_:)), "s", shift: true, target: editor)
        file.addItem(.separator())
        item(file, "关闭标签", #selector(EditorWindowController.closeDocument(_:)), "w", target: editor)
        let edit = menu("编辑")
        item(edit, "撤销", #selector(EditorWindowController.undoDocument(_:)), "z", target: editor)
        item(edit, "重做", #selector(EditorWindowController.redoDocument(_:)), "z", shift: true, target: editor)
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "复制", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")
        let window = menu("窗口")
        item(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}
