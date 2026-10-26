import XCTest
import Darwin
@testable import SublineCore

final class AtomicSaveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SublineAtomicTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func chmod(_ arguments: [String], _ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments + [url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "real ACL fixture must succeed, not skip")
        guard process.terminationStatus == 0 else { throw TextFileError.io("ACL fixture failed") }
    }

    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else {
            throw TextFileError.io("ACL fixture read failed")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { throw TextFileError.io("ACL fixture text failed") }
        defer { acl_free(text) }
        return String(cString: text)
    }

    private func identity(_ url: URL) throws -> [UInt64] {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw TextFileError.io("stat fixture failed") }
        return [UInt64(info.st_dev), info.st_ino, UInt64(info.st_mode),
                UInt64(info.st_uid), UInt64(info.st_gid), UInt64(info.st_flags)]
    }

    func testRealDenyAndGrantACLRefuseOverwriteWithoutChangingDiskOrDocument() throws {
        let store = TextFileStore()
        for (index, entry) in ["user:nobody deny read", "user:nobody allow read"].enumerated() {
            for saveAs in [false, true] {
                let target = try file("acl-\(index)-\(saveAs).txt", "old protected bytes")
                try chmod([index == 0 ? "0644" : "0600"], target)
                try chmod(["+a", entry], target)
                let originalACL = try aclText(target)
                XCTAssertTrue(originalACL.contains(index == 0 ? "deny" : "allow"))
                let originalIdentity = try identity(target)
                let source = saveAs ? try file("source-\(index).txt", "source bytes") : target
                let doc = EditorDocument(url: source, loaded: try store.load(source))
                let baseline = doc.baseline
                let savedText = doc.savedText
                doc.edit("local Chinese 中文😀 draft")
                let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
                XCTAssertThrowsError(try doc.save(to: target, expecting: try store.expectation(at: target), using: store)) {
                    XCTAssertTrue($0.localizedDescription.contains("访问控制"), "must explain safe refusal: \($0)")
                }
                XCTAssertEqual(try Data(contentsOf: target), Data("old protected bytes".utf8))
                XCTAssertEqual(try aclText(target), originalACL)
                XCTAssertEqual(try identity(target), originalIdentity)
                XCTAssertEqual(doc.url, source)
                XCTAssertEqual(doc.text, "local Chinese 中文😀 draft")
                XCTAssertEqual(doc.savedText, savedText)
                XCTAssertEqual(doc.baseline, baseline)
                XCTAssertTrue(doc.isDirty)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
            }
        }
    }

    func testInheritedGrantACLRefusesNewFileBeforeWritingText() throws {
        let directory = root.appendingPathComponent("inherited")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try chmod(["+a", "user:nobody allow read,file_inherit,directory_inherit"], directory)
        let probe = directory.appendingPathComponent("probe")
        try Data().write(to: probe)
        XCTAssertTrue(try aclText(probe).contains("inherited"))
        try FileManager.default.removeItem(at: probe)
        var io = AtomicSaveIO()
        var writes = 0
        io.write = { fd, bytes, count in
            writes += 1
            return Darwin.write(fd, bytes, count)
        }
        let doc = EditorDocument()
        doc.edit("private draft")
        let target = directory.appendingPathComponent("new.txt")
        XCTAssertThrowsError(try doc.save(to: target, expecting: .missing, using: TextFileStore(io: io))) {
            XCTAssertEqual($0 as? TextFileError, .unsafeAccessControl)
        }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertNil(doc.url)
        XCTAssertNil(doc.baseline)
        XCTAssertEqual(doc.savedText, "")
        XCTAssertEqual(doc.text, "private draft")
        XCTAssertTrue(doc.isDirty)
    }

    private enum Fault: CaseIterable {
        case originalStat, originalACL, temporaryACL, owner, permissions, appliedStat
        case appliedMismatch, finalTemporaryACL, finalOriginalACL, finalOriginalStat
        case write, partialWrite, zeroWrite, sync, replace
    }

    private func checkFailure(_ fault: Fault, saveAs: Bool) throws {
        let store = TextFileStore()
        let target = try file("target.txt", "old target bytes")
        try chmod(["0640"], target)
        let before = try identity(target)
        let source = saveAs ? try file("source.txt", "source bytes") : target
        let doc = EditorDocument(url: source, loaded: try store.load(source))
        let baseline = doc.baseline
        let savedText = doc.savedText
        doc.edit("edited 中文😀 text")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        var io = AtomicSaveIO()
        var aclCalls = 0
        var statusCalls = 0
        var writes = 0
        var hit = false
        var partialBytes = 0
        var temporaryFD: Int32 = -1
        io.readACL = { fd in
            aclCalls += 1
            let failAt: Int
            switch fault {
            case .originalACL: failAt = 1
            case .temporaryACL: failAt = 2
            case .finalTemporaryACL: failAt = 3
            case .finalOriginalACL: failAt = 4
            default: failAt = 0
            }
            if aclCalls == failAt { hit = true; errno = EACCES; return nil }
            return acl_get_fd_np(fd, ACL_TYPE_EXTENDED)
        }
        io.status = { fd, info in
            statusCalls += 1
            let failAt: Int
            switch fault {
            case .originalStat: failAt = 1
            case .appliedStat, .appliedMismatch: failAt = 2
            case .finalOriginalStat: failAt = 3
            default: failAt = 0
            }
            if statusCalls == failAt {
                hit = true
                if fault == .appliedMismatch {
                    let result = fstat(fd, info)
                    info.pointee.st_gid += 1
                    return result
                }
                errno = EIO
                return -1
            }
            return fstat(fd, info)
        }
        io.owner = { fd, uid, gid in
            if fault == .owner { hit = true; errno = EPERM; return -1 }
            return fchown(fd, uid, gid)
        }
        io.permissions = { fd, mode in
            if fault == .permissions { hit = true; errno = EPERM; return -1 }
            return fchmod(fd, mode)
        }
        io.write = { fd, bytes, count in
            writes += 1
            temporaryFD = fd
            if fault == .partialWrite && writes == 1 {
                partialBytes = Darwin.write(fd, bytes, min(3, count))
                return partialBytes
            }
            if fault == .write || fault == .partialWrite { hit = true; errno = ENOSPC; return -1 }
            if fault == .zeroWrite { hit = true; return 0 }
            return Darwin.write(fd, bytes, count)
        }
        io.sync = { fd in
            if fault == .sync { hit = true; errno = EIO; return -1 }
            return fsync(fd)
        }
        io.replace = { from, to in
            if fault == .replace { hit = true; errno = EACCES; return -1 }
            return rename(from, to)
        }
        XCTAssertThrowsError(try doc.save(to: target, expecting: try store.expectation(at: target),
                                        using: TextFileStore(io: io)), "\(fault), Save As=\(saveAs)")
        XCTAssertTrue(hit, "injected boundary must actually execute: \(fault)")
        if fault == .partialWrite { XCTAssertEqual(partialBytes, 3); XCTAssertEqual(writes, 2) }
        if temporaryFD >= 0 {
            errno = 0
            XCTAssertEqual(fcntl(temporaryFD, F_GETFD), -1)
            XCTAssertEqual(errno, EBADF, "temporary descriptor must be closed")
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("old target bytes".utf8))
        XCTAssertEqual(try identity(target), before)
        XCTAssertEqual(doc.url, source)
        XCTAssertEqual(doc.baseline, baseline)
        XCTAssertEqual(doc.savedText, savedText)
        XCTAssertEqual(doc.text, "edited 中文😀 text")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), names)
        // A failed attempt must not poison the baseline or the next live save.
        try doc.save(to: target, expecting: try store.expectation(at: target), using: store)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try Data(contentsOf: target), Data(doc.text.utf8))
        if saveAs { XCTAssertEqual(try Data(contentsOf: source), Data("source bytes".utf8)) }
        for name in names { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    }

    func testMetadataAndPartialWriteSyncRenameFailuresPreserveDiskAndDocument() throws {
        for fault in Fault.allCases { try checkFailure(fault, saveAs: false) }
    }

    func testSaveAsMetadataAndPartialWriteSyncRenameFailuresPreserveSourcePath() throws {
        for fault in Fault.allCases { try checkFailure(fault, saveAs: true) }
    }

    func testACLAddedBeforeFinalCheckRefusesReplacement() throws {
        let store = TextFileStore()
        let target = try file("changed-acl.txt", "original")
        let doc = EditorDocument(url: target, loaded: try store.load(target))
        let baseline = doc.baseline
        let originalIdentity = try identity(target)
        doc.edit("local edit")
        var io = AtomicSaveIO()
        var fixtureError: Error?
        io.sync = { fd in
            do { try self.chmod(["+a", "user:nobody deny read"], target) }
            catch { fixtureError = error }
            return fsync(fd)
        }
        XCTAssertThrowsError(try doc.save(to: target, expecting: .existing(baseline!), using: TextFileStore(io: io))) {
            XCTAssertEqual($0 as? TextFileError, .unsafeAccessControl)
        }
        XCTAssertNil(fixtureError)
        XCTAssertTrue(try aclText(target).contains("deny"))
        XCTAssertEqual(try identity(target), originalIdentity)
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertEqual(doc.baseline, baseline)
        XCTAssertEqual(doc.url, target)
        XCTAssertEqual(doc.savedText, "original")
        XCTAssertEqual(doc.text, "local edit")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["changed-acl.txt"])
    }

    func testSpecialPermissionBitsRefuseReplacement() throws {
        let store = TextFileStore()
        let target = try file("special.txt", "original")
        try chmod(["4644"], target)
        let before = try identity(target)
        let doc = EditorDocument(url: target, loaded: try store.load(target))
        let baseline = doc.baseline
        doc.edit("local edit")
        XCTAssertThrowsError(try doc.save(to: target, expecting: .existing(baseline!), using: store)) {
            XCTAssertEqual($0 as? TextFileError, .unsafeAccessControl)
        }
        XCTAssertEqual(try identity(target), before)
        XCTAssertEqual(try Data(contentsOf: target), Data("original".utf8))
        XCTAssertEqual(doc.url, target)
        XCTAssertEqual(doc.baseline, baseline)
        XCTAssertEqual(doc.savedText, "original")
        XCTAssertEqual(doc.text, "local edit")
        XCTAssertTrue(doc.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["special.txt"])
    }


    func testShortWritesAndInterruptRetryPreserveOwnerGroupMode() throws {
        let store = TextFileStore()
        let target = try file("short-writes.txt", "original")
        try chmod(["0640"], target)
        let before = try identity(target)
        let doc = EditorDocument(url: target, loaded: try store.load(target))
        doc.edit("中文😀 with short writes")
        var io = AtomicSaveIO()
        var calls = 0
        io.write = { fd, bytes, count in
            calls += 1
            if calls == 1 { errno = EINTR; return -1 }
            return Darwin.write(fd, bytes, min(2, count))
        }
        try doc.save(to: target, expecting: .existing(doc.baseline!), using: TextFileStore(io: io))
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(try Data(contentsOf: target), Data(doc.text.utf8))
        XCTAssertFalse(doc.isDirty)
        let after = try identity(target)
        XCTAssertNotEqual(after[1], before[1], "atomic replacement uses a new inode")
        XCTAssertEqual(Array(after[2...]), Array(before[2...]), "mode, owner, group and flags retained")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["short-writes.txt"])
    }

    func testEmptyNewFileSaveDoesNotNeedWriteAndUsesPrivateMode() throws {
        var io = AtomicSaveIO()
        var writes = 0
        io.write = { fd, bytes, count in writes += 1; return Darwin.write(fd, bytes, count) }
        let doc = EditorDocument()
        let target = root.appendingPathComponent("empty.txt")
        try doc.save(to: target, expecting: .missing, using: TextFileStore(io: io))
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: target), Data())
        XCTAssertEqual(try identity(target)[2] & 0o777, 0o600)
        XCTAssertEqual(doc.url, target)
        XCTAssertNotNil(doc.baseline)
        XCTAssertFalse(doc.isDirty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["empty.txt"])
    }

}
