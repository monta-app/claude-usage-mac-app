import Foundation

/// Per-member spend "on top of" the Max/Team plan — the extra-usage cost shown
/// at claude.ai/admin-settings/usage. Uses the Claude Enterprise Analytics API:
///   GET /v1/organizations/analytics/user_cost_report
/// authenticated with an **Analytics API key** (read:analytics), created by the
/// org's primary owner at claude.ai → Org settings → API.
///
/// We request month-to-date for all products, filter to one member's email, and
/// sum `amount` (fractional cents → USD). Available only to Claude Enterprise
/// (usage-based) organizations.
enum ClaudeCodeSpend {

    enum Result: Equatable {
        case amount(Double)   // USD, month-to-date
        case noConfig         // no analytics key / email set
        case error(String)
        case loading
    }

    static func monthToDate(analyticsKey: String, email: String) async -> Result {
        guard !analyticsKey.isEmpty, !email.isEmpty else { return .noConfig }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month], from: Date())
        guard let monthStart = cal.date(from: comps) else { return .error("date error") }
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(identifier: "UTC")!
        let startRFC = iso.string(from: monthStart)   // e.g. 2026-07-01T00:00:00Z

        let lowerEmail = email.lowercased()
        var cents = 0.0
        var matched = false
        var page: String? = nil
        repeat {
            var comps2 = URLComponents(string: "https://api.anthropic.com/v1/organizations/analytics/user_cost_report")!
            comps2.queryItems = [
                URLQueryItem(name: "starting_at", value: startRFC),
                URLQueryItem(name: "limit", value: "1000")
                // ending_at omitted → defaults to now (month-to-date), all products.
            ] + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            var req = URLRequest(url: comps2.url!)
            req.setValue(analyticsKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.timeoutInterval = 25
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else { return .error("No response") }
                if http.statusCode == 401 || http.statusCode == 403 {
                    return .error("Analytics key rejected (Enterprise + read:analytics required)")
                }
                guard (200..<300).contains(http.statusCode) else { return .error("HTTP \(http.statusCode)") }
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .error("Unexpected response")
                }
                for row in (root["data"] as? [[String: Any]] ?? []) {
                    guard let actor = row["actor"] as? [String: Any],
                          let em = actor["email"] as? String,
                          em.lowercased() == lowerEmail else { continue }
                    matched = true
                    cents += Double((row["amount"] as? String) ?? "0") ?? 0
                }
                page = (root["has_more"] as? Bool == true) ? (root["next_page"] as? String) : nil
            } catch {
                return .error(error.localizedDescription)
            }
        } while page != nil

        // No matching row = the member had no billable usage this month → $0.
        _ = matched
        return .amount(cents / 100.0)
    }
}
