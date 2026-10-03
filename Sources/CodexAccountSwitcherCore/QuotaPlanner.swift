import Foundation

/// 등록된 Codex·Claude 계정의 남은 한도와 초기화 시각을 비교해
/// 어떤 계정을 먼저, 언제까지 써야 버려지는 한도가 없는지 계산한다.
public enum QuotaProvider: String, Codable, Sendable {
    case codex
    case claude

    public var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public struct QuotaWindowState: Equatable, Sendable {
    public var usedPercent: Double
    public var resetsAt: Date?
    /// 서버가 준 값이 아니라 사용 기록에서 추정한 초기화 시각인지 여부.
    public var isEstimated: Bool

    public init(usedPercent: Double, resetsAt: Date?, isEstimated: Bool = false) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.isEstimated = isEstimated
    }

    public var remainingPercent: Double { min(max(100 - usedPercent, 0), 100) }
}

public struct QuotaAccountSnapshot: Identifiable, Equatable, Sendable {
    public var id: String
    public var provider: QuotaProvider
    public var name: String
    public var planName: String?
    public var isCurrent: Bool
    public var weekly: QuotaWindowState?
    public var session: QuotaWindowState?
    /// 5시간 창 하나를 끝까지 썼을 때 줄어드는 주간 한도(%). 알 수 있을 때만 5시간 제약을 계산한다.
    public var weeklyPercentPerSession: Double?
    public var resetCreditCount: Int
    public var resetCreditExpiresAt: Date?
    public var observedAt: Date

    public init(
        id: String,
        provider: QuotaProvider,
        name: String,
        planName: String? = nil,
        isCurrent: Bool = false,
        weekly: QuotaWindowState?,
        session: QuotaWindowState? = nil,
        weeklyPercentPerSession: Double? = nil,
        resetCreditCount: Int = 0,
        resetCreditExpiresAt: Date? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.planName = planName
        self.isCurrent = isCurrent
        self.weekly = weekly
        self.session = session
        self.weeklyPercentPerSession = weeklyPercentPerSession
        self.resetCreditCount = resetCreditCount
        self.resetCreditExpiresAt = resetCreditExpiresAt
        self.observedAt = observedAt
    }
}

public enum QuotaAdviceStatus: Equatable, Sendable {
    /// 지금 쓸 수 있음.
    case available
    /// 5시간(또는 단기) 한도를 다 써서 이 시각까지 대기.
    case sessionBlocked(until: Date?)
    /// 주간 한도를 다 써서 이 시각까지 대기.
    case weeklyExhausted(until: Date?)
    /// 한도 정보가 없음.
    case unknown
}

public struct QuotaAdvice: Identifiable, Equatable, Sendable {
    public var account: QuotaAccountSnapshot
    public var status: QuotaAdviceStatus
    public var weeklyRemaining: Double?
    public var weeklyResetAt: Date?
    public var weeklyResetIsEstimated: Bool
    public var sessionRemaining: Double?
    public var sessionResetAt: Date?
    /// 주간 잔량을 다 쓰는 데 필요한 5시간 창 수(현재 창 포함하지 않음).
    public var sessionsNeeded: Int?
    /// 주간 초기화 전에 쓸 수 있는 최대치(%). 5시간 제약을 아는 경우에만 계산한다.
    public var achievableBeforeReset: Double?
    /// 최대 속도로 써도 초기화 전에 버려지는 주간 한도(%).
    public var unavoidableWaste: Double
    /// 잔량을 다 쓰려면 늦어도 이 시각부터 5시간마다 이어서 써야 한다.
    public var latestStartAt: Date?
    /// 잔량을 다 쓰기 위한 마감(주간 초기화 또는 초기화권 만료 중 이른 쪽).
    public var drainDeadline: Date?
    /// 하루 평균 써야 하는 주간 한도(%).
    public var dailyPace: Double?
    public var notes: [String]

    public var id: String { account.id }
}

public struct QuotaProviderRecommendation: Equatable, Sendable {
    public var provider: QuotaProvider
    public var advice: QuotaAdvice?
    public var headline: String
    public var detail: String?
}

public struct QuotaPlan: Equatable, Sendable {
    public var generatedAt: Date
    public var advices: [QuotaAdvice]
    public var recommendations: [QuotaProviderRecommendation]
}

public enum QuotaPlanner {
    public static let sessionLength: TimeInterval = 5 * 60 * 60
    public static let week: TimeInterval = 7 * 24 * 60 * 60

    public static func plan(_ accounts: [QuotaAccountSnapshot], now: Date = Date()) -> QuotaPlan {
        let advices = accounts.map { advise($0, now: now) }.sorted { lhs, rhs in
            urgencyKey(lhs, now: now) < urgencyKey(rhs, now: now)
        }
        let providers = [QuotaProvider.claude, .codex].filter { provider in
            accounts.contains { $0.provider == provider }
        }
        return QuotaPlan(
            generatedAt: now,
            advices: advices,
            recommendations: providers.map { recommend($0, advices: advices, now: now) }
        )
    }

    // MARK: - 계정별 계산

    public static func advise(_ account: QuotaAccountSnapshot, now: Date) -> QuotaAdvice {
        let weekly = account.weekly.map { normalizeWeekly($0, now: now) }
        let session = account.session.map { normalizeSession($0, now: now) }

        var advice = QuotaAdvice(
            account: account,
            status: .unknown,
            weeklyRemaining: weekly?.remainingPercent,
            weeklyResetAt: weekly?.resetsAt,
            weeklyResetIsEstimated: weekly?.isEstimated ?? false,
            sessionRemaining: session?.remainingPercent,
            sessionResetAt: session?.resetsAt,
            sessionsNeeded: nil,
            achievableBeforeReset: nil,
            unavoidableWaste: 0,
            latestStartAt: nil,
            drainDeadline: nil,
            dailyPace: nil,
            notes: []
        )

        guard let weekly else {
            if let session {
                advice.status = session.remainingPercent <= 0 ? .sessionBlocked(until: session.resetsAt) : .available
            }
            return advice
        }

        let remaining = weekly.remainingPercent
        if remaining <= 0 {
            advice.status = .weeklyExhausted(until: weekly.resetsAt)
        } else if let session, session.remainingPercent <= 0 {
            advice.status = .sessionBlocked(until: session.resetsAt)
        } else {
            advice.status = .available
        }

        // 초기화권은 주간 한도를 다 쓴 뒤 써야 이득이다. 초기화권이 주간 초기화보다 먼저 만료되면
        // 그 전에 주간 잔량을 비워야 한다.
        var deadline = weekly.resetsAt
        if account.resetCreditCount > 0 {
            if let expiry = account.resetCreditExpiresAt {
                if let reset = weekly.resetsAt, expiry < reset {
                    deadline = expiry
                    advice.notes.append("초기화권 \(account.resetCreditCount)개가 주간 초기화보다 먼저 만료 → 그 전에 주간 한도를 비우고 초기화권 사용")
                } else {
                    advice.notes.append("초기화권 \(account.resetCreditCount)개 · 주간 한도를 다 쓴 뒤 사용")
                }
            } else {
                advice.notes.append("초기화권 \(account.resetCreditCount)개 · 주간 한도를 다 쓴 뒤 사용")
            }
        }
        advice.drainDeadline = deadline

        guard let deadline, remaining > 0 else { return advice }
        let timeLeft = deadline.timeIntervalSince(now)
        if timeLeft > 0 {
            advice.dailyPace = remaining / max(timeLeft / 86_400, 1.0 / 24)
        }

        // 5시간 제약: 창 하나에 쓸 수 있는 주간 % 가 정해져 있으므로 남은 창 수로 소진 가능량이 정해진다.
        guard let perSession = account.weeklyPercentPerSession, perSession > 0 else { return advice }

        var currentCapacity = 0.0
        var freshStart = now
        if let session, let sessionReset = session.resetsAt, sessionReset > now {
            currentCapacity = min(session.remainingPercent / 100 * perSession, remaining)
            freshStart = sessionReset
        }
        let afterCurrent = max(remaining - currentCapacity, 0)
        let freshWindows: Int
        if deadline > freshStart {
            freshWindows = Int(floor(deadline.timeIntervalSince(freshStart) / sessionLength)) + 1
        } else {
            freshWindows = 0
        }
        let achievable = min(currentCapacity + Double(freshWindows) * perSession, remaining)
        advice.achievableBeforeReset = achievable
        advice.unavoidableWaste = max(remaining - achievable, 0)

        let needed = Int(ceil(afterCurrent / perSession - 0.000_1))
        advice.sessionsNeeded = needed
        if needed > 0 {
            let latest = deadline.addingTimeInterval(-Double(needed - 1) * sessionLength - sessionLength / 5)
            advice.latestStartAt = max(latest, freshStart)
        } else {
            // 현재 창 안에서 다 쓸 수 있음.
            advice.latestStartAt = now
        }
        return advice
    }

    /// 관찰 이후 초기화 시각이 지났다면 한도가 다시 찬 것으로 보고 다음 주기로 넘긴다.
    static func normalizeWeekly(_ window: QuotaWindowState, now: Date) -> QuotaWindowState {
        guard var reset = window.resetsAt else { return window }
        guard reset <= now else { return window }
        while reset <= now { reset = reset.addingTimeInterval(week) }
        return QuotaWindowState(usedPercent: 0, resetsAt: reset, isEstimated: true)
    }

    static func normalizeSession(_ window: QuotaWindowState, now: Date) -> QuotaWindowState {
        guard let reset = window.resetsAt, reset <= now else { return window }
        return QuotaWindowState(usedPercent: 0, resetsAt: nil, isEstimated: window.isEstimated)
    }

    // MARK: - 추천

    /// 버려질 위험이 큰(마감이 빠른) 계정이 앞에 오도록 정렬 키를 만든다.
    static func urgencyKey(_ advice: QuotaAdvice, now: Date) -> Double {
        let far = Double.greatestFiniteMagnitude / 4
        switch advice.status {
        case .unknown: return far * 3
        case .weeklyExhausted(let until): return far * 2 + (until?.timeIntervalSince(now) ?? 0)
        case .sessionBlocked, .available: break
        }
        guard let remaining = advice.weeklyRemaining, remaining > 0 else { return far * 2 }
        if let latest = advice.latestStartAt { return latest.timeIntervalSince(now) }
        if let deadline = advice.drainDeadline { return deadline.timeIntervalSince(now) }
        return far
    }

    static func recommend(_ provider: QuotaProvider, advices: [QuotaAdvice], now: Date) -> QuotaProviderRecommendation {
        let candidates = advices.filter { $0.account.provider == provider }
        if let pick = candidates.first(where: { $0.status == .available && ($0.weeklyRemaining ?? 0) > 0 }) {
            return QuotaProviderRecommendation(
                provider: provider,
                advice: pick,
                headline: "지금은 \(pick.account.name) 사용",
                detail: reason(for: pick, now: now)
            )
        }
        let waiting = candidates.compactMap { advice -> (QuotaAdvice, Date)? in
            switch advice.status {
            case .sessionBlocked(let until), .weeklyExhausted(let until):
                return until.map { (advice, $0) }
            default:
                return nil
            }
        }.min { $0.1 < $1.1 }
        if let (advice, until) = waiting {
            return QuotaProviderRecommendation(
                provider: provider,
                advice: advice,
                headline: "모든 계정 한도 소진 · \(advice.account.name) \(QuotaFormat.time(until, now: now)) 복구",
                detail: nil
            )
        }
        return QuotaProviderRecommendation(
            provider: provider,
            advice: nil,
            headline: "한도 정보가 아직 없습니다",
            detail: provider == .codex ? "Codex 탭에서 계정 한도를 새로고침하세요" : "Claude 앱에서 해당 계정으로 한 번 이상 사용해야 기록됩니다"
        )
    }

    static func reason(for advice: QuotaAdvice, now: Date) -> String {
        var parts: [String] = []
        if let remaining = advice.weeklyRemaining, let reset = advice.weeklyResetAt {
            parts.append("주간 \(Int(remaining.rounded()))% 남음, \(QuotaFormat.time(reset, now: now))\(advice.weeklyResetIsEstimated ? "(추정)" : "") 초기화")
        } else if let remaining = advice.weeklyRemaining {
            parts.append("주간 \(Int(remaining.rounded()))% 남음 · 초기화 시각 미확인")
        }
        if advice.unavoidableWaste >= 1 {
            parts.append("지금부터 쉬지 않고 써도 \(Int(advice.unavoidableWaste.rounded()))%는 버려짐")
        } else if let latest = advice.latestStartAt, latest > now.addingTimeInterval(60) {
            parts.append("늦어도 \(QuotaFormat.time(latest, now: now))부터 5시간마다 써야 다 소진")
        } else if advice.latestStartAt != nil {
            parts.append("지금부터 5시간마다 이어서 써야 다 소진")
        }
        return parts.joined(separator: " · ")
    }
}

public enum QuotaFormat {
    public static func time(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "오늘 HH:mm"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            formatter.dateFormat = "내일 HH:mm"
        } else {
            formatter.dateFormat = "M/d(E) HH:mm"
        }
        return formatter.string(from: date)
    }

    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        if minutes < 60 { return "\(minutes)분" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)시간" : "\(hours)시간 \(minutes % 60)분" }
        return "\(hours / 24)일 \(hours % 24)시간"
    }
}
