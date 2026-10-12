import AppKit
import CoreBluetooth
import CoreLocation
import EventKit

/// Welche Freigaben Saphir braucht, welche schon da sind, und wo man die
/// fehlenden erteilt.
///
/// Bewusst nur *lesen* und *anstossen* — nichts erzwingen. macOS zeigt jeden
/// Dialog genau einmal; danach fuehrt der Weg nur noch ueber die
/// Systemeinstellungen, und dorthin verlinken wir direkt.
enum Freigabe: String, CaseIterable, Identifiable {
    case bedienungshilfen
    case bildschirmaufnahme
    case kalender
    case standort
    case bluetooth
    case automation

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bedienungshilfen: return "Bedienungshilfen"
        case .bildschirmaufnahme: return "Bildschirmaufnahme"
        case .kalender: return "Kalender"
        case .standort: return "Ortungsdienste"
        case .bluetooth: return "Bluetooth"
        case .automation: return "Kurzbefehle an andere Apps"
        }
    }

    var wofuer: String {
        switch self {
        case .bedienungshilfen: return "Lautstaerke- und Helligkeitstasten, Fenster andocken, globale Tastenkuerzel"
        case .bildschirmaufnahme: return "Menueleiste anpassen"
        case .kalender: return "Naechste Termine anzeigen"
        case .standort: return "Wetter am aktuellen Ort"
        case .bluetooth: return "Verbundene Geraete und Akkustand"
        case .automation: return "Musik in Spotify und Musik steuern"
        }
    }

    /// Die Funktionen, die ohne diese Freigabe nicht laufen.
    var betrifft: [Funktion] {
        switch self {
        case .bedienungshilfen: return [.lautstaerkeHud, .helligkeitHud, .snapZones, .kurzbefehle]
        case .bildschirmaufnahme: return [.menueleiste]
        case .kalender: return [.kalender]
        case .standort: return [.wetter]
        case .bluetooth: return [.bluetooth]
        case .automation: return [.musik]
        }
    }

    /// Die passende Seite der Systemeinstellungen.
    var systemeinstellungen: URL? {
        let anker: String
        switch self {
        case .bedienungshilfen: anker = "Privacy_Accessibility"
        case .bildschirmaufnahme: anker = "Privacy_ScreenCapture"
        case .kalender: anker = "Privacy_Calendars"
        case .standort: anker = "Privacy_LocationServices"
        case .bluetooth: anker = "Privacy_Bluetooth"
        case .automation: anker = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anker)")
    }
}

enum Freigabestand {
    case erteilt
    case verweigert
    case ungefragt
    /// Laesst sich von aussen nicht zuverlaessig ablesen (Automation, Bluetooth
    /// vor dem ersten Zugriff). Ehrlicher als ein geratenes Haekchen.
    case unbekannt

    var text: String {
        switch self {
        case .erteilt: return "erteilt"
        case .verweigert: return "verweigert"
        case .ungefragt: return "noch nicht gefragt"
        case .unbekannt: return "unbekannt"
        }
    }
}

@MainActor
final class Berechtigungen: ObservableObject {
    static let shared = Berechtigungen()

    @Published private(set) var stand: [Freigabe: Freigabestand] = [:]

    private init() { aktualisieren() }

    func aktualisieren() {
        var neu: [Freigabe: Freigabestand] = [:]
        for f in Freigabe.allCases { neu[f] = lies(f) }
        stand = neu
    }

    func stand(_ f: Freigabe) -> Freigabestand { stand[f] ?? .unbekannt }

    private func lies(_ f: Freigabe) -> Freigabestand {
        switch f {
        case .bedienungshilfen:
            return AXIsProcessTrusted() ? .erteilt : .verweigert

        case .bildschirmaufnahme:
            return CGPreflightScreenCaptureAccess() ? .erteilt : .verweigert

        case .kalender:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .erteilt
            case .denied, .restricted: return .verweigert
            case .notDetermined: return .ungefragt
            default: return .unbekannt
            }

        case .standort:
            switch CLLocationManager().authorizationStatus {
            case .authorized, .authorizedAlways: return .erteilt
            case .denied, .restricted: return .verweigert
            case .notDetermined: return .ungefragt
            @unknown default: return .unbekannt
            }

        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .erteilt
            case .denied, .restricted: return .verweigert
            case .notDetermined: return .ungefragt
            @unknown default: return .unbekannt
            }

        case .automation:
            // Es gibt keine Abfrage, die nicht selbst schon ein Apple-Event
            // schickt. Wir raten hier nicht, sondern sagen es so.
            return .unbekannt
        }
    }

    /// Den Systemdialog anstossen, soweit es einen gibt. Sonst die passende
    /// Seite der Systemeinstellungen oeffnen.
    func anfragen(_ f: Freigabe) {
        switch f {
        case .bedienungshilfen:
            // Der einzige Weg, der die App gleich in die Liste eintraegt.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        case .bildschirmaufnahme:
            CGRequestScreenCaptureAccess()

        case .kalender:
            EKEventStore().requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in self?.aktualisieren() }
            }

        case .standort, .bluetooth, .automation:
            // Diese drei fragen erst beim ersten echten Zugriff. Bis dahin
            // hilft nur der Weg ueber die Systemeinstellungen.
            oeffneSystemeinstellungen(f)
        }

        // Der Dialog laeuft asynchron; kurz danach noch einmal nachsehen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.aktualisieren()
        }
    }

    func oeffneSystemeinstellungen(_ f: Freigabe) {
        guard let url = f.systemeinstellungen else { return }
        NSWorkspace.shared.open(url)
    }
}
