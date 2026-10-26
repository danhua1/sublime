import Foundation
import CryptoKit
import Darwin

public enum TextFileError: LocalizedError, Equatable {
    case notRegularFile
    case tooLarge
    case unsupportedEncoding
    case binaryContent
    case conflict
    case unsafeAccessControl
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile: return "只能打开本地普通文本文件，不能打开目录或设备。"
        case .tooLarge: return "文件超过 20 MiB 安全上限，未读取或改写文件。"
        case .unsupportedEncoding: return "不支持此编码。请先将文件转换为 UTF-8（可带 BOM）。"
        case .binaryContent: return "文件含有二进制控制字节，不能作为文本打开。"
        case .conflict: return "磁盘文件自打开或确认后已变化或被移除。为避免覆盖，保存已取消；请另存为新文件。"
        case .unsafeAccessControl: return "无法安全保持此文件的访问控制属性（ACL、所有者、组或权限）。未替换原文件；请另存为新文件。"
        case .io(let message): return message
        }
    }
}

public enum LineEnding: String {
    case lf, crlf, cr

    public func encode(_ text: String) -> String {
        let normalized = Self.normalize(text)
        switch self {
        case .lf: return normalized
        case .crlf: return normalized.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: return normalized.replacingOccurrences(of: "\n", with: "\r")
        }
    }

    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // All editor buffers use LF. Mixed files adopt the first newline on save;
    // pure LF/CRLF/CR and a UTF-8 BOM round-trip without changing their style.
    public static func detect(_ text: String) -> LineEnding {
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\r" { return iterator.next() == "\n" ? .crlf : .cr }
            if scalar == "\n" { return .lf }
        }
        return .lf
    }
}

public struct FileSnapshot: Equatable {
    public let digest: Data
    public let device: Int32
    public let inode: UInt64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int
}

public enum FileExpectation: Equatable {
    case missing
    case existing(FileSnapshot)
}

public struct LoadedText {
    public let text: String
    public let lineEnding: LineEnding
    public let hasBOM: Bool
    public let snapshot: FileSnapshot
}

// Internal syscall boundary for deterministic pre-commit failure tests only.
// The application always uses the live functions; no environment fault switch.
struct AtomicSaveIO {
    var readACL: (Int32) -> acl_t? = { acl_get_fd_np($0, ACL_TYPE_EXTENDED) }
    var status: (Int32, UnsafeMutablePointer<stat>) -> Int32 = { fstat($0, $1) }
    var owner: (Int32, uid_t, gid_t) -> Int32 = { fchown($0, $1, $2) }
    var permissions: (Int32, mode_t) -> Int32 = { fchmod($0, $1) }
    var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var sync: (Int32) -> Int32 = { fsync($0) }
    var replace: (String, String) -> Int32 = { rename($0, $1) }
}

private struct AccessControl: Equatable {
    let device: Int32
    let inode: UInt64
    let mode: mode_t
    let owner: uid_t
    let group: gid_t
    let flags: UInt32
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        mode = info.st_mode
        owner = info.st_uid
        group = info.st_gid
        flags = info.st_flags
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }
}

public final class TextFileStore {
    public static let maximumBytes = 20 * 1024 * 1024
    private let io: AtomicSaveIO
    public init() { io = AtomicSaveIO() }
    init(io: AtomicSaveIO) { self.io = io }

    public func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func systemError() -> TextFileError {
        .io(String(cString: strerror(errno)))
    }

    // fstat precedes reading. A bounded descriptor read also handles a file
    // growing after the initial size check without allocating unbounded data.
    private func bytesAndSnapshot(_ url: URL) throws -> (Data, FileSnapshot) {
        guard url.isFileURL else { throw TextFileError.notRegularFile }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw systemError() }
        guard before.st_mode & S_IFMT == S_IFREG else { throw TextFileError.notRegularFile }
        guard before.st_size <= Self.maximumBytes else { throw TextFileError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = Self.maximumBytes + 1 - data.count
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, min($0.count, remaining))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw systemError()
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumBytes else { throw TextFileError.tooLarge }
        }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw systemError() }
        guard before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw TextFileError.conflict
        }
        return (data, FileSnapshot(digest: Data(SHA256.hash(data: data)),
                                   device: after.st_dev, inode: after.st_ino,
                                   modifiedSeconds: after.st_mtimespec.tv_sec,
                                   modifiedNanoseconds: after.st_mtimespec.tv_nsec))
    }

    public func expectation(at url: URL) throws -> FileExpectation {
        let path = canonicalURL(url)
        var info = stat()
        if lstat(path.path, &info) != 0 {
            if errno == ENOENT { return .missing }
            throw systemError()
        }
        return .existing(try bytesAndSnapshot(path).1)
    }

    public func load(_ url: URL) throws -> LoadedText {
        let (data, snapshot) = try bytesAndSnapshot(canonicalURL(url))
        let bom = data.starts(with: [0xEF, 0xBB, 0xBF])
        let body = bom ? Data(data.dropFirst(3)) : data
        guard let decoded = String(data: body, encoding: .utf8) else {
            throw TextFileError.unsupportedEncoding
        }
        guard !body.contains(where: { $0 < 0x20 && $0 != 9 && $0 != 10 && $0 != 13 && $0 != 12 }) else {
            throw TextFileError.binaryContent
        }
        return LoadedText(text: LineEnding.normalize(decoded), lineEnding: .detect(decoded),
                          hasBOM: bom, snapshot: snapshot)
    }

    private func requireNoACL(_ fd: Int32) throws {
        errno = 0
        if let acl = io.readACL(fd) {
            acl_free(UnsafeMutableRawPointer(acl))
            // Even an empty or inherited ACL is conservatively refused: this
            // writer does not recreate ACLs. Never replace it with POSIX mode.
            throw TextFileError.unsafeAccessControl
        }
        // Darwin reports ENOENT when there is no extended ACL. Permission,
        // unsupported-filesystem and other retrieval failures are not absence.
        guard errno == ENOENT else { throw TextFileError.unsafeAccessControl }
    }

    private func accessControl(at target: URL) throws -> AccessControl? {
        let fd = open(target.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw TextFileError.unsafeAccessControl
        }
        defer { close(fd) }
        var info = stat()
        guard io.status(fd, &info) == 0 else { throw TextFileError.unsafeAccessControl }
        guard info.st_mode & S_IFMT == S_IFREG else { throw TextFileError.notRegularFile }
        try requireNoACL(fd)
        // Do not drop special mode bits or file protection flags on replacement.
        guard info.st_mode & 0o7000 == 0, info.st_flags == 0 else {
            throw TextFileError.unsafeAccessControl
        }
        return AccessControl(info)
    }

    // A same-directory temporary keeps replacement on the same volume. All
    // metadata checks must succeed before rename, including existing-file and
    // inherited temporary ACL checks. Errors before rename leave the old inode.
    private func atomicWrite(_ data: Data, to target: URL, expecting expected: FileExpectation) throws {
        let original = try accessControl(at: target)
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".subline-save-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw systemError() }
        defer { close(fd); unlink(temporary.path) }
        // A directory grant ACL may override 0600. Reject before writing text.
        try requireNoACL(fd)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let count = io.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError()
                }
                guard count > 0 else { throw TextFileError.io("无法完成文本写入。") }
                offset += count
            }
        }
        if let original = original {
            guard io.owner(fd, original.owner, original.group) == 0,
                  io.permissions(fd, original.mode & 0o777) == 0 else {
                throw TextFileError.unsafeAccessControl
            }
            var applied = stat()
            guard io.status(fd, &applied) == 0,
                  applied.st_uid == original.owner, applied.st_gid == original.group,
                  applied.st_mode & 0o7777 == original.mode & 0o7777,
                  applied.st_flags == original.flags else { throw TextFileError.unsafeAccessControl }
        }
        try requireNoACL(fd)
        guard io.sync(fd) == 0 else { throw systemError() }
        guard try expectation(at: target) == expected,
              try accessControl(at: target) == original else { throw TextFileError.conflict }
        guard io.replace(temporary.path, target.path) == 0 else { throw systemError() }
    }

    public func save(text: String, to url: URL, lineEnding: LineEnding, hasBOM: Bool,
                     expecting expected: FileExpectation) throws -> FileSnapshot {
        guard url.isFileURL else { throw TextFileError.notRegularFile }
        let target = canonicalURL(url)
        var data = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(contentsOf: lineEnding.encode(text).utf8)
        guard data.count <= Self.maximumBytes else { throw TextFileError.tooLarge }
        var coordinationError: NSError?
        var result: Result<FileSnapshot, Error>?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                // Cooperating writers are serialized. Never offer a force-save
                // on a stale baseline; even Save As to the same path uses it.
                guard try self.expectation(at: coordinated) == expected else { throw TextFileError.conflict }
                try self.atomicWrite(data, to: coordinated, expecting: expected)
                let (written, snapshot) = try self.bytesAndSnapshot(coordinated)
                guard written == data else { throw TextFileError.conflict }
                return snapshot
            }
        }
        if let result = result { return try result.get() }
        throw (coordinationError as Error?) ?? TextFileError.io("无法协调文件保存。")
    }
}
