import Foundation

/// Die Werte des System-Dashboards, jede Sekunde frisch.
///
/// Gemessen wird nur, solange die Seite sichtbar ist. Eine zugeklappte Insel
/// kostet damit nichts, auch wenn die Funktion an ist; dafuer fehlt der Kurve
/// beim Oeffnen die Zeit, in der niemand hingesehen hat.
@MainActor
final class SystemDienst: ObservableObject {
    static let shared = SystemDienst()

    @Published private(set) var stand = SystemStand()
    @Published private(set) var verlaeufe = Verlaeufe()

    /// Alle Messungen laufen auf dieser Warteschlange: der Leser merkt sich
    /// Zaehlerstaende und darf nur von einem Faden benutzt werden. Ein Timer auf
    /// der Hauptschleife wuerde ausserdem stehen, solange die Maus zieht.
    private let warteschlange = DispatchQueue(label: "saphir.system", qos: .utility)
    private let fach = LeserFach()
    private var takt: DispatchSourceTimer?

    /// Haelt den Leser. Gehoert der Warteschlange, nicht dem Hauptfaden: nur von
    /// dort wird er angelegt, benutzt und wieder weggeworfen. Das ist die Regel, die
    /// `@unchecked Sendable` hier traegt.
    private final class LeserFach: @unchecked Sendable {
        var leser: SystemLeser?
    }

    private init() {}

    var laeuft: Bool { takt != nil }

    func starte() {
        guard takt == nil else { return }
        // Der Leser legt beim Anlegen seine Ausgangsstaende fest. Damit die erste
        // Kurve nicht den ganzen Abstand seit dem letzten Mal mittelt, entsteht er
        // bei jedem Start neu.
        let fach = self.fach
        warteschlange.async { fach.leser = SystemLeser() }

        let timer = DispatchSource.makeTimerSource(queue: warteschlange)
        // Nach einer halben Sekunde die erste Messung, dann jede Sekunde.
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler {
            guard let leser = fach.leser else { return }
            let messung = leser.messe()
            Task { @MainActor in SystemDienst.shared.uebernehme(messung) }
        }
        timer.resume()
        takt = timer
    }

    func stoppe() {
        takt?.cancel()
        takt = nil
        let fach = self.fach
        warteschlange.async { fach.leser = nil }
    }

    /// Eine fertige Messung eintragen. Eine, die nach dem Stoppen noch ankommt,
    /// wird verworfen, sonst waechst die Kurve hinter der geschlossenen Insel.
    func uebernehme(_ messung: SystemStand) {
        guard laeuft else { return }
        stand = messung
        var neu = verlaeufe
        neu.fuegeAn(messung)
        verlaeufe = neu
    }
}
