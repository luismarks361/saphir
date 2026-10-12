import SwiftUI

/// Die Startseite der aufgeklappten Flaeche: alle Widgets in einem Raster.
struct Uebersicht: View {
    @ObservedObject private var register = WidgetRegister.shared
    @ObservedObject private var einstellungen = Einstellungen.shared

    var body: some View {
        let kacheln = register.sichtbare
        if kacheln.isEmpty {
            LeereFlaeche(symbol: "square.grid.2x2")
        } else {
            VStack(spacing: 10) {
                    ForEach(Self.zeilen(aus: kacheln), id: \.first!.id) { zeile in
                        HStack(spacing: 10) {
                            ForEach(zeile) { kachel in
                                Kachelrahmen(kachel: kachel)
                            }
                            // Eine einzelne schmale Kachel bleibt schmal, statt
                            // sich auf die ganze Zeile zu ziehen.
                            if zeile.count == 1 && zeile[0].spalten < 2 {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Zwei schmale Kacheln teilen sich eine Zeile, eine breite bekommt sie
    /// ganz. LazyVGrid kann das nicht — dort gibt es keine Kachel ueber zwei
    /// Spalten (`gridCellColumns` gilt nur im `Grid`).
    static func zeilen(aus kacheln: [WidgetKachel]) -> [[WidgetKachel]] {
        var zeilen: [[WidgetKachel]] = []
        var offen: [WidgetKachel] = []
        for kachel in kacheln {
            if kachel.spalten >= 2 {
                if !offen.isEmpty { zeilen.append(offen); offen = [] }
                zeilen.append([kachel])
            } else {
                offen.append(kachel)
                if offen.count == 2 { zeilen.append(offen); offen = [] }
            }
        }
        if !offen.isEmpty { zeilen.append(offen) }
        return zeilen
    }
}

/// Der Rahmen um jedes Widget: Titelzeile, darunter der Inhalt.
struct Kachelrahmen: View {
    let kachel: WidgetKachel

    var body: some View {
        // Keine Ueberschrift: das Widget zeigt selbst, was es ist.
        kachel.inhalt()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glas(radius: 14)
    }
}
