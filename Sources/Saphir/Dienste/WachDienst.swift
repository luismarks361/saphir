import Foundation
import IOKit.pwr_mgt
import SwiftUI

/// Haelt den Mac wach.
///
/// Ueber IOPMAssertion, nicht ueber einen `caffeinate`-Prozess: das ist
/// dieselbe Schnittstelle, die `caffeinate` selbst benutzt, nur ohne fremden
/// Prozess, der ueberwacht und beim Beenden aufgeraeumt werden muesste. Zwei
/// Zusicherungen — eine gegen den Ruhezustand des Rechners, eine gegen das
/// Abschalten des Bildschirms.
@MainActor
final class WachDienst: ObservableObject {
    static let shared = WachDienst()

    @Published private(set) var istAn = false
    /// Bis wann es laeuft. Nil heisst: bis es jemand abschaltet.
    @Published private(set) var bisWann: Date?

    /// Die waehlbaren Zeiten. Nil ist „ohne Ende".
    static let zeiten: [TimeInterval?] = [15 * 60, 60 * 60, nil]

    private var rechner: IOPMAssertionID = 0
    private var bildschirm: IOPMAssertionID = 0
    private var uhr: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.istAn,
                      !Einstellungen.shared.istAn(.caffeinate) else { return }
                self.aus()
            }
        }
    }

    func schalte(dauer: TimeInterval?) {
        if istAn, bisWann == nil, dauer == nil { aus(); return }
        if istAn, let bisWann, let dauer,
           abs(bisWann.timeIntervalSinceNow - dauer) < 60 { aus(); return }
        an(dauer: dauer)
    }

    func an(dauer: TimeInterval?) {
        if !istAn {
            let name = "Saphir haelt den Mac wach" as CFString
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &rechner)
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &bildschirm)
            istAn = true
            Protokoll.info("Wach halten an")
        }

        bisWann = dauer.map { Date().addingTimeInterval($0) }
        uhr?.invalidate()
        uhr = nil
        guard bisWann != nil else { melde(); return }

        // Sekundentakt, damit die verbleibende Zeit in der Insel mitlaeuft.
        uhr = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let dienst = WachDienst.shared
                guard let ende = dienst.bisWann else { return }
                if ende.timeIntervalSinceNow <= 0 { dienst.aus() } else { dienst.melde() }
            }
        }
        melde()
    }

    func aus() {
        uhr?.invalidate()
        uhr = nil
        bisWann = nil
        guard istAn else { return }
        IOPMAssertionRelease(rechner)
        IOPMAssertionRelease(bildschirm)
        rechner = 0
        bildschirm = 0
        istAn = false
        Protokoll.info("Wach halten aus")
        melde()
    }

    /// Die verbleibende Zeit als m:ss, oder nil wenn es ohne Ende laeuft.
    var restText: String? {
        guard let bisWann else { return nil }
        let rest = max(0, Int(bisWann.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d", rest / 60, rest % 60)
    }

    // MARK: - Insel

    private func melde() {
        guard istAn else {
            LiveAktivitaeten.shared.entferne("wach")
            return
        }
        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "wach",
            funktion: .caffeinate,
            // Musik gewinnt: die laeuft laenger und aendert sich staendig.
            // Dass wach gehalten wird, sagt dann das Menueleisten-Symbol.
            prioritaet: 5,
            links: LiveInhalt(symbol: "cup.and.saucer.fill", farbe: .orange),
            rechts: LiveInhalt(text: restText, farbe: .orange)
        ))
    }
}
