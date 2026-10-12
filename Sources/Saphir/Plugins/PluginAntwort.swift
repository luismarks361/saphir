import SwiftUI

/// Was ein Plugin auf eine Abfrage zurueckgibt. Alle drei Teile sind optional:
/// fehlt einer, zeigt sich an dieser Stelle nichts mehr.
///
/// Bewusst nur Daten, keine Views. Die Live-Aktivitaet muss ihre Breite kennen,
/// bevor SwiftUI zeichnet (siehe `LiveInhalt`), und die Kachel soll in jedem
/// Plugin gleich aussehen, ohne dass es dafuer Saphirs Gestaltung kennen muss.
struct PluginAntwort: Decodable, Equatable {
    var live: Live?
    var hud: Hud?
    var kachel: Kachel?

    struct Live: Decodable, Equatable {
        var links: Ohr?
        var rechts: Ohr?
    }

    struct Ohr: Decodable, Equatable {
        var symbol: String?
        var text: String?
        var anteil: Double?
        var farbe: String?
    }

    struct Hud: Decodable, Equatable {
        /// Dieselbe Kennung zeigt sich nur einmal. Das Plugin darf die Meldung
        /// bei jeder Abfrage mitschicken, ohne dass sie ein zweites Mal aufgeht.
        var id: String
        var symbol: String
        var text: String
        var anteil: Double?
        var farbe: String?
        var sekunden: Double?
    }

    struct Kachel: Decodable, Equatable {
        var bausteine: [Baustein]
    }

    /// Ein Baustein der Kachel. `art` entscheidet, welche Felder gelten.
    ///
    ///   text    text, stil (gross | normal | klein), farbe
    ///   symbol  symbol, farbe
    ///   balken  anteil (0 bis 1), farbe
    ///   knopf   text, symbol, aktion
    ///   zeile   bausteine nebeneinander
    ///   spalte  bausteine untereinander
    ///
    /// Eine unbekannte `art` bleibt leer, statt die ganze Kachel zu kippen.
    struct Baustein: Decodable, Equatable {
        var art: String
        var text: String?
        var symbol: String?
        var stil: String?
        var farbe: String?
        var anteil: Double?
        var aktion: String?
        var bausteine: [Baustein]?
    }
}

extension PluginAntwort.Ohr {
    /// Texte neben der Kamera sind kurz. Was laenger ist, wuerde die Insel
    /// breiter ziehen als der Bildschirm Platz hat.
    static let maxZeichen = 24

    var inhalt: LiveInhalt {
        var t = text
        if let s = t, s.count > Self.maxZeichen { t = String(s.prefix(Self.maxZeichen - 1)) + "…" }
        return LiveInhalt(symbol: symbol, text: t, anteil: anteil.map { min(max($0, 0), 1) },
                          farbe: PluginFarbe.farbe(farbe))
    }
}

/// Farben, wie ein Plugin sie nennt: ein Name oder `#RRGGBB`.
enum PluginFarbe {
    static func farbe(_ name: String?, standard: Color = .white) -> Color {
        guard let name else { return standard }
        switch name.lowercased() {
        case "weiss": return .white
        case "blau": return .blue
        case "gruen": return .green
        case "gelb": return .yellow
        case "orange": return .orange
        case "rot": return .red
        case "cyan": return .cyan
        case "grau": return .gray
        default: break
        }
        guard name.hasPrefix("#"), name.count == 7,
              let wert = UInt32(name.dropFirst(), radix: 16) else { return standard }
        return Color(red: Double((wert >> 16) & 0xFF) / 255,
                     green: Double((wert >> 8) & 0xFF) / 255,
                     blue: Double(wert & 0xFF) / 255)
    }
}
