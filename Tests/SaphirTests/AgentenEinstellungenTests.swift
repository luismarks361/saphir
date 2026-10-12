import XCTest
@testable import Saphir

/// Das Eintragen in Claudes `settings.json`: nichts verlieren, nichts doppeln,
/// nichts anfassen, was nicht lesbar ist.
final class AgentenEinstellungenTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AgentenTestUmgebung.pruefe()
    }

    private func lies(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func befehle(_ eintrag: Any?) -> [String] {
        (eintrag as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []) }
            .compactMap { $0["command"] as? String }
    }

    // MARK: - Hooks

    func testEintragenInEineFehlendeDatei() throws {
        let datei = try AgentenTestUmgebung.neueSettings()
        try HookInstaller.install()

        let hooks = try XCTUnwrap(lies(datei)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookInstaller.events.map(\.event)))
        XCTAssertTrue(HookInstaller.isInstalled)

        // Nur die Freigabe blockiert und bekommt Zeit fuer einen Menschen.
        let frage = try XCTUnwrap((hooks["PermissionRequest"] as? [[String: Any]])?.first)
        let hook = try XCTUnwrap((frage["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(hook["timeout"] as? Int, 600)
        let stop = try XCTUnwrap(((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        XCTAssertEqual(stop["timeout"] as? Int, 10)

        var istOrdner: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: AgentenPfade.hookSkript.path, isDirectory: &istOrdner))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: AgentenPfade.hookSkript.path))
    }

    func testFremdeHooksUndSchluesselBleiben() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: """
        {
          "model": "opus",
          "permissions": { "allow": ["Bash(ls:*)"] },
          "hooks": {
            "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/mein-stop" } ] } ],
            "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "/usr/local/bin/pruefer" } ] } ]
          }
        }
        """)
        try HookInstaller.install()

        let alles = try lies(datei)
        XCTAssertEqual(alles["model"] as? String, "opus")
        XCTAssertNotNil(alles["permissions"])
        let hooks = try XCTUnwrap(alles["hooks"] as? [String: Any])
        XCTAssertTrue(befehle(hooks["Stop"]).contains("/usr/local/bin/mein-stop"))
        XCTAssertTrue(befehle(hooks["PreToolUse"]).contains("/usr/local/bin/pruefer"))
        XCTAssertEqual(befehle(hooks["Stop"]).filter { $0.contains("saphir-hook.sh") }.count, 1)
    }

    func testZweitesEintragenAendertNichtsMehr() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: #"{"model":"opus"}"#)
        try HookInstaller.install()
        let nachErstem = try Data(contentsOf: datei)
        try HookInstaller.install()
        XCTAssertEqual(try Data(contentsOf: datei), nachErstem)

        let hooks = try XCTUnwrap(lies(datei)["hooks"] as? [String: Any])
        for (_, eintrag) in hooks {
            XCTAssertEqual(befehle(eintrag).filter { $0.contains("saphir-hook.sh") }.count, 1)
        }
    }

    func testEntfernenLaesstFremdesStehen() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: """
        { "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "/usr/local/bin/mein-stop" } ] } ] } }
        """)
        try HookInstaller.install()
        try HookInstaller.uninstall()

        let hooks = try XCTUnwrap(lies(datei)["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["Stop"])
        XCTAssertEqual(befehle(hooks["Stop"]), ["/usr/local/bin/mein-stop"])
        XCTAssertFalse(HookInstaller.isInstalled)
    }

    func testEntfernenRaeumtLeeresHooksObjektWeg() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: #"{"model":"opus"}"#)
        try HookInstaller.install()
        try HookInstaller.uninstall()
        let alles = try lies(datei)
        XCTAssertNil(alles["hooks"])
        XCTAssertEqual(alles["model"] as? String, "opus")
    }

    func testKaputteDateiBleibtUnangetastet() throws {
        let kaputt = #"{ "model": "opus", "hooks": { "Stop": [ }"#
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: kaputt)

        XCTAssertThrowsError(try HookInstaller.install())
        XCTAssertThrowsError(try StatuslineInstaller.install())
        XCTAssertThrowsError(try HookInstaller.uninstall())
        XCTAssertEqual(try String(contentsOf: datei, encoding: .utf8), kaputt)
    }

    func testLeereDateiIstKeinFehler() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: "  \n")
        XCTAssertNoThrow(try HookInstaller.install())
        XCTAssertNotNil(try lies(datei)["hooks"])
    }

    func testSicherungVorDerErstenAenderung() throws {
        let original = #"{"model":"opus"}"#
        _ = try AgentenTestUmgebung.neueSettings(inhalt: original)
        try HookInstaller.install()

        let sicherungen = (try FileManager.default.contentsOfDirectory(
            at: Ablage.ordner, includingPropertiesForKeys: nil))
            .filter { $0.lastPathComponent.hasPrefix("settings-backup-") }
        let passende = try sicherungen.filter {
            try String(contentsOf: $0, encoding: .utf8) == original
        }
        XCTAssertEqual(passende.count, 1, "genau eine Sicherung mit dem Stand vor Saphir")
    }

    // MARK: - Statuszeile

    func testFremdeStatuszeileWirdWeitergereichtUndKommtZurueck() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: """
        { "statusLine": { "type": "command", "command": "~/bin/meine-zeile.sh" } }
        """)
        try StatuslineInstaller.install()

        let zeile = try XCTUnwrap(lies(datei)["statusLine"] as? [String: Any])
        XCTAssertTrue((zeile["command"] as? String)?.hasSuffix("saphir-statusline.sh") == true)
        XCTAssertEqual(try String(contentsOf: StatuslineInstaller.innerCommand, encoding: .utf8),
                       "~/bin/meine-zeile.sh")
        XCTAssertTrue(StatuslineInstaller.isInstalled)

        try StatuslineInstaller.uninstall()
        let danach = try XCTUnwrap(lies(datei)["statusLine"] as? [String: Any])
        XCTAssertEqual(danach["command"] as? String, "~/bin/meine-zeile.sh")
        XCTAssertFalse(StatuslineInstaller.isInstalled)
    }

    func testStatuszeileOhneVorgaengerWirdEntferntNichtLeerGelassen() throws {
        let datei = try AgentenTestUmgebung.neueSettings(inhalt: #"{"model":"opus"}"#)
        try? FileManager.default.removeItem(at: StatuslineInstaller.innerCommand)
        try StatuslineInstaller.install()
        XCTAssertNotNil(try lies(datei)["statusLine"])
        try StatuslineInstaller.uninstall()
        XCTAssertNil(try lies(datei)["statusLine"])
    }

    func testRestEinerFrueherenStatuszeileLaeuftNichtWeiter() throws {
        _ = try AgentenTestUmgebung.neueSettings(inhalt: #"{"statusLine":{"type":"command","command":"~/alt.sh"}}"#)
        try StatuslineInstaller.install()
        try StatuslineInstaller.uninstall()

        // Der Nutzer hat inzwischen keine Statuszeile mehr: kein Rest, der mitlaeuft.
        try Data(#"{"model":"opus"}"#.utf8).write(to: AgentenPfade.claudeSettings)
        try "~/alt.sh".write(to: StatuslineInstaller.innerCommand, atomically: true, encoding: .utf8)
        try StatuslineInstaller.install()
        XCTAssertFalse(FileManager.default.fileExists(atPath: StatuslineInstaller.innerCommand.path))
    }

    func testStatuszeileZweimalEintragenKettetSichNichtSelbst() throws {
        _ = try AgentenTestUmgebung.neueSettings(inhalt: #"{"statusLine":{"type":"command","command":"~/a.sh"}}"#)
        try StatuslineInstaller.install()
        try StatuslineInstaller.install()
        XCTAssertEqual(try String(contentsOf: StatuslineInstaller.innerCommand, encoding: .utf8), "~/a.sh")
    }
}
