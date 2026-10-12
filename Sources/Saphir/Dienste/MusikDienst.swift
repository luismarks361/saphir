import AppKit
import SwiftUI

/// Was gerade laeuft.
struct Wiedergabe: Equatable {
    var app: Musikapp
    var titel: String
    var kuenstler: String
    var laeuft: Bool
    /// Sekunden.
    var position: Double
    var dauer: Double
    /// Kennung des Stuecks, um das Cover nicht bei jedem Takt neu zu laden.
    var stueckId: String

    var anteil: Double {
        guard dauer > 0 else { return 0 }
        return min(max(position / dauer, 0), 1)
    }
}

enum Musikapp: String, Equatable {
    case spotify
    case musik

    var bundleId: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .musik: return "com.apple.Music"
        }
    }

    var skriptname: String {
        switch self {
        case .spotify: return "Spotify"
        case .musik: return "Music"
        }
    }

    var name: String {
        switch self {
        case .spotify: return "Spotify"
        case .musik: return "Musik"
        }
    }
}

/// Liest die laufende Wiedergabe und steuert sie.
///
/// Weg ueber AppleScript, nicht ueber MediaRemote: das private Framework ist
/// seit macOS 15.4 fuer fremde Prozesse dicht. AppleScript kostet dafuer die
/// Automation-Freigabe je App — die steht in der Freigaben-Seite.
@MainActor
final class MusikDienst: ObservableObject {
    static let shared = MusikDienst()

    @Published private(set) var jetzt: Wiedergabe?
    @Published private(set) var cover: NSImage?
    /// Die tragende Farbe des Covers — traegt den Schein um die Insel und die
    /// Fortschrittsleiste, wie im Original.
    @Published private(set) var coverFarbe: Color = .white

    private var takt: Timer?
    private var coverFuer: String?
    private var coverLaeuft = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
        NotificationCenter.default.addObserver(
            forName: .saphirSpotifyVerbunden, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                SpotifyKonto.shared.pruefe(uri: self?.jetzt?.stueckId ?? "")
            }
        }
        taktPruefen()
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.musik) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        // Eine Sekunde: fein genug, dass der Fortschritt nicht springt, und
        // grob genug, dass die staendigen Apple-Events nicht auffallen.
        takt = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lies() }
        }
        lies()
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        setze(nil)
    }

    // MARK: - Lesen

    private func lies() {
        // Mit zugeklapptem Deckel friert „Deckel zu" Spotify ein. Ein Apple-Event
        // an eine eingefrorene App haengt den Hauptthread bis zum Timeout, und
        // dort laeuft auch das Auftauen beim Aufklappen: Saphir wartete auf
        // Spotify, Spotify auf Saphir. Zu ist der Deckel ohnehin, also nicht fragen.
        if DeckelDienst.shared.deckelZu { return }
        // Nur Apps fragen, die schon laufen. `tell application "Spotify"`
        // wuerde Spotify sonst STARTEN — eine Notch-Anzeige, die von selbst
        // Programme oeffnet, waere ein Fehler, kein Feature.
        let offen = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let kandidaten = [Musikapp.spotify, .musik].filter { offen.contains($0.bundleId) }

        for app in kandidaten {
            if let w = frage(app), w.laeuft {
                setze(w)
                return
            }
        }
        // Keiner spielt: pausierte Wiedergabe trotzdem zeigen, wenn es sie gibt.
        for app in kandidaten {
            if let w = frage(app) {
                setze(w)
                return
            }
        }
        setze(nil)
    }

    private func frage(_ app: Musikapp) -> Wiedergabe? {
        let dauerAusdruck = app == .spotify
            ? "((duration of current track) / 1000)"   // Spotify: Millisekunden
            : "(duration of current track)"            // Musik.app: Sekunden

        let skript = """
        tell application "\(app.skriptname)"
            if player state is stopped then return "-"
            set t to name of current track
            set k to artist of current track
            set p to player position
            set d to \(dauerAusdruck)
            set s to (player state as text)
            set i to (id of current track) as text
            return t & "\\n" & k & "\\n" & (p as text) & "\\n" & (d as text) & "\\n" & s & "\\n" & i
        end tell
        """

        guard let roh = ausfuehren(skript), roh != "-" else { return nil }
        let z = roh.components(separatedBy: "\n")
        guard z.count >= 6 else { return nil }

        return Wiedergabe(
            app: app,
            titel: z[0],
            kuenstler: z[1],
            laeuft: z[4] == "playing",
            position: zahl(z[2]),
            dauer: zahl(z[3]),
            stueckId: z[5]
        )
    }

    /// AppleScript liefert Zahlen in der Systemsprache — auf einem deutschen Mac
    /// mit Komma. `Double("120,04")` ergibt dort nil.
    private func zahl(_ s: String) -> Double {
        Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func setze(_ neu: Wiedergabe?) {
        guard neu != jetzt else { return }
        jetzt = neu
        meldeAktivitaet()
        coverPruefen()
        // Steht das Plus am Titel schon gefuellt da oder nicht?
        SpotifyKonto.shared.pruefe(uri: neu?.app == .spotify ? (neu?.stueckId ?? "") : "")
    }

    // MARK: - Cover

    private func coverPruefen() {
        guard let jetzt else {
            cover = nil
            coverFarbe = .white
            coverFuer = nil
            return
        }
        guard coverFuer != jetzt.stueckId, !coverLaeuft else { return }
        let id = jetzt.stueckId

        switch jetzt.app {
        case .spotify:
            // Nur die Adresse kommt per AppleScript; das Laden selbst gehoert
            // nicht auf den Hauptthread.
            let skript = "tell application \"Spotify\" to return artwork url of current track"
            guard let s = ausfuehren(skript), let url = URL(string: s) else { return }
            coverLaeuft = true
            Task { [weak self] in
                let daten = try? await URLSession.shared.data(from: url).0
                await MainActor.run {
                    self?.uebernimm(daten.flatMap(NSImage.init(data:)), fuer: id)
                }
            }

        case .musik:
            // Musik.app liefert die Bilddaten selbst; der Umweg ueber eine
            // Datei ist zuverlaessiger als Rohdaten im Skriptergebnis.
            let ziel = NSTemporaryDirectory() + "saphir-cover.tiff"
            let skript = """
            tell application "Music"
                if (count of artworks of current track) is 0 then return "-"
                set d to raw data of artwork 1 of current track
            end tell
            set f to open for access POSIX file "\(ziel)" with write permission
            set eof f to 0
            write d to f
            close access f
            return "ok"
            """
            guard ausfuehren(skript) == "ok" else { return }
            uebernimm(NSImage(contentsOfFile: ziel), fuer: id)
        }
    }

    private func uebernimm(_ bild: NSImage?, fuer id: String) {
        coverLaeuft = false
        // Inzwischen laeuft schon das naechste Stueck: verwerfen und neu holen.
        guard jetzt?.stueckId == id else { coverPruefen(); return }
        cover = bild
        coverFarbe = bild.flatMap(Bildfarbe.tragende) ?? .white
        coverFuer = id
        meldeAktivitaet()
    }

    // MARK: - Steuern

    func abspielenPause() { steuere("playpause") }
    func weiter() { steuere("next track") }
    func zurueck() {
        // Zweimal, weil "previous track" beim ersten Mal nur an den Anfang des
        // laufenden Stuecks springt, sobald es ein paar Sekunden laeuft.
        if let jetzt, jetzt.position > 3 {
            springeAuf(0)
        } else {
            steuere("previous track")
        }
    }

    func springeAuf(_ sekunden: Double) {
        guard let app = jetzt?.app else { return }
        let wert = String(format: "%.2f", sekunden)
        _ = ausfuehren("tell application \"\(app.skriptname)\" to set player position to \(wert)")
        lies()
    }

    /// Holt die laufende Musik-App nach vorn — der Klick auf Cover oder Titel.
    ///
    /// Bewusst nur aktivieren und nicht `spotify:track:...` oeffnen: das wuerde
    /// das laufende Stueck von vorn starten.
    func zeigeInApp() {
        guard let app = jetzt?.app else { return }
        NSRunningApplication
            .runningApplications(withBundleIdentifier: app.bundleId)
            .first?
            .activate()
    }

    private func steuere(_ befehl: String) {
        guard let app = jetzt?.app else { return }
        _ = ausfuehren("tell application \"\(app.skriptname)\" to \(befehl)")
        lies()
    }

    // MARK: - AppleScript

    private func ausfuehren(_ quelltext: String) -> String? {
        var fehler: NSDictionary?
        // Ohne eigene Frist wartet ein Apple-Event 2 Minuten auf eine App, die
        // haengt oder eingefroren ist, und blockiert solange den Hauptthread.
        let begrenzt = "with timeout of 2 seconds\n\(quelltext)\nend timeout"
        let ergebnis = NSAppleScript(source: begrenzt)?.executeAndReturnError(&fehler)
        if let fehler {
            let nr = fehler[NSAppleScript.errorNumber] as? Int ?? 0
            // -1743 = Automation nicht erlaubt. Einmal melden reicht, sonst
            // stuende das im Sekundentakt im Protokoll.
            if nr == -1743, !automationGemeldet {
                automationGemeldet = true
                Protokoll.fehler("Musik: keine Automation-Freigabe. Einstellungen → Freigaben.")
            }
            return nil
        }
        return ergebnis?.stringValue
    }

    private var automationGemeldet = false

    // MARK: - Anzeige

    private func meldeAktivitaet() {
        guard let jetzt else {
            LiveAktivitaeten.shared.entferne("musik")
            return
        }
        LiveAktivitaeten.shared.zeige(LiveAktivitaet(
            id: "musik",
            funktion: .musik,
            prioritaet: 10,
            // Eingeklappt wie Apples Dynamic Island: links das Cover, rechts
            // die tanzenden Balken. Kein Titel, kein Fortschritt — der Titel
            // steht aufgeklappt.
            links: LiveInhalt(bild: cover, farbe: coverFarbe),
            rechts: LiveInhalt(farbe: coverFarbe, wellen: jetzt.laeuft ? .tanzt : .steht)
        ))
    }
}
