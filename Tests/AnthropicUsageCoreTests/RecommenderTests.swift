import Testing
import Foundation
@testable import AnthropicUsageCore

/// Build a Window quickly. id drives classification (session vs weekly).
private func win(_ id: String, _ frac: Double) -> ClaudeCode.Window {
    ClaudeCode.Window(id: id, label: id, fraction: frac, resetText: nil, resetAt: nil)
}

private let a = UUID(), b = UUID(), c = UUID()

// MARK: usage(from:)

@Test func usageDistillsWindows() {
    let u = Recommender.usage(from: [
        win("five_hour", 0.5),
        win("seven_day", 0.7),
        win("seven_day_opus", 0.9),
    ])
    #expect(u.sessionFrac == 0.5)
    #expect(u.weeklyAllFrac == 0.7)
    #expect(u.weeklyPeakFrac == 0.9)   // worst weekly
    #expect(u.peak == 0.9)             // worst overall
    #expect(u.isBlocked == false)
}

@Test func sessionMatchedByLabelFallback() {
    let u = Recommender.usage(from: [win("current session", 0.42)])
    #expect(u.sessionFrac == 0.42)
}

@Test func emptyWindows() {
    let u = Recommender.usage(from: [])
    #expect(u.sessionFrac == nil)
    #expect(u.weeklyPeakFrac == nil)
    #expect(u.peak == 0)
}

// MARK: recommend — silence

@Test func noActiveIDIsSilent() {
    let usages = [a: Recommender.Usage(weeklyPeakFrac: 0.1, peak: 0.1)]
    #expect(Recommender.recommend(usages: usages, activeID: nil) == nil)
}

@Test func activeNotInUsagesIsSilent() {
    let usages = [b: Recommender.Usage(weeklyPeakFrac: 0.1, peak: 0.1)]
    #expect(Recommender.recommend(usages: usages, activeID: a) == nil)
}

@Test func coolSeatNoNudge() {
    // Active well below hot threshold → stay quiet even if a fresher seat exists.
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 0.5, peak: 0.5),
        b: Recommender.Usage(weeklyPeakFrac: 0.0, peak: 0.0),
    ]
    #expect(Recommender.recommend(usages: usages, activeID: a) == nil)
}

// MARK: recommend — nudge (.suggestion)

@Test func hotSeatNudgesToFresher() {
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 0.85, peak: 0.85),
        b: Recommender.Usage(weeklyPeakFrac: 0.10, peak: 0.10),
    ]
    let move = Recommender.recommend(usages: usages, activeID: a)
    #expect(move?.targetID == b)
    #expect(move?.urgency == .suggestion)
    #expect(move?.reason == "weekly limit almost full")
}

@Test func hotSessionReasonWhenWeeklyCool() {
    let usages = [
        a: Recommender.Usage(sessionFrac: 0.9, weeklyPeakFrac: 0.2, peak: 0.9),
        b: Recommender.Usage(sessionFrac: 0.0, weeklyPeakFrac: 0.0, peak: 0.0),
    ]
    let move = Recommender.recommend(usages: usages, activeID: a)
    #expect(move?.urgency == .suggestion)
    #expect(move?.reason == "5h session almost gone")
}

@Test func noNudgeWhenImprovementTooSmall() {
    // Hot, but the only alternative is barely better than minImprovement (0.15).
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 0.85, peak: 0.85),
        b: Recommender.Usage(weeklyPeakFrac: 0.80, peak: 0.80),
    ]
    #expect(Recommender.recommend(usages: usages, activeID: a) == nil)
}

@Test func nudgePicksMostDesirableTarget() {
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 0.90, peak: 0.90),
        b: Recommender.Usage(weeklyPeakFrac: 0.40, peak: 0.40),
        c: Recommender.Usage(weeklyPeakFrac: 0.05, peak: 0.05),
    ]
    #expect(Recommender.recommend(usages: usages, activeID: a)?.targetID == c)
}

// MARK: recommend — must move (.mustMove)

@Test func blockedSeatMustMove() {
    let usages = [
        a: Recommender.Usage(sessionFrac: 1.0, weeklyPeakFrac: 0.3, peak: 1.0),
        b: Recommender.Usage(weeklyPeakFrac: 0.1, peak: 0.1),
    ]
    let move = Recommender.recommend(usages: usages, activeID: a)
    #expect(move?.urgency == .mustMove)
    #expect(move?.targetID == b)
    #expect(move?.reason == "hit its 5h limit — blocked until it resets")
}

@Test func weeklyBlockedReason() {
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 1.0, peak: 1.0),
        b: Recommender.Usage(weeklyPeakFrac: 0.1, peak: 0.1),
    ]
    let move = Recommender.recommend(usages: usages, activeID: a)
    #expect(move?.urgency == .mustMove)
    #expect(move?.reason == "hit its weekly limit — blocked for days")
}

@Test func blockedButNowhereToGoIsSilent() {
    // Active blocked, and the only other seat is also blocked → no move.
    let usages = [
        a: Recommender.Usage(weeklyPeakFrac: 1.0, peak: 1.0),
        b: Recommender.Usage(weeklyPeakFrac: 1.0, peak: 1.0),
    ]
    #expect(Recommender.recommend(usages: usages, activeID: a) == nil)
}
