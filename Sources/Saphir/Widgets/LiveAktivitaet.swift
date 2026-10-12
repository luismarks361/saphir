import AppKit
import SwiftUI

/// Was in einem der beiden Streifen neben der Kamera steht.
///
/// Bewusst Daten statt einer View: die Insel muss ihre Breite kennen, *bevor*
/// SwiftUI zeichnet — sonst zuckt die Form beim ersten Bild. Aus diesen Feldern
/// laesst sich die Breite ausrechnen, aus einer beliebigen View nicht.
struct LiveInhalt: Equatable {
    var symbol: String?
    var bild: NSImage?
    /// Die echte Marke eines Agenten statt eines Symbols. Wird eingefaerbt,
    /// nicht beschnitten — anders als das Albumcover in `bild`.
    var marke: Marke?
    var text: String?
    /// 0 bis 1. Zeigt einen schmalen Balken statt eines Textes.
    var anteil: Double?
    var farbe: Color = .white
    /// Tanzende Balken statt Text — wie in Apples Dynamic Island bei Musik.
    /// `false` laesst sie stehen (pausiert).
    var wellen: Wellen?
    /// Ein kleiner Punkt je Vorgang, in dessen Farbe. Fuer die Claude-Sessions:
    /// wie viele laufen, und wie es ihnen geht — ohne ein Wort.
    var punkte: [Color]?

    enum Wellen: Equatable { case tanzt, steht }

    enum Marke: Equatable { case claude }

    /// Maße aus dem Original: AlbumArtView ist 20 x 20 mit Radius 7,
    /// NowPlayingTextView schreibt in 10 pt halbfett, abgerundet.
    ///
    /// Das Cover ist bewusst etwas groesser als dort — 24 statt 20,
    /// der Radius im gleichen Verhaeltnis mit. Mehr geht nicht: die
    /// eingeklappte Insel ist nur die Hoehe der Notch hoch, und darunter darf
    /// kein Rand mehr wegfallen.
    static let symbolBreite: CGFloat = 24
    static let symbolRadius: CGFloat = 8
    static let balkenBreite: CGFloat = 38
    static let markeBreite: CGFloat = 15
    static let punktBreite: CGFloat = 6
    static let punktLuecke: CGFloat = 4
    static let wellenBreite: CGFloat = Wellenform.breite
    static let abstand: CGFloat = 6
    static let rand: CGFloat = 9
    static let schriftGroesse: CGFloat = 10
    static let schrift = NSFont.systemFont(ofSize: schriftGroesse, weight: .semibold)

    /// Wie breit dieser Inhalt sein will. Text wird echt gemessen, nicht geraten.
    var breite: CGFloat {
        var teile: [CGFloat] = []
        if bild != nil { teile.append(Self.symbolBreite) }
        else if marke != nil { teile.append(Self.markeBreite) }
        else if symbol != nil { teile.append(Self.symbolBreite) }
        if let text, !text.isEmpty {
            let gemessen = (text as NSString)
                .size(withAttributes: [.font: Self.schrift]).width
            teile.append(min(ceil(gemessen), 150))
        }
        if anteil != nil { teile.append(Self.balkenBreite) }
        if wellen != nil { teile.append(Self.wellenBreite) }
        if let punkte, !punkte.isEmpty {
            teile.append(CGFloat(punkte.count) * Self.punktBreite
                         + CGFloat(punkte.count - 1) * Self.punktLuecke)
        }
        guard !teile.isEmpty else { return 0 }
        let inhalt = teile.reduce(0, +) + CGFloat(teile.count - 1) * Self.abstand
        return inhalt + Self.rand * 2
    }
}

/// Ein laufender Vorgang, der sich in der eingeklappten Insel zeigen darf.
///
/// Eine Aktivitaet besetzt beide Seiten zugleich, nicht je eine — sonst
/// stuenden links die Musik und rechts der Akku, und niemand wuesste, was
/// zusammengehoert.
struct LiveAktivitaet: Identifiable, Equatable {
    let id: String
    /// Zu welcher Funktion sie gehoert. Ist die aus, verschwindet sie.
    var funktion: Funktion? = nil
    /// Oder zu welchem Plugin. Genau eines von beiden ist gesetzt.
    var plugin: String? = nil
    /// Wer gewinnt, wenn mehrere gleichzeitig wollen. Groesser schlaegt kleiner.
    var prioritaet: Int = 0
    var links: LiveInhalt?
    var rechts: LiveInhalt?

    /// Beide Ohren sind gleich breit — das ist keine Kosmetik.
    ///
    /// Sind sie verschieden, liegt die freigelassene Mitte nicht mehr ueber der
    /// physischen Notch: die ganze Zeile rutscht um die halbe Differenz, und
    /// Inhalt verschwindet unter der Aussparung. Im Screenshot ist das
    /// unsichtbar, weil der Framebuffer die Punkte trotzdem enthaelt — man
    /// sieht es nur auf dem echten Display. (Lehre aus Agent Island.)
    var ohrBreite: CGFloat {
        max(links?.breite ?? 0, rechts?.breite ?? 0)
    }

    /// Ob ihre Funktion oder ihr Plugin an ist.
    @MainActor
    var istAn: Bool {
        if let funktion { return Einstellungen.shared.istAn(funktion) }
        if let plugin { return PluginVerwalter.shared.istAn(plugin) }
        return false
    }
}

/// Wer gerade neben der Kamera stehen darf.
///
/// Es zeigt sich immer nur **eine** Aktivitaet. Zwei nebeneinander waeren in
/// einem Streifen von wenigen Zentimetern nicht mehr lesbar; das Original
/// macht es genauso.
@MainActor
final class LiveAktivitaeten: ObservableObject {
    static let shared = LiveAktivitaeten()

    @Published private(set) var alle: [LiveAktivitaet] = []

    private init() {
        // Wird eine Funktion abgeschaltet, faellt ihre Aktivitaet sofort weg.
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.melde() }
        }
    }

    /// Die Aktivitaet, die gerade gezeigt wird.
    var vorne: LiveAktivitaet? {
        alle.filter(\.istAn)
            .max { $0.prioritaet < $1.prioritaet }
    }

    /// Anlegen oder aktualisieren. Gleiche `id` ersetzt den alten Stand, damit
    /// ein laufender Titel nicht bei jedem Sekundenschlag neu einzieht.
    func zeige(_ neu: LiveAktivitaet) {
        if let i = alle.firstIndex(where: { $0.id == neu.id }) {
            guard alle[i] != neu else { return }
            alle[i] = neu
        } else {
            alle.append(neu)
        }
        melde()
    }

    func entferne(_ id: String) {
        guard alle.contains(where: { $0.id == id }) else { return }
        alle.removeAll { $0.id == id }
        melde()
    }

    private func melde() {
        NotificationCenter.default.post(name: .saphirLiveAktivitaetGeaendert, object: nil)
    }
}

extension Notification.Name {
    static let saphirLiveAktivitaetGeaendert = Notification.Name("saphir.liveaktivitaet.geaendert")
    /// Die HUD-Zeile hat ihren Zweck erfuellt und darf sofort verschwinden.
    static let saphirHudSchliessen = Notification.Name("saphir.hud.schliessen")
}
