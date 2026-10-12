import Foundation

/// Anthropic's own usage figures — the only numbers that agree with `/usage` in
/// Claude Code, because they come from the same place.
///
/// They are not on disk anywhere: Claude Code hands them to **statusline
/// scripts** (field `rate_limits`, since 2.1.80) and nowhere else. So the app
/// registers a statusline script that posts the payload to `POST /statusline`
/// and prints back whatever line the app wants in the terminal.
///
/// Everything derived from transcripts stays as a fallback: it is a good guess
/// at token volume, but a guess only — measured against the biggest block ever
/// seen it read 3 % while Claude Code said 17 %, and its five-hour window ended
/// at 01:00 while the real one ends at 01:30.
struct RateLimits: Codable, Sendable {
    struct Window: Codable, Sendable {
        let usedPercentage: Int
        let resetsAt: Date

        var isCurrent: Bool { Date() < resetsAt }
        var freePercentage: Int { max(0, min(100, 100 - usedPercentage)) }
    }

    var fiveHour: Window?
    var sevenDay: Window?
    /// When Claude Code last told us. A quiet machine means stale numbers, and
    /// stale numbers can only ever under-report usage — so they get labelled.
    var capturedAt: Date

    var age: TimeInterval { Date().timeIntervalSince(capturedAt) }

    // MARK: - The statusline payload

    /// Pulls `rate_limits` out of a statusline payload. Returns nil when the
    /// field is absent, which is normal for older Claude Code versions.
    static func from(statusline payload: [String: Any]) -> RateLimits? {
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }

        func window(_ key: String) -> Window? {
            guard let raw = limits[key] as? [String: Any],
                  let used = raw["used_percentage"] as? Int ?? (raw["used_percentage"] as? Double).map(Int.init),
                  let resets = raw["resets_at"] as? Double ?? (raw["resets_at"] as? Int).map(Double.init)
            else { return nil }
            return Window(usedPercentage: used, resetsAt: Date(timeIntervalSince1970: resets))
        }

        let five = window("five_hour")
        let seven = window("seven_day")
        guard five != nil || seven != nil else { return nil }
        return RateLimits(fiveHour: five, sevenDay: seven, capturedAt: Date())
    }

    // MARK: - Keeping them across restarts

    private static var file: URL {
        AgentenPfade.rateLimits
    }

    static func load() -> RateLimits? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder.saphir.decode(RateLimits.self, from: data)
    }

    func save() {
        Ablage.anlegen()
        guard let data = try? JSONEncoder.saphir.encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

extension JSONDecoder {
    static let saphir: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

extension JSONEncoder {
    static let saphir: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}
