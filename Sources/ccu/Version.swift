import Foundation

public enum CCUVersion {
    /// Short git SHA this binary was built from. "dev" if unset.
    public static let sha: String = "dev"
    /// Date-based version: YYYYMMDD-HHMMSS-<short-sha>. "dev" if unset.
    public static let version: String = "dev"
    public static let repo = "monta-app/claude-usage-mac-app"
    public static let assetName = "ccu.tar.gz"
}
