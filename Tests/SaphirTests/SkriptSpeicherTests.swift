import Foundation
import XCTest
@testable import Saphir

/// Der Speicher fuer uebersetzte AppleScripts (Musik fragt damit jede Sekunde).
/// Geprueft wird nur, was ohne Musik-App geht: dass wiederverwendet wird, dass
/// das Ergebnis dasselbe bleibt und dass ein Fehler den Eintrag loescht.
@MainActor
final class SkriptSpeicherTests: XCTestCase {

    func testGleicherTextGibtDasselbeSkriptZurueck() throws {
        let speicher = SkriptSpeicher()
        let erstes = try XCTUnwrap(speicher.skript(fuer: "return \"ok\""))
        let zweites = try XCTUnwrap(speicher.skript(fuer: "return \"ok\""))
        XCTAssertTrue(erstes === zweites, "wiederverwenden statt neu anlegen")
        XCTAssertEqual(speicher.anzahl, 1)
    }

    func testAnderesSkriptBekommtEinEigenes() throws {
        let speicher = SkriptSpeicher()
        let a = try XCTUnwrap(speicher.skript(fuer: "return 1"))
        let b = try XCTUnwrap(speicher.skript(fuer: "return 2"))
        XCTAssertFalse(a === b)
        XCTAssertEqual(speicher.anzahl, 2)
    }

    func testDasWiederverwendeteSkriptLiefertJedesMalDasselbeErgebnis() throws {
        let speicher = SkriptSpeicher()
        var ergebnisse: [String?] = []
        for _ in 0..<3 {
            var fehler: NSDictionary?
            let skript = try XCTUnwrap(speicher.skript(fuer: "return \"ok\""))
            ergebnisse.append(skript.executeAndReturnError(&fehler).stringValue)
            XCTAssertNil(fehler)
        }
        XCTAssertEqual(ergebnisse, ["ok", "ok", "ok"])
        // Nach dem ersten Lauf ist es uebersetzt und bleibt es.
        XCTAssertTrue(try XCTUnwrap(speicher.skript(fuer: "return \"ok\"")).isCompiled)
    }

    func testNachEinemFehlerWirdFrischUebersetzt() throws {
        let speicher = SkriptSpeicher()
        let quelle = "error \"kaputt\" number 42"
        let alt = try XCTUnwrap(speicher.skript(fuer: quelle))
        var fehler: NSDictionary?
        _ = alt.executeAndReturnError(&fehler)
        XCTAssertEqual(fehler?[NSAppleScript.errorNumber] as? Int, 42)

        speicher.vergiss(quelle)
        XCTAssertEqual(speicher.anzahl, 0)
        let neu = try XCTUnwrap(speicher.skript(fuer: quelle))
        XCTAssertFalse(alt === neu)
    }
}
