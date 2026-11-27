import Foundation

/// How much of the plan's usage limits is left, as last seen by Claude Code.
///
/// There is no command that prints this, and the usage API needs Claude Code's login from the keychain.
/// Instead Claude Code's status line script (`~/.claude/statusline.sh`) is given the limits with every
/// update and saves them to `~/.claude/rate-limits.json`, so the numbers are as fresh as the last session.
struct ClaudeUsage {
    struct Window {
        let usedPercentage: Double
        let resetsAt: Date

        /// Once the window has reset, nothing of the new one has been used until a session says otherwise.
        var leftPercentage: Int {
            resetsAt < Date() ? 100 : max(0, 100 - Int(usedPercentage.rounded()))
        }
    }

    let session: Window?
    let week: Window?

    static let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/rate-limits.json")

    static func load() -> ClaudeUsage? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = json[key] as? [String: Any],
                  let used = (w["used_percentage"] as? NSNumber)?.doubleValue,
                  let resets = (w["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let usage = ClaudeUsage(session: window("five_hour"), week: window("seven_day"))
        return usage.session == nil && usage.week == nil ? nil : usage
    }
}
