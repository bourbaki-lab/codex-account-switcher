import AppKit
import CodexAccountSwitcherCore
import Foundation
import ServiceManagement

enum AccountDisplayMode: Equatable {
    case checking
    case officialHostManaged
    case storedAuthentication
    case switchVerified
}

struct ProfileRateLimitStatus: Equatable, Sendable {
    var account: AccountIdentity
    var rateLimits: AccountRateLimits
    var checkedAt: Date
}

@MainActor
final class AppModel: ObservableObject {
    @Published var environment: EnvironmentReport?
    @Published var profiles: [AccountProfile] = []
    @Published var currentAccount: AccountIdentity?
    @Published var storedAccount: AccountIdentity?
    @Published var accountDisplayMode: AccountDisplayMode = .checking
    @Published var rateLimits: AccountRateLimits?
    @Published var rateLimitFailure: String?
    @Published var rateLimitProfileID: UUID?
    @Published var profileRateLimits: [UUID: ProfileRateLimitStatus] = [:]
    @Published var profileRateLimitFailures: [UUID: String] = [:]
    @Published var lastRateLimitRefreshAt: Date?
    @Published var isRefreshingRateLimits = false
    @Published var usage: AccountUsageSummary?
    @Published var phase: SwitchPhase = .idle
    @Published var statusMessage = "환경 확인 대기 중"
    @Published var isBusy = false
    @Published var continuityRecord: ContinuityTestRecord?
    @Published var lastSnapshotComparison: SnapshotComparison?
    @Published var oneClickSwitchAvailability = OneClickSwitchAvailability.unavailable("환경 확인 중")

    let paths = SwitcherPaths()
    let profileStore: EncryptedProfileStore
    let continuityStore: ContinuityTestStore
    private var didBootstrap = false

    init() {
        profileStore = EncryptedProfileStore(paths: paths)
        continuityStore = ContinuityTestStore(paths: paths)
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refreshAll()
    }

    func refreshAll() async {
        isBusy = true
        phase = .idle
        accountDisplayMode = .checking
        currentAccount = nil
        storedAccount = nil
        rateLimits = nil
        rateLimitFailure = nil
        rateLimitProfileID = nil
        profileRateLimits = [:]
        profileRateLimitFailures = [:]
        lastRateLimitRefreshAt = nil
        usage = nil
        oneClickSwitchAvailability = .unavailable("환경 확인 중")
        statusMessage = "현재 환경 확인 중"
        let report = EnvironmentInspector(paths: paths).inspect()
        environment = report
        do {
            profiles = try await profileStore.loadProfiles()
            continuityRecord = try await continuityStore.load()
            if report.officialAppAuthenticationMode == .hostManaged {
                accountDisplayMode = .officialHostManaged
                statusMessage = "공식 앱은 호스트 관리 인증을 사용 중입니다. auth.json 계정 한도를 확인합니다"
                SecureLogger.info("공식 앱 호스트 관리 인증 감지: auth.json 계정을 현재 계정으로 표시하지 않음")
            } else if let client = appServerClient(from: report) {
                let identity = try await client.readAccount(refreshToken: false)
                storedAccount = identity
                currentAccount = identity
                do {
                    rateLimits = try await client.readRateLimits()
                    rateLimitFailure = rateLimits == nil
                        ? rateLimitUnavailableMessage(for: identity, requestFailed: false)
                        : nil
                } catch {
                    rateLimits = nil
                    rateLimitFailure = rateLimitUnavailableMessage(for: identity, requestFailed: true)
                    SecureLogger.error("account/rateLimits/read 실패: \(Redactor.redact(error.localizedDescription))")
                }
                usage = try? await client.readUsage()
                accountDisplayMode = .storedAuthentication
                if let identity {
                    try await reconcileActiveProfile(using: identity)
                }
                statusMessage = identity == nil ? "로그인이 필요합니다" : "저장된 인증 계정을 확인했습니다"
                if let storedAccount {
                    SecureLogger.info(
                        "account/read 성공 email=\(Redactor.maskEmail(storedAccount.email) ?? "none") plan=\(storedAccount.planType ?? "unknown")"
                    )
                }
                if let primary = rateLimits?.primary {
                    SecureLogger.info("account/rateLimits/read 성공 usedPercent=\(Int(primary.usedPercent))")
                }
            } else {
                accountDisplayMode = .storedAuthentication
                statusMessage = "Codex App Server 실행 파일을 찾지 못했습니다"
            }
            if let binary = binaryURL(from: report) {
                await refreshProfileRateLimits(binaryURL: binary)
                if report.officialAppAuthenticationMode == .hostManaged {
                    await refreshHostManagedRateLimitReference(using: report)
                    statusMessage = rateLimits == nil && profileRateLimits.isEmpty
                        ? "공식 앱 현재 계정과 사용량은 공식 앱에서 확인하세요"
                        : "공식 앱 현재 계정은 앱에서 확인하세요. auth.json 및 저장 프로필 한도를 새로고침했습니다"
                }
                lastRateLimitRefreshAt = Date()
            }
        } catch {
            accountDisplayMode = report.officialAppAuthenticationMode == .hostManaged
                ? .officialHostManaged
                : .storedAuthentication
            statusMessage = Redactor.redact(error.localizedDescription)
            SecureLogger.error(statusMessage)
        }
        oneClickSwitchAvailability = AccountSwitchPreflightPolicy.evaluate(
            credentialsStoreSetting: report.credentialsStoreSetting,
            authFileExists: report.authFileExists,
            officialAppAuthenticationMode: report.officialAppAuthenticationMode,
            runtimeIdentityAvailable: storedAccount != nil
        )
        isBusy = false
    }

    /// Keeps the visible quota values fresh without repeating the heavier
    /// environment inspection. SwiftUI cancels this task when the popover
    /// content disappears, and starts it again on the next open.
    func editNickname(_ profile: AccountProfile) {
        guard let nickname = NicknamePrompt.ask(
            title: "Codex 프로필 별명",
            detail: "\(profile.maskedEmail ?? "이메일 없음")\(profile.planType.map { " · \($0.capitalized)" } ?? "")",
            current: profile.displayName
        ), !nickname.isEmpty, nickname != profile.displayName else { return }
        Task {
            do {
                try await profileStore.rename(profile.id, to: nickname)
                profiles = try await profileStore.loadProfiles()
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    func runAutomaticRateLimitRefresh() async {
        await bootstrap()
        await refreshRateLimits()

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            await refreshRateLimits()
        }
    }

    func refreshRateLimits() async {
        guard
            !isBusy,
            !isRefreshingRateLimits,
            let report = environment,
            let binary = binaryURL(from: report)
        else { return }

        isRefreshingRateLimits = true
        defer { isRefreshingRateLimits = false }

        await refreshProfileRateLimits(binaryURL: binary)
        if report.officialAppAuthenticationMode == .hostManaged {
            await refreshHostManagedRateLimitReference(using: report)
        } else {
            await refreshStoredAuthenticationRateLimitReference(using: report)
        }
        lastRateLimitRefreshAt = Date()
        SecureLogger.info("Codex 한도 자동 새로고침 완료")
    }

    func captureCurrentAccount() {
        Task {
            guard let identity = storedAccount else {
                statusMessage = "먼저 저장된 인증을 새로고침하세요"
                return
            }
            isBusy = true
            do {
                let data = try Data(contentsOf: paths.authFile, options: .mappedIfSafe)
                try AuthCacheValidator.validate(data)
                let matchingProfile: AccountProfile?
                if let email = identity.email {
                    matchingProfile = try await profileStore.profile(matchingAccountEmail: email)
                } else {
                    matchingProfile = nil
                }
                let profile = AccountProfile(
                    id: matchingProfile?.id ?? UUID(),
                    displayName: matchingProfile?.displayName
                        ?? "\((identity.planType ?? "ChatGPT").capitalized) Account \(profiles.count + 1)",
                    maskedEmail: Redactor.maskEmail(identity.email),
                    planType: identity.planType,
                    createdAt: matchingProfile?.createdAt ?? Date(),
                    lastValidatedAt: Date(),
                    isActive: true
                )
                _ = try await profileStore.save(
                    profile: profile,
                    secret: ProfileSecret(authCache: data, accountEmail: identity.email, planType: identity.planType)
                )
                try await profileStore.markActive(profile.id, identity: identity)
                profiles = try await profileStore.loadProfiles()
                if let report = environment, let binary = binaryURL(from: report) {
                    await refreshProfileRateLimits(binaryURL: binary)
                    if report.officialAppAuthenticationMode == .hostManaged {
                        await refreshHostManagedRateLimitReference(using: report)
                    }
                }
                statusMessage = matchingProfile == nil
                    ? "auth.json의 저장 계정을 암호화해 등록했습니다"
                    : "auth.json에 저장된 인증을 갱신했습니다"
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
            isBusy = false
        }
    }

    func addAccount(flow: LoginFlow = .browser, replacing profile: AccountProfile? = nil) {
        Task {
            guard let report = environment, let binary = binaryURL(from: report) else {
                statusMessage = "Codex App Server 실행 파일을 찾지 못했습니다"
                return
            }
            isBusy = true
            statusMessage = profile == nil ? "공식 ChatGPT 로그인 준비 중" : "교체할 계정 로그인 준비 중"
            do {
                let registration = AccountRegistrationService(binaryURL: binary, profileStore: profileStore)
                let registeredProfile = try await registration.register(flow: flow, replacing: profile) { challenge in
                    await MainActor.run {
                        if let code = challenge.userCode {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        return NSWorkspace.shared.open(challenge.verificationURL)
                    }
                }
                profiles = try await profileStore.loadProfiles()
                if let currentAccount, accountDisplayMode != .officialHostManaged {
                    try await reconcileActiveProfile(using: currentAccount)
                }
                if let profile {
                    let remainsActive = profiles.first(where: { $0.id == registeredProfile.id })?.isActive == true
                    statusMessage = remainsActive
                        ? "\(profile.displayName)의 저장된 인증을 갱신했습니다"
                        : "\(profile.displayName)의 저장 계정을 변경했습니다. 적용하려면 전환을 누르세요"
                } else {
                    statusMessage = flow == .browser
                        ? "계정을 암호화해 등록하거나 기존 인증을 갱신했습니다"
                        : "계정을 등록하거나 갱신했습니다. Device Code는 클립보드에 복사했습니다"
                }
                await refreshProfileRateLimits(binaryURL: binary)
                if report.officialAppAuthenticationMode == .hostManaged {
                    await refreshHostManagedRateLimitReference(using: report)
                }
                SecureLogger.info(profile == nil ? "공식 로그인 프로필 등록 성공" : "공식 로그인 프로필 교체 성공")
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
                SecureLogger.error(statusMessage)
            }
            isBusy = false
        }
    }

    func requestAccountChange(_ profile: AccountProfile, flow: LoginFlow) {
        let alert = NSAlert()
        alert.messageText = "\(profile.displayName)의 저장 계정을 변경할까요?"
        alert.informativeText = "공식 로그인으로 새 인증을 받은 뒤 이 프로필의 암호화된 인증만 교체합니다. 현재 사용 중인 계정은 즉시 바뀌지 않으며, 완료 후 전환 버튼을 눌러 적용합니다."
        alert.addButton(withTitle: "계정 변경")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        addAccount(flow: flow, replacing: profile)
    }

    func requestSwitch(to profile: AccountProfile) {
        guard !isBusy else {
            statusMessage = "다른 작업이 끝난 뒤 다시 전환하세요"
            return
        }
        guard oneClickSwitchAvailability.isAvailable else {
            statusMessage = SwitcherError.oneClickSwitchUnavailable(
                oneClickSwitchAvailability.reason ?? "인증 저장 방식을 확인할 수 없습니다."
            ).localizedDescription
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(profile.displayName) 계정으로 전환할까요?"
        var explanation = "공식 ChatGPT/Codex 앱을 정상 종료한 뒤 인증 캐시만 교체하고 다시 실행합니다. 별도 Codex CLI가 열려 있으면 종료 승인을 한 번 더 요청합니다."
        if let warning = oneClickSwitchAvailability.warning {
            explanation += "\n\n주의: \(warning)"
        }
        alert.informativeText = explanation
        alert.addButton(withTitle: "전환")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performSwitch(to: profile, forceQuitApproved: false, closeConflictingProcessesApproved: false)
    }

    func openOfficialApp() {
        Task {
            guard let app = environment?.officialApp else {
                statusMessage = SwitcherError.officialAppNotFound.localizedDescription
                return
            }
            do {
                try await OfficialAppController().open(app)
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    func guidedSwitch(to targetProfile: AccountProfile? = nil) {
        let alert = NSAlert()
        alert.messageText = targetProfile.map { "\($0.displayName) 계정으로 공식 로그인할까요?" }
            ?? "공식 로그인으로 계정을 바꿀까요?"
        let targetHint = targetProfile?.maskedEmail.map { " 대상 계정: \($0)." } ?? ""
        alert.informativeText = "공식 앱의 로그아웃 메뉴를 실행한 뒤 로그인 화면을 엽니다.\(targetHint) 원하는 계정의 로그인은 공식 앱에서 직접 완료해야 하며 로컬 task와 프로젝트 파일은 삭제하지 않습니다."
        alert.addButton(withTitle: "로그아웃 후 로그인")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            guard let report = environment, let app = report.officialApp else {
                statusMessage = "공식 앱을 찾지 못했습니다"
                return
            }
            isBusy = true
            var madeBackup = false
            do {
                if report.officialAppAuthenticationMode == .hostManaged {
                    let appController = OfficialAppController()
                    try await appController.open(app)
                    try await OfficialAppAccountController().requestLogout(app)
                    currentAccount = nil
                    storedAccount = nil
                    rateLimits = nil
                    rateLimitFailure = nil
                    rateLimitProfileID = nil
                    usage = nil
                    accountDisplayMode = .officialHostManaged
                    statusMessage = targetProfile.map {
                        "공식 앱에서 \($0.maskedEmail ?? $0.displayName) 계정으로 로그인하세요"
                    } ?? "공식 앱에서 원하는 계정으로 로그인하세요"
                    SecureLogger.info("공식 앱 로그아웃 메뉴 실행 완료")
                    isBusy = false
                    return
                }
                guard let client = appServerClient(from: report) else {
                    throw SwitcherError.appServer("Codex App Server 실행 파일을 찾지 못했습니다")
                }
                let blockers = try CodexProcessScanner().scan(officialAppPath: app.path)
                    .filter(\.blocksSwitch)
                    .map(\.safeDescription)
                guard blockers.isEmpty else { throw SwitcherError.activeProcessConflict(blockers) }
                if FileManager.default.fileExists(atPath: paths.authFile.path) {
                    let auth = try Data(contentsOf: paths.authFile, options: .mappedIfSafe)
                    try RecoveryStore(paths: paths).createBackup(from: auth)
                    madeBackup = true
                }
                let controller = OfficialAppController()
                guard await controller.requestNormalQuit(app) else {
                    throw SwitcherError.officialAppQuitTimedOut
                }
                try await client.logout()
                try await controller.launch(app)
                currentAccount = nil
                storedAccount = nil
                accountDisplayMode = .officialHostManaged
                rateLimits = nil
                rateLimitFailure = nil
                rateLimitProfileID = nil
                statusMessage = "공식 앱에서 원하는 계정으로 직접 로그인한 뒤 새로고침하세요"
            } catch {
                if madeBackup {
                    try? RecoveryStore(paths: paths).restoreLatest()
                    try? await OfficialAppController().launch(app)
                }
                statusMessage = Redactor.redact(error.localizedDescription)
            }
            isBusy = false
        }
    }

    func emergencyRestore() {
        let alert = NSAlert()
        alert.messageText = "마지막 인증 백업을 복원할까요?"
        alert.informativeText = "공식 앱을 종료하고 암호화된 긴급복구 백업을 되돌린 뒤 앱을 다시 실행합니다."
        alert.addButton(withTitle: "복원")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            guard
                let report = environment,
                let app = report.officialApp,
                let client = appServerClient(from: report)
            else {
                statusMessage = "복구에 필요한 공식 앱 정보를 찾지 못했습니다"
                return
            }
            isBusy = true
            do {
                let coordinator = AccountSwitchCoordinator(
                    paths: paths,
                    officialApp: app,
                    profileStore: profileStore,
                    accountProbe: client
                )
                try await coordinator.emergencyRestore()
                statusMessage = "마지막 인증 백업을 복원했습니다"
                await refreshAll()
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
            isBusy = false
        }
    }

    func beginContinuityTest() {
        Task {
            do {
                let activeID = profiles.first(where: \.isActive)?.id
                let record = try await continuityStore.begin(
                    sourceProfileID: activeID,
                    sourceAccount: currentAccount?.email
                )
                continuityRecord = record
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.marker, forType: .string)
                statusMessage = "마커를 복사했습니다. 공식 앱의 테스트 대화에 붙여넣은 뒤 '마커 찾기'를 누르세요"
                openOfficialApp()
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    func locateContinuityMarker() {
        Task {
            guard let record = continuityRecord else { return }
            isBusy = true
            do {
                guard let match = try SessionMarkerFinder(codexHome: paths.codexHome).find(marker: record.marker) else {
                    throw SwitcherError.markerNotFound
                }
                continuityRecord = try await continuityStore.recordMarkerMatch(match)
                statusMessage = "기존 세션을 찾았습니다. 대상 계정으로 전환하고 같은 대화에서 후속 질문을 실행하세요"
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
            isBusy = false
        }
    }

    func finishContinuityTest(_ verdict: ContinuityVerdict) {
        Task {
            do {
                continuityRecord = try await continuityStore.finish(
                    verdict: verdict,
                    targetProfileID: profiles.first(where: \.isActive)?.id,
                    targetAccount: currentAccount?.email,
                    followUpSucceeded: verdict == .pass,
                    notes: verdict == .pass ? "동일 세션에서 실제 후속 요청 성공을 사용자가 확인함" : nil
                )
                statusMessage = "Session Continuity 판정을 \(verdict.rawValue)로 기록했습니다"
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    func openBundledDocument(_ name: String) {
        let candidates = [
            Bundle.main.resourceURL?.appending(path: "Documentation/\(name)"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "docs/\(name)")
        ].compactMap { $0 }
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            statusMessage = "문서를 찾지 못했습니다: \(name)"
            return
        }
        NSWorkspace.shared.open(file)
    }

    func deleteProfile(_ profile: AccountProfile) {
        Task {
            do {
                try await profileStore.delete(profile.id)
                profiles = try await profileStore.loadProfiles()
                profileRateLimits[profile.id] = nil
                profileRateLimitFailures[profile.id] = nil
                if rateLimitProfileID == profile.id {
                    rateLimitProfileID = nil
                    rateLimits = nil
                    rateLimitFailure = nil
                }
                statusMessage = "프로필을 삭제했습니다"
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    private func performSwitch(
        to profile: AccountProfile,
        forceQuitApproved: Bool,
        closeConflictingProcessesApproved: Bool
    ) {
        guard !isBusy else {
            statusMessage = "다른 작업이 끝난 뒤 다시 전환하세요"
            return
        }
        isBusy = true
        Task {
            if isRefreshingRateLimits {
                statusMessage = "한도 갱신 완료 후 계정 전환을 시작합니다"
            }
            while isRefreshingRateLimits && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard
                let report = environment,
                let app = report.officialApp,
                let client = appServerClient(from: report)
            else {
                statusMessage = "공식 앱 또는 App Server를 찾지 못했습니다"
                isBusy = false
                return
            }
            do {
                let coordinator = AccountSwitchCoordinator(
                    paths: paths,
                    officialApp: app,
                    profileStore: profileStore,
                    accountProbe: client
                )
                let result = try await coordinator.switchAccount(
                    to: profile.id,
                    forceQuitApproved: forceQuitApproved,
                    closeConflictingProcessesApproved: closeConflictingProcessesApproved
                ) { [weak self] phase in
                    self?.phase = phase
                    self?.statusMessage = phase.koreanDescription
                    SecureLogger.info("계정 전환 단계=\(phase.rawValue)")
                }
                currentAccount = result.account
                storedAccount = result.account
                accountDisplayMode = .switchVerified
                rateLimits = result.rateLimits
                rateLimitFailure = result.rateLimits == nil
                    ? rateLimitUnavailableMessage(for: result.account, requestFailed: false)
                    : nil
                rateLimitProfileID = profile.id
                if let limits = result.rateLimits {
                    profileRateLimits[profile.id] = ProfileRateLimitStatus(
                        account: result.account,
                        rateLimits: limits,
                        checkedAt: Date()
                    )
                }
                lastSnapshotComparison = result.snapshotChanges
                profiles = try await profileStore.loadProfiles()
                oneClickSwitchAvailability = AccountSwitchPreflightPolicy.evaluate(
                    credentialsStoreSetting: report.credentialsStoreSetting,
                    authFileExists: true,
                    officialAppAuthenticationMode: report.officialAppAuthenticationMode,
                    runtimeIdentityAvailable: true
                )
                statusMessage = result.snapshotChanges.modified.isEmpty
                    ? "계정 전환 및 세션 보호 확인 완료"
                    : "계정은 전환됐고 보호 파일 변경 \(result.snapshotChanges.modified.count)건을 기록했습니다"
            } catch SwitcherError.forceQuitApprovalRequired {
                isBusy = false
                phase = .idle
                let alert = NSAlert()
                alert.messageText = "공식 앱이 정상 종료되지 않았습니다"
                alert.informativeText = "저장되지 않은 작업이 손실될 수 있습니다. 강제 종료 후 전환을 계속할까요?"
                alert.addButton(withTitle: "강제 종료 후 계속")
                alert.addButton(withTitle: "취소")
                if alert.runModal() == .alertFirstButtonReturn {
                    performSwitch(
                        to: profile,
                        forceQuitApproved: true,
                        closeConflictingProcessesApproved: closeConflictingProcessesApproved
                    )
                } else {
                    statusMessage = "계정 전환을 취소했습니다"
                }
                return
            } catch SwitcherError.activeProcessConflict(let blockers) {
                isBusy = false
                phase = .idle
                guard !closeConflictingProcessesApproved else {
                    statusMessage = SwitcherError.activeProcessConflict(blockers).localizedDescription
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Codex CLI 세션 \(blockers.count)개를 종료할까요?"
                alert.informativeText = "열린 CLI 작업은 중단될 수 있습니다. 먼저 Ctrl+C 방식으로 중단을 요청하고, 남아 있으면 정상 종료한 뒤 계정 전환을 계속합니다. 강제 종료는 하지 않습니다.\n\n\(blockers.joined(separator: ", "))"
                alert.addButton(withTitle: "CLI 종료 후 전환")
                alert.addButton(withTitle: "취소")
                if alert.runModal() == .alertFirstButtonReturn {
                    performSwitch(
                        to: profile,
                        forceQuitApproved: forceQuitApproved,
                        closeConflictingProcessesApproved: true
                    )
                } else {
                    statusMessage = "CLI 세션을 유지하고 계정 전환을 취소했습니다"
                }
                return
            } catch SwitcherError.oneClickSwitchUnavailable(let reason) {
                phase = .idle
                oneClickSwitchAvailability = .unavailable(reason)
                statusMessage = SwitcherError.oneClickSwitchUnavailable(reason).localizedDescription
                SecureLogger.error(statusMessage)
            } catch SwitcherError.accountVerificationFailed(let reason) {
                phase = .idle
                isBusy = false
                let safeReason = Redactor.redact(reason)
                statusMessage = "\(profile.displayName) 적용 검증 실패: \(safeReason). 이전 계정으로 복구했습니다"
                SecureLogger.error("계정 검증 실패: \(safeReason)")
                let alert = NSAlert()
                alert.messageText = "\(profile.displayName)의 저장 인증을 갱신할까요?"
                alert.informativeText = "전환은 취소되고 이전 계정으로 복구됐습니다. Device Code로 이 프로필의 인증을 다시 받은 뒤 재시도할 수 있습니다."
                alert.addButton(withTitle: "Device Code로 갱신")
                alert.addButton(withTitle: "닫기")
                if alert.runModal() == .alertFirstButtonReturn {
                    addAccount(flow: .deviceCode, replacing: profile)
                }
                return
            } catch {
                phase = .idle
                statusMessage = Redactor.redact(error.localizedDescription)
                SecureLogger.error(statusMessage)
            }
            isBusy = false
        }
    }

    private func reconcileActiveProfile(using identity: AccountIdentity) async throws {
        guard let email = identity.email else { return }
        for profile in profiles {
            if let secret = try? await profileStore.secret(for: profile.id),
               let stored = secret.accountEmail,
               stored.caseInsensitiveCompare(email) == .orderedSame {
                try await profileStore.markActive(profile.id, identity: identity)
                profiles = try await profileStore.loadProfiles()
                return
            }
        }
    }

    private func refreshProfileRateLimits(binaryURL: URL) async {
        let targetProfiles = profiles
        let store = profileStore
        let outcomes = await withTaskGroup(
            of: (UUID, ProfileRateLimitProbeResult?, String?).self,
            returning: [(UUID, ProfileRateLimitProbeResult?, String?)].self
        ) { group in
            for profile in targetProfiles {
                group.addTask {
                    do {
                        let secret = try await store.secret(for: profile.id)
                        let result = try await ProfileRateLimitProbe(binaryURL: binaryURL).read(secret: secret)
                        try await store.updateCachedAuthentication(
                            profileID: profile.id,
                            authCache: result.refreshedAuthCache,
                            identity: result.account
                        )
                        return (profile.id, result, nil)
                    } catch {
                        return (profile.id, nil, Redactor.redact(error.localizedDescription))
                    }
                }
            }

            var collected: [(UUID, ProfileRateLimitProbeResult?, String?)] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        var refreshed: [UUID: ProfileRateLimitStatus] = [:]
        var failures: [UUID: String] = [:]
        for (profileID, result, errorMessage) in outcomes {
            if let result, let limits = result.rateLimits {
                refreshed[profileID] = ProfileRateLimitStatus(
                    account: result.account,
                    rateLimits: limits,
                    checkedAt: result.checkedAt
                )
            } else if let result {
                let requestFailed = result.rateLimitErrorDescription != nil
                failures[profileID] = rateLimitUnavailableMessage(
                    for: result.account,
                    requestFailed: requestFailed
                )
                if let rateLimitError = result.rateLimitErrorDescription {
                    SecureLogger.error("저장 프로필 한도 응답 실패 id=\(profileID.uuidString) error=\(rateLimitError)")
                }
            } else if let errorMessage {
                failures[profileID] = "인증 갱신 필요"
                SecureLogger.error("저장 프로필 한도 조회 실패 id=\(profileID.uuidString) error=\(errorMessage)")
            }
        }
        profileRateLimits = refreshed
        profileRateLimitFailures = failures
        if let reloaded = try? await profileStore.loadProfiles() {
            profiles = reloaded
        }
    }

    private func refreshHostManagedRateLimitReference(using report: EnvironmentReport) async {
        await refreshAuthenticationFileRateLimitReference(using: report, updatesCurrentAccount: false)
    }

    private func refreshStoredAuthenticationRateLimitReference(using report: EnvironmentReport) async {
        await refreshAuthenticationFileRateLimitReference(using: report, updatesCurrentAccount: true)
    }

    private func refreshAuthenticationFileRateLimitReference(
        using report: EnvironmentReport,
        updatesCurrentAccount: Bool
    ) async {
        guard let client = appServerClient(from: report) else {
            return
        }

        let account: AccountIdentity
        let authenticationFileLimits: AccountRateLimits?
        do {
            guard let refreshedAccount = try await client.readAccount(refreshToken: false) else {
                return
            }
            account = refreshedAccount
            authenticationFileLimits = try await client.readRateLimits()
        } catch {
            rateLimitFailure = rateLimitUnavailableMessage(for: storedAccount, requestFailed: true)
            SecureLogger.error("auth.json 계정 한도 새로고침 실패: \(Redactor.redact(error.localizedDescription))")
            return
        }

        storedAccount = account
        if updatesCurrentAccount {
            currentAccount = account
        }
        rateLimits = authenticationFileLimits
        rateLimitFailure = authenticationFileLimits == nil
            ? rateLimitUnavailableMessage(for: account, requestFailed: false)
            : nil
        rateLimitProfileID = nil

        guard
            let authenticationFileLimits,
            let email = account.email,
            let profile = try? await profileStore.profile(matchingAccountEmail: email)
        else { return }

        rateLimitProfileID = profile.id
        profileRateLimits[profile.id] = ProfileRateLimitStatus(
            account: account,
            rateLimits: authenticationFileLimits,
            checkedAt: Date()
        )
        profileRateLimitFailures[profile.id] = nil
        SecureLogger.info("auth.json 계정 한도 조회 성공 profile=\(profile.id.uuidString)")
    }

    private func rateLimitUnavailableMessage(
        for account: AccountIdentity?,
        requestFailed: Bool
    ) -> String {
        switch account?.type.lowercased() {
        case "apikey", "amazonbedrock":
            return "ChatGPT 한도 조회 대상이 아닌 인증입니다"
        default:
            return requestFailed
                ? "한도 조회 실패 · 30초 후 자동 재시도"
                : "서버가 이 계정의 한도 정보를 제공하지 않았습니다"
        }
    }

    private func binaryURL(from report: EnvironmentReport) -> URL? {
        if let bundled = report.officialApp?.bundledCodexPath {
            return URL(fileURLWithPath: bundled)
        }
        if let cli = report.codexCLIPath {
            return URL(fileURLWithPath: cli)
        }
        return nil
    }

    private func appServerClient(from report: EnvironmentReport) -> CodexAppServerClient? {
        binaryURL(from: report).map { CodexAppServerClient(binaryURL: $0, codexHome: paths.codexHome) }
    }
}

extension SwitchPhase {
    var koreanDescription: String {
        switch self {
        case .idle: "대기 중"
        case .checkingProcesses: "실행 중인 Codex 작업 확인 중"
        case .closingConflictingProcesses: "승인된 Codex CLI 정상 종료 중"
        case .checkingAuthenticationSource: "인증 저장 방식 확인 중"
        case .snapshottingSessions: "세션 보호 스냅샷 생성 중"
        case .savingCurrentAccount: "현재 계정 저장 중"
        case .quittingOfficialApp: "공식 앱 종료 중"
        case .backingUpAuthentication: "긴급복구 백업 생성 중"
        case .replacingAuthentication: "인증 교체 중"
        case .validatingAccount: "새 계정 검증 중"
        case .verifyingAuthenticationIsolation: "인증 외 보호 상태 불변 확인 중"
        case .relaunchingOfficialApp: "공식 앱 재실행 중"
        case .verifyingSessionProtection: "세션 보호 상태 확인 중"
        case .rollingBack: "이전 인증으로 자동 롤백 중"
        case .completed: "완료"
        }
    }
}
