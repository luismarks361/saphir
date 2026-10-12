import AppKit

/// Steht oben gerade die Menüleiste — oder malt eine App im Vollbild dort ihr
/// eigenes Schwarz?
///
/// Läuft eine App im Vollbild, ist der Streifen über ihr schwarz, und die Insel
/// verschmilzt damit exakt: eingeklappt ist sie genau so hoch wie die Notch.
/// Sichtbar bleibt dann nur noch ihr Schatten, der als weicher Rand in den
/// App-Inhalt ragt. Genau dafür ist dieser Wächter da.
///
/// Gemessen wird nicht „ist eine App im Vollbild“, sondern das, worauf es
/// ankommt: liegt oben noch das Menüleisten-Fenster? Der Weg über die Fenster-
/// liste war der einzige, der im Test getragen hat (17.08.2026):
///
/// - `NSScreen.visibleFrame` ändert sich im Vollbild **nicht** (blieb bei 1130
///   von 1169) — für einen Hintergrundprozess also nutzlos.
/// - Das Vollbild-Fenster der App selbst taucht nur während des Übergangs eine
///   Sekunde lang in der Liste auf, danach nicht mehr (eigener Space).
/// - Das Menüleisten-Fenster dagegen ist ein verlässlicher Schalter: Ebene 24
///   (`.mainMenuWindow`), Eigentümer „Window Server“, volle Bildschirmbreite,
///   39 pt hoch. Im Vollbild fällt es aus der Liste und kommt beim Verlassen
///   zurück — sauber und ohne Flackern.
///
/// Berechtigungen braucht das keine: nur Fenster*namen* sind seit 10.15 gesperrt,
/// Ebene und Maße nicht.
///
/// Bekannter Grenzfall: Wer die Menüleiste in den Systemeinstellungen automatisch
/// ausblenden lässt, bekommt auch auf dem normalen Schreibtisch „nicht sichtbar“
/// gemeldet — dort fehlt der Schatten dann über dem Hintergrundbild. Kostet im
/// schlimmsten Fall einen Schatten, keine Funktion.
enum MenueleisteSichtbar {

    static func isShowing(on screen: NSScreen) -> Bool {
        let frame = screen.frame
        // Fensterliste rechnet von oben links des Hauptbildschirms, NSScreen von
        // unten links — für Bildschirme über/unter dem Hauptschirm muss das oben
        // umgerechnet werden.
        guard let main = NSScreen.screens.first?.frame else { return true }
        let topY = main.maxY - frame.maxY

        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else {
            // Keine Auskunft: Schatten anlassen. So sah die Insel immer aus.
            return true
        }

        let menuLayer = Int(CGWindowLevelForKey(.mainMenuWindow))
        for window in list {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == menuLayer,
                  let b = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0
            let width = b["Width"] ?? 0, height = b["Height"] ?? 0

            if abs(x - frame.minX) < 2, abs(y - topY) < 2,
               abs(width - frame.width) < 2, height > 10, height < 80 {
                return true
            }
        }
        return false
    }
}
