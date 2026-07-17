import Foundation

enum AppVersion {
    /// Short git SHA this app was built from. "dev" if unset.
    static let sha: String = "dev"
    /// Date-based version: YYYYMMDD-HHMMSS-<short-sha>. "dev" if unset.
    static let version: String = "dev"
    static let repo = "monta-app/claude-usage-mac-app"
}
