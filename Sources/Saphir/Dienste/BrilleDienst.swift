import AppKit
import SwiftUI

/// Erinnert daran, die Blaulichtbrille aufzusetzen.
///
/// Ab 18 Uhr faehrt die Insel alle fuenfzehn Minuten eine Zeile weit auf,
/// zeigt die Brille mit einem Glanz darueber und schliesst sich von selbst
/// wieder. Kein Fenster, kein Ton, kein Wegklicken.
@MainActor
final class BrilleDienst {
    static let shared = BrilleDienst()

    /// Wohin die Erinnerung geht. Setzt der AppDelegate.
    var erinnere: ((HudAnzeige) -> Void)?

    static let abstand: TimeInterval = 15 * 60
    static let standzeit: TimeInterval = 5

    private var takt: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.brille) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        takt = Timer.scheduledTimer(withTimeInterval: Self.abstand, repeats: true) { _ in
            MainActor.assumeIsolated { BrilleDienst.shared.zeige() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
    }

    /// Zeigt die Erinnerung sofort. Auch von aussen aufrufbar.
    func zeige() {
        // Tagsueber schweigt sie: erinnert wird ab 18 Uhr, wenn das Licht
        // draussen weggeht und der Bildschirm das hellste im Raum ist.
        guard NachtDienst.istAbend(ab: NachtDienst.brilleAb) else { return }
        // Waehrend eine App im Vollbild laeuft, gibt es keine Menueleiste und
        // damit auch keinen Platz fuer die Insel — dann lieber schweigen als
        // in einen Film hineinplatzen.
        guard MenueleisteSichtbar.isShowing(on: NotchGeometrie.aktuell().screen) else { return }
        Klang.spiele(.erinnerung)
        erinnere?(HudAnzeige(symbol: "eyeglasses", text: "", farbe: .cyan, glanz: true))
    }
}
