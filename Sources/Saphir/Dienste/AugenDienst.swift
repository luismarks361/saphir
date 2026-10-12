import AppKit
import Foundation

/// Die 20-20-20-Regel: alle 20 Minuten 20 Sekunden lang 20 Fuss weit schauen.
///
/// Die Insel faehrt eine Zeile weit auf, zeigt ein Auge und zaehlt die
/// Sekunden herunter. Wer nicht mitmacht, muss nichts wegklicken.
@MainActor
final class AugenDienst {
    static let shared = AugenDienst()

    var zeige: ((HudAnzeige) -> Void)?

    static let abstand: TimeInterval = 20 * 60
    static let pause = 20

    private var takt: Timer?
    private var lauf: Timer?
    private var rest = 0

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.augenpause) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        takt = Timer.scheduledTimer(withTimeInterval: Self.abstand, repeats: true) { _ in
            MainActor.assumeIsolated { AugenDienst.shared.beginnePause() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        lauf?.invalidate()
        lauf = nil
    }

    /// Startet die Pause sofort. Auch von aussen aufrufbar.
    func beginnePause() {
        guard MenueleisteSichtbar.isShowing(on: NotchGeometrie.aktuell().screen) else { return }
        lauf?.invalidate()
        rest = Self.pause
        Klang.spiele(.erinnerung)
        melde()
        lauf = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let dienst = AugenDienst.shared
                dienst.rest -= 1
                guard dienst.rest > 0 else {
                    dienst.lauf?.invalidate()
                    dienst.lauf = nil
                    NotificationCenter.default.post(name: .saphirHudSchliessen, object: nil)
                    return
                }
                dienst.melde()
            }
        }
    }

    /// Der Ring fuellt sich, waehrend die Pause laeuft — die Zahl allein liest
    /// sich niemand aus dem Augenwinkel.
    private func melde() {
        zeige?(HudAnzeige(symbol: "eye",
                          text: "\(rest)",
                          anteil: Double(Self.pause - rest) / Double(Self.pause),
                          farbe: .mint))
    }
}
