import Foundation
import XCTest
@testable import CodexAccountSwitcherCore

final class IntegrationSwitchTests: XCTestCase {
    func testTenSwitchesChangeOnlyAuthenticationAndKeepLogsSecretFree() async throws {
        let root = try TestFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        let writer = AtomicFileWriter()
        let vault = CryptoVault(keyStore: MemoryKeyStore())
        let store = EncryptedProfileStore(paths: paths, vault: vault)
        let accountA = AccountProfile(displayName: "Account A", maskedEmail: "a***@example.com", planType: "pro", isActive: true)
        let accountB = AccountProfile(displayName: "Account B", maskedEmail: "b***@example.com", planType: "pro")
        _ = try await store.save(
            profile: accountA,
            secret: ProfileSecret(authCache: TestFixtures.authentication("account-a"), accountEmail: "a@example.com", planType: "pro")
        )
        _ = try await store.save(
            profile: accountB,
            secret: ProfileSecret(authCache: TestFixtures.authentication("account-b"), accountEmail: "b@example.com", planType: "pro")
        )
        try writer.write(TestFixtures.authentication("account-a"), to: paths.authFile)

        let snapshotter = SessionSnapshotter(codexHome: paths.codexHome)
        let baseline = try snapshotter.capture()
        for index in 0..<10 {
            let target = index.isMultiple(of: 2) ? accountB.id : accountA.id
            let secret = try await store.secret(for: target)
            try AuthCacheValidator.validate(secret.authCache)
            try writer.write(secret.authCache, to: paths.authFile)
            XCTAssertEqual(try writer.permissions(of: paths.authFile), 0o600)
            XCTAssertTrue(snapshotter.compare(baseline, try snapshotter.capture()).isUnchanged)
        }

        XCTAssertEqual(try Data(contentsOf: paths.codexHome.appending(path: "history.jsonl")), Data("history-stable".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.codexHome.appending(path: "sessions/2026/08/session.jsonl")), Data("session-stable".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.codexHome.appending(path: "config.toml")), Data("config-stable".utf8))
        XCTAssertEqual(try Data(contentsOf: paths.codexHome.appending(path: "skills/example/SKILL.md")), Data("skill-stable".utf8))

        let rawLog = "access_token=fixture-account-a refresh_token=refresh-account-a authorization=Bearer hidden"
        let safeLog = Redactor.redact(rawLog)
        let logURL = root.appending(path: "switch.log")
        try Data(safeLog.utf8).write(to: logURL)
        let persistedLog = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(persistedLog.contains("fixture-account-a"))
        XCTAssertFalse(persistedLog.contains("refresh-account-a"))
        XCTAssertFalse(persistedLog.contains("Bearer hidden"))
    }

    @MainActor
    func testCoordinatorVerifiesTargetWithoutForcingSecondTokenRefresh() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SequenceAccountProbe(results: [fixture.identityA, fixture.identityB])
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        let result = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
        let refreshRequests = await probe.refreshTokenRequests()
        let activeProfileID = try await fixture.store.loadProfiles().first(where: \.isActive)?.id

        XCTAssertEqual(result.account, fixture.identityB)
        XCTAssertEqual(refreshRequests, [true, false])
        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationB)
        XCTAssertEqual(activeProfileID, fixture.accountB.id)
    }

    @MainActor
    func testCoordinatorKeepsTargetAfterSkillsDirectoryMetadataChanges() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let skills = fixture.paths.codexHome.appending(path: "skills")
        let probe = SequenceAccountProbe(
            results: [fixture.identityA, fixture.identityB, fixture.identityA],
            onRead: { call in
                if call == 2 {
                    try FileManager.default.setAttributes(
                        [.modificationDate: Date().addingTimeInterval(60)],
                        ofItemAtPath: skills.path
                    )
                }
            }
        )
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)
        var phases: [SwitchPhase] = []

        let result = try await coordinator.switchAccount(to: fixture.accountB.id) { phases.append($0) }
        let activeProfileID = try await fixture.store.loadProfiles().first(where: \.isActive)?.id

        XCTAssertEqual(result.account, fixture.identityB)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationB)
        XCTAssertEqual(activeProfileID, fixture.accountB.id)
        XCTAssertTrue(result.snapshotChanges.isUnchanged)
        XCTAssertEqual(phases.last, .completed)
        XCTAssertFalse(phases.contains(.rollingBack))
        XCTAssertEqual(appController.launchCount, 1)
    }

    @MainActor
    func testCoordinatorRestoresPreviousAuthenticationWhenTargetVerificationFails() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SequenceAccountProbe(results: [fixture.identityA, nil, fixture.identityA])
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)
        var phases: [SwitchPhase] = []

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { phases.append($0) }
            XCTFail("대상 계정 검증 실패에서 전환이 성공하면 안 됩니다")
        } catch SwitcherError.accountVerificationFailed {
            // Expected after a successful rollback.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountA.id)
        XCTAssertTrue(phases.contains(.rollingBack))
        XCTAssertEqual(appController.launchCount, 1)
    }

    @MainActor
    func testCoordinatorRestoresPreviousAuthenticationWhenOfficialAppRelaunchFails() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SequenceAccountProbe(results: [fixture.identityA, fixture.identityB, fixture.identityA])
        let appController = FakeOfficialAppController(failedLaunchCalls: [1])
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
            XCTFail("공식 앱 재실행 실패에서 전환이 성공하면 안 됩니다")
        } catch FakeCoordinatorError.launchFailed {
            // Expected after a successful rollback and second launch.
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountA.id)
        XCTAssertEqual(appController.launchCount, 2)
        XCTAssertTrue(appController.isRunning(fixture.officialApp))
    }

    @MainActor
    func testCoordinatorRollsAuthenticationBackWhenProtectedSessionIsDeleted() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let protectedSession = fixture.paths.codexHome.appending(path: "sessions/2026/08/session.jsonl")
        let probe = SequenceAccountProbe(results: [fixture.identityA, fixture.identityB, fixture.identityA])
        let appController = FakeOfficialAppController { launchCall in
            if launchCall == 1 {
                try FileManager.default.removeItem(at: protectedSession)
            }
        }
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
            XCTFail("보호 세션 삭제를 성공으로 처리하면 안 됩니다")
        } catch SwitcherError.sessionFilesMissing(let paths) {
            XCTAssertTrue(paths.contains("sessions/2026/08/session.jsonl"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountA.id)
    }

    @MainActor
    func testCoordinatorRejectsProtectedMutationDuringAuthenticationOnlyWindow() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let protectedSession = fixture.paths.codexHome.appending(path: "sessions/2026/08/session.jsonl")
        let probe = SequenceAccountProbe(
            results: [fixture.identityA, fixture.identityB, fixture.identityA],
            onRead: { call in
                if call == 2 {
                    try Data("unexpected-session-mutation".utf8).write(to: protectedSession)
                }
            }
        )
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
            XCTFail("인증 교체 구간의 보호 상태 변경을 성공으로 처리하면 안 됩니다")
        } catch SwitcherError.protectedStateChangedDuringSwitch(let paths) {
            XCTAssertTrue(paths.contains("sessions/2026/08/session.jsonl"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountA.id)
    }

    @MainActor
    func testCoordinatorStillRollsBackWhenProtectedSkillFileChanges() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let skill = fixture.paths.codexHome.appending(path: "skills/example/SKILL.md")
        let probe = SequenceAccountProbe(
            results: [fixture.identityA, fixture.identityB, fixture.identityA],
            onRead: { call in
                if call == 2 {
                    try Data("unexpected-skill-mutation".utf8).write(to: skill)
                }
            }
        )
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)
        var phases: [SwitchPhase] = []

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { phases.append($0) }
            XCTFail("실제 skill 파일 변경은 계속 전환을 중단해야 합니다")
        } catch SwitcherError.protectedStateChangedDuringSwitch(let paths) {
            XCTAssertEqual(paths, ["skills/example/SKILL.md"])
        }

        let activeProfileID = try await fixture.store.loadProfiles().first(where: \.isActive)?.id
        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        XCTAssertEqual(activeProfileID, fixture.accountA.id)
        XCTAssertTrue(phases.contains(.rollingBack))
        XCTAssertFalse(phases.contains(.completed))
    }

    @MainActor
    func testCoordinatorReportsRollbackFailureWhenPreviousAccountCannotBeVerified() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SequenceAccountProbe(results: [fixture.identityA, nil, nil])
        let appController = FakeOfficialAppController()
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
            XCTFail("롤백 계정 재검증 실패를 성공으로 처리하면 안 됩니다")
        } catch SwitcherError.rollbackFailed(let message) {
            XCTAssertTrue(message.contains("롤백 후 계정이 인증되지 않았습니다"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationA)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountA.id)
    }

    @MainActor
    func testCoordinatorDoesNotRewriteAuthenticationWhenRollbackQuitIsRefused() async throws {
        let fixture = try await makeCoordinatorFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let protectedSession = fixture.paths.codexHome.appending(path: "sessions/2026/08/session.jsonl")
        let probe = SequenceAccountProbe(results: [fixture.identityA, fixture.identityB])
        let appController = FakeOfficialAppController(normalQuitResults: [true, false]) { launchCall in
            if launchCall == 1 {
                try FileManager.default.removeItem(at: protectedSession)
            }
        }
        let coordinator = makeCoordinator(fixture: fixture, probe: probe, appController: appController)

        do {
            _ = try await coordinator.switchAccount(to: fixture.accountB.id) { _ in }
            XCTFail("실행 중인 앱을 종료하지 못한 롤백은 실패해야 합니다")
        } catch SwitcherError.rollbackFailed(let message) {
            XCTAssertTrue(message.contains("정상 종료되지 않았습니다"))
        }

        XCTAssertEqual(try Data(contentsOf: fixture.paths.authFile), fixture.authenticationB)
        let activeProfile = try await fixture.store.loadProfiles().first(where: \.isActive)
        XCTAssertEqual(activeProfile?.id, fixture.accountB.id)
    }

    @MainActor
    private func makeCoordinatorFixture() async throws -> CoordinatorFixture {
        let root = try TestFixtures.temporaryDirectory()
        let paths = TestFixtures.paths(root: root)
        try TestFixtures.populateSharedState(paths)
        let store = EncryptedProfileStore(paths: paths, vault: CryptoVault(keyStore: MemoryKeyStore()))
        let accountA = AccountProfile(
            displayName: "Account A",
            maskedEmail: "a***@example.com",
            planType: "pro",
            isActive: true
        )
        let accountB = AccountProfile(
            displayName: "Account B",
            maskedEmail: "b***@example.com",
            planType: "pro"
        )
        let authenticationA = TestFixtures.authentication("account-a")
        let authenticationB = TestFixtures.authentication("account-b")
        _ = try await store.save(
            profile: accountA,
            secret: ProfileSecret(authCache: authenticationA, accountEmail: "a@example.com", planType: "pro")
        )
        _ = try await store.save(
            profile: accountB,
            secret: ProfileSecret(authCache: authenticationB, accountEmail: "b@example.com", planType: "pro")
        )
        try AtomicFileWriter().write(authenticationA, to: paths.authFile)
        return CoordinatorFixture(
            root: root,
            paths: paths,
            store: store,
            accountA: accountA,
            accountB: accountB,
            authenticationA: authenticationA,
            authenticationB: authenticationB
        )
    }

    @MainActor
    private func makeCoordinator(
        fixture: CoordinatorFixture,
        probe: SequenceAccountProbe,
        appController: FakeOfficialAppController
    ) -> AccountSwitchCoordinator {
        AccountSwitchCoordinator(
            paths: fixture.paths,
            officialApp: fixture.officialApp,
            profileStore: fixture.store,
            accountProbe: probe,
            appController: appController,
            processScanner: StaticProcessScanner(),
            preflight: AlwaysAllowPreflight(),
            recoveryStore: RecoveryStore(
                paths: fixture.paths,
                vault: CryptoVault(keyStore: MemoryKeyStore())
            )
        )
    }
}

private struct CoordinatorFixture: Sendable {
    let root: URL
    let paths: SwitcherPaths
    let store: EncryptedProfileStore
    let accountA: AccountProfile
    let accountB: AccountProfile
    let authenticationA: Data
    let authenticationB: Data

    var identityA: AccountIdentity {
        AccountIdentity(type: "chatgpt", email: "a@example.com", planType: "pro", requiresOpenAIAuth: true)
    }

    var identityB: AccountIdentity {
        AccountIdentity(type: "chatgpt", email: "b@example.com", planType: "pro", requiresOpenAIAuth: true)
    }

    var officialApp: OfficialAppInfo {
        OfficialAppInfo(
            path: "/Applications/Codex.app",
            bundleIdentifier: "com.openai.codex",
            shortVersion: "test",
            buildVersion: "test",
            bundledCodexPath: "/Applications/Codex.app/Contents/Resources/codex"
        )
    }
}

private actor SequenceAccountProbe: AccountProbing {
    private var results: [AccountIdentity?]
    private var readCount = 0
    private var refreshRequests: [Bool] = []
    private let onRead: (@Sendable (Int) throws -> Void)?

    init(results: [AccountIdentity?], onRead: (@Sendable (Int) throws -> Void)? = nil) {
        self.results = results
        self.onRead = onRead
    }

    func readAccount(refreshToken: Bool) async throws -> AccountIdentity? {
        readCount += 1
        refreshRequests.append(refreshToken)
        try onRead?(readCount)
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }

    func refreshTokenRequests() -> [Bool] {
        refreshRequests
    }

    func readRateLimits() async throws -> AccountRateLimits? {
        nil
    }
}

private struct StaticProcessScanner: CodexProcessScanning {
    var processes: [ProcessSummary] = []

    func scan(officialAppPath: String?) throws -> [ProcessSummary] {
        processes
    }
}

private struct AlwaysAllowPreflight: AccountSwitchPreflighting {
    func validateBeforeSwitch() async throws {}
    func validateAfterLaunch() async throws {}
}

private enum FakeCoordinatorError: Error {
    case launchFailed
}

@MainActor
private final class FakeOfficialAppController: OfficialAppControlling {
    private var running = true
    private var normalQuitResults: [Bool]
    private let failedLaunchCalls: Set<Int>
    private let onLaunch: (@MainActor (Int) throws -> Void)?
    private(set) var launchCount = 0

    init(
        normalQuitResults: [Bool] = [],
        failedLaunchCalls: Set<Int> = [],
        onLaunch: (@MainActor (Int) throws -> Void)? = nil
    ) {
        self.normalQuitResults = normalQuitResults
        self.failedLaunchCalls = failedLaunchCalls
        self.onLaunch = onLaunch
    }

    func isRunning(_ app: OfficialAppInfo) -> Bool {
        running
    }

    func requestNormalQuit(_ app: OfficialAppInfo, timeout: TimeInterval) async -> Bool {
        let result = normalQuitResults.isEmpty ? true : normalQuitResults.removeFirst()
        if result { running = false }
        return result
    }

    func forceQuit(_ app: OfficialAppInfo, userApproved: Bool) throws {
        guard userApproved else { throw SwitcherError.forceQuitApprovalRequired }
        running = false
    }

    func launch(_ app: OfficialAppInfo) async throws {
        launchCount += 1
        guard !failedLaunchCalls.contains(launchCount) else {
            running = false
            throw FakeCoordinatorError.launchFailed
        }
        try onLaunch?(launchCount)
        running = true
    }
}
