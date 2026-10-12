import AppKit
import Foundation
import SwiftUI

/// What we hand back to a blocked hook.
enum DecisionOutcome: Sendable {
    case allow(rule: String?)
    case deny(reason: String)
    /// Answers to an AskUserQuestion, keyed by the exact question text. Several
    /// selections in one question are joined with ", " — that is the shape the
    /// tool's own schema expects.
    case answers([String: String])
    /// Give up and let the agent fall back to its own terminal prompt.
    case passthrough
}

/// Der Motor hinter den Claude-Sessions: nimmt die Hook-Ereignisse entgegen,
/// fuehrt Buch ueber Sessions und offene Freigaben und haelt die Hooks an, bis
/// jemand entschieden hat.
///
/// Stammt aus Agent Island (siehe `doku/agenten-herkunft.md`). Er kennt die Insel
/// nicht: was sie angeht, geht ueber die `bei...`-Rueckrufe, die `AgentDienst`
/// beim Start einhaengt.
@MainActor
final class AgentenMotor: ObservableObject {
    static let shared = AgentenMotor()

    @Published private(set) var sessions: [MotorSession] = []
    /// Anthropic's own usage figures, as last reported by a statusline render.
    @Published var rateLimits: RateLimits? { didSet { checkQuotaLevel() } }
    @Published var serverPort: UInt16 = 0
    @Published var hooksInstalled: Bool = false

    /// Continuations of hooks currently blocked on a user decision.
    private var waiters: [String: CheckedContinuation<DecisionOutcome, Never>] = [:]

    // Die Verbindung zur Insel. Der Motor kennt sie nicht, `AgentDienst` haengt
    // diese Rueckrufe beim Start ein.
    /// Der Stand der Sessions hat sich geaendert.
    var beiAenderung: (() -> Void)?
    /// Etwas ist passiert, das man sehen soll, ohne antworten zu muessen:
    /// kurz aufklappen, die angegebenen Sekunden lang.
    var beiKurzZeigen: ((Double) -> Void)?
    /// Eine Zeile unter der Notch: Symbol, Text, Sekunden.
    var beiHinweis: ((String, String, Double) -> Void)?
    /// Auf- oder zuklappen von aussen (`POST /panel`).
    var beiPanel: ((Bool, Bool?) -> Void)?


    private init() {}

    // MARK: - Derived state

    /// Sessions worth showing, most urgent first, then most recently active.
    var visibleSessions: [MotorSession] {
        sessions.sorted { a, b in
            if a.state.rang != b.state.rang { return a.state.rang > b.state.rang }
            return a.lastEventAt > b.lastEventAt
        }
    }

    var wantsAttention: Bool {
        sessions.contains { $0.state == .needsApproval || $0.state == .needsInput }
    }

    /// The decision the expanded panel should put front and centre: the oldest
    /// one still waiting, so a queue drains in the order it arrived.
    var frontPending: (session: MotorSession, pending: PendingDecision)? {
        var best: (MotorSession, PendingDecision)?
        for session in sessions {
            guard let pending = session.pending else { continue }
            if let current = best, current.1.createdAt <= pending.createdAt { continue }
            best = (session, pending)
        }
        guard let best else { return nil }
        return (session: best.0, pending: best.1)
    }

    var summaryState: AgentZustand {
        visibleSessions.first?.state ?? .idle
    }

    var workingCount: Int { sessions.filter { $0.state == .working }.count }

    // MARK: - Session mutation

    private func index(of id: String) -> Int? {
        sessions.firstIndex { $0.id == id }
    }

    @discardableResult
    private func upsert(_ id: String, agent: AgentKind, cwd: String,
                        mutate: (inout MotorSession) -> Void) -> MotorSession {
        if let i = index(of: id) {
            sessions[i].lastEventAt = Date()
            if !cwd.isEmpty { sessions[i].cwd = cwd }
            // Sessions can be renamed mid-flight, so keep looking.
            if let title = SessionIndex.name(for: id) { sessions[i].title = title }
            mutate(&sessions[i])
            return sessions[i]
        }
        var s = MotorSession(id: id, agent: agent, cwd: cwd)
        s.title = SessionIndex.name(for: id)
        mutate(&s)
        sessions.append(s)
        return s
    }

    /// Folds the terminal context of an event into the session row.
    ///
    /// Only `SessionStart` and `UserPromptSubmit` used to store it, so a row
    /// first seen mid-session — after an app restart, or an update — knew no
    /// terminal at all and clicking it did nothing. A half-filled origin was
    /// just as bad: without a tty we could only raise the terminal app, which
    /// lands on whatever tab happens to be in front.
    private func absorbOrigin(_ event: HookEvent) {
        guard let i = index(of: event.sessionID) else { return }
        var origin = sessions[i].origin.merged(with: event.origin)
        // Last resort for the tty: the session index knows the CLI's pid, and a
        // process always knows its own terminal.
        if origin.pid == nil { origin.pid = SessionIndex.pid(for: event.sessionID) }
        if origin != sessions[i].origin { sessions[i].origin = origin }
    }

    /// Picks up a `/rename` right away. Titles otherwise only move when the
    /// session's next hook event arrives, which can be minutes later.
    func refreshTitles() {
        var changed = false
        for i in sessions.indices {
            guard let title = SessionIndex.name(for: sessions[i].id),
                  title != sessions[i].title else { continue }
            sessions[i].title = title
            changed = true
        }
        if changed { refreshNotch() }
    }

    func removeSession(_ id: String) {
        if let i = index(of: id) {
            if let pending = sessions[i].pending { resolve(requestID: pending.id, with: .passthrough) }
            sessions.remove(at: i)
        }
        refreshNotch()
    }

    func acknowledge(_ id: String) {
        guard let i = index(of: id) else { return }
        if sessions[i].state == .done || sessions[i].state == .failed {
            sessions.remove(at: i)
        } else {
            sessions[i].acknowledged = true
        }
        refreshNotch()
    }

    func clearFinished() {
        for s in sessions where s.state == .done || s.state == .failed {
            if let i = index(of: s.id) { sessions.remove(at: i) }
        }
        refreshNotch()
    }

    // MARK: - Event intake

    /// Handles one hook event. Returns a JSON body for the hook to print, or nil
    /// for "no opinion" (the agent then behaves normally).
    func handle(event: HookEvent) async -> [String: Any]? {
        let id = event.sessionID
        guard !id.isEmpty else { return nil }

        // Before the switch as well as after it: `PermissionRequest` answers from
        // inside the switch and would otherwise never contribute its origin.
        absorbOrigin(event)
        defer { absorbOrigin(event) }
        releaseIfAnsweredInTerminal(event)

        switch event.name {
        case "SessionStart":
            SessionIndex.invalidate()   // a brand-new session needs a fresh scan
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.origin = s.origin.merged(with: event.origin)
                s.state = .idle
                s.model = event.model
                s.permissionMode = event.permissionMode
                s.startedAt = Date()
            }
            Klang.spiele(.auf)

        case "UserPromptSubmit":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                if !event.origin.isEmpty { s.origin = event.origin }
                s.state = .working
                s.turnStartedAt = Date()
                s.toolCount = 0
                s.acknowledged = false
                s.lastMessage = nil
                s.errorText = nil
                s.activity = "denkt nach"
                s.permissionMode = event.permissionMode ?? s.permissionMode
                if let p = event.message, !p.isEmpty { s.lastPrompt = p }
            }

        case "PreToolUse":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.state = .working
                if s.turnStartedAt == nil { s.turnStartedAt = Date() }
                s.activity = Self.activityLabel(tool: event.toolName, input: event.toolInput)
            }

        case "PostToolUse":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.toolCount += 1
                s.state = .working
            }

        case "PostToolUseFailure":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.toolCount += 1
                s.activity = "\(event.toolName ?? "Tool") fehlgeschlagen"
            }

        case "SubagentStart":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.activity = "Subagent: \(event.agentType ?? "läuft")"
            }

        case "PreCompact":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.activity = "verdichtet Kontext"
            }

        case "PermissionRequest":
            return await handlePermissionRequest(event)

        case "Notification":
            handleNotification(event)

        case "Stop":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                // A decision may still be outstanding from a parallel tool batch;
                // that outranks "finished".
                guard s.pending == nil else { return }
                s.state = .done
                s.activity = nil
                s.lastMessage = event.lastAssistantMessage
                s.turnStartedAt = nil
            }
            Klang.spiele(.fertig)
            NotifCenter.shared.postDone(session: sessions.first { $0.id == id })
            peekNotch()

        case "StopFailure":
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                s.state = .failed
                s.activity = nil
                s.errorText = event.errorMessage ?? event.errorType
                s.turnStartedAt = nil
            }
            Klang.spiele(.fehler)
            peekNotch()

        case "SessionEnd":
            removeSession(id)

        default:
            // Generic /event pings from non-Claude agents land here.
            upsert(id, agent: event.agent, cwd: event.cwd) { s in
                if let st = event.explicitState { s.state = st }
                if let a = event.message { s.activity = a }
            }
        }

        refreshNotch()
        return nil
    }

    private func handleNotification(_ event: HookEvent) {
        let type = event.notificationType ?? ""
        switch type {
        case "permission_prompt", "agent_needs_input", "elicitation_dialog":
            // Claude is asking in the terminal and we could not intercept it —
            // surface it so the user at least knows, and can jump there.
            upsert(event.sessionID, agent: event.agent, cwd: event.cwd) { s in
                guard s.pending == nil else { return }  // already handled in-notch
                s.state = .needsInput
                s.activity = event.message
            }
            Klang.spiele(.erinnerung)
            NotifCenter.shared.postNeedsInput(message: event.message ?? "Claude braucht dich",
                                              session: sessions.first { $0.id == event.sessionID })
        case "idle_prompt":
            // Fires when a turn has ended and the prompt sits idle. If we already
            // know the turn finished, saying "waiting for your input" on top of
            // "fertig" just muddies the row.
            var wasWorking = false
            upsert(event.sessionID, agent: event.agent, cwd: event.cwd) { s in
                wasWorking = s.state == .working
                if wasWorking {
                    s.state = .needsInput
                    s.activity = event.message
                }
            }
            if wasWorking { Klang.spiele(.erinnerung) }
        case "agent_completed":
            upsert(event.sessionID, agent: event.agent, cwd: event.cwd) { s in
                s.state = .done
                s.activity = nil
            }
            peekNotch()
        default:
            break
        }
    }

    // MARK: - Approvals

    /// Drops the card of a request the user answered in the terminal instead.
    ///
    /// Answering "yes" there does not touch the hook at all: Claude Code leaves
    /// it running, so its connection stays open and the hangup watcher in
    /// `HTTPServer` never fires. The only trace is what the session does next —
    /// the tool finishing, or the turn moving on. A `PostToolUse` counts only for
    /// the very tool and input that was asked about, because other tool calls
    /// (subagents) report in on the same session while a question is open.
    private func releaseIfAnsweredInTerminal(_ event: HookEvent) {
        guard let i = index(of: event.sessionID), let pending = sessions[i].pending else { return }
        switch event.name {
        case "PostToolUse", "PostToolUseFailure":
            // AskUserQuestion comes back with `answers` added, so the input of
            // the request only has to be contained in it.
            guard event.toolName == pending.toolName,
                  pending.toolInput.allSatisfy({ event.toolInput[$0.key] == $0.value }) else { return }
        case "UserPromptSubmit", "Stop", "StopFailure":
            break
        default:
            return
        }
        // Cleared here and not by the waiter: it resumes only after this event
        // has set its own state, and would overwrite a `.done` with `.working`.
        sessions[i].pending = nil
        resolve(requestID: pending.id, with: .passthrough)
    }

    private func handlePermissionRequest(_ event: HookEvent) async -> [String: Any]? {
        guard AgentenOptionen.shared.freigabenInInsel else { return nil }
        let tool = event.toolName ?? "Tool"

        // Tools the user has waved through permanently are answered instantly.
        if AgentenOptionen.shared.istSchonErlaubt(werkzeug: tool, eingabe: event.toolInput) {
            return PermissionResponse.allow()
        }

        let kind: PendingKind
        switch tool {
        case "ExitPlanMode": kind = .plan
        case "AskUserQuestion": kind = .question
        default: kind = .permission
        }

        let requestID = UUID().uuidString
        let pending = PendingDecision(
            id: requestID,
            sessionID: event.sessionID,
            kind: kind,
            toolName: tool,
            toolInput: event.toolInput,
            createdAt: Date(),
            questions: Self.parseQuestions(event.toolInput)
        )

        upsert(event.sessionID, agent: event.agent, cwd: event.cwd) { s in
            if !event.origin.isEmpty { s.origin = event.origin }
            s.pending = pending
            s.state = .needsApproval
            s.activity = Self.activityLabel(tool: tool, input: event.toolInput)
        }
        NotifCenter.shared.postApproval(pending: pending,
                                        session: sessions.first { $0.id == event.sessionID })
        refreshNotch()

        // If the hook process dies (user hit Esc, agent exited), the server cancels
        // this task and we must resume the continuation or leak it forever.
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<DecisionOutcome, Never>) in
                waiters[requestID] = cont
                armTimeout(for: requestID)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(requestID: requestID, with: .passthrough)
            }
        }

        // Clear the pending marker whichever way it went. A cancelled task means
        // the hook was killed: the user said no or hit Esc in the terminal, and
        // nothing follows that turn — the session is waiting for them, not working.
        if let i = index(of: event.sessionID), sessions[i].pending?.id == requestID {
            sessions[i].pending = nil
            sessions[i].state = Task.isCancelled ? .idle : .working
        }
        refreshNotch()

        switch outcome {
        case .allow(let rule):
            if let rule { AgentenOptionen.shared.merkeImmerErlaubt(rule) }
            return PermissionResponse.allow(rule: rule)
        case .deny(let reason):
            return PermissionResponse.deny(reason: reason)
        case .answers(let answers):
            return PermissionResponse.answers(answers, input: event.toolInput)
        case .passthrough:
            return nil
        }
    }

    private func armTimeout(for requestID: String) {
        let seconds = AgentenOptionen.shared.freigabeFrist
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.waiters[requestID] != nil else { return }
                // Hand control back to the terminal rather than blocking forever.
                self.resolve(requestID: requestID, with: .passthrough)
            }
        }
    }

    /// Called by the UI, and by the server when the hook's connection dies.
    func resolve(requestID: String, with outcome: DecisionOutcome) {
        guard let cont = waiters.removeValue(forKey: requestID) else { return }
        cont.resume(returning: outcome)
    }

    /// Answer whatever the given session is waiting for. Same path the buttons
    /// take, exposed over the local API so approvals can also be scripted or
    /// driven from another device.
    /// Returns false when that session has nothing pending.
    @discardableResult
    func decide(sessionID: String?, decision: String, reason: String?,
                answers: [String: String]? = nil) -> Bool {
        let target: MotorSession?
        if let sessionID {
            target = sessions.first { $0.id == sessionID && $0.pending != nil }
        } else {
            target = frontPending?.session
        }
        guard let session = target, let pending = session.pending else { return false }

        switch decision.lowercased() {
        case "allow", "yes":
            resolve(requestID: pending.id, with: .allow(rule: nil))
        case "always":
            resolve(requestID: pending.id, with: .allow(rule: pending.suggestedRule))
        case "deny", "no":
            resolve(requestID: pending.id, with: .deny(reason: reason ?? "Abgelehnt"))
        case "answer":
            // Answers may be keyed by question text or, for convenience from a
            // phone, given as a single label for a single-question call.
            guard pending.kind == .question else { return false }
            var filled = answers ?? [:]
            if filled.isEmpty, let label = reason, pending.questions.count == 1,
               let question = pending.questions.first {
                filled[question.question] = label
            }
            guard !filled.isEmpty else { return false }
            resolve(requestID: pending.id, with: .answers(filled))
        default:
            return false
        }
        return true
    }

    /// Focus the terminal a session lives in. With no id, the most urgent one.
    @discardableResult
    func jump(to sessionID: String?) -> Bool {
        let target = sessionID.flatMap { id in sessions.first { $0.id == id } }
                     ?? visibleSessions.first
        guard let session = target else { return false }
        TerminalJumper.jump(to: session.origin, cwd: session.cwd)
        return true
    }

    func cancelWaiters(matching sessionID: String) {
        for (id, _) in waiters {
            if sessions.first(where: { $0.pending?.id == id })?.id == sessionID {
                resolve(requestID: id, with: .passthrough)
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Kontingent-Ampel

    private var lastQuotaLevel: QuotaLevel?

    /// Anteil des verbrauchten Kontingents: Anthropics eigene Zahl, solange sie
    /// aktuell ist. Eine Schaetzung aus den Transcripts gibt es nicht mehr, sie
    /// lag gemessen um Groessenordnungen daneben.
    private var usedFraction: Double? {
        guard let five = rateLimits?.fiveHour, five.isCurrent else { return nil }
        return Double(five.usedPercentage) / 100
    }

    /// Springt die Ampel auf eine schlechtere Farbe, sagt die Insel einmal
    /// Bescheid. Ein besserer Stand (nach dem Reset) nimmt die Warnung
    /// stillschweigend wieder weg, und beim allerersten Messwert gibt es keine:
    /// wer die App bei 8 % Rest startet, hat das nicht gerade eben verursacht.
    private func checkQuotaLevel() {
        guard let used = usedFraction else { return }
        let level = QuotaLevel.forFree(1 - used)
        defer { lastQuotaLevel = level }
        guard let previous = lastQuotaLevel, level > previous else { return }

        let free = Int(((1 - used) * 100).rounded())
        Protokoll.info("Kontingent-Ampel: \(previous) → \(level) (\(free) % frei)")
        guard AgentenOptionen.shared.kontingentZeigen else { return }
        // Nur eine Zeile, nicht die ganze Insel: wer gerade arbeitet, will hier
        // keine Sessionliste vor die Nase gesetzt bekommen. Mit Ton, weil
        // knappes Kontingent sonst erst auffaellt, wenn nichts mehr geht.
        beiHinweis?("exclamationmark.triangle.fill", level.warning(freePercent: free), 6)
        Klang.spiele(level == .red ? .fehler : .zu)
    }

    /// Show the panel for a moment because something happened that the user
    /// should see but does not have to answer.
    private func peekNotch() {
        guard AgentenOptionen.shared.beiFertigAufklappen else { return }
        beiKurzZeigen?(AgentenOptionen.shared.aufklappDauer)
    }

    private func refreshNotch() {
        objectWillChange.send()
        beiAenderung?()
    }

    /// Auf- oder zuklappen von aussen, ueber `POST /panel`.
    func panel(open: Bool, pin: Bool?) {
        beiPanel?(open, pin)
    }

    /// Takes a statusline payload and answers with the line to print in the
    /// terminal. The payload is the only place Claude Code publishes its real
    /// rate limits, so this is where the good numbers enter the app.
    func applyStatusline(_ payload: [String: Any]) -> String {
        if let limits = RateLimits.from(statusline: payload) {
            rateLimits = limits
            limits.save()
            beiAenderung?()
        }
        guard AgentenOptionen.shared.kontingentZeigen else { return "" }

        var parts: [String] = []
        if let model = (payload["model"] as? [String: Any])?["display_name"] as? String {
            parts.append(model)
        }
        if let five = rateLimits?.fiveHour, five.isCurrent {
            parts.append("5h \(five.usedPercentage) %")
            parts.append("Reset \(Self.clock.string(from: five.resetsAt))")
        }
        if let seven = rateLimits?.sevenDay, seven.isCurrent {
            parts.append("Woche \(seven.usedPercentage) %")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func rateLimitsJSON() -> Any {
        guard let limits = rateLimits else { return NSNull() }
        func window(_ w: RateLimits.Window?) -> Any {
            guard let w else { return NSNull() }
            return ["usedPercentage": w.usedPercentage,
                    "resetsAt": ISO8601DateFormatter.saphir.string(from: w.resetsAt)]
        }
        return ["fiveHour": window(limits.fiveHour),
                "sevenDay": window(limits.sevenDay),
                "capturedAt": ISO8601DateFormatter.saphir.string(from: limits.capturedAt)]
    }

    /// Machine-readable view of the app, served on `GET /state`. Handy for
    /// scripting and for checking the app is alive without opening the panel.
    func stateSnapshot() -> [String: Any] {
        [
            "port": Int(serverPort),
            "hooksInstalled": hooksInstalled,
            // Anthropic's own numbers, straight from the statusline payload.
            "rateLimits": rateLimitsJSON(),
            "sessions": sessions.map { session -> [String: Any] in
                var row: [String: Any] = [
                    "id": session.id,
                    "agent": session.agent.rawValue,
                    "cwd": session.cwd,
                    "project": session.projectName,
                    "name": session.displayName,
                    "state": session.state.rawValue,
                    "tools": session.toolCount
                ]
                if let activity = session.activity { row["activity"] = activity }
                if let duration = session.turnDuration { row["seconds"] = Int(duration) }
                row["terminal"] = [
                    "app": session.origin.appLabel,
                    "tty": session.origin.tty ?? "",
                    "tmux": session.origin.tmuxPane ?? "",
                    "precision": TerminalJumper.precision(for: session.origin)
                ]
                if let pending = session.pending {
                    var block: [String: Any] = ["kind": pending.kind.rawValue,
                                                "tool": pending.toolName]
                    // A remote client can only answer a question if it knows
                    // what was asked — all of it, not just the first one.
                    if pending.kind == .question {
                        block["questions"] = pending.questions.map { q -> [String: Any] in
                            ["question": q.question,
                             "header": q.header,
                             "multiSelect": q.multiSelect,
                             "options": q.options.map { ["label": $0.label,
                                                         "description": $0.description] }]
                        }
                    }
                    row["pending"] = block
                }
                return row
            }
        ]
    }

    static func activityLabel(tool: String?, input: [String: JSONValue]) -> String {
        guard let tool else { return "arbeitet" }
        switch tool {
        case "Bash":
            let cmd = input["command"]?.stringValue ?? ""
            return "Bash · " + String(cmd.prefix(60))
        case "Read", "Write", "Edit":
            let p = input["file_path"]?.stringValue ?? ""
            return "\(tool) · " + (p as NSString).lastPathComponent
        case "Grep", "Glob":
            return "\(tool) · " + String((input["pattern"]?.stringValue ?? "").prefix(40))
        case "WebFetch", "WebSearch":
            return "\(tool) · " + String((input["url"]?.stringValue ?? input["query"]?.stringValue ?? "").prefix(50))
        case "Task", "Agent":
            return "Subagent · " + String((input["description"]?.stringValue ?? "").prefix(40))
        case "ExitPlanMode":
            return "Plan fertig"
        default:
            return tool
        }
    }

    /// AskUserQuestion nests: questions[] with question/header/multiSelect and
    /// options[] of label/description. All of them, not just the first — the
    /// call is only answered once every question has a selection.
    static func parseQuestions(_ input: [String: JSONValue]) -> [PendingQuestion] {
        guard case .array(let raw)? = input["questions"] else { return [] }
        return raw.compactMap { item in
            guard case .object(let q) = item,
                  let text = q["question"]?.stringValue,
                  case .array(let rawOptions)? = q["options"] else { return nil }
            let options: [QuestionOption] = rawOptions.compactMap { opt in
                guard case .object(let o) = opt, let label = o["label"]?.stringValue else { return nil }
                return QuestionOption(label: label, description: o["description"]?.stringValue ?? "")
            }
            guard !options.isEmpty else { return nil }
            var multi = false
            if case .bool(let flag)? = q["multiSelect"] { multi = flag }
            return PendingQuestion(question: text,
                                   header: q["header"]?.stringValue ?? "",
                                   multiSelect: multi,
                                   options: options)
        }
    }
}

/// JSON bodies for the PermissionRequest hook contract.
///
/// The reason is sent under both `decision.message` and the top-level
/// `permissionDecisionReason`, because the two hook families spell it
/// differently and an extra key is harmless.
enum PermissionResponse {
    static func allow(rule: String? = nil, updatedInput: [String: Any]? = nil) -> [String: Any] {
        var decision: [String: Any] = ["behavior": "allow"]
        if let updatedInput { decision["updatedInput"] = updatedInput }
        if let rule {
            decision["ruleToAdd"] = ["type": "allow", "pattern": rule]
        }
        return [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ]
    }

    static func deny(reason: String) -> [String: Any] {
        [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": reason],
                "permissionDecisionReason": reason
            ]
        ]
    }

    /// Answering an AskUserQuestion from outside the terminal.
    ///
    /// The tool takes its answers as part of its own input: `answers` maps each
    /// question's exact text to the chosen label (several labels joined with
    /// ", "). Allowing the call with that field filled in is precisely what the
    /// terminal dialog does when it resolves the permission request — the tool
    /// then runs without asking again and hands the model a proper result.
    ///
    /// Denying with the answer in the reason (what we did before) reached the
    /// model only as an error, carried no question→answer mapping, and silently
    /// dropped every question after the first.
    static func answers(_ answers: [String: String], input: [String: JSONValue]) -> [String: Any] {
        var updated = input.mapValues(\.anyValue)
        updated["answers"] = answers
        return allow(updatedInput: updated)
    }
}

extension TerminalOrigin {
    var isEmpty: Bool {
        app == nil && tty == nil && itermSessionID == nil && tmuxPane == nil && pid == nil
    }
}

extension ISO8601DateFormatter {
    static let saphir: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
