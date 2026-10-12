import Foundation
import SwiftUI

// MARK: - Agent kinds

/// Which CLI produced an event. Claude Code is first-class (full lifecycle +
/// approvals); the others report progress through the generic `/event` endpoint.
enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case gemini
    case cursor
    case opencode
    case aider
    case generic

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .cursor: return "Cursor"
        case .opencode: return "opencode"
        case .aider: return "Aider"
        case .generic: return "Agent"
        }
    }

    /// Short mark drawn in the session badge.
    var glyph: String {
        switch self {
        case .claude: return "✳"
        case .codex: return "◆"
        case .gemini: return "✦"
        case .cursor: return "▸"
        case .opencode: return "◈"
        case .aider: return "⌘"
        case .generic: return "●"
        }
    }
}

// MARK: - Quota level

/// Ampelstufe des Kontingents, gemessen an dem, was noch **frei** ist.
enum QuotaLevel: Int, Comparable, Sendable {
    case green, yellow, red

    static func < (a: QuotaLevel, b: QuotaLevel) -> Bool { a.rawValue < b.rawValue }

    static func forFree(_ free: Double) -> QuotaLevel {
        if free <= 0.10 { return .red }
        if free <= 0.25 { return .yellow }
        return .green
    }

    var color: Color {
        switch self {
        case .green: return AgentZustand.done.farbe
        case .yellow: return AgentZustand.needsApproval.farbe
        case .red: return AgentZustand.failed.farbe
        }
    }

    /// Was in der Warnung steht, wenn die Ampel hierher springt.
    func warning(freePercent: Int) -> String {
        switch self {
        case .red: return "Kontingent fast leer · \(freePercent) % frei"
        case .yellow: return "Kontingent knapp · \(freePercent) % frei"
        case .green: return "Kontingent wieder frei"
        }
    }
}

// MARK: - Terminal origin

/// Everything we need to jump back to the exact place a session lives.
/// Captured by the hook script from its own environment, which it inherits
/// from the agent CLI process.
struct TerminalOrigin: Codable, Hashable, Sendable {
    var app: String?             // TERM_PROGRAM, e.g. "iTerm.app", "Apple_Terminal", "ghostty"
    var bundleID: String?        // __CFBundleIdentifier when present
    var tty: String?             // /dev/ttys004 — the controlling terminal of the CLI
    var termSessionID: String?   // Terminal.app TERM_SESSION_ID
    var itermSessionID: String?  // iTerm2 ITERM_SESSION_ID ("w0t0p0:UUID")
    var tmuxPane: String?        // TMUX_PANE, e.g. "%3"
    var tmuxSocket: String?      // TMUX, e.g. "/private/tmp/tmux-501/default,1234,0"
    var weztermPane: String?
    var kittyWindowID: String?
    var pid: Int?                // pid of the agent CLI process
    var sshClient: String?       // set when the agent runs over SSH

    var isRemote: Bool { sshClient?.isEmpty == false }

    /// True when we know nothing at all about where the session runs.
    var isBlank: Bool {
        app == nil && bundleID == nil && tty == nil && itermSessionID == nil
            && tmuxPane == nil && weztermPane == nil && kittyWindowID == nil && pid == nil
    }

    /// Folds a newly seen origin into this one, field by field.
    ///
    /// Every hook event carries the terminal context, but a single event can be
    /// missing a field (the tty read can come back empty), and a row rebuilt
    /// from a mid-session event starts out with nothing at all. Merging means
    /// the row ends up with the most complete picture anyone has reported,
    /// instead of whatever happened to arrive first.
    func merged(with other: TerminalOrigin) -> TerminalOrigin {
        func pick(_ new: String?, _ old: String?) -> String? {
            if let new, !new.isEmpty { return new }
            return old
        }
        var out = self
        out.app = pick(other.app, app)
        out.bundleID = pick(other.bundleID, bundleID)
        out.tty = pick(other.tty, tty)
        out.termSessionID = pick(other.termSessionID, termSessionID)
        out.itermSessionID = pick(other.itermSessionID, itermSessionID)
        out.tmuxPane = pick(other.tmuxPane, tmuxPane)
        out.tmuxSocket = pick(other.tmuxSocket, tmuxSocket)
        out.weztermPane = pick(other.weztermPane, weztermPane)
        out.kittyWindowID = pick(other.kittyWindowID, kittyWindowID)
        out.sshClient = pick(other.sshClient, sshClient)
        out.pid = other.pid ?? pid
        return out
    }

    /// Best-effort human label for the terminal.
    var appLabel: String {
        if let app, !app.isEmpty {
            switch app {
            case "Apple_Terminal": return "Terminal"
            case "iTerm.app": return "iTerm2"
            case "vscode": return "VS Code"
            default: return app.replacingOccurrences(of: ".app", with: "").capitalized
            }
        }
        if isRemote { return "SSH" }
        return "Terminal"
    }
}

// MARK: - Pending decisions

/// What kind of thing is blocking, which decides how the panel renders it.
enum PendingKind: String, Codable, Sendable {
    case permission   // ordinary tool permission (Bash, Edit, Write, MCP…)
    case plan         // ExitPlanMode — render the plan as markdown
    case question     // AskUserQuestion — render the options as buttons
}

/// A blocked hook waiting for the user to click something in the notch.
struct PendingDecision: Identifiable, Sendable {
    let id: String              // request id, generated by us
    let sessionID: String
    let kind: PendingKind
    let toolName: String
    let toolInput: [String: JSONValue]
    let createdAt: Date
    /// Every question in the call, in order — AskUserQuestion may ask up to four
    /// at once, and answering only the first one loses the rest.
    var questions: [PendingQuestion] = []

    /// The one-line summary shown in the header.
    var headline: String {
        switch kind {
        case .plan: return "Plan freigeben"
        case .question:
            guard let first = questions.first else { return "Frage beantworten" }
            return questions.count > 1
                ? "\(questions.count) Fragen · \(first.question)"
                : first.question
        case .permission: return toolName
        }
    }

    /// The body we render under the headline: command, diff, plan markdown…
    var detail: String {
        switch kind {
        case .plan:
            if case .string(let p)? = toolInput["plan"] { return p }
            return ""
        case .question:
            return ""
        case .permission:
            return PendingDecision.summarize(tool: toolName, input: toolInput)
        }
    }

    /// A compact, human-readable rendering of a tool call.
    static func summarize(tool: String, input: [String: JSONValue]) -> String {
        func str(_ key: String) -> String? {
            if case .string(let s)? = input[key] { return s }
            return nil
        }
        switch tool {
        case "Bash", "BashOutput":
            var out = str("command") ?? ""
            if let d = str("description"), !d.isEmpty { out = "# \(d)\n" + out }
            return out
        case "Write":
            let path = str("file_path") ?? ""
            let content = str("content") ?? ""
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(path)\n\n\(lines) Zeilen schreiben"
        case "Edit":
            let path = str("file_path") ?? ""
            let old = str("old_string") ?? ""
            let new = str("new_string") ?? ""
            return "\(path)\n\n- \(old.prefix(400))\n+ \(new.prefix(400))"
        case "Read":
            return str("file_path") ?? ""
        case "WebFetch":
            return str("url") ?? ""
        case "Glob", "Grep":
            return str("pattern") ?? ""
        default:
            // MCP tools and anything unknown: pretty-print the input.
            let pairs = input
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.compactDescription)" }
            return pairs.joined(separator: "\n")
        }
    }

    /// Suggested permission rule for the "immer erlauben" button, e.g. `Bash(npm test:*)`.
    ///
    /// Returns nil when a standing rule would be irresponsible — the button is
    /// then hidden and the call can only be allowed this one time.
    var suggestedRule: String? {
        switch toolName {
        case "Bash":
            guard case .string(let raw)? = toolInput["command"] else { return nil }
            let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // A rule is a prefix match, so a compound command could smuggle
            // anything in behind the part we match on. Only single commands
            // ever earn a standing rule.
            guard !cmd.contains(where: { "&|;`\n".contains($0) }),
                  !cmd.contains("$("),
                  !PendingDecision.isDangerous(cmd) else { return nil }
            // Two words is a useful granularity: `npm test`, `git status`.
            let words = cmd.split(separator: " ").prefix(2).joined(separator: " ")
            return words.isEmpty ? nil : "Bash(\(words):*)"
        case "Read", "Write", "Edit":
            guard case .string(let path)? = toolInput["file_path"] else { return nil }
            let dir = (path as NSString).deletingLastPathComponent
            // Refuse to hand out a whole home or system directory.
            guard PendingDecision.isSafeDirectoryForRule(dir) else { return nil }
            return "\(toolName)(\(dir)/**)"
        case "WebFetch", "WebSearch":
            return nil   // varies per URL; a standing rule says nothing useful
        default:
            return toolName
        }
    }

    /// Commands where a standing "always allow" is a bad idea, because the same
    /// two leading words can do something entirely different next time.
    static func isDangerous(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let firstToken = lowered.split(separator: " ").first.map(String.init) ?? ""
        let destructive: Set<String> = [
            "rm", "rmdir", "sudo", "dd", "mkfs", "diskutil", "shutdown", "reboot",
            "killall", "pkill", "kill", "chown", "chmod", "launchctl", "defaults",
            "csrutil", "spctl", "security", "scutil", "nvram", "systemsetup"
        ]
        if destructive.contains(firstToken) { return true }
        // Piping a download straight into a shell, force pushes, history rewrites.
        let phrases = ["| sh", "|sh", "| bash", "|bash", "push --force", "push -f",
                       "reset --hard", "> /dev/", "mv /", "curl -s http", "eval "]
        return phrases.contains { lowered.contains($0) }
    }

    /// A directory is only rule-worthy if it is meaningfully deep inside the
    /// user's own files — never `~`, `/`, `/etc`, `~/.ssh` and friends.
    static func isSafeDirectoryForRule(_ dir: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard dir.hasPrefix(home), dir != home else { return false }
        let relative = String(dir.dropFirst(home.count))
        // Hidden config folders hold credentials; keep them out.
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
        // At least two levels below home, e.g. ~/Desktop/Projekt.
        return relative.split(separator: "/").count >= 2
    }
}

struct QuestionOption: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let description: String
}

/// One question of an AskUserQuestion call. A call carries up to four of them,
/// each with its own options and its own single/multiple choice mode.
struct PendingQuestion: Identifiable, Sendable {
    let id = UUID()
    /// The exact question text — this is the key the answer must be filed under.
    let question: String
    /// Short chip label ("Praktikumsart"), used for the progress line.
    let header: String
    let multiSelect: Bool
    let options: [QuestionOption]

    var title: String { header.isEmpty ? question : header }
}

// MARK: - Session

struct MotorSession: Identifiable, Sendable {
    let id: String                 // agent's session id
    var agent: AgentKind
    var cwd: String
    var state: AgentZustand = .idle
    var origin: TerminalOrigin = TerminalOrigin()

    var startedAt: Date = Date()
    var lastEventAt: Date = Date()
    /// When the current turn began — the timer shown in the row.
    var turnStartedAt: Date?

    var model: String?
    var permissionMode: String?
    /// Name the user gave the session in Claude Code, if any.
    var title: String?

    /// What the agent is doing right now, e.g. "Bash · npm test".
    var activity: String?
    /// Last assistant message, shown when the session is done.
    var lastMessage: String?
    /// Reason we are in `.failed`.
    var errorText: String?
    /// The user's most recent prompt — the best label for what the session is about.
    var lastPrompt: String?

    var pending: PendingDecision?
    /// Tools completed this turn, for the little counter.
    var toolCount: Int = 0
    /// Set while the user has explicitly dismissed a `done` session.
    var acknowledged: Bool = false

    var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// What to call this session on screen: the name it was given in Claude Code
    /// if there is one, otherwise the project folder.
    var displayName: String {
        title ?? projectName
    }

    /// True when the name differs from the folder, so the folder is worth showing
    /// as a second line.
    var hasDistinctTitle: Bool {
        guard let title else { return false }
        return title != projectName
    }

    var turnDuration: TimeInterval? {
        guard let turnStartedAt else { return nil }
        return Date().timeIntervalSince(turnStartedAt)
    }
}

// MARK: - Minimal JSON value

/// A tiny `Codable` JSON tree. We need to carry arbitrary `tool_input` payloads
/// around without knowing their shape, and `Any` is not `Sendable`.
enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Back to plain Foundation objects, so a tool input we received can be
    /// handed straight back to the hook as `updatedInput`.
    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    /// Single-line rendering used in tool-input summaries.
    var compactDescription: String {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map(\.compactDescription).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.compactDescription)" }
                .joined(separator: ", ") + "}"
        }
    }
}
