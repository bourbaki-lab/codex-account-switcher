import Foundation
import XCTest
@testable import CodexAccountSwitcherCore

final class AtomicSnapshotAndRecoveryTests: XCTestCase {
    func testAtomicReplacementAnd0600Permissions() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "auth.json")
        let writer = AtomicFileWriter()
        try writer.write(TestFixtures.authentication("a"), to: file)
        try writer.write(TestFixtures.authentication("b"), to: file)
        XCTAssertEqual(try Data(contentsOf: file), TestFixtures.authentication("b"))
        XCTAssertEqual(try writer.permissions(of: file), 0o600)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains(".tmp") })
    }

    func testSwitchLockRejectsConcurrentAcquisition() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockURL = root.appending(path: "switch.lock")
        let first = try SwitchLock.acquire(at: lockURL)
        _ = first
        XCTAssertThrowsError(try SwitchLock.acquire(at: lockURL))
    }

    func testSessionSnapshotIgnoresAuthAndDetectsSessionChanges() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        try AtomicFileWriter().write(TestFixtures.authentication("a"), to: paths.authFile)
        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)
        let before = try snapshotter.capture()

        try AtomicFileWriter().write(TestFixtures.authentication("b"), to: paths.authFile)
        let authOnly = snapshotter.compare(before, try snapshotter.capture())
        XCTAssertTrue(authOnly.isUnchanged)

        try Data("changed".utf8).write(to: paths.codexHome.appending(path: "sessions/2026/08/session.jsonl"))
        let changed = snapshotter.compare(before, try snapshotter.capture())
        XCTAssertEqual(changed.modified, ["sessions/2026/08/session.jsonl"])
    }

    func testMetadataSnapshotDetectsProtectedMutationWithoutHashingContents() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)
        let session = paths.codexHome.appending(path: "sessions/2026/08/session.jsonl")
        let before = try snapshotter.capture(mode: .metadataOnly)

        try Data("session-mutated".utf8).write(to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: session.path
        )

        let comparison = snapshotter.compare(before, try snapshotter.capture(mode: .metadataOnly))
        XCTAssertTrue(comparison.modified.contains("sessions/2026/08/session.jsonl"))
    }

    func testSnapshotsIgnoreDirectoryTimestampChanges() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)

        for mode in [SessionSnapshotCaptureMode.contentHashed, .metadataOnly] {
            let before = try snapshotter.capture(mode: mode)
            for path in ["skills", "skills/example", "sessions"] {
                let originalDate = try XCTUnwrap(before.entries[path]?.modifiedAt)
                try FileManager.default.setAttributes(
                    [.modificationDate: originalDate.addingTimeInterval(60)],
                    ofItemAtPath: paths.codexHome.appending(path: path).path
                )
            }
            let after = try snapshotter.capture(mode: mode)
            XCTAssertNotEqual(before.entries["skills"]?.modifiedAt, after.entries["skills"]?.modifiedAt)
            let comparison = snapshotter.compare(before, after)
            XCTAssertTrue(comparison.isUnchanged)
            XCTAssertEqual(comparison.unchangedCount, before.entries.count)
        }
    }

    func testSnapshotIgnoresDirectorySizeButStillDetectsTypeChanges() {
        let snapshotter = SessionSnapshotter(codexHome: URL(fileURLWithPath: "/fixture"))
        let before = SessionSnapshot(codexHome: "/fixture", entries: [
            "skills": FileFingerprint(relativePath: "skills", kind: .directory, size: 64, modifiedAt: nil, sha256: nil)
        ])
        var after = before
        after.entries["skills"]?.size = 512
        after.entries["skills"]?.modifiedAt = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(snapshotter.compare(before, after).isUnchanged)

        after.entries["skills"]?.kind = .file
        XCTAssertEqual(snapshotter.compare(before, after).modified, ["skills"])
        XCTAssertEqual(snapshotter.compare(after, before).modified, ["skills"])
    }

    func testSnapshotsStillDetectProtectedSkillFileChanges() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)
        let skill = paths.codexHome.appending(path: "skills/example/SKILL.md")
        let additionalSkill = paths.codexHome.appending(path: "skills/example/EXTRA.md")

        for mode in [SessionSnapshotCaptureMode.contentHashed, .metadataOnly] {
            try Data("skill-stable".utf8).write(to: skill)
            let before = try snapshotter.capture(mode: mode)
            // Same-size content still needs to be detected, not just length changes.
            try Data("skill-edited".utf8).write(to: skill)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(60)],
                ofItemAtPath: skill.path
            )
            XCTAssertEqual(
                snapshotter.compare(before, try snapshotter.capture(mode: mode)).modified,
                ["skills/example/SKILL.md"]
            )

            try FileManager.default.removeItem(at: skill)
            try Data("new skill".utf8).write(to: additionalSkill)
            let changed = snapshotter.compare(before, try snapshotter.capture(mode: mode))
            XCTAssertEqual(changed.deleted, ["skills/example/SKILL.md"])
            XCTAssertEqual(changed.added, ["skills/example/EXTRA.md"])
            XCTAssertTrue(changed.modified.isEmpty)
            XCTAssertTrue(changed.hasDestructiveChange)
            try FileManager.default.removeItem(at: additionalSkill)
        }
    }

    func testSnapshotsStillDetectDirectoryAdditionAndDeletion() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        let skills = paths.codexHome.appending(path: "skills")
        try FileManager.default.createDirectory(at: skills.appending(path: "old"), withIntermediateDirectories: true)
        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)
        let before = try snapshotter.capture(mode: .metadataOnly)

        try FileManager.default.removeItem(at: skills.appending(path: "old"))
        try FileManager.default.createDirectory(at: skills.appending(path: "new"), withIntermediateDirectories: true)
        let changed = snapshotter.compare(before, try snapshotter.capture(mode: .metadataOnly))
        XCTAssertEqual(changed.deleted, ["skills/old"])
        XCTAssertEqual(changed.added, ["skills/new"])
        XCTAssertTrue(changed.hasDestructiveChange)
        XCTAssertFalse(changed.isUnchanged)
    }

    func testRecoveryStoreRollsAuthenticationBack() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        let vault = CryptoVault(keyStore: MemoryKeyStore())
        let recovery = RecoveryStore(paths: paths, vault: vault)
        let original = TestFixtures.authentication("original")
        try AtomicFileWriter().write(original, to: paths.authFile)
        try recovery.createBackup(from: original)
        try AtomicFileWriter().write(TestFixtures.authentication("new"), to: paths.authFile)
        try recovery.restoreLatest()
        XCTAssertEqual(try Data(contentsOf: paths.authFile), original)
        XCTAssertEqual(try AtomicFileWriter().permissions(of: paths.authFile), 0o600)
    }

    func testSessionMarkerFinderReturnsExactSessionIDWithoutReadingSecrets() throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        let id = "019fd5d1-8a49-7380-a838-a13ed09603d1"
        let session = paths.codexHome.appending(path: "sessions/2026/08/rollout-\(id).jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = "CAS-PROBE-\(UUID().uuidString)"
        try Data("{\"message\":\"\(marker)\"}".utf8).write(to: session)
        let match = try SessionMarkerFinder(codexHome: paths.codexHome).find(marker: marker)
        XCTAssertEqual(match?.fileURL.resolvingSymlinksInPath(), session.resolvingSymlinksInPath())
        XCTAssertEqual(match?.sessionID, id)
    }
}
