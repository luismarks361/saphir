import Foundation

/// One normalised event coming off the wire.
///
/// Claude Code hooks post their raw payload; the wrapper script adds a `_saphir`
/// object carrying terminal context that only the child process can see.
struct HookEvent: Sendable {
    var name: String
    var agent: AgentKind
    var sessionID: String
    var cwd: String
    var origin: TerminalOrigin

    var toolName: String?
    var toolInput: [String: JSONValue] = [:]
    var message: String?
    var notificationType: String?
    var lastAssistantMessage: String?
    var errorType: String?
    var errorMessage: String?
    var permissionMode: String?
    var model: String?
    var agentType: String?
    var explicitState: AgentZustand?

    static func parse(_ data: Data) -> HookEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func str(_ key: String) -> String? { root[key] as? String }

        // The wrapper adds this; a raw hook post (e.g. an http-type hook wired by
        // hand) simply has none, and we degrade to "unknown terminal".
        let island = root["_saphir"] as? [String: Any] ?? [:]

        // The shell hook always sends every key, using "" for anything unset —
        // so an empty string has to be treated as absent, not as a value.
        func field(_ key: String) -> String? {
            guard let value = island[key] as? String, !value.isEmpty else { return nil }
            return value
        }

        var origin = TerminalOrigin()
        origin.app = field("term_program")
        origin.bundleID = field("bundle_id")
        origin.tty = field("tty")
        origin.termSessionID = field("term_session_id")
        origin.itermSessionID = field("iterm_session_id")
        origin.tmuxPane = field("tmux_pane")
        origin.tmuxSocket = field("tmux")
        origin.weztermPane = field("wezterm_pane")
        origin.kittyWindowID = field("kitty_window_id")
        origin.sshClient = field("ssh_client")
        if let pid = island["pid"] as? Int { origin.pid = pid }
        else if let pidStr = island["pid"] as? String { origin.pid = Int(pidStr) }

        let agentRaw = (island["agent"] as? String) ?? "claude"
        let agent = AgentKind(rawValue: agentRaw) ?? .claude

        let name = str("hook_event_name") ?? str("event") ?? "Unknown"

        var event = HookEvent(
            name: name,
            agent: agent,
            sessionID: str("session_id") ?? str("sessionId") ?? "",
            cwd: str("cwd") ?? (island["cwd"] as? String) ?? "",
            origin: origin
        )

        event.toolName = str("tool_name")
        if let input = root["tool_input"],
           let data = try? JSONSerialization.data(withJSONObject: input),
           let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            event.toolInput = decoded
        }
        event.message = str("message") ?? str("prompt")
        event.notificationType = str("notification_type")
        event.lastAssistantMessage = str("last_assistant_message")
        event.errorType = str("error_type")
        event.errorMessage = str("error_message")
        event.permissionMode = str("permission_mode")
        event.agentType = str("agent_type")
        event.model = str("model") ?? (root["effort"] as? [String: Any])?["level"] as? String
        if let s = str("state") { event.explicitState = AgentZustand(rawValue: s) }

        return event
    }
}
