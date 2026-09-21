import CryptoKit
import Foundation

public struct FileFingerprint: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file
        case directory
    }

    public var relativePath: String
    public var kind: Kind
    public var size: UInt64
    public var modifiedAt: Date?
    public var sha256: String?

    public init(relativePath: String, kind: Kind, size: UInt64, modifiedAt: Date?, sha256: String?) {
        self.relativePath = relativePath
        self.kind = kind
        self.size = size
        self.modifiedAt = modifiedAt
        self.sha256 = sha256
    }
}

public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var codexHome: String
    public var createdAt: Date
    public var entries: [String: FileFingerprint]

    public init(codexHome: String, createdAt: Date = Date(), entries: [String: FileFingerprint]) {
        self.codexHome = codexHome
        self.createdAt = createdAt
        self.entries = entries
    }
}

public struct SnapshotComparison: Codable, Equatable, Sendable {
    public var deleted: [String]
    public var modified: [String]
    public var added: [String]
    public var unchangedCount: Int

    public init(deleted: [String] = [], modified: [String] = [], added: [String] = [], unchangedCount: Int = 0) {
        self.deleted = deleted
        self.modified = modified
        self.added = added
        self.unchangedCount = unchangedCount
    }

    public var hasDestructiveChange: Bool { !deleted.isEmpty }
    public var isUnchanged: Bool { deleted.isEmpty && modified.isEmpty && added.isEmpty }
}

public struct SessionProtectionPolicy: Sendable {
    public var recursivelyHashedPaths: [String]
    public var singleHashedPaths: [String]
    public var existenceOnlyPaths: [String]

    public init(
        recursivelyHashedPaths: [String] = ["sessions", "archived_sessions", "skills", "rules"],
        singleHashedPaths: [String] = [
            "history.jsonl",
            "session_index.jsonl",
            "config.toml",
            "hooks.json",
            ".codex-global-state.json",
            "state_5.sqlite",
            "thread_history_1.sqlite",
            "external_agent_session_imports.json"
        ],
        existenceOnlyPaths: [String] = ["threads", "projects", "worktrees"]
    ) {
        self.recursivelyHashedPaths = recursivelyHashedPaths
        self.singleHashedPaths = singleHashedPaths
        self.existenceOnlyPaths = existenceOnlyPaths
    }
}

public enum SessionSnapshotCaptureMode: Sendable {
    case contentHashed
    case metadataOnly
}

public struct SessionSnapshotter: Sendable {
    public let codexHome: URL
    public let policy: SessionProtectionPolicy

    public init(codexHome: URL, policy: SessionProtectionPolicy = SessionProtectionPolicy()) {
        self.codexHome = codexHome.resolvingSymlinksInPath().standardizedFileURL
        self.policy = policy
    }

    public func capture(mode: SessionSnapshotCaptureMode = .contentHashed) throws -> SessionSnapshot {
        var entries: [String: FileFingerprint] = [:]
        for path in policy.singleHashedPaths {
            let url = codexHome.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                let item = try fingerprint(url: url, hashContents: mode == .contentHashed)
                entries[item.relativePath] = item
            }
        }
        for path in policy.recursivelyHashedPaths {
            let root = codexHome.appending(path: path, directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { continue }
            let rootItem = try fingerprint(url: root, hashContents: false)
            entries[rootItem.relativePath] = rootItem
            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }
                for case let itemURL as URL in enumerator {
                    let values = try itemURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isDirectory == true || values.isRegularFile == true else { continue }
                    if shouldExclude(itemURL) {
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    let item = try fingerprint(
                        url: itemURL,
                        hashContents: values.isRegularFile == true && mode == .contentHashed
                    )
                    entries[item.relativePath] = item
                }
            }
        }
        for path in policy.existenceOnlyPaths {
            let url = codexHome.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path) {
                let item = try fingerprint(url: url, hashContents: false)
                entries[item.relativePath] = item
            }
        }
        return SessionSnapshot(codexHome: codexHome.path, entries: entries)
    }

    public func compare(_ before: SessionSnapshot, _ after: SessionSnapshot) -> SnapshotComparison {
        let beforeKeys = Set(before.entries.keys)
        let afterKeys = Set(after.entries.keys)
        let deleted = beforeKeys.subtracting(afterKeys).sorted()
        let added = afterKeys.subtracting(beforeKeys).sorted()
        var modified: [String] = []
        var unchanged = 0
        for key in beforeKeys.intersection(afterKeys).sorted() {
            guard let old = before.entries[key], let new = after.entries[key] else { continue }
            // Directory timestamps and allocation sizes also change for ignored or
            // temporary children. Compare protected children separately; additions,
            // deletions, and directory/file type changes must still be detected.
            if old.kind == .directory, new.kind == .directory {
                unchanged += 1
                continue
            }
            let contentChanged: Bool
            if old.sha256 != nil || new.sha256 != nil {
                contentChanged = old.sha256 != new.sha256
            } else {
                contentChanged = old.modifiedAt != new.modifiedAt
            }
            if old.kind != new.kind || old.size != new.size || contentChanged {
                modified.append(key)
            } else {
                unchanged += 1
            }
        }
        return SnapshotComparison(deleted: deleted, modified: modified, added: added, unchangedCount: unchanged)
    }

    private func fingerprint(url: URL, hashContents: Bool) throws -> FileFingerprint {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let relativePath = relativePath(for: url)
        if values.isDirectory == true {
            return FileFingerprint(
                relativePath: relativePath,
                kind: .directory,
                size: UInt64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate,
                sha256: nil
            )
        }
        return FileFingerprint(
            relativePath: relativePath,
            kind: .file,
            size: UInt64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate,
            sha256: hashContents ? try sha256(url: url) : nil
        )
    }

    private func sha256(url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw SwitcherError.fileOperation("보호 파일을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw SwitcherError.fileOperation("보호 파일 해시 계산에 실패했습니다: \(url.lastPathComponent)")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func relativePath(for url: URL) -> String {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        let root = codexHome.path.hasSuffix("/") ? codexHome.path : codexHome.path + "/"
        if url.path == codexHome.path { return "." }
        guard url.path.hasPrefix(root) else { return url.lastPathComponent }
        return String(url.path.dropFirst(root.count))
    }

    private func shouldExclude(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix("-wal")
            || name.hasSuffix("-shm")
            || name.hasSuffix(".tmp")
            || name.hasSuffix(".lock")
            || name == "auth.json"
    }
}
