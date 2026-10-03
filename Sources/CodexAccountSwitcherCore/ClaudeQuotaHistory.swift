import Foundation

/// Claude 앱의 `plan-usage-history.json`(15분 간격 사용률 기록)에서 조직별 한도 상태를 추정한다.
///
/// 기록에는 사용률(%)만 있고 초기화 시각이 없다. 그래서
/// - 주간 초기화: 주간 사용률이 크게 떨어진 시점들 중 7일 주기와 가장 잘 맞는 최근 시점 + 7일 배수
/// - 5시간 초기화: 현재 5시간 창이 처음 사용된 시점 + 5시간
/// - 5시간 창 하나의 주간 환산: 같은 창 안에서 늘어난 주간 % ÷ 늘어난 5시간 %
/// 으로 계산한다. 모두 추정값이며 기록 간격(약 15분)만큼 오차가 있다.
public struct ClaudeQuotaEstimate: Equatable, Sendable {
    public var organizationUUID: String
    public var latest: ClaudeUsageSample
    public var sessionStartedAt: Date?
    public var weeklyResetAt: Date?
    public var weeklyPercentPerSession: Double?

    public var sessionResetAt: Date? { sessionStartedAt?.addingTimeInterval(QuotaPlanner.sessionLength) }

    /// 마지막 기록 이후 초기화 시각이 지났으면 다시 찬 것으로 본 지금 시점의 한도.
    /// 다른 계정의 오래된 기록을 그대로 보여 주면 이미 풀린 5시간 한도가 0%로 남아 보인다.
    public func current(now: Date = Date()) -> (fiveHour: QuotaWindowState?, weekly: QuotaWindowState?) {
        let fiveHour = latest.fiveHourUsedPercent.map {
            QuotaPlanner.normalizeSession(
                QuotaWindowState(usedPercent: Double($0), resetsAt: sessionResetAt, isEstimated: true),
                now: now
            )
        }
        let weekly = latest.sevenDayUsedPercent.map {
            QuotaPlanner.normalizeWeekly(
                QuotaWindowState(usedPercent: Double($0), resetsAt: weeklyResetAt, isEstimated: true),
                now: now
            )
        }
        return (fiveHour, weekly)
    }
}

public struct ClaudeQuotaHistory: Sendable {
    struct Sample: Equatable {
        var time: Date
        var fiveHour: Int
        var sevenDay: Int
    }

    /// 5시간 창 환산 비율을 믿을 만큼 쌓인 5시간 사용률 증가량(%).
    static let minimumObservedSessionPercent = 40
    static let weeklyDropThreshold = 5

    let samplesByOrganization: [String: [Sample]]

    public init(paths: ClaudeDesktopPaths = ClaudeDesktopPaths()) {
        self.init(object: ClaudeJSON.object(at: paths.usageHistoryFile))
    }

    init(object: [String: Any]?) {
        var grouped: [String: [Sample]] = [:]
        for sample in object?["samples"] as? [[String: Any]] ?? [] {
            guard
                let organization = sample["org"] as? String,
                let milliseconds = (sample["t"] as? NSNumber)?.doubleValue,
                let usage = sample["u"] as? [String: Any],
                let fiveHour = (usage["fh"] as? NSNumber)?.intValue,
                let sevenDay = (usage["sd"] as? NSNumber)?.intValue
            else { continue }
            grouped[organization, default: []].append(Sample(
                time: Date(timeIntervalSince1970: milliseconds / 1_000),
                fiveHour: fiveHour,
                sevenDay: sevenDay
            ))
        }
        samplesByOrganization = grouped.mapValues { $0.sorted { $0.time < $1.time } }
    }

    public func estimates() -> [String: ClaudeQuotaEstimate] {
        var result: [String: ClaudeQuotaEstimate] = [:]
        for (organization, samples) in samplesByOrganization {
            guard let last = samples.last else { continue }
            result[organization] = ClaudeQuotaEstimate(
                organizationUUID: organization,
                latest: ClaudeUsageSample(
                    fiveHourUsedPercent: last.fiveHour,
                    sevenDayUsedPercent: last.sevenDay,
                    sampledAt: last.time
                ),
                sessionStartedAt: Self.sessionStart(samples),
                weeklyResetAt: Self.weeklyReset(samples),
                weeklyPercentPerSession: Self.weeklyPercentPerSession(samples)
            )
        }
        return result
    }

    /// 마지막 기록이 속한 5시간 창의 시작 시각. 마지막 5시간 사용률이 0이면 진행 중인 창이 없다.
    static func sessionStart(_ samples: [Sample]) -> Date? {
        guard let last = samples.last, last.fiveHour > 0 else { return nil }
        var index = samples.count - 1
        while index > 0 {
            let previous = samples[index - 1]
            let current = samples[index]
            // 같은 창이면 5시간 사용률이 줄지 않고, 창은 5시간을 넘겨 이어질 수 없다.
            let sameWindow = previous.fiveHour > 0
                && previous.fiveHour <= current.fiveHour
                && last.time.timeIntervalSince(previous.time) < QuotaPlanner.sessionLength
            if !sameWindow {
                // 창은 이전 기록과 이 기록 사이에 열렸다. 간격이 짧으면 가운데로 잡는다.
                let gap = current.time.timeIntervalSince(previous.time)
                return gap <= 30 * 60 ? previous.time.addingTimeInterval(gap / 2) : current.time
            }
            index -= 1
        }
        return samples[0].time
    }

    /// 주간 사용률이 떨어진 시점들 중 7일 주기와 가장 많이 맞는 가장 최근 시점에 7일 배수를 더한 다음 초기화.
    /// 초기화권 사용 같은 비정기 초기화는 다른 주기와 맞지 않아 뒤로 밀린다.
    static func weeklyReset(_ samples: [Sample]) -> Date? {
        var drops: [Date] = []
        for (previous, current) in zip(samples, samples.dropFirst())
        where previous.sevenDay - current.sevenDay >= weeklyDropThreshold || (previous.sevenDay >= weeklyDropThreshold && current.sevenDay <= 1) {
            let gap = current.time.timeIntervalSince(previous.time)
            drops.append(gap <= 60 * 60 ? previous.time.addingTimeInterval(gap / 2) : current.time)
        }
        guard !drops.isEmpty, let last = samples.last else { return nil }

        let tolerance: TimeInterval = 2 * 60 * 60
        func support(_ anchor: Date) -> Int {
            drops.filter { drop in
                let offset = drop.timeIntervalSince(anchor) / QuotaPlanner.week
                let distance = abs(offset - offset.rounded()) * QuotaPlanner.week
                return distance <= tolerance
            }.count
        }
        let anchor = drops.max { lhs, rhs in
            let lhsSupport = support(lhs)
            let rhsSupport = support(rhs)
            return lhsSupport == rhsSupport ? lhs < rhs : lhsSupport < rhsSupport
        }!

        var next = anchor
        while next <= last.time { next = next.addingTimeInterval(QuotaPlanner.week) }
        return next
    }

    static func weeklyPercentPerSession(_ samples: [Sample]) -> Double? {
        var fiveHourTotal = 0
        var sevenDayTotal = 0
        for (previous, current) in zip(samples, samples.dropFirst()) {
            let fiveHour = current.fiveHour - previous.fiveHour
            let sevenDay = current.sevenDay - previous.sevenDay
            guard fiveHour > 0, sevenDay >= 0, current.time.timeIntervalSince(previous.time) < 60 * 60 else { continue }
            fiveHourTotal += fiveHour
            sevenDayTotal += sevenDay
        }
        guard fiveHourTotal >= minimumObservedSessionPercent else { return nil }
        return Double(sevenDayTotal) / Double(fiveHourTotal) * 100
    }
}
