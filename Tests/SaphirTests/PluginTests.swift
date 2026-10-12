import SwiftUI
import XCTest
@testable import Saphir

/// Das Plugin-System: Manifest, Programmstart, Antwort und die Verbindung zur
/// Insel. Die Plugins sind hier kleine Shell-Skripte in einem Wegwerf-Ordner.
@MainActor
final class PluginTests: XCTestCase {

    private var wurzel: URL!

    override func setUp() {
        super.setUp()
        AgentenTestUmgebung.pruefe()
        wurzel = FileManager.default.temporaryDirectory
            .appendingPathComponent("saphir-plugins-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: wurzel, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: wurzel)
        super.tearDown()
    }

    // MARK: - Hilfen

    /// Legt ein Plugin an. `skript` ist der Rumpf eines sh-Programms.
    @discardableResult
    private func lege(_ id: String, skript: String, manifest: String? = nil,
                      in basis: URL? = nil) throws -> URL {
        let ordner = (basis ?? wurzel.appendingPathComponent("plugins", isDirectory: true))
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let start = ordner.appendingPathComponent("lauf.sh")
        try "#!/bin/sh\n\(skript)\n".write(to: start, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: start.path)
        let json = manifest ?? """
        {"schnittstelle":1,"id":"\(id)","name":"Test \(id)","start":"lauf.sh","takt":5,
         "andocken":["live","hud","kachel"]}
        """
        try json.write(to: ordner.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        return ordner
    }

    private func anfrage(befehl: String = "abfrage", aktion: String? = nil,
                         einstellungen: [String: String] = [:]) -> PluginLauf.Anfrage {
        PluginLauf.Anfrage(befehl: befehl, aktion: aktion, einstellungen: einstellungen,
                           daten: wurzel.appendingPathComponent("daten").path)
    }

    private func fuehreAus(_ ordner: URL, frist: Double = 5,
                           anfrage a: PluginLauf.Anfrage? = nil) -> Result<Data, PluginLauf.Fehler> {
        PluginLauf.fuehreAus(programm: ordner.appendingPathComponent("lauf.sh"), ordner: ordner,
                             anfrage: a ?? anfrage(), frist: frist)
    }

    /// Dreht die Laufschleife, bis die Bedingung stimmt. Die Plugins laufen auf
    /// einem Hintergrundfaden und melden sich ueber den Hauptfaden zurueck.
    private func warte(sekunden: Double = 8, bis bedingung: () -> Bool) {
        let ende = Date().addingTimeInterval(sekunden)
        while !bedingung(), Date() < ende { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func verwalter() -> PluginVerwalter {
        let suite = "saphir-test-\(UUID().uuidString)"
        return PluginVerwalter(ordner: wurzel.appendingPathComponent("plugins"),
                               datenOrdner: wurzel.appendingPathComponent("daten"),
                               defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - Manifest

    func testGueltigesManifestMitStandardwerten() throws {
        let ordner = try lege("demo", skript: "echo {}")
        let m = try PluginManifest.lade(aus: ordner)
        XCTAssertEqual(m.id, "demo")
        XCTAssertEqual(m.taktSekunden, 5)
        XCTAssertEqual(m.livePrioritaet, 15)
        XCTAssertEqual(m.kachelSpalten, 2)
        XCTAssertTrue(m.felder.isEmpty)
    }

    func testTaktUndPrioritaetBleibenInIhrenGrenzen() throws {
        let ordner = try lege("grenze", skript: "echo {}", manifest: """
        {"schnittstelle":1,"id":"grenze","name":"G","start":"lauf.sh","takt":0.1,
         "andocken":["live"],"prioritaet":99,"spalten":7}
        """)
        let m = try PluginManifest.lade(aus: ordner)
        XCTAssertEqual(m.taktSekunden, 5)
        // Ueber dem Kalender (20) und der Freigabe (30) darf sich nichts draengen.
        XCTAssertEqual(m.livePrioritaet, 19)
        XCTAssertEqual(m.kachelSpalten, 2)
    }

    func testOrdnernameMussDieKennungSein() throws {
        let ordner = try lege("anders", skript: "echo {}", manifest: """
        {"schnittstelle":1,"id":"demo","name":"D","start":"lauf.sh","andocken":[]}
        """)
        XCTAssertThrowsError(try PluginManifest.lade(aus: ordner)) {
            XCTAssertEqual($0 as? PluginManifest.Mangel, .ordner("anders"))
        }
    }

    func testStartdateiMussImPluginOrdnerLiegen() throws {
        for start in ["../lauf.sh", "/bin/sh", ""] {
            let ordner = try lege("pfad", skript: "echo {}", manifest: """
            {"schnittstelle":1,"id":"pfad","name":"P","start":"\(start)","andocken":[]}
            """)
            XCTAssertThrowsError(try PluginManifest.lade(aus: ordner), "start=\(start)") {
                XCTAssertEqual($0 as? PluginManifest.Mangel, .start(start))
            }
        }
    }

    func testUnbekannteSchnittstelleWirdAbgelehnt() throws {
        let ordner = try lege("neu", skript: "echo {}", manifest: """
        {"schnittstelle":2,"id":"neu","name":"N","start":"lauf.sh","andocken":[]}
        """)
        XCTAssertThrowsError(try PluginManifest.lade(aus: ordner)) {
            XCTAssertEqual($0 as? PluginManifest.Mangel, .schnittstelle(2))
        }
    }

    func testKaputtesManifestMeldetDenGrund() throws {
        let ordner = try lege("kaputt", skript: "echo {}", manifest: "{\"schnittstelle\":1}")
        XCTAssertThrowsError(try PluginManifest.lade(aus: ordner)) {
            guard case .unlesbar(let grund)? = $0 as? PluginManifest.Mangel else {
                return XCTFail("falscher Fehler: \($0)")
            }
            XCTAssertTrue(grund.contains("fehlt"), grund)
        }
    }

    // MARK: - Programmstart

    func testAnfrageKommtAufStdinAnUndAntwortAufStdout() throws {
        let ordner = try lege("echo", skript: "cat")
        let roh = try fuehreAus(ordner, anfrage: anfrage(befehl: "aktion", aktion: "zaehlen",
                                                        einstellungen: ["ziel": "5"])).get()
        let gespiegelt = try XCTUnwrap(JSONSerialization.jsonObject(with: roh) as? [String: Any])
        XCTAssertEqual(gespiegelt["befehl"] as? String, "aktion")
        XCTAssertEqual(gespiegelt["aktion"] as? String, "zaehlen")
        XCTAssertEqual((gespiegelt["einstellungen"] as? [String: String])?["ziel"], "5")
        XCTAssertNotNil(gespiegelt["daten"])
    }

    func testHaengendesPluginWirdNachDerFristBeendet() throws {
        let ordner = try lege("haengt", skript: "sleep 30")
        let start = Date()
        let ergebnis = fuehreAus(ordner, frist: 1)
        XCTAssertEqual(ergebnis, .failure(.zeit(1)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
    }

    func testAbsturzMeldetCodeUndFehlermeldung() throws {
        let ordner = try lege("stirbt", skript: "echo Anmeldung abgelehnt >&2; exit 3")
        XCTAssertEqual(fuehreAus(ordner), .failure(.beendet(3, "Anmeldung abgelehnt")))
    }

    func testZuGrosseAusgabeWirdAbgebrochen() throws {
        let ordner = try lege("laut", skript: "yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
        XCTAssertEqual(fuehreAus(ordner), .failure(.zuGross))
    }

    func testPluginOhneAusfuehrrechtStartetNicht() throws {
        let ordner = try lege("ohnerecht", skript: "echo {}")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: ordner.appendingPathComponent("lauf.sh").path)
        guard case .failure(.nichtGestartet) = fuehreAus(ordner) else {
            return XCTFail("haette nicht starten duerfen")
        }
    }

    // MARK: - Antwort

    func testLeereAusgabeHeisstNichtsZuZeigen() {
        XCTAssertEqual(try? PluginLauf.lies(Data("  \n".utf8)).get(), PluginAntwort())
    }

    func testUnlesbareAusgabeNenntDasFehlendeFeld() {
        let kaputt = Data(#"{"hud":{"id":"a","symbol":"bell"}}"#.utf8)
        guard case .failure(.unlesbar(let grund)) = PluginLauf.lies(kaputt) else {
            return XCTFail("haette scheitern muessen")
        }
        XCTAssertTrue(grund.contains("text"), grund)
    }

    func testUnbekannteBausteinArtKippenDieKachelNicht() throws {
        let json = Data(#"{"kachel":{"bausteine":[{"art":"hologramm"},{"art":"text","text":"ok"}]}}"#.utf8)
        let antwort = try PluginLauf.lies(json).get()
        XCTAssertEqual(antwort.kachel?.bausteine.count, 2)
    }

    func testLangerOhrtextWirdGekuerzt() {
        let ohr = PluginAntwort.Ohr(text: String(repeating: "a", count: 80))
        XCTAssertEqual(ohr.inhalt.text?.count, PluginAntwort.Ohr.maxZeichen)
    }

    func testFarbenNachNameUndHex() {
        XCTAssertEqual(PluginFarbe.farbe("rot"), .red)
        XCTAssertEqual(PluginFarbe.farbe("unsinn"), .white)
        XCTAssertEqual(PluginFarbe.farbe(nil, standard: .gray), .gray)
        XCTAssertEqual(PluginFarbe.farbe("#FF0000"), Color(red: 1, green: 0, blue: 0))
    }

    // MARK: - Verwalter und Insel

    func testNeuesPluginIstAusUndLaeuftNicht() throws {
        try lege("still", skript: "echo '{\"live\":{\"rechts\":{\"text\":\"1\"}}}'")
        let v = verwalter()
        v.neuEinlesen()

        XCTAssertEqual(v.plugins.map(\.id), ["still"])
        XCTAssertFalse(v.istAn("still"))
        XCTAssertEqual(v.stand["still"], .aus)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        XCTAssertNil(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.still" })
    }

    func testEingeschaltetesPluginErscheintUndVerschwindetWieder() throws {
        // Der Schalter der Insel haengt am gemeinsamen Verwalter, also laeuft
        // dieser Test ueber ihn, in der Test-Ablage.
        let v = PluginVerwalter.shared
        let ordner = try lege("live", skript: """
        echo '{"live":{"links":{"text":"Anna"},"rechts":{"text":"8 min"}},"kachel":{"bausteine":[{"art":"text","text":"hi"}]}}'
        """, in: PluginVerwalter.standardOrdner)
        addTeardownBlock { @MainActor in
            v.setzeAn("live", false)
            try? FileManager.default.removeItem(at: ordner)
            v.neuEinlesen()
            UserDefaults.standard.removeObject(forKey: "plugin.live.an")
        }
        v.neuEinlesen()
        v.setzeAn("live", true)

        warte { LiveAktivitaeten.shared.alle.contains { $0.id == "plugin.live" } }
        let aktivitaet = try XCTUnwrap(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.live" })
        XCTAssertEqual(aktivitaet.plugin, "live")
        XCTAssertNil(aktivitaet.funktion)
        XCTAssertEqual(aktivitaet.prioritaet, 15)
        XCTAssertEqual(aktivitaet.rechts?.text, "8 min")
        XCTAssertTrue(aktivitaet.istAn)
        XCTAssertTrue(WidgetRegister.shared.sichtbare.contains { $0.id == "plugin.live" })
        guard case .ok = v.stand["live"] else { return XCTFail("Stand: \(String(describing: v.stand["live"]))") }

        v.setzeAn("live", false)
        XCTAssertNil(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.live" })
        XCTAssertFalse(WidgetRegister.shared.kacheln.contains { $0.id == "plugin.live" })
        XCTAssertEqual(v.stand["live"], .aus)
    }

    func testEineHudMeldungMitGleicherKennungKommtNurEinmal() throws {
        try lege("hud", skript: """
        echo '{"hud":{"id":"m-1","symbol":"bell","text":"Gleich"}}'
        """)
        let v = verwalter()
        var gezeigt: [String] = []
        v.zeigeHud = { anzeige, _ in gezeigt.append(anzeige.text) }
        v.neuEinlesen()
        v.setzeAn("hud", true)
        warte { !gezeigt.isEmpty }

        v.frageAb("hud")
        v.frageAb("hud")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(gezeigt, ["Gleich"])
        v.setzeAn("hud", false)
    }

    func testNichtAngemeldeterAndockpunktWirdIgnoriert() throws {
        try lege("nurhud", skript: """
        echo '{"live":{"rechts":{"text":"x"}},"kachel":{"bausteine":[{"art":"text","text":"x"}]}}'
        """, manifest: """
        {"schnittstelle":1,"id":"nurhud","name":"N","start":"lauf.sh","takt":5,"andocken":["hud"]}
        """)
        let v = verwalter()
        v.neuEinlesen()
        v.setzeAn("nurhud", true)
        warte { if case .ok = v.stand["nurhud"] { return true } else { return false } }

        XCTAssertNil(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.nurhud" })
        XCTAssertNil(v.kacheln["nurhud"])
        v.setzeAn("nurhud", false)
    }

    func testFehlerNimmtDieAnzeigeWegUndNenntDenGrund() throws {
        // Erst gut, dann kaputt: der Marker steuert, was das Plugin tut.
        let marker = wurzel.appendingPathComponent("kaputt")
        try lege("wackelt", skript: """
        if [ -e "\(marker.path)" ]; then echo "Server weg" >&2; exit 1; fi
        echo '{"live":{"rechts":{"text":"8 min"}}}'
        """)
        let v = verwalter()
        v.neuEinlesen()
        v.setzeAn("wackelt", true)
        warte { LiveAktivitaeten.shared.alle.contains { $0.id == "plugin.wackelt" } }
        XCTAssertNotNil(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.wackelt" })

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        v.frageAb("wackelt")
        warte { if case .fehler = v.stand["wackelt"] { return true } else { return false } }

        XCTAssertEqual(v.stand["wackelt"], .fehler("Code 1: Server weg"))
        // Ein Countdown, der nicht mehr stimmt, waere eine Falschmeldung.
        XCTAssertNil(LiveAktivitaeten.shared.alle.first { $0.id == "plugin.wackelt" })
        v.setzeAn("wackelt", false)
    }

    func testKnopfdruckRuftDasPluginMitDerAktionAufUndFragtDanachNeuAb() throws {
        let zaehler = wurzel.appendingPathComponent("zaehler")
        try lege("knopf", skript: """
        eingabe=$(cat)
        case "$eingabe" in
          *'"befehl":"aktion"'*) echo x >> "\(zaehler.path)"; exit 0 ;;
        esac
        n=$(wc -l < "\(zaehler.path)" 2>/dev/null || echo 0)
        echo "{\\"kachel\\":{\\"bausteine\\":[{\\"art\\":\\"text\\",\\"text\\":\\"$(echo $n)\\"}]}}"
        """)
        let v = verwalter()
        v.neuEinlesen()
        v.setzeAn("knopf", true)
        warte { v.kacheln["knopf"]?.first?.text == "0" }
        XCTAssertEqual(v.kacheln["knopf"]?.first?.text, "0")

        v.fuehreAktionAus("knopf", "zaehlen")
        warte { v.kacheln["knopf"]?.first?.text == "1" }
        XCTAssertEqual(v.kacheln["knopf"]?.first?.text, "1")
        v.setzeAn("knopf", false)
    }

    func testDasBeispielPluginAusDerDokuLaesstSichLaden() throws {
        let quelle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("doku/plugins/beispiel")
        let m = try PluginManifest.lade(aus: quelle)
        XCTAssertEqual(m.andocken, [.kachel, .live, .hud])
        let roh = try PluginLauf.fuehreAus(
            programm: try XCTUnwrap(m.programm(in: quelle)), ordner: quelle,
            anfrage: anfrage(einstellungen: ["ziel": "5"])).get()
        let antwort = try PluginLauf.lies(roh).get()
        XCTAssertNotNil(antwort.live)
        XCTAssertNotNil(antwort.kachel)
    }
}
