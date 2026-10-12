import AppKit

/// Wo die Notch physisch sitzt, und in welchem Fenster wir sie zeichnen.
///
/// Auf einem Mac mit Notch liefert `NSScreen` die beiden Menueleisten-Streifen
/// links und rechts davon (`auxiliaryTopLeftArea` / `auxiliaryTopRightArea`);
/// die Luecke dazwischen ist die Notch. Auf Macs ohne Notch erfinden wir eine
/// Flaeche mit ueblichen Massen, damit die App sich ueberall gleich verhaelt.
///
/// Uebernommen aus Agent Island, hier nur mit groesseren Ausklapp-Massen: Saphir
/// zeigt aufgeklappt eine Widget-Flaeche, keine Liste.
struct NotchGeometrie {
    let screen: NSScreen
    /// Die Notch selbst, in Bildschirmkoordinaten (Ursprung unten links).
    let notchRect: CGRect
    /// Wahr, wenn der Mac wirklich eine Notch hat (statt unserer erfundenen).
    let istEcht: Bool

    /// Untergrenze der aufgeklappten Breite. Schmal genug, dass kein leerer
    /// Raum stehen bleibt; wenn die Reiter mehr brauchen, waechst die Flaeche
    /// (siehe `InselZustand.groesseOffen`).
    static let breiteOffen: CGFloat = 500
    /// Obergrenze der Hoehe; laengere Inhalte scrollen.
    static let maxHoeheOffen: CGFloat = 380
    /// Luft rund um die Insel im Fenster, damit der Schatten nicht abgeschnitten wird.
    static let schattenLuft: CGFloat = 44

    static func aktuell(bevorzugt screen: NSScreen? = nil) -> NotchGeometrie {
        let ziel = screen ?? bildschirmMitNotch() ?? NSScreen.main ?? NSScreen.screens.first!
        let rahmen = ziel.frame

        let links = ziel.auxiliaryTopLeftArea
        let rechts = ziel.auxiliaryTopRightArea
        let einzug = ziel.safeAreaInsets.top

        if let links, let rechts, einzug > 0 {
            let breite = rechts.minX - links.maxX
            if breite > 40 {
                // Vier Punkte breiter als gemessen, wie im Original
                // (`measuredNotchSize`): je zwei Punkte Ueberlappung auf beiden
                // Seiten. Die gemessene Kante ist auf das Zehntel genau, der
                // gezeichnete Rand nicht — ohne die Ueberlappung steht bei
                // manchen Skalierungen ein heller Faden zwischen Insel und
                // Aussparung. Mittig bleibt es, weil beide Seiten gleich viel
                // bekommen.
                let ueberlappung: CGFloat = 4
                let rect = CGRect(x: links.maxX - ueberlappung / 2,
                                  y: rahmen.maxY - einzug,
                                  width: breite + ueberlappung,
                                  height: einzug)
                return NotchGeometrie(screen: ziel, notchRect: rect, istEcht: true)
            }
        }

        let hoehe = max(einzug, NSStatusBar.system.thickness, 24)
        let breite: CGFloat = 200
        let rect = CGRect(x: rahmen.midX - breite / 2,
                          y: rahmen.maxY - hoehe,
                          width: breite,
                          height: hoehe)
        return NotchGeometrie(screen: ziel, notchRect: rect, istEcht: false)
    }

    private static func bildschirmMitNotch() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 && $0.auxiliaryTopLeftArea != nil }
    }

    var notchHoehe: CGFloat { notchRect.height }
    var notchBreite: CGFloat { notchRect.width }

    /// Der eine, unveraenderliche Fensterrahmen. Gross genug fuer jeden Zustand,
    /// damit das Fenster selbst nie seine Groesse aendern muss — nur die Form
    /// darin. Genau daran haengt, dass das Auf- und Zuklappen fluessig aussieht.
    var fensterRahmen: CGRect {
        // Muss jeden Zustand fassen, auch den breitesten: die aufgeklappte
        // Flaeche waechst mit der Zahl der Reiter (`InselZustand.groesseOffen`),
        // und acht Reiter je Seite brauchen 540 Punkte plus die Kehlen.
        //
        // War das Fenster zu schmal, wuchs die SwiftUI-Ansicht darueber hinaus
        // und sass ab da **linksbuendig** statt mittig: die eingeklappte Insel
        // stand 25 Punkte neben der physischen Notch. Im Screenshot faellt das
        // nicht auf, gemessen schon.
        let breite = max(Self.breiteOffen, notchBreite + 600) + Self.schattenLuft * 2
        let hoehe = Self.maxHoeheOffen + Self.schattenLuft
        return CGRect(x: notchRect.midX - breite / 2,
                      y: notchRect.maxY - hoehe,
                      width: breite,
                      height: hoehe)
    }
}
