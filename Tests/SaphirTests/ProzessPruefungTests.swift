import XCTest
@testable import Saphir

/// Eine Session, deren CLI hart beendet wurde, sendet kein `SessionEnd`. Ohne
/// Pruefung bliebe ihre Zeile fuer immer in der Insel stehen.
@MainActor
final class ProzessPruefungTests: XCTestCase {

    private let motor = AgentenMotor.shared

    override func setUp() async throws {
        try await super.setUp()
        AgentenTestUmgebung.pruefe()
        Einstellungen.shared.klaengeAn = false
        AgentenOptionen.shared.mitteilungen = false
    }

    override func tearDown() async throws {
        for s in motor.sessions { motor.removeSession(s.id) }
        try await super.tearDown()
    }

    /// Startet `sleep`, wartet bis der Kernel den Prozess kennt, und gibt ihn zurueck.
    private func starteSchlaefer() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["60"]
        try p.run()
        return p
    }

    private func ereignis(_ name: String, session: String, pid: Int) -> HookEvent {
        let json = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": name, "session_id": session, "cwd": "/tmp/projekt-\(session)",
            "_saphir": ["agent": "claude", "pid": pid]
        ] as [String: Any])
        return HookEvent.parse(json)!
    }

    func testLaufenderProzessLebt() {
        XCTAssertEqual(ProzessPruefung.befund(pid: Int(getpid()), seit: Date()), .lebt)
    }

    func testBeendeterProzessIstTot() throws {
        let p = try starteSchlaefer()
        let pid = Int(p.processIdentifier)
        let seit = Date()
        p.terminate()
        p.waitUntilExit()
        XCTAssertEqual(ProzessPruefung.befund(pid: pid, seit: seit), .tot)
    }

    /// Eine neu vergebene pid gehoert einem Prozess, der nach der Session
    /// gestartet wurde. Der darf die Zeile nicht am Leben halten.
    func testNeuVergebenePidIstTot() {
        let vorDemStart = Date().addingTimeInterval(-3600)
        XCTAssertEqual(ProzessPruefung.befund(pid: Int(getpid()), seit: vorDemStart), .tot)
    }

    func testUngueltigePidIstTot() {
        XCTAssertEqual(ProzessPruefung.befund(pid: 0, seit: Date()), .tot)
        XCTAssertEqual(ProzessPruefung.befund(pid: -5, seit: Date()), .tot)
    }

    func testMotorEntferntNurToteSessions() async throws {
        let lebend = Int(getpid())
        let schlaefer = try starteSchlaefer()
        let totePid = Int(schlaefer.processIdentifier)

        _ = await motor.handle(event: ereignis("UserPromptSubmit", session: "lebt", pid: lebend))
        _ = await motor.handle(event: ereignis("UserPromptSubmit", session: "stirbt", pid: totePid))
        XCTAssertEqual(motor.sessions.count, 2)

        // Der Schlaefer lebt noch: nichts wird angefasst.
        XCTAssertEqual(motor.raeumeVerwaisteAuf(), [])
        XCTAssertEqual(motor.sessions.count, 2)

        // Hart beendet, ohne `SessionEnd`.
        kill(schlaefer.processIdentifier, SIGKILL)
        schlaefer.waitUntilExit()

        XCTAssertEqual(motor.raeumeVerwaisteAuf(), ["stirbt"])
        XCTAssertEqual(motor.sessions.map(\.id), ["lebt"])
    }

    /// Ohne bekannte pid (zum Beispiel ein Agent, der nur Pings schickt) gibt es
    /// nichts zu pruefen. Die Zeile bleibt.
    func testSessionOhnePidBleibt() async {
        let json = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "ohne-pid", "cwd": "/tmp/x"
        ] as [String: Any])
        _ = await motor.handle(event: HookEvent.parse(json)!)
        XCTAssertEqual(motor.raeumeVerwaisteAuf(), [])
        XCTAssertEqual(motor.sessions.count, 1)
    }
}
