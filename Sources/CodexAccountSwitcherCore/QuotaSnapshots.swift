import Foundation

/// 각 서비스의 한도 정보를 `QuotaPlanner` 입력으로 바꾼다.
public enum QuotaSnapshots {
    /// Codex 프로필별 한도. 6시간 이하 창은 단기(5시간) 한도, 그보다 긴 창은 주간 한도로 본다.
    /// 5시간 한도는 상태 표시에만 쓰고 소진 계산에는 넣지 않는다.
    public static func codex(
        profiles: [AccountProfile],
        limits: [UUID: (rateLimits: AccountRateLimits, checkedAt: Date)]
    ) -> [QuotaAccountSnapshot] {
        profiles.map { profile in
            let entry = limits[profile.id]
            var session: QuotaWindowState?
            var weekly: QuotaWindowState?
            let windows = [entry?.rateLimits.primary, entry?.rateLimits.secondary].compactMap { $0 }
            for (index, window) in windows.enumerated() {
                let state = QuotaWindowState(usedPercent: window.usedPercent, resetsAt: window.resetsAt)
                let isShort = window.windowDurationMinutes.map { $0 <= 360 } ?? (index == 0 && windows.count > 1)
                if isShort {
                    session = state
                } else {
                    weekly = state
                }
            }
            let credits = entry?.rateLimits.resetCredits
            return QuotaAccountSnapshot(
                id: "codex/\(profile.id.uuidString)",
                provider: .codex,
                name: profile.displayName,
                planName: (entry?.rateLimits.planType ?? profile.planType)?.capitalized,
                isCurrent: profile.isActive,
                weekly: weekly,
                session: session,
                resetCreditCount: credits?.availableCount ?? 0,
                resetCreditExpiresAt: credits?.earliestAvailableExpiration,
                observedAt: entry?.checkedAt ?? .distantPast
            )
        }
    }

    /// Claude 계정은 사용 기록이 조직 단위로 남으므로 조직마다 하나로 묶는다.
    /// 같은 조직이 여러 계정 폴더에 있으면 현재 계정, 그다음 세션이 많은 쪽을 쓴다.
    public static func claude(
        report: ClaudeDesktopReport,
        estimates: [String: ClaudeQuotaEstimate]
    ) -> [QuotaAccountSnapshot] {
        var chosen: [String: ClaudeAccountPartition] = [:]
        for partition in report.partitions {
            guard let existing = chosen[partition.organizationUUID] else {
                chosen[partition.organizationUUID] = partition
                continue
            }
            if (partition.isCurrent ? 1 : 0, partition.sessionCount) > (existing.isCurrent ? 1 : 0, existing.sessionCount) {
                chosen[partition.organizationUUID] = partition
            }
        }
        return chosen.values
            .sorted { $0.id < $1.id }
            .map { partition in
                let estimate = estimates[partition.organizationUUID]
                let weekly = estimate.flatMap { estimate in
                    estimate.latest.sevenDayUsedPercent.map {
                        QuotaWindowState(usedPercent: Double($0), resetsAt: estimate.weeklyResetAt, isEstimated: true)
                    }
                }
                let session = estimate.flatMap { estimate in
                    estimate.latest.fiveHourUsedPercent.map {
                        QuotaWindowState(usedPercent: Double($0), resetsAt: estimate.sessionResetAt, isEstimated: true)
                    }
                }
                return QuotaAccountSnapshot(
                    id: "claude/\(partition.organizationUUID)",
                    provider: .claude,
                    name: partition.displayName,
                    planName: partition.label?.planName,
                    isCurrent: partition.isCurrent,
                    weekly: weekly,
                    session: session,
                    weeklyPercentPerSession: estimate?.weeklyPercentPerSession,
                    observedAt: estimate?.latest.sampledAt ?? .distantPast
                )
            }
    }
}
