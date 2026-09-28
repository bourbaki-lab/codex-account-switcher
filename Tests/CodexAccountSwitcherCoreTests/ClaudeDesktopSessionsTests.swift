import Foundation
import XCTest
@testable import CodexAccountSwitcherCore

final class ClaudeDesktopSessionsTests: XCTestCase {
    private let accountA = "aaaaaaaa-0000-0000-0000-000000000001"
    private let orgA = "0a0a0a0a-0000-0000-0000-000000000001"
    private let accountB = "bbbbbbbb-0000-0000-0000-000000000002"
    private let orgB = "0b0b0b0b-0000-0000-0000-000000000002"

    func testInspectorGroupsSessionsByAccountAndMarksCurrent() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeSession(paths, account: accountA, org: orgA, name: "local_2.json", cliSessionID: "cli-gone", activity: 2_000)
        try writeSession(paths, account: accountB, org: orgB, name: "local_3.json", cliSessionID: "cli-3", activity: 3_000)
        try writeTranscript(paths, cliSessionID: "cli-1")
        try writeTranscript(paths, cliSessionID: "cli-3")

        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()

        XCTAssertEqual(report.currentAccountUUID, accountB)
        XCTAssertEqual(report.partitions.count, 2)
        XCTAssertEqual(report.currentPartition?.accountUUID, accountB)
        let other = try XCTUnwrap(report.otherPartitions.first)
        XCTAssertEqual(other.accountUUID, accountA)
        XCTAssertEqual(other.sessionCount, 2)
        XCTAssertEqual(other.resumableCount, 1)
        XCTAssertEqual(other.lastActivityAt, Date(timeIntervalSince1970: 2))
    }

    func testUsageUsesLatestSamplePerOrganization() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountA)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        let history: [String: Any] = [
            "version": 2,
            "samples": [
                ["t": 3_000, "org": orgA, "u": ["fh": 15, "sd": 4]],
                ["t": 1_000, "org": orgA, "u": ["fh": 90, "sd": 50]],
                ["t": 2_000, "org": orgB, "u": ["fh": 1, "sd": 2]]
            ]
        ]
        try Self.writeJSON(history, to: paths.usageHistoryFile)

        let usage = try XCTUnwrap(ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect().currentPartition?.usage)

        XCTAssertEqual(usage.fiveHourUsedPercent, 15)
        XCTAssertEqual(usage.sevenDayUsedPercent, 4)
        XCTAssertEqual(usage.sampledAt, Date(timeIntervalSince1970: 3))
    }

    func testLabelStoreKeepsOnlyMaskedEmailFromCLIConfig() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountA)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeCLIAccount(paths, account: accountA, org: orgA, email: "person@example.com")

        let label = try XCTUnwrap(ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect().currentPartition?.label)

        XCTAssertEqual(label.maskedEmail, "p***@example.com")
        XCTAssertEqual(label.planName, "Max 20x")
        let stored = try String(contentsOf: paths.accountLabelsFile, encoding: .utf8)
        XCTAssertFalse(stored.contains("person@example.com"))
        XCTAssertEqual(try AtomicFileWriter().permissions(of: paths.accountLabelsFile), 0o600)
    }

    func testLabelSurvivesAfterCLIConfigMovesToAnotherAccount() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountA)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeCLIAccount(paths, account: accountA, org: orgA, email: "first@example.com")
        _ = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()

        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeCLIAccount(paths, account: accountB, org: orgB, email: "second@example.com")
        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()

        XCTAssertEqual(report.otherPartitions.first?.label?.maskedEmail, "f***@example.com")
        XCTAssertEqual(report.currentPartition?.label?.maskedEmail, "s***@example.com")
    }

    func testNewAccountWithoutSessionFolderUsesCLIOrganizationAsTarget() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeCLIAccount(paths, account: accountB, org: orgB, email: "second@example.com")
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeTranscript(paths, cliSessionID: "cli-1")

        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()
        let target = try XCTUnwrap(report.currentPartition)
        XCTAssertEqual(target.organizationUUID, orgB)
        XCTAssertFalse(target.directoryExists)

        let carryOver = ClaudeSessionCarryOver(paths: paths)
        let source = try XCTUnwrap(report.otherPartitions.first)
        let record = try carryOver.perform(carryOver.plan(from: source, to: target), claudeIsRunning: false)

        XCTAssertEqual(record.copiedFiles.map(\.name), ["local_1.json"])
        let copied = paths.partitionDirectory(accountUUID: accountB, organizationUUID: orgB).appending(path: "local_1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testCarryOverCopiesOnlyMissingResumableSessionsAndLeavesSourceIntact() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeSession(paths, account: accountA, org: orgA, name: "local_new.json", cliSessionID: "cli-new", activity: 1_000)
        try writeSession(paths, account: accountA, org: orgA, name: "local_shared.json", cliSessionID: "cli-shared", activity: 1_000)
        try writeSession(paths, account: accountA, org: orgA, name: "local_gone.json", cliSessionID: "cli-gone", activity: 1_000)
        try writeSession(paths, account: accountB, org: orgB, name: "local_shared.json", cliSessionID: "cli-shared", activity: 5_000, title: "target copy")
        try writeTranscript(paths, cliSessionID: "cli-new")
        try writeTranscript(paths, cliSessionID: "cli-shared")
        let sourceDirectory = paths.partitionDirectory(accountUUID: accountA, organizationUUID: orgA)
        let sourceBefore = try Self.contents(of: sourceDirectory)
        let targetShared = paths.partitionDirectory(accountUUID: accountB, organizationUUID: orgB).appending(path: "local_shared.json")
        let targetSharedBefore = try Data(contentsOf: targetShared)

        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()
        let carryOver = ClaudeSessionCarryOver(paths: paths)
        let plan = carryOver.plan(
            from: try XCTUnwrap(report.otherPartitions.first),
            to: try XCTUnwrap(report.currentPartition)
        )
        XCTAssertEqual(plan.filesToCopy, ["local_new.json"])
        XCTAssertEqual(plan.skippedExisting, 1)
        XCTAssertEqual(plan.skippedWithoutTranscript, 1)

        _ = try carryOver.perform(plan, claudeIsRunning: false)

        let copied = paths.partitionDirectory(accountUUID: accountB, organizationUUID: orgB).appending(path: "local_new.json")
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: sourceDirectory.appending(path: "local_new.json")))
        XCTAssertEqual(try AtomicFileWriter().permissions(of: copied), 0o600)
        XCTAssertEqual(try Data(contentsOf: targetShared), targetSharedBefore)
        XCTAssertEqual(try Self.contents(of: sourceDirectory), sourceBefore)
    }

    func testCarryOverRefusesWhileClaudeIsRunning() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeSession(paths, account: accountB, org: orgB, name: "local_2.json", cliSessionID: "cli-2", activity: 2_000)
        try writeTranscript(paths, cliSessionID: "cli-1")

        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()
        let carryOver = ClaudeSessionCarryOver(paths: paths)
        let plan = carryOver.plan(from: try XCTUnwrap(report.otherPartitions.first), to: try XCTUnwrap(report.currentPartition))

        XCTAssertThrowsError(try carryOver.perform(plan, claudeIsRunning: true))
        let target = paths.partitionDirectory(accountUUID: accountB, organizationUUID: orgB).appending(path: "local_1.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertNil(carryOver.latestUndoableRecord())
    }

    func testUndoRemovesUnchangedCopiesAndKeepsSessionsUsedByNewAccount() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = Self.paths(root: root)
        try writeDesktopConfig(paths, currentAccount: accountB)
        try writeSession(paths, account: accountA, org: orgA, name: "local_1.json", cliSessionID: "cli-1", activity: 1_000)
        try writeSession(paths, account: accountA, org: orgA, name: "local_2.json", cliSessionID: "cli-2", activity: 1_000)
        try writeSession(paths, account: accountB, org: orgB, name: "local_3.json", cliSessionID: "cli-3", activity: 2_000)
        try writeTranscript(paths, cliSessionID: "cli-1")
        try writeTranscript(paths, cliSessionID: "cli-2")

        let report = ClaudeDesktopInspector(paths: paths, searchRoots: []).inspect()
        let carryOver = ClaudeSessionCarryOver(paths: paths)
        let record = try carryOver.perform(
            carryOver.plan(from: try XCTUnwrap(report.otherPartitions.first), to: try XCTUnwrap(report.currentPartition)),
            claudeIsRunning: false
        )
        XCTAssertEqual(carryOver.latestUndoableRecord()?.id, record.id)

        let targetDirectory = paths.partitionDirectory(accountUUID: accountB, organizationUUID: orgB)
        try Data("{\"cliSessionId\":\"cli-2\",\"title\":\"continued\"}".utf8)
            .write(to: targetDirectory.appending(path: "local_2.json"))

        XCTAssertThrowsError(try carryOver.undo(record, claudeIsRunning: true))
        let result = try carryOver.undo(record, claudeIsRunning: false)

        XCTAssertEqual(result, ClaudeUndoResult(removed: 1, keptBecauseModified: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDirectory.appending(path: "local_1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appending(path: "local_2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetDirectory.appending(path: "local_3.json").path))
        XCTAssertNil(carryOver.latestUndoableRecord())
        let sourceDirectory = paths.partitionDirectory(accountUUID: accountA, organizationUUID: orgA)
        XCTAssertEqual(try Self.contents(of: sourceDirectory).count, 2)
    }

    func testPlanNameMapping() {
        XCTAssertEqual(ClaudeDesktopInspector.planName(organizationType: "claude_max", rateLimitTier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(ClaudeDesktopInspector.planName(organizationType: "claude_pro", rateLimitTier: nil), "Pro")
        XCTAssertEqual(ClaudeDesktopInspector.planName(organizationType: "claude_team", rateLimitTier: "default"), "Team")
        XCTAssertNil(ClaudeDesktopInspector.planName(organizationType: nil, rateLimitTier: nil))
    }

    // MARK: - Fixtures

    private static func paths(root: URL) -> ClaudeDesktopPaths {
        ClaudeDesktopPaths(
            applicationSupport: root.appending(path: "Claude", directoryHint: .isDirectory),
            claudeHome: root.appending(path: ".claude", directoryHint: .isDirectory),
            cliConfigFile: root.appending(path: ".claude.json"),
            switcherDirectory: root.appending(path: "Switcher/Claude", directoryHint: .isDirectory)
        )
    }

    private func writeDesktopConfig(_ paths: ClaudeDesktopPaths, currentAccount: String) throws {
        try Self.writeJSON(["lastKnownAccountUuid": currentAccount, "locale": "ko-KR"], to: paths.desktopConfigFile)
    }

    private func writeCLIAccount(_ paths: ClaudeDesktopPaths, account: String, org: String, email: String) throws {
        try Self.writeJSON([
            "oauthAccount": [
                "accountUuid": account,
                "organizationUuid": org,
                "emailAddress": email,
                "organizationType": "claude_max",
                "organizationRateLimitTier": "default_claude_max_20x"
            ]
        ], to: paths.cliConfigFile)
    }

    private func writeSession(
        _ paths: ClaudeDesktopPaths,
        account: String,
        org: String,
        name: String,
        cliSessionID: String,
        activity: Double,
        title: String = "session"
    ) throws {
        try Self.writeJSON([
            "sessionId": String(name.dropLast(".json".count)),
            "cliSessionId": cliSessionID,
            "title": title,
            "isArchived": false,
            "lastActivityAt": activity
        ], to: paths.partitionDirectory(accountUUID: account, organizationUUID: org).appending(path: name))
    }

    private func writeTranscript(_ paths: ClaudeDesktopPaths, cliSessionID: String) throws {
        let project = paths.projectsDirectory.appending(path: "-Users-test-project", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("{\"type\":\"user\"}\n".utf8).write(to: project.appending(path: "\(cliSessionID).jsonl"))
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private static func contents(of directory: URL) throws -> [String: Data] {
        var output: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            output[name] = try Data(contentsOf: directory.appending(path: name))
        }
        return output
    }
}
