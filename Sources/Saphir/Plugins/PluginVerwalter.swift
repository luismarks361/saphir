import Foundation
import SwiftUI

/// Ein Ordner unter `~/.saphir/plugins`, gelesen oder mit Mangel.
struct PluginInfo: Identifiable, Equatable {
    let id: String
    let ordner: URL
    let manifest: PluginManifest?
    /// Warum das Manifest nicht taugt. Steht dann statt eines Schalters in den
    /// Einstellungen, damit ein Tippfehler nicht still ein totes Plugin ergibt.
    let mangel: String?

    var name: String { manifest?.name ?? id }
}

enum PluginStand: Equatable {
    case aus
    case wartet
    case ok(Date)
    case fehler(String)
}

/// Findet die Plugins, ruft sie im Takt ab und haengt ihre Antworten an die
/// drei Stellen der Insel: Kachel, Live-Aktivitaet, HUD-Zeile.
///
/// Die Insel selbst weiss nichts von Plugins. Eine Plugin-Kachel liegt im
/// `WidgetRegister`, eine Plugin-Aktivitaet in `LiveAktivitaeten`, genau wie
/// die eingebauten, nur mit `plugin` statt `funktion` als Schalter.
@MainActor
final class PluginVerwalter: ObservableObject {
    static let shared = PluginVerwalter()

    nonisolated static var standardOrdner: URL { Ablage.ordner.appendingPathComponent("plugins", isDirectory: true) }
    nonisolated static var standardDaten: URL { Ablage.ordner.appendingPathComponent("plugin-daten", isDirectory: true) }

    @Published private(set) var plugins: [PluginInfo] = []
    @Published private(set) var stand: [String: PluginStand] = [:]
    @Published private(set) var kacheln: [String: [PluginAntwort.Baustein]] = [:]

    /// Wohin eine HUD-Meldung geht, mit ihrer Standzeit. Setzt der AppDelegate.
    var zeigeHud: ((HudAnzeige, Double) -> Void)?

    private let ordner: URL
    private let datenOrdner: URL
    private let defaults: UserDefaults
    private var takte: [String: Timer] = [:]
    private var laeuft: Set<String> = []
    private var wartendeAktion: [String: String] = [:]
    private var letzteHud: [String: String] = [:]

    init(ordner: URL = PluginVerwalter.standardOrdner,
         datenOrdner: URL = PluginVerwalter.standardDaten,
         defaults: UserDefaults = .standard) {
        self.ordner = ordner
        self.datenOrdner = datenOrdner
        self.defaults = defaults
    }

    static func liveId(_ plugin: String) -> String { "plugin.\(plugin)" }
    static func kachelId(_ plugin: String) -> String { "plugin.\(plugin)" }

    // MARK: - Schalter und Einstellungen

    /// Neue Plugins sind aus: sie laufen als Programm mit deinen Rechten, das
    /// soll eine bewusste Entscheidung sein.
    func istAn(_ id: String) -> Bool { defaults.bool(forKey: "plugin.\(id).an") }

    func setzeAn(_ id: String, _ an: Bool) {
        defaults.set(an, forKey: "plugin.\(id).an")
        objectWillChange.send()
        if let info = plugins.first(where: { $0.id == id }) { gleicheAb(info) } else { stoppe(id) }
        NotificationCenter.default.post(name: .saphirFunktionGeaendert, object: nil)
    }

    func wert(_ id: String, _ feld: PluginManifest.Feld) -> String {
        switch feld.typ {
        case .geheim:
            return Schluesselbund.lies("plugin.\(id).\(feld.schluessel)") ?? ""
        case .text:
            return defaults.string(forKey: "plugin.\(id).e.\(feld.schluessel)") ?? feld.standard ?? ""
        }
    }

    func setzeWert(_ id: String, _ feld: PluginManifest.Feld, _ neu: String) {
        switch feld.typ {
        case .geheim: Schluesselbund.setze(neu.isEmpty ? nil : neu, fuer: "plugin.\(id).\(feld.schluessel)")
        case .text: defaults.set(neu, forKey: "plugin.\(id).e.\(feld.schluessel)")
        }
    }

    private func werte(_ manifest: PluginManifest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: manifest.felder.map { ($0.schluessel, wert(manifest.id, $0)) })
    }

    // MARK: - Finden

    func starte() { neuEinlesen() }

    /// Liest den Ordner neu und gleicht die laufenden Plugins an. Neue Ordner
    /// erscheinen so ohne Neustart der App.
    func neuEinlesen() {
        var gefunden: [PluginInfo] = []
        let fm = FileManager.default
        let eintraege = (try? fm.contentsOfDirectory(at: ordner, includingPropertiesForKeys: nil)) ?? []
        for url in eintraege.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var istOrdner: ObjCBool = false
            guard fm.fileExists(atPath: url.appendingPathComponent("plugin.json").path, isDirectory: &istOrdner),
                  !istOrdner.boolValue else { continue }
            do {
                let manifest = try PluginManifest.lade(aus: url)
                gefunden.append(PluginInfo(id: manifest.id, ordner: url, manifest: manifest, mangel: nil))
            } catch {
                gefunden.append(PluginInfo(id: url.lastPathComponent, ordner: url, manifest: nil,
                                           mangel: "\(error)"))
            }
        }
        plugins = gefunden

        let ids = Set(gefunden.map(\.id))
        for id in Set(takte.keys).union(stand.keys) where !ids.contains(id) { stoppe(id) }
        for info in gefunden {
            // Mit neuem Takt oder neuem Programm im Manifest: sauber neu starten.
            stoppe(info.id, behalteStand: true)
            gleicheAb(info)
        }
        NotificationCenter.default.post(name: .saphirFunktionGeaendert, object: nil)
    }

    private func gleicheAb(_ info: PluginInfo) {
        guard let manifest = info.manifest, istAn(info.id) else {
            stoppe(info.id)
            return
        }
        guard takte[info.id] == nil else { return }
        if stand[info.id] == nil || stand[info.id] == .aus { stand[info.id] = .wartet }
        takte[info.id] = Timer.scheduledTimer(withTimeInterval: manifest.taktSekunden, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.frageAb(info.id) }
        }
        frageAb(info.id)
    }

    private func stoppe(_ id: String, behalteStand: Bool = false) {
        takte[id]?.invalidate()
        takte[id] = nil
        wartendeAktion[id] = nil
        letzteHud[id] = nil
        LiveAktivitaeten.shared.entferne(Self.liveId(id))
        entferneKachel(id)
        if behalteStand { return }
        if plugins.contains(where: { $0.id == id }) { stand[id] = .aus } else { stand[id] = nil }
    }

    // MARK: - Abfragen

    /// Ruft das Plugin einmal auf. Mit `aktion` ist es ein Knopfdruck, danach
    /// wird sofort neu abgefragt, damit die Kachel das Ergebnis zeigt.
    func frageAb(_ id: String, aktion: String? = nil) {
        guard takte[id] != nil,
              let info = plugins.first(where: { $0.id == id }),
              let manifest = info.manifest,
              let programm = manifest.programm(in: info.ordner) else { return }
        if laeuft.contains(id) {
            // Ein Knopfdruck waehrend einer Abfrage geht nicht verloren.
            if let aktion { wartendeAktion[id] = aktion }
            return
        }
        laeuft.insert(id)

        let daten = datenOrdner.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: daten, withIntermediateDirectories: true)
        let anfrage = PluginLauf.Anfrage(befehl: aktion == nil ? "abfrage" : "aktion", aktion: aktion,
                                         einstellungen: werte(manifest), daten: daten.path)
        let wurzel = info.ordner

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let roh = PluginLauf.fuehreAus(programm: programm, ordner: wurzel, anfrage: anfrage)
            let ergebnis: Result<PluginAntwort?, PluginLauf.Fehler>
            switch roh {
            case .failure(let fehler):
                ergebnis = .failure(fehler)
            case .success(let bytes):
                if aktion != nil {
                    ergebnis = .success(nil)
                } else {
                    switch PluginLauf.lies(bytes) {
                    case .success(let antwort): ergebnis = .success(antwort)
                    case .failure(let fehler): ergebnis = .failure(fehler)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fertig(id, aktion: aktion, ergebnis) }
            }
        }
    }

    func fuehreAktionAus(_ id: String, _ aktion: String) { frageAb(id, aktion: aktion) }

    private func fertig(_ id: String, aktion: String?, _ ergebnis: Result<PluginAntwort?, PluginLauf.Fehler>) {
        laeuft.remove(id)
        // Inzwischen abgeschaltet: die Antwort kommt zu spaet.
        guard takte[id] != nil else { return }

        switch ergebnis {
        case .failure(let fehler):
            fehlgeschlagen(id, "\(fehler)")
        case .success(let antwort):
            if let antwort {
                // Nur der Wechsel ins Gute steht im Protokoll, nicht jeder Takt.
                if case .ok = stand[id] {} else { Protokoll.info("Plugin \(id): antwortet") }
                uebernehme(id, antwort)
                stand[id] = .ok(Date())
            } else {
                // Eine Aktion hat gelaufen: die Kachel soll das Ergebnis zeigen.
                frageAb(id)
                return
            }
        }
        if let wartend = wartendeAktion.removeValue(forKey: id) { frageAb(id, aktion: wartend) }
    }

    private func fehlgeschlagen(_ id: String, _ text: String) {
        if stand[id] != .fehler(text) { Protokoll.fehler("Plugin \(id): \(text)") }
        stand[id] = .fehler(text)
        // Eine veraltete Anzeige waere schlimmer als keine: ein Countdown, der
        // nicht mehr stimmt, ist eine Falschmeldung.
        LiveAktivitaeten.shared.entferne(Self.liveId(id))
        entferneKachel(id)
    }

    // MARK: - Anhaengen

    func uebernehme(_ id: String, _ antwort: PluginAntwort) {
        guard let manifest = plugins.first(where: { $0.id == id })?.manifest else { return }

        if manifest.andocken.contains(.live), let live = antwort.live,
           live.links != nil || live.rechts != nil {
            LiveAktivitaeten.shared.zeige(LiveAktivitaet(
                id: Self.liveId(id), plugin: id, prioritaet: manifest.livePrioritaet,
                links: live.links?.inhalt, rechts: live.rechts?.inhalt))
        } else {
            LiveAktivitaeten.shared.entferne(Self.liveId(id))
        }

        if manifest.andocken.contains(.hud), let hud = antwort.hud, letzteHud[id] != hud.id {
            letzteHud[id] = hud.id
            Protokoll.info("Plugin \(id): Meldung \"\(hud.text)\"")
            zeigeHud?(HudAnzeige(symbol: hud.symbol, text: hud.text,
                                 anteil: hud.anteil.map { min(max($0, 0), 1) },
                                 farbe: PluginFarbe.farbe(hud.farbe)),
                      min(max(hud.sekunden ?? 5, 1), 30))
        }

        if manifest.andocken.contains(.kachel), let kachel = antwort.kachel {
            setzeKachel(manifest, kachel.bausteine)
        } else {
            entferneKachel(id)
        }
    }

    private func setzeKachel(_ manifest: PluginManifest, _ bausteine: [PluginAntwort.Baustein]) {
        if kacheln[manifest.id] != bausteine { kacheln[manifest.id] = bausteine }
        let id = Self.kachelId(manifest.id)
        guard !WidgetRegister.shared.kacheln.contains(where: { $0.id == id }) else { return }
        let plugin = manifest.id
        WidgetRegister.shared.melde(WidgetKachel(
            id: id, plugin: plugin, titel: manifest.name,
            symbol: manifest.symbol ?? "puzzlepiece.extension",
            spalten: manifest.kachelSpalten, reihenfolge: 20,
            inhalt: { AnyView(PluginKachelAnsicht(plugin: plugin)) }))
    }

    private func entferneKachel(_ id: String) {
        if kacheln[id] != nil { kacheln[id] = nil }
        WidgetRegister.shared.entferne(Self.kachelId(id))
    }
}
