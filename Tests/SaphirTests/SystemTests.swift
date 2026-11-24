import AppKit
import SwiftUI
import XCTest
@testable import Saphir

/// Das System-Dashboard: die Rechnung hinter den Zahlen, das Lesen vom echten Mac
/// und die Ansicht. Die Rechnung laeuft ohne Hardware, das Lesen prueft nur, dass
/// die Werte in sinnvollen Grenzen liegen (ein Mac hat immer Kerne und Speicher).
@MainActor
final class SystemTests: XCTestCase {

    // MARK: - Prozessor

    func testKernLastRechnetDieDifferenzZweierStaende() {
        let vorher = [KernTicks(arbeit: 0, gesamt: 0), KernTicks(arbeit: 100, gesamt: 200)]
        let nachher = [KernTicks(arbeit: 50, gesamt: 100), KernTicks(arbeit: 130, gesamt: 300)]
        let last = SystemRechnung.kernLast(vorher: vorher, nachher: nachher)
        XCTAssertEqual(last[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(last[1], 0.3, accuracy: 0.0001)
    }

    func testKernLastTeiltNieDurchNullUndTraegtKeinenRueckschritt() {
        // Zaehler steht: keine Last, kein Absturz.
        let still = [KernTicks(arbeit: 10, gesamt: 20)]
        XCTAssertEqual(SystemRechnung.kernLast(vorher: still, nachher: still), [0])
        // Zaehler lief rueckwaerts (zurueckgesetzt): auch keine Last statt Unsinn.
        let zurueck = SystemRechnung.kernLast(vorher: [KernTicks(arbeit: 500, gesamt: 900)],
                                              nachher: [KernTicks(arbeit: 10, gesamt: 1000)])
        XCTAssertEqual(zurueck, [0])
        // Anderer Kernzahl zwischen zwei Messungen: nichts vergleichen.
        XCTAssertEqual(SystemRechnung.kernLast(vorher: still, nachher: []), [])
    }

    func testGesamtLastGewichtetNachTicksNichtNachKernen() {
        // Ein Kern voll ausgelastet ueber 100 Ticks, einer ueber 300 Ticks im Leerlauf.
        let vorher = [KernTicks(arbeit: 0, gesamt: 0), KernTicks(arbeit: 0, gesamt: 0)]
        let nachher = [KernTicks(arbeit: 100, gesamt: 100), KernTicks(arbeit: 0, gesamt: 300)]
        XCTAssertEqual(SystemRechnung.gesamtLast(vorher: vorher, nachher: nachher), 0.25, accuracy: 0.0001)
        XCTAssertEqual(SystemRechnung.gesamtLast(vorher: [], nachher: []), 0)
    }

    // MARK: - Arbeitsspeicher

    func testSpeicherRechnetWieDieAktivitaetsanzeige() {
        let seite: UInt64 = 16384
        let z = SeitenZaehler(intern: 1000, kaufbar: 200, extern: 300, wired: 100, komprimiert: 50)
        let s = SystemRechnung.speicher(seiten: z, seitenGroesse: seite, gesamt: 4000 * seite)
        XCTAssertEqual(s.app, 800 * seite)
        XCTAssertEqual(s.wired, 100 * seite)
        XCTAssertEqual(s.komprimiert, 50 * seite)
        XCTAssertEqual(s.cache, 500 * seite, "Dateicache und kaufbarer Speicher")
        XCTAssertEqual(s.benutzt, 950 * seite, "Programme, fest verdrahtet, komprimiert")
        XCTAssertEqual(s.frei, 3050 * seite)
        XCTAssertEqual(s.anteilBenutzt, 0.2375, accuracy: 0.0001)
    }

    func testSpeicherUeberlaeuftNicht() {
        // Mehr kaufbar als intern gibt es nicht, darf aber auch nicht unterlaufen.
        let z = SeitenZaehler(intern: 10, kaufbar: 20, extern: 0, wired: 0, komprimiert: 0)
        XCTAssertEqual(SystemRechnung.speicher(seiten: z, seitenGroesse: 4096, gesamt: 1 << 20).app, 0)
        // Mehr benutzt als vorhanden: frei bleibt bei null, der Anteil bei eins.
        let voll = SpeicherStand(gesamt: 100, app: 90, wired: 20, komprimiert: 10)
        XCTAssertEqual(voll.frei, 0)
        XCTAssertEqual(voll.anteilBenutzt, 1)
    }

    func testSpeicherdruckKennNurDieDreiStufen() {
        XCTAssertEqual(Speicherdruck(stufe: 1), .normal)
        XCTAssertEqual(Speicherdruck(stufe: 2), .erhoeht)
        XCTAssertEqual(Speicherdruck(stufe: 4), .kritisch)
        XCTAssertEqual(Speicherdruck(stufe: nil), .normal)
        XCTAssertEqual(Speicherdruck(stufe: 99), .normal)
    }

    // MARK: - Temperatur

    func testTemperaturenIgnorierenPlatzhalterUndKalibrierwerte() {
        // So meldet es ein M4 Pro im Leerlauf.
        let lesungen: [(name: String, wert: Double)] = [
            ("PMU tdie1", 26.9), ("PMU tdie2", 27.7), ("PMU tdie3", 26.1),
            ("PMU tdev1", -9202.9), ("PMU tcal", 51.8),
            ("gas gauge battery", 23.1), ("NAND CH0 temp", 24.0)
        ]
        let t = SystemRechnung.temperaturen(aus: lesungen)
        XCTAssertEqual(t.cpuMittel!, (26.9 + 27.7 + 26.1) / 3, accuracy: 0.0001)
        XCTAssertEqual(t.cpuMax, 27.7)
        XCTAssertEqual(t.akku, 23.1)
        XCTAssertEqual(t.ssd, 24.0)
    }

    func testTemperaturenOhneSensorenSindLeerStattNull() {
        let t = SystemRechnung.temperaturen(aus: [("PMU tdie1", -9202.9), ("PMU tdie2", 0)])
        XCTAssertNil(t.cpuMittel)
        XCTAssertNil(t.cpuMax)
        XCTAssertNil(t.akku)
        XCTAssertNil(t.ssd)
    }

    // MARK: - Netz

    func testZaehlerDifferenzUeberlebtDenUeberlauf() {
        XCTAssertEqual(SystemRechnung.zaehlerDifferenz(alt: 1000, neu: 1500), 500)
        // Der 32-Bit-Zaehler laeuft bei vier Milliarden ueber und beginnt von vorn.
        XCTAssertEqual(SystemRechnung.zaehlerDifferenz(alt: 4_294_967_000, neu: 100), 396)
        // Ein zurueckgesetzter Zaehler ist keine Datenmenge.
        XCTAssertEqual(SystemRechnung.zaehlerDifferenz(alt: 5000, neu: 10), 0)
    }

    // MARK: - Zeigen

    func testGroesseWaehltDieEinheitUndSetztDasKomma() {
        XCTAssertEqual(SystemRechnung.groesse(0).zahl, "0")
        XCTAssertEqual(SystemRechnung.groesse(0).einheit, "B")
        let ram = SystemRechnung.groesse(25_769_803_776)
        XCTAssertEqual(ram.zahl, "24,0")
        XCTAssertEqual(ram.einheit, "GB", "24 GiB heissen auch in „Ueber diesen Mac“ 24 GB")
        let platte = SystemRechnung.groesse(312_000_000_000, basis: 1000)
        XCTAssertEqual(platte.zahl, "312")
        XCTAssertEqual(platte.einheit, "GB")
        XCTAssertEqual(SystemRechnung.groesse(1500, basis: 1000).zahl, "1,5")
    }

    func testKompakteGroesseSparktDieNachkommastelleAbZehn() {
        XCTAssertEqual(SystemRechnung.groesse(12_300_000, basis: 1000, kompakt: true).zahl, "12")
        XCTAssertEqual(SystemRechnung.groesse(2_340_000, basis: 1000, kompakt: true).zahl, "2,3")
        // Ohne den Schalter bleibt die Stelle: das Netz zeigt „12,3 MB/s“.
        XCTAssertEqual(SystemRechnung.groesse(12_300_000, basis: 1000).zahl, "12,3")
    }

    func testRateHaengtProSekundeAn() {
        let r = SystemRechnung.rate(2_400_000)
        XCTAssertEqual(r.zahl, "2,4")
        XCTAssertEqual(r.einheit, "MB/s")
        XCTAssertEqual(SystemRechnung.rate(0).einheit, "B/s")
    }

    func testProzentBleibtZwischenNullUndHundert() {
        XCTAssertEqual(SystemRechnung.prozent(0.234), "23")
        XCTAssertEqual(SystemRechnung.prozent(1.5), "100")
        XCTAssertEqual(SystemRechnung.prozent(-1), "0")
    }

    func testLaufzeitZeigtDieGroebsteSinnvolleEinheit() {
        XCTAssertEqual(SystemRechnung.laufzeit(90), "1 Min")
        XCTAssertEqual(SystemRechnung.laufzeit(3 * 3600 + 120), "3 Std 2 Min")
        XCTAssertEqual(SystemRechnung.laufzeit(3 * 86400 + 4 * 3600 + 59), "3 T 4 Std")
    }

    // MARK: - Verlauf

    func testMessreiheBehaeltNurDieNeuestenWerte() {
        var r = Messreihe()
        for i in 0..<(Messreihe.laenge + 15) { r.fuegeAn(Double(i)) }
        XCTAssertEqual(r.werte.count, Messreihe.laenge)
        XCTAssertEqual(r.werte.last, Double(Messreihe.laenge + 14))
        XCTAssertEqual(r.werte.first, 15)
    }

    func testVerlaufSitztRechtsUndWaechstVonDortNachLinks() {
        let g = CGSize(width: 103, height: 33)
        let wenig = SystemVerlauf.punkte([0.5, 1.0], skala: 1, groesse: g)
        // Der neueste Wert steht am rechten Rand (3 Punkt Luft), der aeltere
        // knapp daneben statt in der Mitte der Flaeche.
        XCTAssertEqual(wenig[1].x, 100, accuracy: 0.001)
        XCTAssertGreaterThan(wenig[0].x, 95)
        // Ein voller Verlauf beginnt am linken Rand.
        let voll = SystemVerlauf.punkte(Array(repeating: 0.2, count: Messreihe.laenge), skala: 1, groesse: g)
        XCTAssertEqual(voll[0].x, 3, accuracy: 0.001)
        // Ganz oben ist ein voller Wert, ganz unten ein leerer.
        XCTAssertLessThan(wenig[1].y, wenig[0].y)
        // Eine Skala unter dem Wert kappt statt aus dem Bild zu laufen.
        let zuviel = SystemVerlauf.punkte([5], skala: 1, groesse: g)
        XCTAssertGreaterThanOrEqual(zuviel[0].y, 0)
    }

    func testFluegelStehtStillOhneDrehzahlUndDrehtSonstInGrenzen() {
        XCTAssertEqual(SystemAnsicht.fluegelWinkel(Date(), anteil: 1, dreht: false), 0)
        let w = SystemAnsicht.fluegelWinkel(Date(), anteil: 0.5, dreht: true)
        XCTAssertGreaterThanOrEqual(w, 0)
        XCTAssertLessThan(w, 360)
    }

    // MARK: - SMC

    func testSMCAnfrageHatDieGroesseDesTreibers() {
        // Der AppleSMC-Treiber erwartet genau 80 Byte. Weicht der Aufbau ab, wird
        // die Antwort stillschweigend leer.
        XCTAssertEqual(MemoryLayout<SMC.Anfrage>.stride, 80)
    }

    func testSMCLiestSchluesselNachDemZweistufigenAufruf() throws {
        // Der SMC antwortet auf die Typ-Abfrage ohne den Schluessel zurueckzugeben.
        // Wer den fuer den zweiten Aufruf aus der Antwort nimmt, fragt nach Schluessel 0
        // und bekommt nie einen Wert (so lieferte das Dashboard zuerst keine Luefter).
        let smc = try XCTUnwrap(SMC(), "kein SMC auf diesem Mac")
        // „FNum“ gibt es auf jedem Mac, auch ohne Luefter: dann ist es null.
        let anzahl = try XCTUnwrap(smc.zahl("FNum"), "FNum nicht lesbar")
        XCTAssertEqual(smc.luefter().count, Int(anzahl))
        XCTAssertNil(smc.zahl("ZZZZ"), "ein unbekannter Schluessel bleibt leer")
    }

    func testDieTemperaturQuelleLiestNurDieAngezeigtenSensorenEinmal() throws {
        XCTAssertTrue(HIDTemperatur.zeigtDasDashboard("PMU tdie3"))
        XCTAssertTrue(HIDTemperatur.zeigtDasDashboard("gas gauge battery"))
        XCTAssertTrue(HIDTemperatur.zeigtDasDashboard("NAND CH0 temp"))
        XCTAssertFalse(HIDTemperatur.zeigtDasDashboard("PMU tdev4"), "Platzhalter-Sensor")
        XCTAssertFalse(HIDTemperatur.zeigtDasDashboard("PMU tcal"), "Kalibrierwert")

        let quelle = try XCTUnwrap(HIDTemperatur(), "keine Temperatursensoren auf diesem Mac")
        let lesungen = quelle.lesungen()
        XCTAssertFalse(lesungen.isEmpty)
        // Jeder Name nur einmal: das System meldet viele Sensoren doppelt.
        XCTAssertEqual(Set(lesungen.map(\.name)).count, lesungen.count)
        XCTAssertTrue(lesungen.allSatisfy { HIDTemperatur.zeigtDasDashboard($0.name) })
    }

    // MARK: - Einbindung

    func testSystemIstEineEinschaltbareFunktionMitEigenemReiter() {
        XCTAssertTrue(Funktion.system.gebaut)
        XCTAssertTrue(Funktion.system.standardAn)
        XCTAssertEqual(WidgetSeite.system.symbol, Funktion.system.symbol)
        XCTAssertEqual(WidgetSeite(rawValue: "system"), .system)
    }

    func testEineMessungNachDemStoppenWirdVerworfen() {
        let dienst = SystemDienst.shared
        XCTAssertFalse(dienst.laeuft)
        var m = SystemStand()
        m.cpu = 0.77
        dienst.uebernehme(m)
        XCTAssertNotEqual(dienst.stand.cpu, 0.77)
    }

    // MARK: - Der echte Mac

    func testDerLeserLiefertSinnvolleWerteVomEchtenMac() throws {
        let leser = SystemLeser()
        Thread.sleep(forTimeInterval: 0.6)
        let s = leser.messe()
        try XCTSkipIf(s.kernLast.isEmpty, "keine Prozessordaten")

        XCTAssertEqual(s.kernLast.count, ProcessInfo.processInfo.processorCount)
        XCTAssertEqual(s.kerneP + s.kerneE, ProcessInfo.processInfo.processorCount)
        XCTAssertTrue((0...1).contains(s.cpu))
        XCTAssertTrue((0...1).contains(s.gpu))
        XCTAssertEqual(s.speicher.gesamt, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(s.speicher.benutzt, 0)
        XCTAssertLessThan(s.speicher.benutzt, s.speicher.gesamt)
        XCTAssertGreaterThan(s.plattenGesamt, 0)
        XCTAssertLessThanOrEqual(s.plattenFrei, s.plattenGesamt)
        XCTAssertGreaterThan(s.laufzeit, 0)
        XCTAssertFalse(s.chip.isEmpty)
        XCTAssertGreaterThanOrEqual(s.down, 0)
        XCTAssertGreaterThanOrEqual(s.up, 0)
        if let t = s.temperaturen.cpuMittel { XCTAssertTrue((10...110).contains(t), "Chiptemperatur \(t)") }
        for f in s.luefter { XCTAssertLessThanOrEqual(f.anteil, 1) }
    }

    // MARK: - Bild

    /// Malt das Dashboard in eine PNG-Datei, ohne Bildschirmaufnahme. Nur mit
    /// `SAPHIR_BILDER=/Ordner swift test --filter testBilderRendern`; sonst
    /// uebersprungen. Damit laesst sich die Gestaltung ansehen, obwohl
    /// `screencapture` hier nur Schwarz liefert.
    func testBilderRendern() throws {
        guard let ordner = ProcessInfo.processInfo.environment["SAPHIR_BILDER"] else {
            throw XCTSkip("SAPHIR_BILDER nicht gesetzt")
        }
        try FileManager.default.createDirectory(atPath: ordner, withIntermediateDirectories: true)

        // 1. Ausgedachte Last, damit alle Elemente etwas zu zeigen haben.
        var viel = SystemStand()
        viel.chip = "Apple M4 Pro"
        viel.kerneP = 8; viel.kerneE = 4; viel.gpuKerne = 16
        viel.kernLast = [0.2, 0.1, 0.05, 0.4, 0.9, 0.7, 0.55, 0.8, 0.3, 0.95, 0.6, 0.15]
        viel.cpu = 0.47; viel.gpu = 0.62
        viel.speicher = SpeicherStand(gesamt: 24 << 30, app: 9 << 30, wired: 3 << 30, komprimiert: 2 << 30,
                                      cache: 6 << 30, druck: .normal)
        viel.temperaturen = Temperaturen(cpuMittel: 61, cpuMax: 74, akku: 31, ssd: 38)
        viel.luefter = [Luefter(drehzahl: 3400, minimum: 2317, maximum: 7826),
                        Luefter(drehzahl: 3350, minimum: 2317, maximum: 7826)]
        viel.leistung = 23.4
        viel.akkuProzent = 64; viel.laedt = true; viel.amNetzteil = true
        viel.down = 3_400_000; viel.up = 420_000
        viel.plattenLesen = 12_000_000; viel.plattenSchreiben = 2_300_000
        viel.plattenFrei = 312_000_000_000; viel.plattenGesamt = 994_000_000_000
        viel.laufzeit = 3 * 86400 + 4 * 3600
        var verlaeufe = Verlaeufe()
        for i in 0..<Messreihe.laenge {
            let t = Double(i)
            var s = viel
            s.cpu = min(max(0.45 + 0.3 * sin(t / 5) + 0.1 * sin(t * 1.7), 0), 1)
            s.gpu = min(max(0.4 + 0.35 * sin(t / 7 + 1), 0), 1)
            s.down = max(0, 2_500_000 + 2_000_000 * sin(t / 6)); s.up = max(0, 400_000 + 300_000 * sin(t / 3))
            s.leistung = 20 + 8 * sin(t / 4)
            verlaeufe.fuegeAn(s)
        }
        try png(SystemAnsicht(stand: viel, verlaeufe: verlaeufe), nach: "\(ordner)/system-last.png")

        // 2. Leerlauf und fehlende Sensoren: Mac mini ohne Akku und Luefter.
        var ruhig = SystemStand()
        ruhig.chip = "Apple M2"
        ruhig.kerneP = 4; ruhig.kerneE = 4
        ruhig.kernLast = Array(repeating: 0.02, count: 8)
        ruhig.speicher = SpeicherStand(gesamt: 8 << 30, app: 2 << 30, wired: 1 << 30, komprimiert: 0, cache: 3 << 30)
        ruhig.plattenFrei = 80_000_000_000; ruhig.plattenGesamt = 256_000_000_000
        ruhig.laufzeit = 600
        try png(SystemAnsicht(stand: ruhig, verlaeufe: Verlaeufe()), nach: "\(ordner)/system-leer.png")

        // 3. Der echte Mac, so wie die Insel ihn gerade sieht.
        let leser = SystemLeser()
        var echt = Verlaeufe()
        var letzter = SystemStand()
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 1.0)
            letzter = leser.messe()
            echt.fuegeAn(letzter)
        }
        try png(SystemAnsicht(stand: letzter, verlaeufe: echt), nach: "\(ordner)/system-echt.png")
    }

    private func png<V: View>(_ inhalt: V, nach pfad: String) throws {
        // Schwarzer Grund wie die Insel, 500 breit wie die schmalste offene Flaeche.
        let flaeche = inhalt
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 500)
            .background(Color.black)
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: flaeche)
        renderer.scale = 3
        guard let bild = renderer.nsImage, let tiff = bild.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let daten = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("Bild konnte nicht gerendert werden: \(pfad)")
        }
        try daten.write(to: URL(fileURLWithPath: pfad))
    }
}
