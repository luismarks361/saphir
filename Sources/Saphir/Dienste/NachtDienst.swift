import AppKit
import CoreGraphics
import SwiftUI

/// Night Shift sitzt in einem privaten Framework. Der Umweg ueber ein
/// @objc-Protokoll ist der uebliche: die Klasse wird zur Laufzeit gesucht, und
/// wenn Apple sie umbenennt, faellt nur Night Shift aus, nicht die App.
@objc private protocol BlaulichtSchalter {
    @objc func setEnabled(_ an: Bool) -> Bool
    @objc func setStrength(_ staerke: Float, commit: Bool) -> Bool
}

/// Anti-Blaulicht: Night Shift ganz aufgedreht, Bildschirm dunkel, und die
/// Farbwiedergabe so verbogen, dass nur noch Rot uebrig bleibt.
///
/// Ab 18 Uhr erinnert Saphir an die Brille, ab 20 Uhr bietet es zusaetzlich
/// diesen Modus an. Angenommen wird das Angebot mit einem Druck in der Insel.
@MainActor
final class NachtDienst: ObservableObject {
    static let shared = NachtDienst()

    @Published private(set) var istAn = false

    /// Ab dieser Stunde erinnert die Brille.
    static let brilleAb = 18
    /// Ab dieser Stunde kommt das Angebot.
    static let angebotAb = 20
    /// Bis hierhin gilt der Abend. Danach ist ohnehin niemand mehr wach.
    static let bisStunde = 2

    /// Wie dunkel es wird. Drei von sechzehn Stufen der Helligkeitstaste —
    /// das ist die Stufe „zwei oder drei", die sich im Dunkeln noch bedienen laesst.
    static let helligkeit: Float = 3.0 / 16.0

    /// Wohin das Angebot geht. Setzt der AppDelegate.
    var biete: ((HudAnzeige) -> Void)?

    private var helligkeitVorher: Float?
    /// Auf welche Helligkeit die Wache zurueckstellt. Anfangs die Nachtstufe;
    /// stellt der Nutzer die Helligkeit selbst um, gilt ab da sein Wert.
    private var zielHelligkeit: Float = NachtDienst.helligkeit
    private var takt: Timer?
    private var helligkeitsWache: Timer?
    /// An welchem Tag das Angebot schon einmal stand. So kommt es einmal je
    /// Abend und nicht jede Minute wieder.
    private var angebotAm: Int?

    private init() {}

    func starte() {
        guard takt == nil else { return }
        takt = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { NachtDienst.shared.pruefeUhrzeit() }
        }
        pruefeUhrzeit()
    }

    /// Ob gerade Abend im Sinne dieser Funktion ist.
    static func istAbend(ab stunde: Int, _ jetzt: Date = Date()) -> Bool {
        let h = Calendar.current.component(.hour, from: jetzt)
        return h >= stunde || h < bisStunde
    }

    private func pruefeUhrzeit() {
        guard Einstellungen.shared.istAn(.nachtmodus) else { return }
        guard !istAn, Self.istAbend(ab: Self.angebotAb) else { return }

        // Der Abend gehoert zum Tag, an dem er begonnen hat: um ein Uhr nachts
        // soll nicht das Angebot vom Vortag noch einmal kommen.
        let tag = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let h = Calendar.current.component(.hour, from: Date())
        let abendTag = h < Self.bisStunde ? tag - 1 : tag
        guard angebotAm != abendTag else { return }
        angebotAm = abendTag

        biete?(HudAnzeige(symbol: "moon.stars.fill", text: "",
                          farbe: .orange, angebot: true))
    }

    // MARK: - An und aus

    func schalte() { istAn ? aus() : an() }

    func an() {
        guard !istAn else { return }
        helligkeitVorher = Systemsteuerung.helligkeit()
        zielHelligkeit = Self.helligkeit

        // Erst das Sichere, dann das Private: faellt Night Shift aus, wirkt
        // der Rest trotzdem.
        rotFilter(an: true)
        Systemsteuerung.setzeHelligkeit(Self.helligkeit)
        nachtSchicht(an: true)

        // Der Lichtsensor dreht die Helligkeit von selbst wieder hoch. Ohne
        // diese Wache stand sie nach wenigen Sekunden wieder bei 44 statt bei
        // 19 Prozent. Sie zieht nur nach unten: eine Helligkeit, die schon
        // niedriger ist, bleibt in Ruhe. Und sie zieht auf den Zielwert, nicht
        // auf die Nachtstufe: wer die Helligkeit absichtlich anhebt, soll nicht
        // nach zehn Sekunden wieder im Dunkeln sitzen.
        helligkeitsWache?.invalidate()
        helligkeitsWache = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard NachtDienst.shared.istAn else { return }
                let ziel = NachtDienst.shared.zielHelligkeit
                guard Systemsteuerung.helligkeit() > ziel + 0.05 else { return }
                Systemsteuerung.setzeHelligkeit(ziel)
            }
        }

        istAn = true
        Klang.spiele(.nacht)
        Protokoll.info("Nachtmodus an")
        melde()
    }

    /// Der Nutzer stellt die Helligkeit mit der Taste um. Die Wache ist gegen den
    /// Lichtsensor da, nicht gegen ihn: ab jetzt haelt sie diesen Wert.
    func helligkeitVonHand(_ wert: Float) {
        guard istAn else { return }
        zielHelligkeit = wert
    }

    func aus() {
        guard istAn else { return }
        helligkeitsWache?.invalidate()
        helligkeitsWache = nil

        nachtSchicht(an: false)
        rotFilter(an: false)
        if let vorher = helligkeitVorher { Systemsteuerung.setzeHelligkeit(vorher) }

        helligkeitVorher = nil
        istAn = false
        Protokoll.info("Nachtmodus aus")
        melde()
    }

    /// Beim Beenden muss die Farbwiedergabe zurueck. Sie haengt am Bildschirm,
    /// nicht an der App — bliebe sie verbogen, saehe der ganze Mac rot aus.
    func aufraeumen() {
        if istAn { aus() }
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: - Rotfilter

    /// Verbiegt die Farbwiedergabe so, dass Gruen und Blau fast ganz
    /// verschwinden. Uebrig bleibt ein gedaempftes Rot — das Licht, das die
    /// Augen abends am wenigsten stoert.
    private func rotFilter(an: Bool) {
        guard an else {
            CGDisplayRestoreColorSyncSettings()
            return
        }
        for bildschirm in NSScreen.screens {
            guard let kennung = bildschirm.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
            CGSetDisplayTransferByFormula(kennung,
                                          0, 0.62, 1.0,   // Rot bleibt, aber gedaempft
                                          0, 0.05, 1.0,   // Gruen fast weg
                                          0, 0.00, 1.0)   // Blau ganz weg
        }
    }

    // MARK: - Night Shift

    private var schalter: BlaulichtSchalter? {
        let pfad = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
        guard dlopen(pfad, RTLD_LAZY) != nil,
              let klasse = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
            return nil
        }
        return unsafeBitCast(klasse.init(), to: BlaulichtSchalter.self)
    }

    /// Der Stand vorher wird bewusst NICHT abgefragt.
    ///
    /// `getBlueLightStatus:` fuellt eine Struktur, deren Groesse nirgends
    /// steht. Ein zu kleiner Puffer wird ueberschrieben, und der Mac stuerzt
    /// erst spaeter ab, wenn der naechste Speicherzugriff auf den Schaden
    /// trifft — genau das ist hier passiert. Beim Abschalten geht Night Shift
    /// deshalb immer aus, auch wenn es vorher schon lief.
    private func nachtSchicht(an: Bool) {
        guard let schalter else {
            Protokoll.info("Night Shift nicht erreichbar, Rotfilter uebernimmt allein")
            return
        }
        if an { _ = schalter.setStrength(1.0, commit: true) }
        _ = schalter.setEnabled(an)
    }

    // MARK: - Insel

    private func melde() {
        guard istAn else {
            LiveAktivitaeten.shared.entferne("nacht")
            return
        }
        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "nacht", funktion: .nachtmodus, prioritaet: 4,
            links: LiveInhalt(symbol: "moon.stars.fill", farbe: .orange)
        ))
    }
}
