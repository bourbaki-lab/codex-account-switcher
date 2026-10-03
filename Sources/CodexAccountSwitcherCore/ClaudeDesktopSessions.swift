import CryptoKit
import Foundation

/// Claude 데스크톱 앱 Code 탭의 로컬 상태 위치.
///
/// 대화 원본은 `~/.claude/projects/<cwd>/<cliSessionId>.jsonl`에 계정과 무관하게 저장되고,
/// 사이드바 세션 목록만 `claude-code-sessions/<accountUuid>/<organizationUuid>/local_*.json`으로
/// 계정별로 나뉜다. 스위처는 목록 파일만 다루며 대화 원본과 로그인 저장소는 건드리지 않는다.
public struct ClaudeDesktopPaths: Sendable {
    public let applicationSupport: URL
    public let claudeHome: URL
    public let cliConfigFile: URL
    public let switcherDirectory: URL

    public init(
        applicationSupport: URL? = nil,
        claudeHome: URL? = nil,
        cliConfigFile: URL? = nil,
        switcherDirectory: URL? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.applicationSupport = (applicationSupport
            ?? home.appending(path: "Library/Application Support/Claude", directoryHint: .isDirectory))
            .standardizedFileURL
        self.claudeHome = (claudeHome ?? home.appending(path: ".claude", directoryHint: .isDirectory))
            .standardizedFileURL
        self.cliConfigFile = (cliConfigFile ?? home.appending(path: ".claude.json")).standardizedFileURL
        self.switcherDirectory = (switcherDirectory
            ?? SwitcherPaths().applicationSupport.appending(path: "Claude", directoryHint: .isDirectory))
            .standardizedFileURL
    }

    public var sessionsRoot: URL { applicationSupport.appending(path: "claude-code-sessions", directoryHint: .isDirectory) }
    public var desktopConfigFile: URL { applicationSupport.appending(path: "config.json") }
    public var usageHistoryFile: URL { applicationSupport.appending(path: "plan-usage-history.json") }
    public var projectsDirectory: URL { claudeHome.appending(path: "projects", directoryHint: .isDirectory) }
    public var accountLabelsFile: URL { switcherDirectory.appending(path: "accounts.json") }
    public var carryOverDirectory: URL { switcherDirectory.appending(path: "CarryOver", directoryHint: .isDirectory) }

    public func partitionDirectory(accountUUID: String, organizationUUID: String) -> URL {
        sessionsRoot
            .appending(path: accountUUID, directoryHint: .isDirectory)
            .appending(path: organizationUUID, directoryHint: .isDirectory)
    }
}

public struct ClaudeUsageSample: Equatable, Sendable {
    public var fiveHourUsedPercent: Int?
    public var sevenDayUsedPercent: Int?
    public var sampledAt: Date

    public init(fiveHourUsedPercent: Int?, sevenDayUsedPercent: Int?, sampledAt: Date) {
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.sevenDayUsedPercent = sevenDayUsedPercent
        self.sampledAt = sampledAt
    }
}

/// 스위처가 관찰한 계정 표시 정보. 전체 이메일은 저장하지 않는다.
public struct ClaudeAccountLabel: Codable, Equatable, Sendable {
    public var accountUUID: String
    public var organizationUUID: String?
    public var maskedEmail: String?
    public var planName: String?
    public var observedAt: Date
    /// 사용자가 붙인 별명. 마스킹 이메일만으로는 계정을 구분하기 어려워 따로 둔다.
    public var nickname: String?

    public init(accountUUID: String, organizationUUID: String?, maskedEmail: String?, planName: String?, observedAt: Date, nickname: String? = nil) {
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.maskedEmail = maskedEmail
        self.planName = planName
        self.observedAt = observedAt
        self.nickname = nickname
    }

    func sameDisplay(as other: ClaudeAccountLabel) -> Bool {
        organizationUUID == other.organizationUUID && maskedEmail == other.maskedEmail && planName == other.planName
    }
}

public struct ClaudeSessionSummary: Equatable, Sendable {
    public var fileName: String
    public var title: String?
    public var cliSessionID: String?
    public var isArchived: Bool
    public var lastActivityAt: Date?
    public var hasTranscript: Bool

    public init(fileName: String, title: String?, cliSessionID: String?, isArchived: Bool, lastActivityAt: Date?, hasTranscript: Bool) {
        self.fileName = fileName
        self.title = title
        self.cliSessionID = cliSessionID
        self.isArchived = isArchived
        self.lastActivityAt = lastActivityAt
        self.hasTranscript = hasTranscript
    }
}

public struct ClaudeAccountPartition: Identifiable, Equatable, Sendable {
    public var accountUUID: String
    public var organizationUUID: String
    public var sessions: [ClaudeSessionSummary]
    public var isCurrent: Bool
    public var directoryExists: Bool
    public var label: ClaudeAccountLabel?
    public var usage: ClaudeUsageSample?

    public init(
        accountUUID: String,
        organizationUUID: String,
        sessions: [ClaudeSessionSummary],
        isCurrent: Bool,
        directoryExists: Bool,
        label: ClaudeAccountLabel?,
        usage: ClaudeUsageSample?
    ) {
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.sessions = sessions
        self.isCurrent = isCurrent
        self.directoryExists = directoryExists
        self.label = label
        self.usage = usage
    }

    public var id: String { "\(accountUUID)/\(organizationUUID)" }
    public var sessionCount: Int { sessions.count }
    public var resumableCount: Int { sessions.filter(\.hasTranscript).count }
    public var lastActivityAt: Date? { sessions.compactMap(\.lastActivityAt).max() }
    public var displayName: String {
        if let nickname = label?.nickname, !nickname.isEmpty { return nickname }
        return label?.maskedEmail ?? "계정 \(accountUUID.prefix(8))…"
    }
}

public struct ClaudeDesktopReport: Equatable, Sendable {
    public var app: OfficialAppInfo?
    public var currentAccountUUID: String?
    public var partitions: [ClaudeAccountPartition]
    public var generatedAt: Date

    public init(app: OfficialAppInfo?, currentAccountUUID: String?, partitions: [ClaudeAccountPartition], generatedAt: Date) {
        self.app = app
        self.currentAccountUUID = currentAccountUUID
        self.partitions = partitions
        self.generatedAt = generatedAt
    }

    /// 현재 로그인 계정의 목록 중 가장 최근에 쓰인 조직. 세션 가져오기의 대상이다.
    public var currentPartition: ClaudeAccountPartition? {
        partitions
            .filter(\.isCurrent)
            .max { ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast) }
    }

    public var otherPartitions: [ClaudeAccountPartition] {
        let currentID = currentPartition?.id
        return partitions.filter { $0.id != currentID }
    }
}

public struct ClaudeAccountLabelStore: Sendable {
    let file: URL

    public init(paths: ClaudeDesktopPaths) {
        file = paths.accountLabelsFile
    }

    public func load() -> [String: ClaudeAccountLabel] {
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let labels = (try? ClaudeJSON.decoder.decode([ClaudeAccountLabel].self, from: data)) ?? []
        return Dictionary(labels.map { ($0.accountUUID, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.observedAt >= rhs.observedAt ? lhs : rhs
        })
    }

    /// 별명만 바꾼다. 아직 관찰한 라벨이 없는 계정이면 별명만 가진 라벨을 만든다. 빈 문자열은 별명 삭제.
    public func setNickname(_ nickname: String?, accountUUID: String, organizationUUID: String?, now: Date = Date()) throws {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = load()[accountUUID] ?? ClaudeAccountLabel(
            accountUUID: accountUUID,
            organizationUUID: organizationUUID,
            maskedEmail: nil,
            planName: nil,
            observedAt: now
        )
        label.nickname = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try upsert(label)
    }

    public func upsert(_ label: ClaudeAccountLabel) throws {
        var labels = load()
        labels[label.accountUUID] = label
        let sorted = labels.values.sorted { $0.accountUUID < $1.accountUUID }
        try AtomicFileWriter().write(try ClaudeJSON.encoder.encode(sorted), to: file)
    }
}

public struct ClaudeDesktopInspector: Sendable {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    let paths: ClaudeDesktopPaths
    let searchRoots: [URL]

    public init(paths: ClaudeDesktopPaths = ClaudeDesktopPaths(), searchRoots: [URL]? = nil) {
        self.paths = paths
        self.searchRoots = searchRoots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        ]
    }

    public func inspect(now: Date = Date()) -> ClaudeDesktopReport {
        let currentAccountUUID = readCurrentAccountUUID()
        let cliAccount = readCLIAccount(observedAt: now)
        let labelStore = ClaudeAccountLabelStore(paths: paths)
        var labels = labelStore.load()
        if var cliAccount, labels[cliAccount.accountUUID]?.sameDisplay(as: cliAccount) != true {
            cliAccount.nickname = labels[cliAccount.accountUUID]?.nickname
            try? labelStore.upsert(cliAccount)
            labels[cliAccount.accountUUID] = cliAccount
        }
        let transcripts = transcriptIndex()
        let usage = latestUsageByOrganization()

        var partitions: [ClaudeAccountPartition] = []
        for accountDirectory in subdirectories(of: paths.sessionsRoot) {
            let accountUUID = accountDirectory.lastPathComponent
            for organizationDirectory in subdirectories(of: accountDirectory) {
                let organizationUUID = organizationDirectory.lastPathComponent
                partitions.append(ClaudeAccountPartition(
                    accountUUID: accountUUID,
                    organizationUUID: organizationUUID,
                    sessions: sessions(in: organizationDirectory, transcripts: transcripts),
                    isCurrent: accountUUID == currentAccountUUID,
                    directoryExists: true,
                    label: labels[accountUUID],
                    usage: usage[organizationUUID]
                ))
            }
        }

        // 새로 로그인한 계정은 첫 세션 전까지 목록 폴더가 없다. CLI 설정이 같은 계정을
        // 가리키면 그 조직으로 대상 폴더를 예약해 가져오기를 허용한다.
        if let currentAccountUUID,
           !partitions.contains(where: { $0.accountUUID == currentAccountUUID }),
           let cliAccount,
           cliAccount.accountUUID == currentAccountUUID,
           let organizationUUID = cliAccount.organizationUUID {
            partitions.append(ClaudeAccountPartition(
                accountUUID: currentAccountUUID,
                organizationUUID: organizationUUID,
                sessions: [],
                isCurrent: true,
                directoryExists: false,
                label: labels[currentAccountUUID],
                usage: usage[organizationUUID]
            ))
        }

        partitions.sort { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
        }
        return ClaudeDesktopReport(
            app: locateApp(),
            currentAccountUUID: currentAccountUUID,
            partitions: partitions,
            generatedAt: now
        )
    }

    public func locateApp() -> OfficialAppInfo? {
        for root in searchRoots {
            let appURL = root.appending(path: "Claude.app", directoryHint: .isDirectory)
            guard
                let data = try? Data(contentsOf: appURL.appending(path: "Contents/Info.plist")),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                info["CFBundleIdentifier"] as? String == Self.bundleIdentifier
            else { continue }
            return OfficialAppInfo(
                path: appURL.path,
                bundleIdentifier: Self.bundleIdentifier,
                shortVersion: info["CFBundleShortVersionString"] as? String,
                buildVersion: info["CFBundleVersion"] as? String,
                bundledCodexPath: nil
            )
        }
        return nil
    }

    static func planName(organizationType: String?, rateLimitTier: String?) -> String? {
        let tier = rateLimitTier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        switch organizationType?.lowercased() {
        case "claude_max": return "Max"
        case "claude_pro": return "Pro"
        case "claude_team": return "Team"
        case "claude_enterprise": return "Enterprise"
        case .some(let other) where !other.isEmpty:
            return other.replacingOccurrences(of: "claude_", with: "").capitalized
        default: return nil
        }
    }

    private func readCurrentAccountUUID() -> String? {
        guard let object = ClaudeJSON.object(at: paths.desktopConfigFile) else { return nil }
        return (object["lastKnownAccountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func readCLIAccount(observedAt: Date) -> ClaudeAccountLabel? {
        guard
            let object = ClaudeJSON.object(at: paths.cliConfigFile),
            let account = object["oauthAccount"] as? [String: Any],
            let accountUUID = account["accountUuid"] as? String,
            !accountUUID.isEmpty
        else { return nil }
        return ClaudeAccountLabel(
            accountUUID: accountUUID,
            organizationUUID: account["organizationUuid"] as? String,
            maskedEmail: Redactor.maskEmail(account["emailAddress"] as? String),
            planName: Self.planName(
                organizationType: account["organizationType"] as? String,
                rateLimitTier: account["organizationRateLimitTier"] as? String
            ),
            observedAt: observedAt
        )
    }

    private func transcriptIndex() -> Set<String> {
        var identifiers = Set<String>()
        for project in subdirectories(of: paths.projectsDirectory) {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: project.path) else { continue }
            for entry in entries where entry.hasSuffix(".jsonl") {
                identifiers.insert(String(entry.dropLast(".jsonl".count)))
            }
        }
        return identifiers
    }

    private func latestUsageByOrganization() -> [String: ClaudeUsageSample] {
        guard
            let object = ClaudeJSON.object(at: paths.usageHistoryFile),
            let samples = object["samples"] as? [[String: Any]]
        else { return [:] }
        var latest: [String: ClaudeUsageSample] = [:]
        for sample in samples {
            guard
                let organization = sample["org"] as? String,
                let milliseconds = (sample["t"] as? NSNumber)?.doubleValue,
                let usage = sample["u"] as? [String: Any]
            else { continue }
            let sampledAt = Date(timeIntervalSince1970: milliseconds / 1_000)
            if let existing = latest[organization], existing.sampledAt >= sampledAt { continue }
            latest[organization] = ClaudeUsageSample(
                fiveHourUsedPercent: (usage["fh"] as? NSNumber)?.intValue,
                sevenDayUsedPercent: (usage["sd"] as? NSNumber)?.intValue,
                sampledAt: sampledAt
            )
        }
        return latest
    }

    private func sessions(in directory: URL, transcripts: Set<String>) -> [ClaudeSessionSummary] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries
            .filter { $0.hasPrefix("local_") && $0.hasSuffix(".json") }
            .sorted()
            .map { name in
                let object = ClaudeJSON.object(at: directory.appending(path: name)) ?? [:]
                let cliSessionID = object["cliSessionId"] as? String
                let lastActivity = (object["lastActivityAt"] as? NSNumber)?.doubleValue
                return ClaudeSessionSummary(
                    fileName: name,
                    title: object["title"] as? String,
                    cliSessionID: cliSessionID,
                    isArchived: object["isArchived"] as? Bool ?? false,
                    lastActivityAt: lastActivity.map { Date(timeIntervalSince1970: $0 / 1_000) },
                    hasTranscript: cliSessionID.map(transcripts.contains) ?? false
                )
            }
    }

    private func subdirectories(of directory: URL) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public struct ClaudeCarryOverPlan: Equatable, Sendable {
    public var source: ClaudeAccountPartition
    public var target: ClaudeAccountPartition
    public var filesToCopy: [String]
    public var skippedExisting: Int
    public var skippedWithoutTranscript: Int
}

public struct ClaudeCarryOverRecord: Codable, Equatable, Identifiable, Sendable {
    public struct CopiedFile: Codable, Equatable, Sendable {
        public var name: String
        public var sha256: String
    }

    public var id: UUID
    public var createdAt: Date
    public var sourceAccountUUID: String
    public var sourceOrganizationUUID: String
    public var targetAccountUUID: String
    public var targetOrganizationUUID: String
    public var copiedFiles: [CopiedFile]
    public var undoneAt: Date?
}

public struct ClaudeUndoResult: Equatable, Sendable {
    public var removed: Int
    public var keptBecauseModified: Int
}

/// 다른 계정의 세션 목록 파일을 현재 계정 목록에 복사한다.
/// 원본은 읽기만 하고, 대상에 이미 있는 파일은 덮어쓰지 않으며, Claude 앱이 실행 중이면 거부한다.
public struct ClaudeSessionCarryOver: Sendable {
    let paths: ClaudeDesktopPaths

    public init(paths: ClaudeDesktopPaths = ClaudeDesktopPaths()) {
        self.paths = paths
    }

    public func plan(from source: ClaudeAccountPartition, to target: ClaudeAccountPartition) -> ClaudeCarryOverPlan {
        let targetDirectory = paths.partitionDirectory(accountUUID: target.accountUUID, organizationUUID: target.organizationUUID)
        var files: [String] = []
        var existing = 0
        var withoutTranscript = 0
        for session in source.sessions {
            if FileManager.default.fileExists(atPath: targetDirectory.appending(path: session.fileName).path) {
                existing += 1
            } else if !session.hasTranscript {
                withoutTranscript += 1
            } else {
                files.append(session.fileName)
            }
        }
        return ClaudeCarryOverPlan(
            source: source,
            target: target,
            filesToCopy: files,
            skippedExisting: existing,
            skippedWithoutTranscript: withoutTranscript
        )
    }

    public func perform(_ plan: ClaudeCarryOverPlan, claudeIsRunning: Bool, now: Date = Date()) throws -> ClaudeCarryOverRecord {
        guard !claudeIsRunning else { throw SwitcherError.claudeAppRunning }
        guard plan.source.id != plan.target.id else {
            throw SwitcherError.claudeCarryOverUnavailable("원본과 대상 계정이 같습니다.")
        }
        guard !plan.filesToCopy.isEmpty else {
            throw SwitcherError.claudeCarryOverUnavailable("가져올 수 있는 세션이 없습니다.")
        }
        let sourceDirectory = paths.partitionDirectory(
            accountUUID: plan.source.accountUUID,
            organizationUUID: plan.source.organizationUUID
        )
        let targetDirectory = paths.partitionDirectory(
            accountUUID: plan.target.accountUUID,
            organizationUUID: plan.target.organizationUUID
        )
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var copied: [ClaudeCarryOverRecord.CopiedFile] = []
        do {
            for name in plan.filesToCopy {
                let destination = targetDirectory.appending(path: name)
                guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                let data = try Data(contentsOf: sourceDirectory.appending(path: name))
                try AtomicFileWriter().write(data, to: destination)
                copied.append(.init(name: name, sha256: Self.sha256(data)))
            }
        } catch {
            for file in copied {
                try? FileManager.default.removeItem(at: targetDirectory.appending(path: file.name))
            }
            throw SwitcherError.fileOperation("세션 목록 복사 중 실패해 복사한 파일을 되돌렸습니다: \(Redactor.redact(error.localizedDescription))")
        }

        let record = ClaudeCarryOverRecord(
            id: UUID(),
            createdAt: now,
            sourceAccountUUID: plan.source.accountUUID,
            sourceOrganizationUUID: plan.source.organizationUUID,
            targetAccountUUID: plan.target.accountUUID,
            targetOrganizationUUID: plan.target.organizationUUID,
            copiedFiles: copied,
            undoneAt: nil
        )
        try save(record)
        return record
    }

    public func latestUndoableRecord() -> ClaudeCarryOverRecord? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: paths.carryOverDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? ClaudeJSON.decoder.decode(ClaudeCarryOverRecord.self, from: Data(contentsOf: $0)) }
            .filter { $0.undoneAt == nil }
            .max { $0.createdAt < $1.createdAt }
    }

    /// 복사 이후 바뀌지 않은 파일만 지운다. 대상 계정에서 이어서 쓴 세션은 남겨 둔다.
    public func undo(_ record: ClaudeCarryOverRecord, claudeIsRunning: Bool, now: Date = Date()) throws -> ClaudeUndoResult {
        guard !claudeIsRunning else { throw SwitcherError.claudeAppRunning }
        let targetDirectory = paths.partitionDirectory(
            accountUUID: record.targetAccountUUID,
            organizationUUID: record.targetOrganizationUUID
        )
        var result = ClaudeUndoResult(removed: 0, keptBecauseModified: 0)
        for file in record.copiedFiles {
            let url = targetDirectory.appending(path: file.name)
            guard let data = try? Data(contentsOf: url) else { continue }
            if Self.sha256(data) == file.sha256 {
                try FileManager.default.removeItem(at: url)
                result.removed += 1
            } else {
                result.keptBecauseModified += 1
            }
        }
        var finished = record
        finished.undoneAt = now
        try save(finished)
        return result
    }

    private func save(_ record: ClaudeCarryOverRecord) throws {
        try AtomicFileWriter().write(
            try ClaudeJSON.encoder.encode(record),
            to: paths.carryOverDirectory.appending(path: "\(record.id.uuidString).json")
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ClaudeJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
