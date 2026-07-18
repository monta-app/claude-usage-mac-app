import Foundation

/// Decides which account you should be coding on right now, given every
/// tracked account's usage and which one you're currently logged into.
///
/// Two flavours of advice, matching how the UI surfaces them:
///  - `.suggestion` — a *quiet* nudge (shown in the menu bar / a banner). Fires
///    *before* you're blocked, when the seat you're on is running hot and a
///    clearly-fresher account exists. Purely optional; you can ignore it.
///  - `.mustMove` — you've actually hit a wall on the account you're on (a
///    window is at 100%). This is the loud, edge-triggered popup: you cannot
///    make requests here until it resets, so move now.
///
/// All logic here is pure (no I/O, no dates fetched internally) so it stays
/// trivially testable and deterministic.
public enum Recommender {

    public enum Urgency { case suggestion, mustMove }

    public struct Move: Equatable {
        public let targetID: UUID
        public let urgency: Urgency
        /// Short, human sentence for the UI, e.g. "5h session almost gone".
        public let reason: String
    }

    /// Per-account view distilled from its usage windows.
    public struct Usage {
        public var sessionFrac: Double?     // the 5h "current session" window
        public var sessionResetAt: Date?
        public var weeklyAllFrac: Double?   // the binding "current week (all models)" wall
        public var weeklyPeakFrac: Double?  // worst of any weekly window (all + scoped)
        public var peak: Double             // worst of ALL windows — 1.0 == blocked

        public init(sessionFrac: Double? = nil, sessionResetAt: Date? = nil,
                    weeklyAllFrac: Double? = nil, weeklyPeakFrac: Double? = nil, peak: Double = 0) {
            self.sessionFrac = sessionFrac; self.sessionResetAt = sessionResetAt
            self.weeklyAllFrac = weeklyAllFrac; self.weeklyPeakFrac = weeklyPeakFrac; self.peak = peak
        }

        public var isBlocked: Bool { peak >= 1.0 }
        /// Blocked specifically by the weekly wall (a multi-day outage, vs. a
        /// 5h block that clears within hours).
        public var weeklyBlocked: Bool { (weeklyPeakFrac ?? 0) >= 1.0 }

        /// Lower is more desirable to move onto. Weekly headroom dominates
        /// (it's the wall that lasts days); 5h is a light tie-breaker.
        public var desirability: Double { (weeklyPeakFrac ?? 0) * 1.0 + (sessionFrac ?? 0) * 0.25 }
    }

    /// A seat is "hot" (worth nudging away from) once any window crosses this,
    /// even though it isn't blocked yet.
    public static let hotThreshold = 0.80
    /// Don't nudge sideways: only suggest a target that's clearly fresher.
    public static let minImprovement = 0.15

    public static func usage(from windows: [ClaudeCode.Window]) -> Usage {
        func frac(_ id: String) -> Double? { windows.first { $0.id == id }?.fraction }
        let session = windows.first { $0.id == "five_hour" || $0.label.lowercased().contains("session") }
        let weeklies = windows.filter { $0.id.hasPrefix("seven_day") }
        return Usage(
            sessionFrac: session?.fraction,
            sessionResetAt: session?.resetAt,
            weeklyAllFrac: frac("seven_day"),
            weeklyPeakFrac: weeklies.map(\.fraction).max(),
            peak: windows.map(\.fraction).max() ?? 0
        )
    }

    /// Core decision. `usages` maps account id → distilled usage (only accounts
    /// with real limit data belong here). `activeID` is the account you're
    /// logged into right now; without it we can't tell whether a target would
    /// even be a move, so we stay silent.
    public static func recommend(usages: [UUID: Usage], activeID: UUID?) -> Move? {
        guard let activeID, let active = usages[activeID] else { return nil }

        // Best account to land on: not blocked, most headroom. Exclude the
        // active one — moving onto yourself isn't a move.
        let target = usages
            .filter { $0.key != activeID && !$0.value.isBlocked }
            .min { $0.value.desirability < $1.value.desirability }

        if active.isBlocked {
            // Hard wall on the seat you're on → must move (if anywhere to go).
            guard let target else { return nil }
            let reason = active.weeklyBlocked
                ? "hit its weekly limit — blocked for days"
                : "hit its 5h limit — blocked until it resets"
            return Move(targetID: target.key, urgency: .mustMove, reason: reason)
        }

        // Not blocked: only a quiet nudge, and only if running hot AND a
        // clearly-fresher seat exists.
        guard active.peak >= hotThreshold, let target else { return nil }
        guard active.desirability - target.value.desirability >= minImprovement else { return nil }

        let reason: String
        if (active.weeklyPeakFrac ?? 0) >= hotThreshold {
            reason = "weekly limit almost full"
        } else {
            reason = "5h session almost gone"
        }
        return Move(targetID: target.key, urgency: .suggestion, reason: reason)
    }
}
