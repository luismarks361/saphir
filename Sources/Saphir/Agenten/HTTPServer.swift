import Foundation
import Network

/// A deliberately small HTTP/1.1 server bound to loopback only.
///
/// The hook script POSTs here and, for permission requests, keeps the connection
/// open until the user clicks something in the notch. That is the whole IPC
/// mechanism — no sockets to clean up, no daemon, no cloud.
final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "saphir.http", qos: .userInitiated)
    private(set) var port: UInt16 = 0
    let token: String

    /// Where the hook script looks up port and token.
    static let endpointURL = AgentenPfade.endpoint

    init() {
        self.token = HTTPServer.loadOrCreateToken()
    }

    // MARK: - Lifecycle

    func start(preferredPort: UInt16 = 8520) throws {
        var lastError: Error?
        // Walk a small range so a second Mac user or a stale process can't wedge us.
        for candidate in preferredPort..<(preferredPort + 20) {
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredInterfaceType = .loopback
                params.includePeerToPeer = false

                guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
                let listener = try NWListener(using: params, on: nwPort)
                listener.newConnectionHandler = { [weak self] conn in
                    self?.accept(conn)
                }
                listener.stateUpdateHandler = { state in
                    if case .failed(let err) = state {
                        Protokoll.fehler("Listener failed: \(err)")
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
                self.port = candidate
                try writeEndpointFile()
                Protokoll.info("HTTP-Server läuft auf 127.0.0.1:\(candidate)")
                return
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? AgentenFehler.message("Kein freier Port gefunden")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: Self.endpointURL)
    }

    private func writeEndpointFile() throws {
        try FileManager.default.createDirectory(at: Ablage.ordner,
                                                withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "port": Int(port),
            "token": token,
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: Self.endpointURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.endpointURL.path)
    }

    private static func loadOrCreateToken() -> String {
        let url = AgentenPfade.token
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        try? FileManager.default.createDirectory(at: Ablage.ordner,
                                                 withIntermediateDirectories: true)
        try? token.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
        return token
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        let handler = ConnectionHandler(connection: conn, token: token, queue: queue)
        handler.run()
    }
}

/// Reads one request, dispatches it, writes one response, closes.
private final class ConnectionHandler {
    private let connection: NWConnection
    private let token: String
    /// Every mutation of `responded`/`work` hops onto this queue, so the peer
    /// watchdog and the answering task can never race each other.
    private let queue: DispatchQueue
    private var buffer = Data()
    private var work: Task<Void, Never>?
    /// Set once we have handed a response to the socket, so the watchdog can tell
    /// our own close apart from the hook dying.
    private var responded = false
    /// Retains the handler until the exchange is finished.
    private var selfRef: ConnectionHandler?

    init(connection: NWConnection, token: String, queue: DispatchQueue) {
        self.connection = connection
        self.token = token
        self.queue = queue
    }

    func run() {
        selfRef = self
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                // The hook went away — unblock anything waiting on it.
                self?.work?.cancel()
                self?.finish()
            default:
                break
            }
        }
        readMore()
    }

    private func finish() {
        selfRef = nil
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.buffer.append(data) }
            if let error {
                Protokoll.fehler("recv: \(error)")
                self.close()
                return
            }
            if let request = HTTPRequest(raw: self.buffer) {
                self.dispatch(request)
                return
            }
            if isComplete {
                self.close()
                return
            }
            self.readMore()
        }
    }

    private func dispatch(_ request: HTTPRequest) {
        // Constant-time-ish comparison is overkill for loopback, but the token
        // still keeps other local processes from driving the notch.
        guard request.headers["x-saphir-token"] == token || request.path == "/health" else {
            respond(status: "403 Forbidden", body: ["error": "bad token"])
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(status: "200 OK", body: ["ok": true, "app": "Saphir"])

        case ("POST", "/hook"), ("POST", "/event"):
            guard let event = HookEvent.parse(request.body) else {
                respond(status: "400 Bad Request", body: ["error": "unparseable payload"])
                return
            }
            // A PermissionRequest parks here for as long as the user takes to
            // decide, so this is the one route that must notice a vanished hook.
            watchForPeerHangup()
            work = Task { [weak self] in
                let result = await AgentenMotor.shared.handle(event: event)
                guard !Task.isCancelled else { return }
                self?.respond(status: "200 OK", body: result ?? [:])
            }

        case ("POST", "/decide"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let session = payload["session"] as? String
            let decision = payload["decision"] as? String ?? ""
            let reason = payload["reason"] as? String
            // `decision: "answer"` takes either a full question→label map or,
            // for a single-question call, just the label in `reason`.
            let answers = (payload["answers"] as? [String: Any])?.compactMapValues { value -> String? in
                if let s = value as? String { return s }
                if let list = value as? [String] { return list.joined(separator: ", ") }
                return nil
            }
            work = Task { [weak self] in
                let ok = await MainActor.run {
                    AgentenMotor.shared.decide(sessionID: session, decision: decision,
                                           reason: reason, answers: answers)
                }
                self?.respond(status: ok ? "200 OK" : "409 Conflict", body: ["ok": ok])
            }

        case ("POST", "/jump"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let session = payload["session"] as? String
            work = Task { [weak self] in
                let ok = await MainActor.run { AgentenMotor.shared.jump(to: session) }
                self?.respond(status: ok ? "200 OK" : "404 Not Found", body: ["ok": ok])
            }

        case ("POST", "/panel"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            let open = payload["open"] as? Bool ?? true
            let pin = payload["pin"] as? Bool
            work = Task { [weak self] in
                await MainActor.run { AgentenMotor.shared.panel(open: open, pin: pin) }
                self?.respond(status: "200 OK", body: ["ok": true])
            }

        case ("POST", "/statusline"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            work = Task { [weak self] in
                let line = await MainActor.run { AgentenMotor.shared.applyStatusline(payload) }
                // Plain text: whatever we answer lands in the terminal verbatim.
                self?.respondText(line)
            }

        case ("GET", "/state"):
            let snapshot = Task { @MainActor in AgentenMotor.shared.stateSnapshot() }
            work = Task { [weak self] in
                let value = await snapshot.value
                self?.respond(status: "200 OK", body: value)
            }

        default:
            respond(status: "404 Not Found", body: ["error": "unknown route"])
        }
    }

    /// Keeps a read outstanding for the whole exchange purely to learn when the
    /// other end goes away.
    ///
    /// Without this, answering a permission prompt in the terminal instead of the
    /// notch left the card sitting there: Claude Code kills the hook, curl dies,
    /// but `NWConnection` only surfaces that through a pending receive — and after
    /// `dispatch` nobody was reading any more. The stale waiter then resurfaced as
    /// the same question a second time when the session ended.
    private func watchForPeerHangup() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            // Our own close races in here right after we answer — not a hangup.
            if self.responded { return }
            guard isComplete || error != nil else {
                self.watchForPeerHangup()   // unexpected trailing bytes; keep waiting
                return
            }
            self.work?.cancel()
            self.close()
        }
    }

    private func respondText(_ text: String) {
        let payload = Data(text.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        send(out)
    }

    private func respond(status: String, body: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        send(out)
    }

    /// Marks the exchange answered and writes it out. Both steps happen on the
    /// connection queue so the watchdog sees `responded` before our close does.
    private func send(_ out: Data) {
        queue.async { [weak self] in
            guard let self, !self.responded else { return }
            self.responded = true
            self.connection.send(content: out, completion: .contentProcessed { [weak self] _ in
                self?.close()
            })
        }
    }

    private func close() {
        connection.cancel()
        finish()
    }
}

/// The smallest HTTP request parser that is still correct for our purposes.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Returns nil while the request is still incomplete.
    init?(raw: Data) {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = raw.range(of: separator) else { return nil }
        let headData = raw[raw.startIndex..<headEnd.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        self.method = String(requestLine[0]).uppercased()
        self.path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        self.headers = headers

        let expected = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        let available = raw.distance(from: bodyStart, to: raw.endIndex)
        guard available >= expected else { return nil }  // keep reading
        let bodyEnd = raw.index(bodyStart, offsetBy: expected)
        self.body = Data(raw[bodyStart..<bodyEnd])
    }
}

enum AgentenFehler: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}
