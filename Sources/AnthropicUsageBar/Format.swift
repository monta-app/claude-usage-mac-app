import Foundation

enum Format {
    static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    static func tokens(_ n: Int) -> String {
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

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
