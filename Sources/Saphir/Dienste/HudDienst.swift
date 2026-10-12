import AppKit
import ApplicationServices
import IOKit.hidsystem
import SwiftUI

/// Der Rueckruf des Ereignisfilters muss eine freie Funktion sein, er kann
/// nichts einfangen. Er reicht alles an den einen Dienst weiter.
private func hudRueckruf(proxy: CGEventTapProxy, art: CGEventType,
                         ereignis: CGEvent, kontext: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if art == .tapDisabledByTimeout || art == .tapDisabledByUserInput {
        DispatchQueue.main.async { MainActor.assumeIsolated { HudDienst.shared.filterWiederAn() } }
        return Unmanaged.passRetained(ereignis)
    }
    if art.rawValue == UInt32(NX_SYSDEFINED) {
        var geschluckt = false
        MainActor.assumeIsolated { geschluckt = HudDienst.shared.taste(ereignis) }
        if geschluckt { return nil }
    }
    return Unmanaged.passRetained(ereignis)
}

/// Ersetzt die graue Systemanzeige fuer Lautstaerke und Helligkeit durch die
/// Zeile unter der Notch.
///
/// Der Weg ist derselbe wie im Original: ein Ereignisfilter faengt die
/// Sondertasten ab und **schluckt** sie. Das System sieht den Tastendruck nie
/// und blendet darum auch seine eigene Anzeige nicht ein; die Aenderung nimmt
/// Saphir selbst vor. Das kostet die Bedienungshilfen-Freigabe — ohne sie
/// bleibt alles beim Alten, statt dass die Tasten tot sind.
@MainActor
final class HudDienst {
    static let shared = HudDienst()

    /// Wohin die fertige Anzeige geht. Setzt der AppDelegate.
    var anzeigen: ((HudAnzeige) -> Void)?

    /// Werte aus dem Original: Schrittweite 6 Prozent, mit Wahl- und
    /// Umschalttaste 1 Prozent; erste Wiederholung nach 0.22 s, dann alle
    /// 0.055 s; die Anzeige steht 2.5 s.
    private static let schritt: Float = 0.06
    private static let feinSchritt: Float = 0.01
    private static let ersteWiederholung: TimeInterval = 0.22
    private static let wiederholung: TimeInterval = 0.055
    static let standzeit: TimeInterval = 2.5

    private enum Richtung { case lauter, leiser, heller, dunkler

        var funktion: Funktion {
            switch self {
            case .lauter, .leiser: return .lautstaerkeHud
            case .heller, .dunkler: return .helligkeitHud
            }
        }

        var vorzeichen: Float { (self == .lauter || self == .heller) ? 1 : -1 }
    }

    private var filter: CFMachPort?
    private var quelle: CFRunLoopSource?
    private var laufende: Richtung?
    private var takt: Timer?
    private var wiederholungen = 0
    private var warteAufFreigabe: Timer?

    private init() {}

    // MARK: - Filter

    func starte() {
        guard filter == nil else { return }
        guard AXIsProcessTrusted() else {
            warteAufFreigabeBeginnen()
            return
        }
        warteAufFreigabe?.invalidate()
        warteAufFreigabe = nil

        filter = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << NX_SYSDEFINED),
            callback: hudRueckruf,
            userInfo: nil)

        guard let filter else {
            Protokoll.info("Ereignisfilter fuer die Sondertasten liess sich nicht anlegen")
            return
        }
        quelle = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, filter, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), quelle, .commonModes)
        CGEvent.tapEnable(tap: filter, enable: true)
        Protokoll.info("Sondertasten werden abgefangen")
    }

    /// Ohne Freigabe gibt es keinen Filter. Statt aufzugeben wird gewartet:
    /// Die Freigabe kommt oft erst, wenn man die Freigaben-Seite sieht, und dann
    /// soll die Anzeige ohne Neustart laufen.
    private func warteAufFreigabeBeginnen() {
        guard warteAufFreigabe == nil else { return }
        warteAufFreigabe = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                HudDienst.shared.starte()
            }
        }
    }

    fileprivate func filterWiederAn() {
        guard let filter else { return }
        CGEvent.tapEnable(tap: filter, enable: true)
    }

    // MARK: - Tasten

    /// Gibt zurueck, ob das Ereignis geschluckt wurde.
    fileprivate func taste(_ ereignis: CGEvent) -> Bool {
        guard let nachricht = NSEvent(cgEvent: ereignis),
              nachricht.type == .systemDefined,
              nachricht.subtype.rawValue == 8 else { return false }

        let daten = nachricht.data1
        let code = Int32((daten & 0xFFFF_0000) >> 16)
        let art = (daten & 0xFF00) >> 8
        let gedrueckt = art == 0x0A
        let losgelassen = art == 0x0B

        if code == NX_KEYTYPE_MUTE {
            guard Einstellungen.shared.istAn(.lautstaerkeHud) else { return false }
            if gedrueckt { stumm() }
            return true
        }

        let richtung: Richtung
        switch code {
        case NX_KEYTYPE_SOUND_UP: richtung = .lauter
        case NX_KEYTYPE_SOUND_DOWN: richtung = .leiser
        case NX_KEYTYPE_BRIGHTNESS_UP: richtung = .heller
        case NX_KEYTYPE_BRIGHTNESS_DOWN: richtung = .dunkler
        default: return false
        }

        guard Einstellungen.shared.istAn(richtung.funktion) else { return false }
        // Ohne DisplayServices koennte Saphir die Helligkeit zwar anzeigen,
        // aber nicht stellen. Dann lieber gar nicht einmischen.
        if richtung.funktion == .helligkeitHud, !Systemsteuerung.helligkeitVerfuegbar { return false }

        if gedrueckt, laufende == nil {
            beginne(richtung)
        } else if losgelassen, laufende == richtung {
            beende()
        }
        return true
    }

    private func beginne(_ richtung: Richtung) {
        laufende = richtung
        wiederholungen = 0
        aendere()
        takt?.invalidate()
        takt = Timer.scheduledTimer(withTimeInterval: Self.ersteWiederholung, repeats: false) { _ in
            MainActor.assumeIsolated {
                let dienst = HudDienst.shared
                dienst.takt?.invalidate()
                dienst.takt = Timer.scheduledTimer(withTimeInterval: Self.wiederholung, repeats: true) { _ in
                    MainActor.assumeIsolated { HudDienst.shared.wiederhole() }
                }
            }
        }
    }

    /// Von null auf hundert sind es siebzehn Schritte. Wer hundert erreicht,
    /// haelt keine Taste mehr — dann ist das Loslassen verloren gegangen
    /// (moeglich, wenn das System den Filter zwischendurch abschaltet). Ohne
    /// diese Grenze liefe die Lautstaerke endlos weiter.
    private func wiederhole() {
        wiederholungen += 1
        guard wiederholungen < 100 else { return beende() }
        aendere()
    }

    private func beende() {
        takt?.invalidate()
        takt = nil
        laufende = nil
    }

    // MARK: - Aendern

    private func aendere() {
        guard let laufende else { return beende() }
        // Wahltaste und Umschalttaste zusammen: ein Prozent je Druck, wie im
        // System selbst.
        let flaggen = NSEvent.modifierFlags
        let fein = flaggen.contains(.option) && flaggen.contains(.shift)

        switch laufende {
        case .lauter, .leiser:
            let neu = naechster(Systemsteuerung.lautstaerke(),
                                vorzeichen: laufende.vorzeichen, fein: fein)
            Systemsteuerung.setzeLautstaerke(neu)
            Systemsteuerung.setzeStumm(neu == 0)
            zeige(lautstaerke: neu, stumm: neu == 0)
        case .heller, .dunkler:
            let neu = naechster(Systemsteuerung.helligkeit(),
                                vorzeichen: laufende.vorzeichen, fein: fein)
            Systemsteuerung.setzeHelligkeit(neu)
            NachtDienst.shared.helligkeitVonHand(neu)
            zeige(helligkeit: neu)
        }
    }

    private func stumm() {
        beende()
        let warStumm = Systemsteuerung.istStumm()
        Systemsteuerung.setzeStumm(!warStumm)
        let stand = warStumm ? Systemsteuerung.lautstaerke() : 0
        zeige(lautstaerke: stand, stumm: !warStumm)
    }

    /// Grob rastet auf das Vielfache der Schrittweite ein, fein zaehlt vom
    /// aktuellen Stand weiter. Beides wie im Original.
    private func naechster(_ jetzt: Float, vorzeichen: Float, fein: Bool) -> Float {
        let neu: Float
        if fein {
            neu = jetzt + Self.feinSchritt * vorzeichen
        } else {
            let stufe = (jetzt / Self.schritt).rounded()
            neu = (stufe + vorzeichen) * Self.schritt
        }
        return min(max(neu, 0), 1)
    }

    // MARK: - Anzeige

    private func zeige(lautstaerke: Float, stumm: Bool) {
        anzeigen?(HudAnzeige(symbol: stumm ? "speaker.slash.fill" : lautsprecher(lautstaerke),
                             text: "\(Int(lautstaerke * 100))%",
                             anteil: Double(lautstaerke),
                             farbe: Self.tonwert(lautstaerke)))
    }

    private func zeige(helligkeit: Float) {
        anzeigen?(HudAnzeige(symbol: "sun.max.fill",
                             text: "\(Int((helligkeit * 100).rounded()))%",
                             anteil: Double(helligkeit),
                             farbe: Self.tonwert(helligkeit)))
    }

    private func lautsprecher(_ stand: Float) -> String {
        if stand == 0 { return "speaker.slash.fill" }
        if stand < 0.33 { return "speaker.wave.1.fill" }
        if stand < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    /// Die mitwachsende Farbe des Originals: ab 60 Prozent gelb, ab 90 rot.
    static func tonwert(_ stand: Float) -> Color {
        if stand >= 0.9 { return .red }
        if stand > 0.6 { return .yellow }
        return .white
    }
}
