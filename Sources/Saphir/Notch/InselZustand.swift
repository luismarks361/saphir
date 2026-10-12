import SwiftUI

/// Kurze Anzeige unterhalb der Notch: Lautstaerke, Helligkeit, ein verbundenes
/// Bluetooth-Geraet. Die Insel oeffnet sich dafuer nur eine Zeile weit.
struct HudAnzeige: Equatable {
    let symbol: String
    let text: String
    /// 0 bis 1, oder nil wenn es nichts zu fuellen gibt.
    let anteil: Double?
    let farbe: Color
    /// Nur das Symbol, gross und mit einem Glanz darueber. Fuer Erinnerungen,
    /// die nichts messen — die Brille zum Beispiel.
    let glanz: Bool
    /// Ein Angebot statt einer Meldung: daneben stehen Ja und Nein.
    let angebot: Bool

    init(symbol: String, text: String, anteil: Double? = nil,
         farbe: Color = .white, glanz: Bool = false, angebot: Bool = false) {
        self.symbol = symbol
        self.text = text
        self.anteil = anteil
        self.farbe = farbe
        self.glanz = glanz
        self.angebot = angebot
    }
}

/// Gemeinsamer Zustand zwischen AppKit und SwiftUI.
///
/// Die Groessen hier sind die *Zielgroessen*; SwiftUI animiert dorthin. Das
/// Fenster selbst bleibt unveraendert gross — nur die Form darin waechst.
@MainActor
final class InselZustand: ObservableObject {
    @Published var geometrie: NotchGeometrie = .aktuell()
    @Published var istOffen: Bool = false
    @Published var istUeberfahren: Bool = false
    /// Vom Stecknadel-Knopf gesetzt: bleibt offen, auch wenn die Maus geht.
    @Published var istAngeheftet: Bool = false
    /// Steht oben die Menueleiste? Fehlt sie, laeuft eine App im Vollbild und
    /// die eingeklappte Insel verschmilzt mit deren schwarzem Streifen — dann
    /// darf kein Schatten darunter stehen bleiben.
    @Published var menueleisteSichtbar: Bool = true

    /// Breite der Live-Aktivitaet links und rechts der Notch, vom Inhalt selbst
    /// gemeldet. Die Insel ist dadurch genau so breit, wie sie sein muss.
    @Published var breiteLinks: CGFloat = 0
    @Published var breiteRechts: CGFloat = 0
    /// Hoehe, die die aufgeklappte Flaeche haben moechte.
    @Published var hoeheOffen: CGFloat = 260
    /// Welche Widget-Seite gerade vorne liegt.
    @Published var seite: WidgetSeite = .start

    @Published var hud: HudAnzeige?

    /// Hoehe der HUD-Zeile unterhalb der Notch: Rand 12, Inhalt 24, Rand 12.
    static let hudZeilenHoehe: CGFloat = 48

    var groesseOffen: CGSize {
        // Breite: so schmal wie moeglich. Links neben der Notch muessen alle
        // Reiter Platz haben, sonst rutschen sie unter die Kamera; darunter
        // gibt die Untergrenze den Widgets ihre Flaeche.
        let reiterBreite = CGFloat(WidgetSeite.reiter.count) * 32 + 14
        // Hoehe: meldet der Inhalt selbst. Untergrenze ist die Notch plus eine
        // Handbreit, damit eine leere Seite nicht zur Pille schrumpft.
        return CGSize(width: max(NotchGeometrie.breiteOffen,
                                 geometrie.notchBreite + reiterBreite * 2),
                      height: min(max(hoeheOffen, geometrie.notchHoehe + 60),
                                  NotchGeometrie.maxHoeheOffen))
    }

    var groesseHud: CGSize {
        // 280 ist die Breite aus dem Original; schmaler als die Notch darf sie
        // nie werden.
        CGSize(width: max(geometrie.notchBreite + 40, 280),
               height: geometrie.notchHoehe + Self.hudZeilenHoehe)
    }

    /// Wie hoch die Seite unter der Notch gezeichnet wird.
    var hoeheInhalt: CGFloat { groesseOffen.height - geometrie.notchHoehe }

    /// Ob der Inhalt hoeher ist, als die Insel werden darf.
    var inhaltRollt: Bool { hoeheOffen > NotchGeometrie.maxHoeheOffen }

    var groesseEingeklappt: CGSize {
        CGSize(width: geometrie.notchBreite + breiteLinks + breiteRechts,
               height: geometrie.notchHoehe)
    }

    /// Die Groesse, in der die Insel gerade gezeichnet werden soll.
    var zielGroesse: CGSize {
        if istOffen { return groesseOffen }
        if hud != nil { return groesseHud }
        return groesseEingeklappt
    }

    /// Nichts zu zeigen: die Notch soll unberuehrt aussehen.
    var istStumm: Bool {
        !istOffen && hud == nil && breiteLinks == 0 && breiteRechts == 0
    }
}

/// Die Seiten der aufgeklappten Flaeche. Waechst mit den Funktionen mit.
enum WidgetSeite: String, CaseIterable, Identifiable {
    case start
    case agenten
    case musik
    case regal
    case kalender
    case zwischenablage
    case notizen
    case zonen
    case einstellungen

    var id: String { rawValue }

    /// Die Reiter links neben der Notch, in ihrer Reihenfolge. Abgeschaltete
    /// Funktionen haben keinen Reiter; die Einstellungen sitzen rechts neben
    /// der Stecknadel und stehen deshalb nicht in dieser Liste.
    @MainActor
    static var reiter: [WidgetSeite] {
        allCases.filter { seite in
            switch seite {
            case .einstellungen: return false
            case .start: return true
            case .agenten: return Einstellungen.shared.istAn(.agenten)
            case .musik: return Einstellungen.shared.istAn(.musik)
            case .regal: return Einstellungen.shared.istAn(.dateiRegal)
            case .kalender: return Einstellungen.shared.istAn(.kalender)
            case .zwischenablage: return Einstellungen.shared.istAn(.zwischenablage)
            case .notizen: return Einstellungen.shared.istAn(.notizen)
            case .zonen: return Einstellungen.shared.istAn(.snapZones)
            }
        }
    }

    var symbol: String {
        switch self {
        case .start: return "square.grid.2x2"
        case .agenten: return "sparkle"
        case .musik: return "music.note"
        case .regal: return "tray.full"
        case .kalender: return "calendar"
        case .zwischenablage: return "doc.on.clipboard"
        case .notizen: return "note.text"
        case .zonen: return "rectangle.split.2x2"
        case .einstellungen: return "gearshape"
        }
    }

    var name: String {
        switch self {
        case .start: return "Uebersicht"
        case .agenten: return "Sessions"
        case .musik: return "Musik"
        case .regal: return "Regal"
        case .kalender: return "Kalender"
        case .zwischenablage: return "Zwischenablage"
        case .notizen: return "Notizen"
        case .zonen: return "Zonen"
        case .einstellungen: return "Einstellungen"
        }
    }
}

/// Der Inhalt meldet seine Breite nach oben, damit die Insel mitwaechst.
struct BreiteLinksKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct BreiteRechtsKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Die groesste gemeldete Hoehe gewinnt, nicht die zuletzt gemeldete.
///
/// `value = nextValue()` sieht harmlos aus, ist hier aber falsch: SwiftUI faltet
/// auch Kinder ein, die gar nichts melden, und deren Standardwert ist null. Bei
/// einem Hintergrund als Messfuehler kam so am Ende immer null heraus.
struct HoeheOffenKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
