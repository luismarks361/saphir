import Foundation
import Observation
import SwiftUI

/// Deckel zu und trotzdem wach: die Schnittstelle zwischen Saphir und dem
/// Motor aus Insomnia (siehe `HERKUNFT.md`).
///
/// Der Motor (`SessionManager` und alles darunter) bleibt unveraendert und
/// kennt Saphir nicht. Dieser Dienst ist die einzige Stelle, die beide
/// kennt: er baut den Motor beim Start auf, raeumt eine liegengebliebene
/// Sitzung ab (`reconcile`), reicht Start, Verlaengern und Ende durch und
/// spiegelt die laufende Sitzung als Live-Aktivitaet in die Insel.
///
/// Anders als „Wach halten" (`WachDienst`, eine IOPMAssertion wie
/// `caffeinate`) haelt das den Mac auch bei zugeklapptem Deckel wach. Dafuer
/// braucht es `pmset disablesleep`, also Root-Rechte: eine einmalige
/// sudoers-Regel, die `doku/deckel-einrichten.sh` anlegt. Deshalb hat jede
/// Sitzung ein Ende; „ohne Ende" gibt es hier nicht.
@MainActor
@Observable
final class DeckelDienst {
    static let shared = DeckelDienst()

    /// Die waehlbaren Zeiten. Kuerzer als bei „Wach halten": mit zugeklapptem
    /// Deckel lohnt sich eine Viertelstunde kaum.
    static let zeiten: [TimeInterval] = [60 * 60, 4 * 60 * 60, 8 * 60 * 60]

    /// Der Motor. Erst nach `starte()` da.
    private(set) var manager: SessionManager?
    /// Ob die sudoers-Regel steht. Ohne sie scheitert jeder Start.
    private(set) var eingerichtet = false
    /// Der Modus der Wach-Kachel: aus = klassisch wach halten, an = auch bei
    /// zugeklapptem Deckel. Standardmaessig **an**; bleibt ueber Neustarts stehen.
    /// Gespeichert als eigene Eigenschaft statt als reiner Durchgriff auf
    /// `UserDefaults`: nur so merkt die Kachel, dass er sich geaendert hat.
    var modusAn: Bool = UserDefaults.standard.object(forKey: "deckelModus") as? Bool ?? true {
        didSet { UserDefaults.standard.set(modusAn, forKey: "deckelModus") }
    }

    @ObservationIgnored private var beendet = false
    /// Letzter gemeldeter Stand, damit die Menueleiste nur bei einem Wechsel
    /// benachrichtigt wird und nicht mit jedem Sekundenschlag.
    @ObservationIgnored private var zuletztAn = false

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

    // MARK: - Stand

    var istAn: Bool { manager?.isActive ?? false }

    /// Bis wann die Sitzung laeuft.
    var bisWann: Date? { manager?.session?.endsAt }

    /// Die Restzeit so, wie der Motor sie zaehlt (`MM:SS`, `H:MM:SS` ...).
    var restText: String? {
        guard let manager, manager.isActive, !manager.countdownText.isEmpty else { return nil }
        return manager.countdownText
    }

    var deckelZu: Bool { manager?.services?.status.lidClosed ?? false }

    /// Was der Motor zuletzt nicht geschafft hat. Nil, solange alles glatt ist.
    var fehler: String? { manager?.lastError }

    /// Haengt noch etwas, das nach einer Sitzung haette zurueckgesetzt werden
    /// muessen? Dann gehoert das vor jedem Zuklappen angeschaut.
    var wiederherstellungOffen: Bool { manager?.state.isDirty == true && !istAn }

    // MARK: - Start

    /// Beim Start der App: Motor aufbauen, Wächter bereitstellen, eine
    /// liegengebliebene Sitzung abraeumen.
    func starte() {
        guard manager == nil else { return }
        let paths = Paths.fromEnvironment()
        Self.skriptBereitstellen(paths: paths)
        let neu = SessionManager.live(paths: paths)
        manager = neu
        pruefeEinrichtung()
        beobachte()
        Task { @MainActor in
            await neu.reconcile()
            self.melde()
        }
    }

    /// Haengt die Insel an den Motor: jede Aenderung von Restzeit oder Stand
    /// schreibt die Live-Aktivitaet neu. `withObservationTracking` feuert nur
    /// einmal, deshalb haengt es sich nach jeder Aenderung neu an. Mit
    /// zugeklapptem Deckel steht der Sekundentakt des Motors still, und damit
    /// auch dieser Weg: kein Aufwachen im Rucksack.
    private func beobachte() {
        guard let manager, !beendet else { return }
        withObservationTracking {
            _ = manager.countdownText
            _ = manager.session
            _ = manager.services?.status.lidClosed
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.melde()
                self?.beobachte()
            }
        }
    }

    // MARK: - Bedienen

    /// Eine Sitzung starten, oder die laufende um `dauer` verlaengern.
    func an(dauer: TimeInterval) {
        guard let manager else { return }
        guard eingerichtet else {
            Protokoll.fehler("Deckel zu: sudoers-Regel fehlt, Start abgelehnt")
            EinstellungenFenster.shared.zeigen(bereich: "deckel")
            return
        }
        // Eine neue Sitzung loest ein laufendes klassisches „Wach halten" ab: die
        // Kachel zeigt im Deckel-Modus nur noch diese eine.
        if !manager.isActive, WachDienst.shared.istAn { WachDienst.shared.aus() }
        Task { @MainActor in
            if manager.isActive {
                await manager.extend(by: dauer)
            } else {
                await manager.start(duration: dauer)
            }
            self.melde()
        }
    }

    func aus() {
        guard let manager, manager.isActive else { return }
        Task { @MainActor in
            _ = await manager.end(reason: .user)
            self.melde()
        }
    }

    /// Beim Beenden von Saphir. Gibt zurueck, ob die App gehen darf: nur wenn
    /// der Mac wieder im Normalzustand ist. Sonst bleibt Saphir, damit der
    /// Motor sein Aufraeumen noch zu Ende bringt.
    func beendeFuerAbschied() async -> Bool {
        // Ohne Sitzung und ohne offenes Journal gibt es nichts zurueckzusetzen,
        // und ein Beenden ohne Anlass wuerde jedes Mal eine Meldung ausloesen.
        guard let manager, manager.isActive || manager.state.isDirty else { return true }
        let ergebnis = await manager.end(reason: .quit)
        switch ergebnis {
        case .restored, .incomplete(agentArmed: true):
            beendet = true
            LiveAktivitaeten.shared.entferne("deckel")
            return true
        case .locked, .incomplete(agentArmed: false), .sessionRetained, .journalUnreadable:
            Protokoll.fehler("Deckel zu: Beenden verschoben, Aufraeumen steht noch aus (\(ergebnis))")
            return false
        }
    }

    // MARK: - Einrichtung

    /// `sudo -n -l <befehl>` fragt nur, ob die Regel passt, und fuehrt nichts
    /// aus. Exit 0 heisst: die Regel steht.
    func pruefeEinrichtung() {
        Task { @MainActor in
            let ergebnis = try? await CancellableCommand().run(
                "/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
                timeout: 10)
            let steht = ergebnis?.succeeded ?? false
            if steht != self.eingerichtet {
                self.eingerichtet = steht
                Protokoll.info("Deckel zu: sudoers-Regel \(steht ? "steht" : "fehlt")")
            }
        }
    }

    /// Der Befehl, den der Nutzer einmal im Terminal ausfuehrt. Liegt im Repo, nicht
    /// im App-Paket: die Regel schreibt nach `/etc` und gehoert nicht in eine
    /// App, die sie sich selbst anlegt.
    static var einrichtungsBefehl: String {
        "cd ~/Code/privat/apps/saphir && ./doku/deckel-einrichten.sh"
    }

    /// Der Waechter-Job startet `backstop.sh` aus dem Anwendungsordner, nicht
    /// aus dem App-Paket: das Paket wird bei jedem Bau ersetzt, und der Job
    /// darf dann nicht ins Leere laufen. Gleicher Inhalt: nichts zu tun.
    private static func skriptBereitstellen(paths: Paths) {
        guard let quelle = Bundle.main.url(forResource: "deckel-backstop", withExtension: "sh"),
              let neu = try? Data(contentsOf: quelle) else {
            Protokoll.info("Deckel zu: kein Waechter-Skript im Paket (Lauf ohne App-Bundle)")
            return
        }
        let ziel = paths.backstopScript
        if let alt = try? Data(contentsOf: ziel), alt == neu { return }
        do {
            try paths.createDirectories()
            try neu.write(to: ziel, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ziel.path)
            Protokoll.info("Deckel zu: Waechter-Skript nach \(ziel.path) kopiert")
        } catch {
            Protokoll.fehler("Deckel zu: Waechter-Skript nicht kopiert: \(error.localizedDescription)")
        }
    }

    // MARK: - Insel

    private func melde() {
        let an = istAn
        if an != zuletztAn {
            zuletztAn = an
            NotificationCenter.default.post(name: .saphirDeckelGeaendert, object: nil)
        }
        guard let manager, manager.isActive, Einstellungen.shared.istAn(.caffeinate) else {
            LiveAktivitaeten.shared.entferne("deckel")
            return
        }
        let rest = restText ?? ""
        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "deckel",
            funktion: .caffeinate,
            // Ueber laufenden Sessions (8), unter der Musik (10) und einer
            // wartenden Freigabe (30). Bei 6 waere die Anzeige nie zu sehen:
            // Sessions laufen fast immer, und „Deckel zu" ist ein begrenzter
            // Zustand, der die Hardware aendert.
            prioritaet: 9,
            links: LiveInhalt(symbol: "laptopcomputer", farbe: .orange),
            rechts: LiveInhalt(text: rest.isEmpty ? nil : rest, farbe: .orange)
        ))
    }
}

extension Notification.Name {
    /// Eine Deckel-zu-Sitzung hat angefangen oder aufgehoert.
    static let saphirDeckelGeaendert = Notification.Name("saphir.deckel.geaendert")
}
