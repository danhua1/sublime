import AppKit

let arguments = CommandLine.arguments
var smokeRoot: URL?
if let index = arguments.firstIndex(of: "--smoke-test") {
    guard arguments.count == index + 2 else {
        fputs("--smoke-test requires an isolated temporary root\n", stderr)
        exit(64)
    }
    let root = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
    let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
    let privateTmp = URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath()
    let recoveryPath = ProcessInfo.processInfo.environment["SUBLINE_RECOVERY_ROOT"] ?? ""
    let recovery = URL(fileURLWithPath: recoveryPath).standardizedFileURL.resolvingSymlinksInPath()
    let preferencesPath = ProcessInfo.processInfo.environment["SUBLINE_SMOKE_PREFERENCES_ROOT"] ?? ""
    let preferences = URL(fileURLWithPath: preferencesPath).standardizedFileURL.resolvingSymlinksInPath()
    let allowed = [temporary.path + "/", privateTmp.path + "/"].contains { root.path.hasPrefix($0) }
    guard allowed, root.lastPathComponent.hasPrefix("Subline-smoke-"),
          FileManager.default.fileExists(atPath: root.appendingPathComponent(".smoke-isolation").path),
          !recoveryPath.isEmpty, recovery == root.appendingPathComponent("recovery"),
          !preferencesPath.isEmpty, preferences == root.appendingPathComponent("preferences") else {
        fputs("Smoke isolation validation failed; no application data accessed\n", stderr)
        exit(64)
    }
    // Test-specific volatile defaults never replace HOME or write an application
    // preferences domain. Native panels start only inside the isolated root.
    UserDefaults.standard.setVolatileDomain([
        "ApplePersistenceIgnoreState": true,
        "NSQuitAlwaysKeepsWindows": false,
        "NSNavLastRootDirectory": root.path,
        "NSNavLastCurrentDirectory": root.path
    ], forName: UserDefaults.argumentDomain)
    smokeRoot = root
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(smokeRoot: smokeRoot)
app.delegate = delegate
app.run()
