import AppKit
import CodexAccountSwitcherCore
import Foundation

@MainActor
final class ClaudeDashboardModel: ObservableObject {
    @Published var report: ClaudeDesktopReport?
    @Published var lastCarryOver: ClaudeCarryOverRecord?
    @Published var statusMessage = "Claude 데스크톱 확인 대기 중"
    @Published var isBusy = false
    @Published var isRunning = false
    /// 다른 계정 목록별 가져오기 계획. 키는 `ClaudeAccountPartition.id`.
    @Published var plans: [String: ClaudeCarryOverPlan] = [:]
    /// 조직별 한도 추정. 키는 조직 UUID.
    @Published var quotaEstimates: [String: ClaudeQuotaEstimate] = [:]

    let paths = ClaudeDesktopPaths()

    func refresh() async {
        let paths = paths
        let (report, plans, estimates) = await Task.detached(priority: .userInitiated) {
            let report = ClaudeDesktopInspector(paths: paths).inspect()
            let estimates = ClaudeQuotaHistory(paths: paths).estimates()
            var plans: [String: ClaudeCarryOverPlan] = [:]
            if let target = report.currentPartition {
                let carryOver = ClaudeSessionCarryOver(paths: paths)
                for source in report.otherPartitions {
                    plans[source.id] = carryOver.plan(from: source, to: target)
                }
            }
            return (report, plans, estimates)
        }.value
        self.report = report
        self.plans = plans
        quotaEstimates = estimates
        lastCarryOver = ClaudeSessionCarryOver(paths: paths).latestUndoableRecord()
        isRunning = report.app.map { OfficialAppController().isRunning($0) } ?? false
        if !isBusy {
            statusMessage = summary(of: report)
        }
    }

    /// 팝오버가 열려 있는 동안만 로컬 파일을 다시 읽는다. 네트워크 요청은 하지 않는다.
    func runAutomaticRefresh() async {
        await refresh()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            if !isBusy { await refresh() }
        }
    }

    func openClaude() {
        Task {
            guard let app = report?.app else {
                statusMessage = "Claude 앱을 찾지 못했습니다"
                return
            }
            do {
                try await OfficialAppController().open(app)
            } catch {
                statusMessage = Redactor.redact(error.localizedDescription)
            }
        }
    }

    func editNickname(accountUUID: String, organizationUUID: String) {
        let partition = report?.partitions.first { $0.accountUUID == accountUUID }
        let masked = partition?.label?.maskedEmail ?? "계정 \(accountUUID.prefix(8))…"
        guard let nickname = NicknamePrompt.ask(
            title: "Claude 계정 별명",
            detail: "\(masked)\(partition?.label?.planName.map { " · \($0)" } ?? "")\n비워 두고 저장하면 별명을 지웁니다.",
            current: partition?.label?.nickname
        ) else { return }
        do {
            try ClaudeAccountLabelStore(paths: paths).setNickname(nickname, accountUUID: accountUUID, organizationUUID: organizationUUID)
            Task { await refresh() }
        } catch {
            statusMessage = Redactor.redact(error.localizedDescription)
        }
    }

    func guideAccountSwitch() {
        let alert = NSAlert()
        alert.messageText = "Claude 앱에서 계정을 바꿀까요?"
        alert.informativeText = "Claude 데스크톱은 로그인 정보를 앱 내부 암호화 저장소에 보관하므로 스위처가 직접 바꾸지 않습니다. 앱의 계정 메뉴에서 로그아웃한 뒤 원하는 계정으로 로그인하세요.\n\n로그인 후 이 탭에서 이전 계정의 '가져오기'를 누르면 그 계정의 세션을 새 계정 목록에서 이어갈 수 있습니다. 대화 파일과 프로젝트는 삭제되지 않습니다.\n\n본인 소유 계정 사이에서만 사용하세요. 계정 공유와 정지 계정 우회는 Anthropic 약관 위반입니다."
        alert.addButton(withTitle: "Claude 앱 열기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openClaude()
    }

    func requestCarryOver(from source: ClaudeAccountPartition) {
        guard !isBusy, let report else { return }
        guard let target = report.currentPartition else {
            statusMessage = "현재 계정의 세션 목록을 찾지 못했습니다. Claude 앱에서 새 계정으로 세션을 하나 시작한 뒤 새로고침하세요"
            return
        }
        let plan = plans[source.id] ?? ClaudeSessionCarryOver(paths: paths).plan(from: source, to: target)
        guard !plan.filesToCopy.isEmpty else {
            statusMessage = "가져올 세션이 없습니다 · 이미 있음 \(plan.skippedExisting)개 · 대화 파일 없음 \(plan.skippedWithoutTranscript)개"
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(source.displayName)의 세션 \(plan.filesToCopy.count)개를 가져올까요?"
        var details = [
            "현재 계정 \(target.displayName)의 목록에 세션 목록 파일만 복사합니다. 원래 계정의 목록과 대화 파일은 그대로 둡니다.",
            "Claude 앱을 정상 종료한 뒤 복사하고 다시 실행합니다. 진행 중인 Claude 작업은 먼저 마무리하세요."
        ]
        if plan.skippedExisting + plan.skippedWithoutTranscript > 0 {
            details.append("건너뜀: 이미 있음 \(plan.skippedExisting)개 · 대화 파일 없음 \(plan.skippedWithoutTranscript)개")
        }
        details.append("가져온 세션의 첫 요청은 새 계정에 캐시가 없어 사용량이 크게 잡힐 수 있습니다.")
        alert.informativeText = details.joined(separator: "\n\n")
        alert.addButton(withTitle: "종료 후 가져오기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runWithClaudeClosed(progress: "세션 목록 복사 중") { [paths] in
            // 앱이 종료되며 목록을 다시 쓸 수 있으므로 종료 후 상태로 계획을 다시 만든다.
            let fresh = ClaudeDesktopInspector(paths: paths).inspect()
            guard
                let freshSource = fresh.partitions.first(where: { $0.id == source.id }),
                let freshTarget = fresh.currentPartition
            else {
                throw SwitcherError.claudeCarryOverUnavailable("종료 후 계정 목록을 다시 찾지 못했습니다.")
            }
            let carryOver = ClaudeSessionCarryOver(paths: paths)
            let record = try carryOver.perform(
                carryOver.plan(from: freshSource, to: freshTarget),
                claudeIsRunning: false
            )
            return "세션 \(record.copiedFiles.count)개를 가져왔습니다. Claude 앱 사이드바에서 이어가세요"
        }
    }

    func requestUndo() {
        guard !isBusy, let record = lastCarryOver else { return }
        let alert = NSAlert()
        alert.messageText = "마지막 가져오기를 되돌릴까요?"
        alert.informativeText = "가져온 세션 목록 파일 \(record.copiedFiles.count)개 중 가져온 뒤 바뀌지 않은 것만 지웁니다. 새 계정에서 이어서 쓴 세션과 모든 대화 파일은 남겨 둡니다. Claude 앱을 정상 종료한 뒤 진행합니다."
        alert.addButton(withTitle: "종료 후 되돌리기")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runWithClaudeClosed(progress: "가져오기 되돌리는 중") { [paths] in
            let result = try ClaudeSessionCarryOver(paths: paths).undo(record, claudeIsRunning: false)
            return result.keptBecauseModified == 0
                ? "가져온 세션 \(result.removed)개를 목록에서 뺐습니다"
                : "가져온 세션 \(result.removed)개를 뺐고, 이어서 쓴 \(result.keptBecauseModified)개는 남겼습니다"
        }
    }

    private func runWithClaudeClosed(
        progress: String,
        operation: @escaping @Sendable () throws -> String
    ) {
        guard let app = report?.app else {
            statusMessage = "Claude 앱을 찾지 못했습니다"
            return
        }
        isBusy = true
        Task {
            let controller = OfficialAppController()
            let wasRunning = controller.isRunning(app)
            do {
                if wasRunning {
                    statusMessage = "Claude 앱 정상 종료 중"
                    guard await controller.requestNormalQuit(app, timeout: 20) else {
                        throw SwitcherError.claudeCarryOverUnavailable("Claude 앱이 20초 안에 정상 종료되지 않아 아무것도 바꾸지 않았습니다.")
                    }
                }
                statusMessage = progress
                let message = try await Task.detached(priority: .userInitiated) { try operation() }.value
                statusMessage = "Claude 앱 다시 실행 중"
                try await controller.launch(app)
                isBusy = false
                await refresh()
                statusMessage = message
                SecureLogger.info("Claude 세션 목록 작업 완료")
            } catch {
                if wasRunning { try? await controller.launch(app) }
                isBusy = false
                await refresh()
                statusMessage = Redactor.redact(error.localizedDescription)
                SecureLogger.error("Claude 세션 목록 작업 실패: \(statusMessage)")
            }
        }
    }

    private func summary(of report: ClaudeDesktopReport) -> String {
        guard report.app != nil else { return "Claude 앱을 찾지 못했습니다" }
        guard let current = report.currentPartition else {
            return report.currentAccountUUID == nil
                ? "Claude 앱 로그인 계정을 확인하지 못했습니다"
                : "현재 계정의 세션 목록이 아직 없습니다. Claude 앱에서 세션을 하나 시작하세요"
        }
        let importable = plans.values.reduce(0) { $0 + $1.filesToCopy.count }
        return importable == 0
            ? "\(current.displayName) · 세션 \(current.sessionCount)개"
            : "다른 계정에서 이어갈 수 있는 세션 \(importable)개가 있습니다"
    }
}
