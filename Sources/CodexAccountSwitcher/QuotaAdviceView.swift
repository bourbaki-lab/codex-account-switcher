import CodexAccountSwitcherCore
import SwiftUI

/// 등록된 Codex·Claude 계정의 남은 한도를 비교해 지금 쓸 계정과 소진 마감을 보여준다.
struct QuotaAdviceView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var claude: ClaudeDashboardModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let plan = QuotaPlanner.plan(snapshots, now: context.date)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(plan.recommendations, id: \.provider) { recommendation in
                    recommendationCard(recommendation)
                }
                if plan.advices.isEmpty {
                    Text("등록된 계정이 없습니다").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("마감이 급한 순서").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(plan.advices) { advice in
                                adviceRow(advice, now: context.date)
                            }
                        }
                    }
                    .frame(maxHeight: 330)
                }
                Text("Claude 초기화 시각과 5시간 창 환산은 Claude 앱의 15분 간격 사용 기록에서 추정합니다. 다른 계정 값은 그 계정으로 마지막에 쓴 시점 기준이며, 초기화 시각이 지났으면 다시 찬 것으로 계산합니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var snapshots: [QuotaAccountSnapshot] {
        let codexLimits = model.profileRateLimits.mapValues { (rateLimits: $0.rateLimits, checkedAt: $0.checkedAt) }
        var result = QuotaSnapshots.codex(profiles: model.profiles, limits: codexLimits)
        if let report = claude.report {
            result += QuotaSnapshots.claude(report: report, estimates: claude.quotaEstimates)
        }
        return result
    }

    private func recommendationCard(_ recommendation: QuotaProviderRecommendation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                providerBadge(recommendation.provider)
                Text(recommendation.headline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
            }
            if let detail = recommendation.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(recommendation.provider).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func adviceRow(_ advice: QuotaAdvice, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                providerBadge(advice.account.provider)
                Text(advice.account.name).fontWeight(.medium).lineLimit(1)
                if let plan = advice.account.planName {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                }
                if advice.account.isCurrent {
                    Text("현재").font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.green.opacity(0.15), in: Capsule())
                }
                Spacer()
                statusText(advice.status, now: now)
            }
            if let remaining = advice.weeklyRemaining {
                ProgressView(value: remaining, total: 100).tint(remaining < 20 ? .orange : tint(advice.account.provider))
                Text(weeklyLine(advice, remaining: remaining, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if advice.account.provider == .claude, let sessionLine = sessionLine(advice, now: now) {
                Text(sessionLine).font(.caption).foregroundStyle(.secondary)
            }
            if let drainLine = drainLine(advice, now: now) {
                Text(drainLine)
                    .font(.caption)
                    .foregroundStyle(advice.unavoidableWaste >= 1 ? .red : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(advice.notes, id: \.self) { note in
                Text(note).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if advice.account.observedAt > .distantPast {
                Text("기록 \(QuotaFormat.time(advice.account.observedAt, now: now))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func weeklyLine(_ advice: QuotaAdvice, remaining: Double, now: Date) -> String {
        var text = "주간 \(Int(remaining.rounded()))% 남음"
        if let reset = advice.weeklyResetAt {
            text += " · \(QuotaFormat.time(reset, now: now))\(advice.weeklyResetIsEstimated ? "(추정)" : "") 초기화"
            text += " · \(QuotaFormat.duration(reset.timeIntervalSince(now))) 후"
        } else {
            text += " · 초기화 시각 미확인"
        }
        return text
    }

    private func sessionLine(_ advice: QuotaAdvice, now: Date) -> String? {
        guard let remaining = advice.sessionRemaining else { return nil }
        var text = "5시간 \(Int(remaining.rounded()))% 남음"
        if let reset = advice.sessionResetAt {
            text += " · \(QuotaFormat.time(reset, now: now)) 초기화"
        } else {
            text += " · 진행 중인 창 없음"
        }
        if let perSession = advice.account.weeklyPercentPerSession {
            text += " · 창 1개 ≈ 주간 \(Int(perSession.rounded()))%"
        }
        return text
    }

    private func drainLine(_ advice: QuotaAdvice, now: Date) -> String? {
        guard let remaining = advice.weeklyRemaining, remaining > 0, let deadline = advice.drainDeadline else { return nil }
        if advice.unavoidableWaste >= 1 {
            return "지금부터 5시간마다 끝까지 써도 \(Int(advice.unavoidableWaste.rounded()))%는 초기화 전에 못 씀 → 최우선"
        }
        var parts: [String] = []
        if let needed = advice.sessionsNeeded, needed > 0 {
            parts.append("5시간 창 \(needed)개 더 필요")
        }
        if let latest = advice.latestStartAt {
            parts.append(latest <= now.addingTimeInterval(60)
                ? "지금 바로 써야 다 소진"
                : "늦어도 \(QuotaFormat.time(latest, now: now))부터 써야 다 소진")
        } else {
            parts.append("\(QuotaFormat.time(deadline, now: now))까지 소진")
        }
        if let pace = advice.dailyPace {
            parts.append("하루 \(Int(pace.rounded()))%씩")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusText(_ status: QuotaAdviceStatus, now: Date) -> some View {
        switch status {
        case .available:
            Text("사용 가능").font(.caption2).foregroundStyle(.green)
        case .sessionBlocked(let until):
            Text(until.map { "5시간 소진 · \(QuotaFormat.time($0, now: now))" } ?? "5시간 소진")
                .font(.caption2).foregroundStyle(.orange)
        case .weeklyExhausted(let until):
            Text(until.map { "주간 소진 · \(QuotaFormat.time($0, now: now))" } ?? "주간 소진")
                .font(.caption2).foregroundStyle(.red)
        case .unknown:
            Text("정보 없음").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func providerBadge(_ provider: QuotaProvider) -> some View {
        Text(provider.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint(provider).opacity(0.18), in: Capsule())
    }

    private func tint(_ provider: QuotaProvider) -> Color {
        provider == .claude ? .orange : .blue
    }
}
