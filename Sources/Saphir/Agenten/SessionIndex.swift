import Foundation

/// Resolves the human name a session was given ("Login-Fehler beheben") instead of
/// falling back to its folder ("my-project").
///
/// Claude Code keeps one small file per running CLI in `~/.claude/sessions/`,
/// keyed by process id, containing `sessionId`, `name`, `cwd` and `status`. It is
/// rewritten as the session goes, so a short cache is enough to stay current.
enum SessionIndex {
    private static let directory = AgentenPfade.claudeSessions

    private static var cache: [String: String] = [:]
    /// Process id per session — the only reliable way back to the terminal when
    /// a hook event arrived without one.
    private static var pids: [String: Int] = [:]
    private static var lastScan: Date = .distantPast
    private static let lock = NSLock()
    private static let maxAge: TimeInterval = 1
    private static let pollInterval: TimeInterval = 1.5
    private static var watcher: Timer?

    /// The session's given name, or nil if it has none.
    static func name(for sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }

        // A session can be renamed at any time, so a cached hit is only good
        // while it is fresh — otherwise re-read the folder before answering.
        // Trusting the cache indefinitely meant a `/rename` kept showing the old
        // name until some unrelated lookup happened to miss and force a rescan.
        if Date().timeIntervalSince(lastScan) > maxAge { rescan() }
        return cache[sessionID]
    }

    /// The pid of the CLI running this session, while it is still running.
    static func pid(for sessionID: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastScan) > maxAge { rescan() }
        return pids[sessionID]
    }

    /// Force a refresh, e.g. when a session starts.
    static func invalidate() {
        lock.lock()
        lastScan = .distantPast
        lock.unlock()
    }

    /// Watches the index and calls `onChange` as soon as a name moves.
    ///
    /// Without this a rename would only surface on that session's next hook
    /// event, so a session renamed while it sits idle would keep its old title
    /// for as long as nothing else happened.
    @MainActor
    static func startWatching(onChange: @escaping @MainActor () -> Void) {
        watcher?.invalidate()
        watcher = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard namesChanged() else { return }
                onChange()
            }
        }
    }

    @MainActor
    static func stopWatching() {
        watcher?.invalidate()
        watcher = nil
    }

    /// Rescans and reports whether that moved any name.
    private static func namesChanged() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = cache
        rescan()
        return cache != before
    }

    private static func rescan() {
        lastScan = Date()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var fresh: [String: String] = [:]
        var freshPIDs: [String: Int] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["sessionId"] as? String else { continue }
            if let pid = obj["pid"] as? Int { freshPIDs[id] = pid }
            guard let name = obj["name"] as? String, !name.isEmpty else { continue }
            fresh[id] = name
        }
        // Keep names of sessions whose file has gone (the CLI exited but we may
        // still be showing the finished row). Pids are the opposite: once the
        // file is gone the process is too, and a stale pid points at nothing.
        cache.merge(fresh) { _, new in new }
        pids = freshPIDs
    }
}
