import Crypto
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A private ledger-only native cursor cache. Resume buffers never enter the numeric export or SSH transport.
final class CodexLedgerCache {
    struct FileStamp: Codable, Equatable {
        let identity: String
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        var contentDigest: String?

        func matchesMetadata(_ other: Self) -> Bool {
            self.identity == other.identity && self.size == other.size
                && self.modifiedSeconds == other.modifiedSeconds && self.modifiedNanoseconds == other
                .modifiedNanoseconds
                && self.changedSeconds == other.changedSeconds && self.changedNanoseconds == other.changedNanoseconds
        }
    }

    struct Snapshot: Codable {
        let version: Int
        let parserHash: String
        let files: [String: FileStamp]
        let evidence: CodexLedgerRequestObserver.Evidence
    }

    struct Envelope: Codable {
        let payload: Data
        let checksum: String
    }

    struct Inventory {
        var files: [String: FileStamp]
        let urls: [String: URL]
    }

    let root: URL
    let stateURL: URL
    let dirtyURL: URL
    private let descriptor: Int32
    private var released = false

    /// Calendar and source roots have separate native buckets; ordinary cost caches are never reused.
    static func defaultRoot(options: CostUsageScanner.Options) -> URL {
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        let key = UsageLedgerRecord.digest(
            roots + [options.calendar.timeZone.identifier, String(describing: options.calendar.identifier)])
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CodexBar/ledger-codex/\(key)", isDirectory: true)
    }

    init(root: URL, checkCancellation: () throws -> Void) throws {
        self.root = root
        self.stateURL = root.appendingPathComponent("request-evidence-v1.json")
        self.dirtyURL = root.appendingPathComponent("scan-in-progress")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let lock = root.appendingPathComponent("ledger.lock")
        let descriptor = lock.path.withCString { open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600)) }
        guard descriptor >= 0 else { throw UsageLedgerError.invalid("Cannot open the private ledger cache lock.") }
        do {
            while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EAGAIN else {
                    throw UsageLedgerError.invalid("Cannot lock the private ledger cache.")
                }
                try checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            }
            try checkCancellation()
        } catch {
            _ = close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        self.release()
    }

    func release() {
        guard !self.released else { return }
        self.released = true
        _ = flock(self.descriptor, LOCK_UN)
        _ = close(self.descriptor)
    }

    /// Metadata inventory costs no JSONL reads. Full replacement/deletion rebuilds native ownership and evidence.
    static func inventory(roots: [URL], checkCancellation: () throws -> Void) throws -> Inventory {
        var files: [String: FileStamp] = [:]
        var urls: [String: URL] = [:]
        for root in roots {
            var enumerationError: Error?
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [],
                errorHandler: { _, error in enumerationError = error; return false })
            while let url = enumerator?.nextObject() as? URL {
                try checkCancellation()
                guard url.pathExtension == "jsonl" else { continue }
                var info = stat()
                guard url.path.withCString({ stat($0, &info) }) == 0 else {
                    throw UsageLedgerError.invalid("Cannot inspect a native usage history file.")
                }
                guard (info.st_mode & S_IFMT) == S_IFREG else { continue }
                #if canImport(Darwin)
                let modified = info.st_mtimespec
                let changed = info.st_ctimespec
                #else
                let modified = info.st_mtim
                let changed = info.st_ctim
                #endif
                let key = CodexLedgerRequestObserver.fileID(url)
                urls[key] = url
                files[key] = FileStamp(
                    identity: UsageLedgerRecord.digest([String(info.st_dev), String(info.st_ino)]),
                    size: Int64(info.st_size),
                    modifiedSeconds: Int64(modified.tv_sec),
                    modifiedNanoseconds: Int64(modified.tv_nsec),
                    changedSeconds: Int64(changed.tv_sec),
                    changedNanoseconds: Int64(changed.tv_nsec),
                    contentDigest: nil)
            }
            if let enumerationError, FileManager.default.fileExists(atPath: root.path) { throw enumerationError }
        }
        return Inventory(files: files, urls: urls)
    }

    /// Any interrupted scan or invalid evidence forces replay, preventing advanced cursors from hiding conflicts.
    func prepare(inventory: inout Inventory, checkCancellation: () throws -> Void) throws -> Snapshot? {
        guard !FileManager.default.fileExists(atPath: self.dirtyURL.path),
              let size = try? self.stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 64 * 1024 * 1024,
              let data = try? Data(contentsOf: self.stateURL),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.checksum == Self.digest(envelope.payload),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: envelope.payload),
              snapshot.version == 2,
              snapshot.parserHash == CodexParserHash.value
        else { return nil }
        for (file, previous) in snapshot.files {
            guard var current = inventory.files[file], current.identity == previous.identity,
                  current.size >= previous.size, let previousDigest = previous.contentDigest
            else { return nil }
            if current.matchesMetadata(previous) {
                current.contentDigest = previousDigest
            } else {
                guard current.size > previous.size, let url = inventory.urls[file] else { return nil }
                // A growing file can be an overwrite. Hash its previous prefix before trusting native append cursors.
                let hashes = try Self.fileDigests(
                    url: url,
                    size: current.size,
                    prefixSize: previous.size,
                    checkCancellation: checkCancellation)
                guard hashes.prefix == previousDigest else { return nil }
                current.contentDigest = hashes.full
            }
            inventory.files[file] = current
        }
        return snapshot
    }

    func beginScan() throws {
        try Data().write(to: self.dirtyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.dirtyURL.path)
    }

    func commit(
        inventory: Inventory,
        evidence: CodexLedgerRequestObserver.Evidence,
        checkCancellation: () throws -> Void) throws
    {
        var files = inventory.files
        for (key, stamp) in files where stamp.contentDigest == nil {
            guard let url = inventory.urls[key] else { continue }
            files[key]?.contentDigest = try Self.fileDigests(
                url: url,
                size: stamp.size,
                prefixSize: stamp.size,
                checkCancellation: checkCancellation).full
        }
        let snapshot = Snapshot(version: 2, parserHash: CodexParserHash.value, files: files, evidence: evidence)
        let payload = try JSONEncoder().encode(snapshot)
        let data = try JSONEncoder().encode(Envelope(payload: payload, checksum: Self.digest(payload)))
        guard data.count <= 64 * 1024 * 1024 else {
            throw UsageLedgerError.invalid("Private ledger evidence exceeds the cache limit.")
        }
        try data.write(to: self.stateURL, options: .atomic)
        for url in try FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil) {
            let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try FileManager.default.setAttributes(
                [.posixPermissions: isDirectory ? 0o700 : 0o600],
                ofItemAtPath: url.path)
        }
        try FileManager.default.removeItem(at: self.dirtyURL)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashing unchanged files is skipped; changed files are streamed without parsing historical JSON again.
    private static func fileDigests(
        url: URL,
        size: Int64,
        prefixSize: Int64,
        checkCancellation: () throws -> Void) throws -> (prefix: String, full: String)
    {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hasher = SHA256()
        var offset: Int64 = 0
        var prefix: String?
        while offset < size {
            try checkCancellation()
            let boundary = offset < prefixSize ? prefixSize : size
            let count = Int(min(1024 * 1024, boundary - offset))
            guard let data = try file.read(upToCount: count), !data.isEmpty else {
                throw UsageLedgerError.invalid("Native usage history changed while validating its cursor.")
            }
            hasher.update(data: data)
            offset += Int64(data.count)
            if offset == prefixSize { prefix = hasher.finalize().map { String(format: "%02x", $0) }.joined() }
        }
        let full = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (prefix ?? full, full)
    }
}
