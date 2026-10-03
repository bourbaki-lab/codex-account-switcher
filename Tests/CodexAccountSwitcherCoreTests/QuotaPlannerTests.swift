import Foundation
import XCTest
@testable import CodexAccountSwitcherCore

final class QuotaPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let hour: TimeInterval = 3_600

    // MARK: - Planner

    func testSoonerWeeklyResetIsRecommendedFirst() {
        let later = claude("later", weeklyUsed: 10, weeklyReset: now + 6 * 24 * hour)
        let sooner = claude("sooner", weeklyUsed: 50, weeklyReset: now + 20 * hour)
        let plan = QuotaPlanner.plan([later, sooner], now: now)
        XCTAssertEqual(plan.advices.first?.account.id, "sooner")
        XCTAssertEqual(plan.recommendations.first?.advice?.account.id, "sooner")
    }

    func testFiveHourLimitCapsWhatCanBeUsedBeforeReset() {
        // 주간 90% 남음, 창 1개 = 주간 20%, 초기화까지 12시간 → 새 창 3개(0h, 5h, 10h) = 60%까지만 사용 가능.
        let account = claude("a", weeklyUsed: 10, weeklyReset: now + 12 * hour, sessionUsed: 0, perSession: 20)
        let advice = QuotaPlanner.advise(account, now: now)
        XCTAssertEqual(advice.achievableBeforeReset ?? 0, 60, accuracy: 0.01)
        XCTAssertEqual(advice.unavoidableWaste, 30, accuracy: 0.01)
        XCTAssertEqual(advice.sessionsNeeded, 5)
    }

    func testLatestStartLeavesEnoughFiveHourWindows() {
        // 주간 40% 남음, 창 1개 = 20% → 창 2개 필요. 초기화 48시간 후면 늦어도 초기화 6시간(5h + 여유 1h) 전에 시작.
        let account = claude("a", weeklyUsed: 60, weeklyReset: now + 48 * hour, sessionUsed: 0, perSession: 20)
        let advice = QuotaPlanner.advise(account, now: now)
        XCTAssertEqual(advice.unavoidableWaste, 0)
        XCTAssertEqual(advice.sessionsNeeded, 2)
        XCTAssertEqual(advice.latestStartAt?.timeIntervalSince(now) ?? 0, 42 * hour, accuracy: 1)
    }

    func testCurrentWindowCapacityCountsBeforeFreshWindows() {
        // 5시간 50% 남음(= 주간 10%), 2시간 뒤 창 초기화.
        let account = claude(
            "a", weeklyUsed: 80, weeklyReset: now + 30 * hour,
            sessionUsed: 50, sessionReset: now + 2 * hour, perSession: 20
        )
        let advice = QuotaPlanner.advise(account, now: now)
        XCTAssertEqual(advice.sessionsNeeded, 1)
        XCTAssertEqual(advice.achievableBeforeReset ?? 0, 20, accuracy: 0.01)
    }

    func testBlockedAccountIsSkippedForRecommendation() {
        let blocked = claude("blocked", weeklyUsed: 10, weeklyReset: now + 10 * hour, sessionUsed: 100, sessionReset: now + hour, perSession: 20)
        let free = claude("free", weeklyUsed: 10, weeklyReset: now + 100 * hour, sessionUsed: 0, perSession: 20)
        let plan = QuotaPlanner.plan([blocked, free], now: now)
        XCTAssertEqual(plan.recommendations.first?.advice?.account.id, "free")
        XCTAssertEqual(plan.advices.first { $0.id == "blocked" }?.status, .sessionBlocked(until: now + hour))
    }

    func testStaleObservationAfterResetIsTreatedAsRefilled() {
        let account = claude("a", weeklyUsed: 100, weeklyReset: now - hour, sessionUsed: 100, sessionReset: now - 2 * hour, perSession: 20)
        let advice = QuotaPlanner.advise(account, now: now)
        XCTAssertEqual(advice.status, .available)
        XCTAssertEqual(advice.weeklyRemaining, 100)
        XCTAssertEqual(advice.weeklyResetAt, now - hour + QuotaPlanner.week)
        XCTAssertEqual(advice.sessionRemaining, 100)
    }

    func testResetCreditExpiringBeforeWeeklyResetMovesDeadline() {
        let expiry = now + 10 * hour
        let account = QuotaAccountSnapshot(
            id: "codex", provider: .codex, name: "Pro",
            weekly: QuotaWindowState(usedPercent: 30, resetsAt: now + 100 * hour),
            resetCreditCount: 1, resetCreditExpiresAt: expiry, observedAt: now
        )
        let advice = QuotaPlanner.advise(account, now: now)
        XCTAssertEqual(advice.drainDeadline, expiry)
        XCTAssertEqual(advice.notes.count, 1)
        XCTAssertNil(advice.latestStartAt, "Codex는 5시간 제약을 계산하지 않는다")
    }

    func testAllExhaustedReportsEarliestRecovery() {
        let a = claude("a", weeklyUsed: 100, weeklyReset: now + 30 * hour)
        let b = claude("b", weeklyUsed: 100, weeklyReset: now + 5 * hour)
        let plan = QuotaPlanner.plan([a, b], now: now)
        XCTAssertEqual(plan.recommendations.first?.advice?.account.id, "b")
        XCTAssertTrue(plan.recommendations.first?.headline.contains("소진") ?? false)
    }

    // MARK: - Codex snapshot

    func testCodexWindowsAreClassifiedByDuration() {
        let profile = AccountProfile(displayName: "Pro", planType: "pro")
        let limits = AccountRateLimits(
            limitID: nil, planType: "pro",
            primary: RateLimitWindow(usedPercent: 30, windowDurationMinutes: 300, resetsAt: now + hour),
            secondary: RateLimitWindow(usedPercent: 40, windowDurationMinutes: 10_080, resetsAt: now + 50 * hour),
            resetCredits: RateLimitResetCredits(availableCount: 2, credits: nil)
        )
        let snapshot = QuotaSnapshots.codex(profiles: [profile], limits: [profile.id: (limits, now)]).first
        XCTAssertEqual(snapshot?.session?.usedPercent, 30)
        XCTAssertEqual(snapshot?.weekly?.usedPercent, 40)
        XCTAssertEqual(snapshot?.resetCreditCount, 2)
    }

    // MARK: - Claude history

    func testHistoryEstimatesWeeklyResetFromRecurringDrops() {
        let base = Date(timeIntervalSince1970: 1_789_000_000)
        var samples: [[String: Any]] = []
        func add(_ offset: TimeInterval, _ fh: Int, _ sd: Int) {
            samples.append(["t": (base + offset).timeIntervalSince1970 * 1_000, "org": "o", "u": ["fh": fh, "sd": sd]])
        }
        let week = QuotaPlanner.week
        add(0, 10, 40); add(15 * 60, 10, 0)                       // 정기 초기화 1
        add(3 * 24 * hour, 20, 50); add(3 * 24 * hour + 900, 0, 0) // 비정기(초기화권) 초기화
        add(week, 10, 60); add(week + 15 * 60, 10, 0)             // 정기 초기화 2
        add(week + 2 * hour, 0, 2)
        add(week + 3 * hour, 10, 4)                               // 새 5시간 창
        add(week + 3 * hour + 900, 30, 9)
        let estimate = ClaudeQuotaHistory(object: ["samples": samples]).estimates()["o"]
        XCTAssertEqual(estimate?.weeklyResetAt?.timeIntervalSince(base) ?? 0, 2 * week + 450, accuracy: 1)
        XCTAssertEqual(estimate?.sessionStartedAt?.timeIntervalSince(base) ?? 0, week + 3 * hour, accuracy: 1, "간격이 30분을 넘으면 사용이 처음 보인 기록 시각으로 잡는다")
        XCTAssertEqual(estimate?.latest.fiveHourUsedPercent, 30)
    }

    func testPerSessionRatioNeedsEnoughObservations() {
        var samples: [[String: Any]] = []
        for step in 0..<6 {
            samples.append(["t": Double(step) * 900_000, "org": "o", "u": ["fh": step * 10, "sd": step * 2]])
        }
        let ratio = ClaudeQuotaHistory(object: ["samples": samples]).estimates()["o"]?.weeklyPercentPerSession
        XCTAssertEqual(ratio ?? 0, 20, accuracy: 0.01)

        let short = ClaudeQuotaHistory(object: ["samples": Array(samples.prefix(3))]).estimates()["o"]
        XCTAssertNil(short?.weeklyPercentPerSession)
    }

    func testEstimateShowsRefilledFiveHourAfterWindowEnds() {
        let samples: [[String: Any]] = [
            ["t": 0.0, "org": "o", "u": ["fh": 0, "sd": 10]],
            ["t": 900_000.0, "org": "o", "u": ["fh": 100, "sd": 22]]
        ]
        let estimate = ClaudeQuotaHistory(object: ["samples": samples]).estimates()["o"]!
        let during = estimate.current(now: Date(timeIntervalSince1970: 3_600))
        XCTAssertEqual(during.fiveHour?.remainingPercent, 0)
        let after = estimate.current(now: Date(timeIntervalSince1970: 6 * 3_600))
        XCTAssertEqual(after.fiveHour?.remainingPercent, 100)
        XCTAssertEqual(after.weekly?.remainingPercent, 78)
    }

    private func claude(
        _ id: String,
        weeklyUsed: Double,
        weeklyReset: Date?,
        sessionUsed: Double? = nil,
        sessionReset: Date? = nil,
        perSession: Double? = nil
    ) -> QuotaAccountSnapshot {
        QuotaAccountSnapshot(
            id: id, provider: .claude, name: id,
            weekly: QuotaWindowState(usedPercent: weeklyUsed, resetsAt: weeklyReset, isEstimated: true),
            session: sessionUsed.map { QuotaWindowState(usedPercent: $0, resetsAt: sessionReset, isEstimated: true) },
            weeklyPercentPerSession: perSession,
            observedAt: now
        )
    }
}
