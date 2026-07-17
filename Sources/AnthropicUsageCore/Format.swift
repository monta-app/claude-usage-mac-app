import Foundation

public enum Format {
    public static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    public static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", d / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", d / 1_000)
        default:
            return "\(n)"
        }
    }

    /// Reset clock time in the user's LOCAL timezone. Same-day → "3:00 PM";
    /// otherwise "Jul 12, 12:00 PM".
    public static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "MMM d, h:mm a"
        return f.string(from: date)
    }

    public static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

public extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
