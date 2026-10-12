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

    /// Eine Freigabe wartet, und die Insel zeigt nur ihre Karte: kein Reiter, keine
    /// Session-Liste. Der dritte Zustand neben „offen“ und „HUD“; die offene
    /// Flaeche bleibt dafuer unangetastet. Ist die Insel zugleich offen, liegt die
    /// volle Flaeche darueber (siehe `zielGroesse`).
    @Published var zeigtFrage: Bool = false
    /// Hoehe der Karte samt Rand unter der Notch, vom Inhalt selbst gemeldet. Der
    /// Startwert ist eine einzeilige Freigabe (Ablehnen, Immer, Erlauben), damit
    /// die Insel nicht erst klein aufgeht und dann nachwaechst.
    @Published var hoeheFrage: CGFloat = 92

    /// Hoehe der HUD-Zeile unterhalb der Notch: Rand 12, Inhalt 24, Rand 12.
    static let hudZeilenHoehe: CGFloat = 48

    /// Breite des Frage-Panels. Schmaler als die offene Flaeche, die den Platz der
    /// Reiter braucht, aber breit genug, dass zwei Antworten je Zeile noch ganz
    /// dastehen (`WrapZeile`).
    static let breiteFrage: CGFloat = 440

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

    var groesseFrage: CGSize {
        // Schmaler als die Notch darf es nie werden (wie beim HUD). Die Hoehe
        // deckelt wie die offene Flaeche: eine Karte, die darueber hinausgeht,
        // laeuft nicht aus dem Fenster.
        CGSize(width: max(geometrie.notchBreite + 40, Self.breiteFrage),
               height: min(geometrie.notchHoehe + hoeheFrage, NotchGeometrie.maxHoeheOffen))
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
    ///
    /// Die Reihenfolge ist die Wertigkeit: die offene Flaeche schlaegt alles, dann
    /// kommt die Frage, dann die kurze HUD-Zeile. Eine Meldung darf die Frage
    /// nicht verdraengen, sonst waeren die Knoepfe weg und die Session haengt.
    var zielGroesse: CGSize {
        if istOffen { return groesseOffen }
        if zeigtFrage { return groesseFrage }
        if hud != nil { return groesseHud }
        return groesseEingeklappt
    }

    /// Unter der Notch steht eine Frage oder eine HUD-Zeile, die Insel ist aber
    /// nicht offen. Beide teilen sich Rundung, Kehle und Feder.
    var istKompakt: Bool { zeigtFrage || hud != nil }

    /// Ein Angebot (Nachtmodus) oder eine Frage wartet auf einen Klick. Die Knoepfe
    /// stehen unter der Notch, der Zeiger muss also hindurch: klappte die Insel
    /// dabei auf, ersetzte die grosse Flaeche die Karte, noch bevor der Zeiger die
    /// Knoepfe erreicht hat.
    var wartetAufKlick: Bool { hud?.angebot == true || zeigtFrage }

    /// Nichts zu zeigen: die Notch soll unberuehrt aussehen.
    var istStumm: Bool {
        !istOffen && !istKompakt && breiteLinks == 0 && breiteRechts == 0
    }

    // MARK: - Frage-Panel

    /// Eine Freigabe ist angekommen. Wahr, wenn dafuer das Frage-Panel aufgeht;
    /// falsch, wenn der Aufrufer die Sessions aufschlagen soll: entweder steht gar
    /// keine Frage an (`kurzZeigen`: Aufgabe fertig), oder die Insel ist schon offen,
    /// weil Luis sie selbst aufgemacht hat. Dort steht die Karte ganz oben, und
    /// alles bleibt, wie es war.
    func zeigeFrage(freigabeSteht: Bool) -> Bool {
        guard freigabeSteht, !istOffen else { return false }
        zeigtFrage = true
        return true
    }

    /// Das Frage-Panel besteht nur aus der Karte der Freigabe. Ist sie weg, bliebe
    /// ein leerer Streifen; deshalb geht das Panel mit ihr, auch wenn die Maus noch
    /// darueber steht. Wahr, wenn es dadurch gerade gegangen ist.
    func frageAbgleichen(freigabeSteht: Bool) -> Bool {
        guard zeigtFrage, !freigabeSteht else { return false }
        zeigtFrage = false
        return true
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

/// Dasselbe fuer das Frage-Panel, mit derselben Regel: die groesste Meldung
/// gewinnt. Ein eigener Schluessel, damit die beiden Flaechen sich beim
/// Ueberblenden nicht gegenseitig die Hoehe zuschreiben.
struct HoeheFrageKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
