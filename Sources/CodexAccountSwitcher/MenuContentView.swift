import AppKit
import CodexAccountSwitcherCore
import SwiftUI

enum DashboardTab: String {
    case codex
    case claude
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var claude: ClaudeDashboardModel
    @AppStorage("dashboardTab") private var tab: DashboardTab = .codex

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("대시보드", selection: $tab) {
                Text("Codex").tag(DashboardTab.codex)
                Text("Claude").tag(DashboardTab.claude)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
            switch tab {
            case .codex:
                codexContent
            case .claude:
                ClaudeContentView(model: claude)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .task { await model.runAutomaticRateLimitRefresh() }
        .task(id: tab) {
            if tab == .claude { await claude.runAutomaticRefresh() }
        }
    }

    @ViewBuilder
    private var codexContent: some View {
        currentAccount
        usage
        Divider()
        profiles
        controls
        Divider()
        continuity
        status
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(tab == .claude ? .orange : .blue)
            VStack(alignment: .leading) {
                Text("Codex Account Switcher").font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isBusy || claude.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var headerSubtitle: String {
        switch tab {
        case .codex:
            model.environment?.officialApp.map { "공식 앱 \($0.shortVersion ?? "버전 미확인")" } ?? "공식 앱 확인 중"
        case .claude:
            claude.report.map { report in
                report.app.map { "Claude 앱 \($0.shortVersion ?? "버전 미확인")" } ?? "Claude 앱 없음"
            } ?? "Claude 앱 확인 중"
        }
    }

    private var currentAccount: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentAccountTitle).font(.caption).foregroundStyle(.secondary)
            if model.accountDisplayMode == .officialHostManaged {
                HStack {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.orange)
                    Text("공식 앱 내부 계정")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("앱에서 확인")
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Text("호스트 관리 인증 사용 중 · auth.json 계정을 현재 계정으로 표시하지 않음")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let account = model.currentAccount {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(Redactor.maskEmail(account.email) ?? "이메일 없음").fontWeight(.semibold)
                    Spacer()
                    Text(account.planType?.capitalized ?? account.type)
                        .font(.caption)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
            } else if model.accountDisplayMode == .checking {
                Label("계정 정보 확인 중", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                Label("인증된 ChatGPT 계정 없음", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var currentAccountTitle: String {
        switch model.accountDisplayMode {
        case .checking:
            "계정 정보"
        case .officialHostManaged:
            "공식 앱 현재 계정"
        case .storedAuthentication:
            "저장된 인증 계정"
        case .switchVerified:
            "방금 전환한 계정"
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("Codex 남은 한도")
                Spacer()
                if model.isRefreshingRateLimits {
                    ProgressView().controlSize(.mini)
                    Text("갱신 중")
                } else if let refreshedAt = model.lastRateLimitRefreshAt {
                    Text("30초 자동 · \(refreshedAt.formatted(date: .omitted, time: .standard))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let limits = model.rateLimits {
                if model.environment?.officialAppAuthenticationMode == .hostManaged {
                    Text(usageReferenceText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let primary = limits.primary {
                    rateLimitWindow(primary, fallbackName: "단기")
                }
                if let secondary = limits.secondary {
                    rateLimitWindow(secondary, fallbackName: "장기")
                }
                if limits.primary == nil, limits.secondary == nil {
                    Text("서버가 한도 사용률은 제공하지 않았습니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let resetCredits = limits.resetCredits {
                    Label(resetCreditSummary(resetCredits), systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.purple)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if model.accountDisplayMode == .officialHostManaged,
                      !model.profileRateLimits.isEmpty {
                Text("auth.json 계정 한도는 없으며 아래에 저장 프로필별 한도를 표시합니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.rateLimitFailure ?? "남은 한도 정보 없음")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var usageReferenceText: String {
        guard
            let profileID = model.rateLimitProfileID,
            let profile = model.profiles.first(where: { $0.id == profileID })
        else {
            return "auth.json 인증 기준 · 공식 앱 현재 계정과 다를 수 있음"
        }
        return "\(profile.displayName) auth.json 인증 기준 · 공식 앱 현재 계정과 다를 수 있음"
    }

    private func rateLimitWindow(_ window: RateLimitWindow, fallbackName: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: window.remainingPercent, total: 100)
            HStack {
                Text("\(windowName(window, fallback: fallbackName)) \(window.remainingPercent, specifier: "%.0f")% 남음")
                Spacer()
                if let reset = window.resetsAt {
                    Text("\(quotaDate(reset)) 초기화")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("등록된 계정").font(.caption).foregroundStyle(.secondary)
            if !model.oneClickSwitchAvailability.isAvailable,
               model.oneClickSwitchAvailability.reason != "환경 확인 중",
               let reason = model.oneClickSwitchAvailability.reason {
                Label(reason, systemImage: "exclamationmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.profiles.isEmpty {
                Text("등록된 프로필이 없습니다").font(.caption).foregroundStyle(.secondary)
            } else if model.profiles.count <= 3 {
                profileRows
            } else {
                ScrollView {
                    profileRows
                }
                .frame(height: 190)
            }
        }
    }

    private var profileRows: some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(model.profiles) { profile in
                profileRow(profile)
            }
        }
    }

    private func profileRow(_ profile: AccountProfile) -> some View {
        let isVerifiedActive = profile.isActive && model.accountDisplayMode != .officialHostManaged
        return HStack {
            Image(systemName: isVerifiedActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isVerifiedActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName)
                Text([profile.planType?.capitalized, profile.maskedEmail].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if profile.isActive && model.accountDisplayMode == .officialHostManaged {
                    Text("스위처의 마지막 전환 기록 · 현재 여부 미확인")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let summary = profileRateLimitSummary(profile) {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let failure = model.profileRateLimitFailures[profile.id] {
                    Text(failure)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if !isVerifiedActive {
                if model.oneClickSwitchAvailability.isAvailable {
                    Button("전환") { model.requestSwitch(to: profile) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isBusy || model.isRefreshingRateLimits)
                } else {
                    Text("원클릭 불가")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                        .help(model.oneClickSwitchAvailability.reason ?? "원클릭 전환을 사용할 수 없습니다")
                }
            }
            Menu {
                Button("브라우저로 계정 변경") { model.requestAccountChange(profile, flow: .browser) }
                Button("Device Code로 계정 변경") { model.requestAccountChange(profile, flow: .deviceCode) }
                Divider()
                Button("프로필 삭제", role: .destructive) { model.deleteProfile(profile) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.isBusy || model.isRefreshingRateLimits)
        }
    }

    private func profileRateLimitSummary(_ profile: AccountProfile) -> String? {
        guard let limits = model.profileRateLimits[profile.id]?.rateLimits else { return nil }
        var lines = [
            limits.primary.map { compactWindow($0, fallback: "단기") },
            limits.secondary.map { compactWindow($0, fallback: "장기") }
        ].compactMap { $0 }
        if let resetCredits = limits.resetCredits {
            lines.append(resetCreditSummary(resetCredits))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func compactWindow(_ window: RateLimitWindow, fallback: String) -> String {
        var summary = "\(windowName(window, fallback: fallback)) \(Int(window.remainingPercent.rounded()))% 남음"
        if let reset = window.resetsAt {
            summary += " · \(quotaDate(reset)) 초기화"
        }
        return summary
    }

    private func windowName(_ window: RateLimitWindow, fallback: String) -> String {
        guard let minutes = window.windowDurationMinutes, minutes > 0 else {
            return "\(fallback) 한도"
        }
        if minutes.isMultiple(of: 10_080) {
            let weeks = minutes / 10_080
            return weeks == 1 ? "주간 한도" : "\(weeks)주 한도"
        }
        if minutes.isMultiple(of: 1_440) {
            return "\(minutes / 1_440)일 한도"
        }
        if minutes.isMultiple(of: 60) {
            return "\(minutes / 60)시간 한도"
        }
        return "\(minutes)분 한도"
    }

    private func resetCreditSummary(_ resetCredits: RateLimitResetCredits) -> String {
        let count = resetCredits.availableCount
        guard count > 0 else { return "초기화권 0장" }
        guard let expiration = resetCredits.earliestAvailableExpiration else {
            return "초기화권 \(count)장 · 사용기한 미제공"
        }
        let expirationLabel = count == 1 ? "사용기한" : "가장 빠른 사용기한"
        return "초기화권 \(count)장 · \(expirationLabel) \(quotaDate(expiration))"
    }

    private func quotaDate(_ date: Date) -> String {
        date.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
    }

    private var controls: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Button("저장 인증 등록") { model.captureCurrentAccount() }
                    .disabled(model.isBusy || model.storedAccount == nil)
                    .help("~/.codex/auth.json에 저장된 계정을 등록합니다. 공식 앱의 호스트 관리 계정과 다를 수 있습니다.")
                Button("계정 추가") { model.addAccount(flow: .browser) }
                    .disabled(model.isBusy)
            }
            GridRow {
                Button("Device Code 추가") { model.addAccount(flow: .deviceCode) }
                    .disabled(model.isBusy)
                Button("계정 정보 새로고침") { Task { await model.refreshAll() } }
                    .disabled(model.isBusy)
            }
            GridRow {
                Button("Codex 앱 열기") { model.openOfficialApp() }
                Button("긴급 복구") { model.emergencyRestore() }
                    .disabled(model.isBusy)
            }
            GridRow {
                Button("Guided Switch") { model.guidedSwitch() }
                    .disabled(model.isBusy)
                Color.clear.frame(height: 1)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var continuity: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Session Continuity Test").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let verdict = model.continuityRecord?.verdict {
                    Text(verdict.rawValue)
                        .font(.caption2.bold())
                        .foregroundStyle(verdict == .pass ? .green : verdict == .pending ? .secondary : .orange)
                }
            }
            if let record = model.continuityRecord {
                Text(record.marker).font(.caption2.monospaced()).textSelection(.enabled)
                HStack {
                    Button("마커 찾기") { model.locateContinuityMarker() }
                    Button("PASS") { model.finishContinuityTest(.pass) }
                    Button("PARTIAL") { model.finishContinuityTest(.partial) }
                    Button("FAIL") { model.finishContinuityTest(.fail) }
                }
                .controlSize(.mini)
            } else {
                Button("연속성 테스트 시작") { model.beginContinuityTest() }
                    .controlSize(.small)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isBusy && model.phase != .idle && model.phase != .completed {
                ProgressView().controlSize(.small)
            }
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(model.statusMessage.contains("실패") || model.statusMessage.contains("오류") ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let comparison = model.lastSnapshotComparison {
                Text("보호 파일: 삭제 \(comparison.deleted.count) · 변경 \(comparison.modified.count) · 유지 \(comparison.unchangedCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("진단 보고서") { model.openBundledDocument("ENVIRONMENT_REPORT.md") }
            Button("도움말") { model.openBundledDocument("TROUBLESHOOTING.md") }
            Spacer()
            SettingsLink { Image(systemName: "gearshape") }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
        }
        .buttonStyle(.plain)
    }
}
