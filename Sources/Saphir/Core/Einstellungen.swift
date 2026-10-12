import Foundation
import ServiceManagement

/// Auf welchem Bildschirm die Insel sitzt.
enum BildschirmWahl: String, CaseIterable {
    case mitNotch   // das eingebaute Display mit der Notch
    case haupt      // der Bildschirm mit der Menueleiste
    case aktiv      // dem Mauszeiger folgen

    var beschriftung: String {
        switch self {
        case .mitNotch: return "Bildschirm mit Notch"
        case .haupt: return "Hauptbildschirm"
        case .aktiv: return "Aktiver Bildschirm"
        }
    }
}

/// Jede Funktion, die sich einzeln abschalten laesst.
///
/// Die Liste ist zugleich die Landkarte des Projekts: was hier steht, ist
/// geplant; was `gebaut` ist, laeuft schon und steht zur Auswahl.
enum Funktion: String, CaseIterable, Identifiable {
    case musik
    case agenten
    case lautstaerkeHud
    case helligkeitHud
    case helligkeitsBoost
    case audioJeApp
    case batterie
    case snapZones
    case dateiRegal
    case kalender
    case wetter
    case bluetooth
    case caffeinate
    case augenpause
    case brille
    case nachtmodus
    case notizen
    case zwischenablage
    case mitteilungen
    case sperrbildschirm
    case menueleiste
    case kurzbefehle
    case nearbyShare

    var id: String { rawValue }

    /// In der Insel steht kein Text — dort vertritt dieses Symbol die Funktion.
    var symbol: String {
        switch self {
        case .musik: return "music.note"
        case .agenten: return "sparkle"
        case .lautstaerkeHud: return "speaker.wave.2"
        case .helligkeitHud: return "sun.max"
        case .helligkeitsBoost: return "sun.max.fill"
        case .audioJeApp: return "hifispeaker"
        case .batterie: return "battery.100"
        case .snapZones: return "rectangle.split.2x2"
        case .dateiRegal: return "tray.full"
        case .kalender: return "calendar"
        case .wetter: return "cloud.sun"
        case .bluetooth: return "wave.3.right"
        case .caffeinate: return "cup.and.saucer"
        case .augenpause: return "eye"
        case .brille: return "eyeglasses"
        case .nachtmodus: return "moon.stars"
        case .notizen: return "note.text"
        case .zwischenablage: return "doc.on.clipboard"
        case .mitteilungen: return "bell"
        case .sperrbildschirm: return "lock"
        case .menueleiste: return "menubar.rectangle"
        case .kurzbefehle: return "command"
        case .nearbyShare: return "shareplay"
        }
    }

    var name: String {
        switch self {
        case .musik: return "Musik"
        case .agenten: return "Claude-Sessions"
        case .lautstaerkeHud: return "Lautstaerke-Anzeige"
        case .helligkeitHud: return "Helligkeits-Anzeige"
        case .helligkeitsBoost: return "Helligkeits-Boost"
        case .audioJeApp: return "Tonausgabe"
        case .batterie: return "Batterie"
        case .snapZones: return "Snap-Zones"
        case .dateiRegal: return "Datei-Regal"
        case .kalender: return "Kalender"
        case .wetter: return "Wetter"
        case .bluetooth: return "Bluetooth"
        case .caffeinate: return "Wach halten"
        case .augenpause: return "Augenpause"
        case .brille: return "Brillen-Erinnerung"
        case .nachtmodus: return "Anti-Blaulicht"
        case .notizen: return "Notizen"
        case .zwischenablage: return "Zwischenablage"
        case .mitteilungen: return "Mitteilungen in der Notch"
        case .sperrbildschirm: return "Sperrbildschirm"
        case .menueleiste: return "Menueleiste anpassen"
        case .kurzbefehle: return "Kurzbefehle"
        case .nearbyShare: return "Nearby Share"
        }
    }

    var erklaerung: String {
        switch self {
        case .musik: return "Laufende Wiedergabe in der Notch, mit Steuerung und Fortschritt."
        case .agenten: return "Laufende Claude-Code-Sessions, Freigaben und das Kontingent. Einmalig unter Claude Code verbinden."
        case .lautstaerkeHud: return "Ersetzt die graue Systemanzeige durch eine an der Notch."
        case .helligkeitHud: return "Dasselbe fuer die Bildschirmhelligkeit."
        case .helligkeitsBoost: return "Nutzt die XDR-Reserve fuer mehr als 100 Prozent."
        case .audioJeApp: return "Zwischen den Ausgabegeraeten wechseln."
        case .batterie: return "Ladestand, Zyklen und eine Ladegrenze gegen Alterung."
        case .snapZones: return "Fenster an eigene Raster andocken."
        case .dateiRegal: return "Dateien in die Notch ziehen und spaeter herausholen."
        case .kalender: return "Naechste Termine, Warnung kurz vorher."
        case .wetter: return "Wetter dauerhaft in der Notch."
        case .bluetooth: return "Meldung beim Verbinden, mit Akkustand."
        case .caffeinate: return "Verhindert den Ruhezustand per Knopf, standardmaessig auch bei zugeklapptem Deckel (mit Ende)."
        case .augenpause: return "Alle 20 Minuten 20 Sekunden in die Ferne schauen."
        case .brille: return "Ab 18 Uhr alle 15 Minuten kurz an die Blaulichtbrille erinnern."
        case .nachtmodus: return "Ab 20 Uhr anbieten: Night Shift ganz auf, Bildschirm dunkel, nur noch Rot."
        case .notizen: return "Schnellnotizen direkt in der Notch."
        case .zwischenablage: return "Verlauf der Zwischenablage mit Suche."
        case .mitteilungen: return "Mitteilungen erscheinen an der Notch statt oben rechts."
        case .sperrbildschirm: return "Musik, Wetter und Termine auf dem Sperrbildschirm."
        case .menueleiste: return "Symbole der Menueleiste ausblenden und ordnen."
        case .kurzbefehle: return "Tastenkuerzel und Anbindung an Kurzbefehle."
        case .nearbyShare: return "Dateien drahtlos zwischen Mac und Android."
        }
    }

    /// Ob es die Funktion schon gibt. Was fehlt, steht nicht zur Auswahl: ein
    /// Schalter, der nichts tut, waere schlimmer als gar keiner.
    var gebaut: Bool {
        switch self {
        case .helligkeitsBoost, .mitteilungen, .sperrbildschirm,
             .menueleiste, .kurzbefehle, .nearbyShare:
            return false
        default:
            return true
        }
    }

    static var gebaute: [Funktion] { allCases.filter(\.gebaut) }

    /// Standardmaessig eingeschaltet. Alles, was Berechtigungen oder Hardware-
    /// Zugriff braucht, bleibt bis zur bewussten Freigabe aus.
    var standardAn: Bool {
        switch self {
        // Wetter bleibt aus: eingeschaltet wuerde es beim ersten Start nach den
        // Ortungsdiensten fragen.
        case .musik, .agenten, .lautstaerkeHud, .helligkeitHud, .caffeinate, .bluetooth,
             .kalender, .batterie, .dateiRegal, .brille, .nachtmodus,
             .zwischenablage, .notizen, .augenpause, .audioJeApp:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class Einstellungen: ObservableObject {
    static let shared = Einstellungen()
    private let defaults = UserDefaults.standard

    private init() {
        var start: [String: Any] = [
            "bildschirmWahl": BildschirmWahl.mitNotch.rawValue,
            "klaengeAn": true,
            "haptikAn": true,
            "beiHoverOeffnen": true
        ]
        for f in Funktion.allCases {
            start["funktion.\(f.rawValue)"] = f.standardAn
        }
        defaults.register(defaults: start)
    }

    func istAn(_ f: Funktion) -> Bool { defaults.bool(forKey: "funktion.\(f.rawValue)") }

    func setze(_ f: Funktion, an: Bool) {
        defaults.set(an, forKey: "funktion.\(f.rawValue)")
        objectWillChange.send()
        NotificationCenter.default.post(name: .saphirFunktionGeaendert, object: f)
    }

    var klaengeAn: Bool {
        get { defaults.bool(forKey: "klaengeAn") }
        set { defaults.set(newValue, forKey: "klaengeAn"); objectWillChange.send() }
    }

    var haptikAn: Bool {
        get { defaults.bool(forKey: "haptikAn") }
        set { defaults.set(newValue, forKey: "haptikAn"); objectWillChange.send() }
    }

    var beiHoverOeffnen: Bool {
        get { defaults.bool(forKey: "beiHoverOeffnen") }
        set { defaults.set(newValue, forKey: "beiHoverOeffnen"); objectWillChange.send() }
    }

    var bildschirmWahl: BildschirmWahl {
        get { BildschirmWahl(rawValue: defaults.string(forKey: "bildschirmWahl") ?? "") ?? .mitNotch }
        set { defaults.set(newValue.rawValue, forKey: "bildschirmWahl"); objectWillChange.send() }
    }

    var startetBeimAnmelden: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                objectWillChange.send()
            } catch {
                Protokoll.fehler("Autostart: \(error.localizedDescription)")
            }
        }
    }
}

extension Notification.Name {
    static let saphirFunktionGeaendert = Notification.Name("saphir.funktion.geaendert")
}
