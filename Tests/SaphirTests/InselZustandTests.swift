import AppKit
import SwiftUI
import XCTest
@testable import Saphir

/// Das Frage-Panel als dritter Zustand der Insel: wann es aufgeht, wie gross es
/// ist, was es verdraengt und wann es geht. Alles ohne Fenster: gerechnet wird
/// allein am Zustand, den AppKit und SwiftUI sich teilen.
@MainActor
final class InselZustandTests: XCTestCase {

    override func setUpWithError() throws {
        // `InselZustand` liest die Notch vom Bildschirm. Ohne einen (reiner Server,
        // kein Fenstersystem) gibt es hier nichts zu pruefen.
        try XCTSkipIf(NSScreen.screens.isEmpty, "kein Bildschirm")
    }

    private func angebot() -> HudAnzeige {
        HudAnzeige(symbol: "moon.stars.fill", text: "", angebot: true)
    }

    // MARK: - Welcher Zustand gewinnt

    func testZielGroesseFolgtDerWertigkeit() {
        let z = InselZustand()
        XCTAssertEqual(z.zielGroesse, z.groesseEingeklappt)

        z.hud = HudAnzeige(symbol: "speaker.wave.2", text: "50")
        XCTAssertEqual(z.zielGroesse, z.groesseHud)

        // Eine Meldung darf die Frage nicht verdraengen: sonst sind die Knoepfe
        // weg und die Claude-Session haengt.
        z.zeigtFrage = true
        XCTAssertEqual(z.zielGroesse, z.groesseFrage)

        // Die offene Flaeche schlaegt alles, auch die Frage.
        z.istOffen = true
        XCTAssertEqual(z.zielGroesse, z.groesseOffen)
    }

    func testFrageIstKompaktUndNieStumm() {
        let z = InselZustand()
        XCTAssertTrue(z.istStumm, "ohne alles soll die Notch unberuehrt aussehen")
        XCTAssertFalse(z.istKompakt)

        z.zeigtFrage = true
        XCTAssertTrue(z.istKompakt)
        XCTAssertFalse(z.istStumm, "ein stummer Zustand wuerde die Frage unsichtbar machen")
    }

    // MARK: - Groesse

    func testFrageHatDieHoeheIhrerKarteUnterDerNotch() {
        let z = InselZustand()
        z.hoeheFrage = 91
        XCTAssertEqual(z.groesseFrage.height, z.geometrie.notchHoehe + 91)
    }

    func testFrageHoeheIstGedeckelt() {
        let z = InselZustand()
        z.hoeheFrage = 10_000
        XCTAssertEqual(z.groesseFrage.height, NotchGeometrie.maxHoeheOffen)
    }

    func testFrageIstNieSchmalerAlsDieNotch() {
        let z = InselZustand()
        XCTAssertGreaterThanOrEqual(z.groesseFrage.width, z.geometrie.notchBreite + 40)
        XCTAssertGreaterThanOrEqual(z.groesseFrage.width, InselZustand.breiteFrage)
    }

    func testFrageIstSchmalerAlsDieOffeneFlaeche() {
        // „Kompakt“ heisst auch: kein Reiterstreifen, also kein Platz fuer ihn.
        let z = InselZustand()
        XCTAssertLessThan(z.groesseFrage.width, z.groesseOffen.width)
    }

    func testFrageBleibtImFenster() {
        // Das Fenster aendert nie seine Groesse. Was darueber hinausgeht, wuerde
        // abgeschnitten, und die Knoepfe waeren nicht klickbar.
        let z = InselZustand()
        z.hoeheFrage = 10_000
        let fenster = z.geometrie.fensterRahmen
        let kehle: CGFloat = 7
        XCTAssertLessThanOrEqual(z.groesseFrage.width + kehle * 2, fenster.width)
        XCTAssertLessThanOrEqual(z.groesseFrage.height, fenster.height - NotchGeometrie.schattenLuft)
    }

    // MARK: - Hover

    func testWartetAufKlick() {
        let z = InselZustand()
        XCTAssertFalse(z.wartetAufKlick)

        z.hud = HudAnzeige(symbol: "speaker.wave.2", text: "50")
        XCTAssertFalse(z.wartetAufKlick, "eine blosse Meldung wartet auf nichts")

        z.hud = angebot()
        XCTAssertTrue(z.wartetAufKlick)

        z.hud = nil
        z.zeigtFrage = true
        XCTAssertTrue(z.wartetAufKlick, "Hover darf die Karte nicht durch die volle Insel ersetzen")
    }

    // MARK: - Aufgehen

    func testFrageGehtNurBeiAnstehenderFreigabeAuf() {
        let z = InselZustand()
        XCTAssertFalse(z.zeigeFrage(freigabeSteht: false),
                       "ohne Frage (kurzZeigen) bleibt es bei den Sessions")
        XCTAssertFalse(z.zeigtFrage)

        XCTAssertTrue(z.zeigeFrage(freigabeSteht: true))
        XCTAssertTrue(z.zeigtFrage)
    }

    func testOffeneInselBekommtKeinPanel() {
        // Hat Luis die Insel selbst aufgemacht, ersetzt das Panel sie nicht.
        let z = InselZustand()
        z.istOffen = true
        XCTAssertFalse(z.zeigeFrage(freigabeSteht: true))
        XCTAssertFalse(z.zeigtFrage)
        XCTAssertEqual(z.zielGroesse, z.groesseOffen)
    }

    // MARK: - Gehen

    func testFrageGehtMitDerFreigabe() {
        let z = InselZustand()
        _ = z.zeigeFrage(freigabeSteht: true)

        XCTAssertFalse(z.frageAbgleichen(freigabeSteht: true),
                       "solange die Freigabe steht, darf das Panel nicht weg")
        XCTAssertTrue(z.zeigtFrage)

        XCTAssertTrue(z.frageAbgleichen(freigabeSteht: false))
        XCTAssertFalse(z.zeigtFrage, "ohne Karte bliebe ein leerer Streifen")
        XCTAssertEqual(z.zielGroesse, z.groesseEingeklappt)
    }

    func testAbgleichOhneFrageTutNichts() {
        let z = InselZustand()
        XCTAssertFalse(z.frageAbgleichen(freigabeSteht: false))
        XCTAssertFalse(z.zeigtFrage)
    }

    func testNaechsteFreigabeBehaeltDasPanel() {
        // Zwei Freigaben nacheinander: zwischen beiden gibt es keinen Augenblick
        // ohne Freigabe, das Panel bleibt also stehen und zeigt die naechste.
        let z = InselZustand()
        _ = z.zeigeFrage(freigabeSteht: true)
        XCTAssertFalse(z.frageAbgleichen(freigabeSteht: true))
        XCTAssertTrue(z.zeigeFrage(freigabeSteht: true))
        XCTAssertTrue(z.zeigtFrage)
    }

    // MARK: - Hoehenmeldung

    func testHoeheFrageKeyNimmtDieGroessteMeldung() {
        // Wie `HoeheOffenKey`: ein Kind ohne Meldung faltet null ein und darf die
        // echte Hoehe nicht ueberschreiben.
        var wert: CGFloat = 0
        HoeheFrageKey.reduce(value: &wert, nextValue: { 91 })
        HoeheFrageKey.reduce(value: &wert, nextValue: { 0 })
        XCTAssertEqual(wert, 91)
    }
}
