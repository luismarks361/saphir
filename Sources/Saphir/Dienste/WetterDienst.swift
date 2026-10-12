import CoreLocation
import Foundation
import SwiftUI

struct WetterStunde: Identifiable, Equatable {
    let id: Int
    let stunde: Int
    let grad: Int
    let symbol: String
}

struct Wetter: Equatable {
    var ort: String
    var grad: Int
    var gefuehlt: Int
    var symbol: String
    var lage: String
    var tief: Int
    var hoch: Int
    var stunden: [WetterStunde]
}

/// Wetter am aktuellen Ort.
///
/// Quelle ist Open-Meteo, wie im Original: kein Konto, kein Schluessel, keine
/// Anmeldung. Der Ort kommt aus den Ortungsdiensten und wird gemerkt — ohne
/// Freigabe bliebe die Kachel sonst dauerhaft leer, und einmal im Monat
/// umziehen tut niemand.
@MainActor
final class WetterDienst: NSObject, ObservableObject {
    static let shared = WetterDienst()

    @Published private(set) var jetzt: Wetter?

    private let ortung = CLLocationManager()
    private var takt: Timer?
    private let defaults = UserDefaults.standard

    private var gemerkterOrt: CLLocationCoordinate2D? {
        get {
            let b = defaults.double(forKey: "wetter.breite")
            let l = defaults.double(forKey: "wetter.laenge")
            guard b != 0 || l != 0 else { return nil }
            return CLLocationCoordinate2D(latitude: b, longitude: l)
        }
        set {
            guard let neu = newValue else { return }
            defaults.set(neu.latitude, forKey: "wetter.breite")
            defaults.set(neu.longitude, forKey: "wetter.laenge")
        }
    }

    private var gemerkterName: String {
        get { defaults.string(forKey: "wetter.ort") ?? "" }
        set { defaults.set(newValue, forKey: "wetter.ort") }
    }

    private override init() {
        super.init()
        ortung.delegate = self
        ortung.desiredAccuracy = kCLLocationAccuracyKilometer

        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.wetter) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        ortSuchen()
        hole()
        // Eine Viertelstunde. Oefter waere unhoeflich gegen einen Dienst, der
        // nichts kostet, und das Wetter aendert sich nicht schneller.
        takt = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { WetterDienst.shared.hole() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        jetzt = nil
    }

    private func ortSuchen() {
        switch ortung.authorizationStatus {
        case .notDetermined: ortung.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways: ortung.requestLocation()
        default: break
        }
    }

    // MARK: - Abruf

    func hole() {
        guard let ort = gemerkterOrt else { return }
        let name = gemerkterName
        Task { [weak self] in
            guard let wetter = await Self.frage(ort: ort, name: name) else { return }
            await MainActor.run { self?.jetzt = wetter }
        }
    }

    private nonisolated static func frage(ort: CLLocationCoordinate2D,
                                          name: String) async -> Wetter? {
        var teile = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        teile.queryItems = [
            .init(name: "latitude", value: String(format: "%.4f", ort.latitude)),
            .init(name: "longitude", value: String(format: "%.4f", ort.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weathercode,is_day"),
            .init(name: "hourly", value: "temperature_2m,weathercode"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "forecast_hours", value: "12")
        ]
        guard let url = teile.url else { return nil }

        do {
            let (daten, _) = try await URLSession.shared.data(from: url)
            guard let wurzel = try JSONSerialization.jsonObject(with: daten) as? [String: Any],
                  let aktuell = wurzel["current"] as? [String: Any],
                  let grad = aktuell["temperature_2m"] as? Double,
                  let code = aktuell["weathercode"] as? Int else { return nil }

            let tag = (aktuell["is_day"] as? Int ?? 1) == 1
            let gefuehlt = aktuell["apparent_temperature"] as? Double ?? grad
            let taeglich = wurzel["daily"] as? [String: Any]
            let hoch = (taeglich?["temperature_2m_max"] as? [Double])?.first ?? grad
            let tief = (taeglich?["temperature_2m_min"] as? [Double])?.first ?? grad

            var stunden: [WetterStunde] = []
            if let stuendlich = wurzel["hourly"] as? [String: Any],
               let zeiten = stuendlich["time"] as? [String],
               let grade = stuendlich["temperature_2m"] as? [Double],
               let codes = stuendlich["weathercode"] as? [Int] {
                // Open-Meteo liefert mit forecast_hours ab der laufenden
                // Stunde. Die erste ist also jetzt und faellt weg.
                for i in zeiten.indices.dropFirst() where i < grade.count && i < codes.count {
                    let teileZeit = zeiten[i].split(separator: "T")
                    guard teileZeit.count == 2,
                          let stunde = Int(teileZeit[1].prefix(2)) else { continue }
                    stunden.append(WetterStunde(id: i, stunde: stunde,
                                                grad: Int(grade[i].rounded()),
                                                symbol: symbol(codes[i], tag: true)))
                    if stunden.count == 5 { break }
                }
            }

            return Wetter(ort: name,
                          grad: Int(grad.rounded()),
                          gefuehlt: Int(gefuehlt.rounded()),
                          symbol: symbol(code, tag: tag),
                          lage: lage(code),
                          tief: Int(tief.rounded()),
                          hoch: Int(hoch.rounded()),
                          stunden: stunden)
        } catch {
            Protokoll.fehler("Wetter: \(error.localizedDescription)")
            return nil
        }
    }

    /// WMO-Wettercodes auf Systemsymbole. Dieselbe Einteilung wie im Original,
    /// nur direkt auf die Symbole statt ueber die Zwischencodes eines anderen
    /// Wetterdienstes.
    nonisolated static func symbol(_ code: Int, tag: Bool) -> String {
        switch code {
        case 0: return tag ? "sun.max.fill" : "moon.stars.fill"
        case 1: return tag ? "sun.min.fill" : "moon.fill"
        case 2: return tag ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 61, 80: return "cloud.rain.fill"
        case 63, 81: return "cloud.rain.fill"
        case 65, 82: return "cloud.heavyrain.fill"
        case 71, 73, 85, 86: return "cloud.snow.fill"
        case 75, 77: return "snowflake"
        case 95: return "cloud.bolt.fill"
        case 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    nonisolated static func lage(_ code: Int) -> String {
        switch code {
        case 0: return "Klar"
        case 1: return "Meist klar"
        case 2: return "Teils bewoelkt"
        case 3: return "Bedeckt"
        case 45, 48: return "Nebel"
        case 51, 53, 55: return "Nieselregen"
        case 56, 57, 66, 67: return "Gefrierender Regen"
        case 61, 80: return "Leichter Regen"
        case 63, 81: return "Regen"
        case 65, 82: return "Starker Regen"
        case 71, 73: return "Schnee"
        case 75, 77: return "Starker Schnee"
        case 85, 86: return "Schneeschauer"
        case 95: return "Gewitter"
        case 96, 99: return "Gewitter mit Hagel"
        default: return ""
        }
    }
}

extension WetterDienst: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus == .authorized
                    || manager.authorizationStatus == .authorizedAlways else { return }
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let ort = locations.last else { return }
        MainActor.assumeIsolated {
            self.gemerkterOrt = ort.coordinate
            self.hole()
        }
        // Der Ortsname ist Zierde, kein Grund zu warten.
        Task {
            guard let marke = try? await CLGeocoder().reverseGeocodeLocation(ort).first,
                  let name = marke.locality ?? marke.administrativeArea else { return }
            await MainActor.run {
                self.gemerkterName = name
                if var wetter = self.jetzt { wetter.ort = name; self.jetzt = wetter }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Protokoll.fehler("Ortung: \(error.localizedDescription)")
    }
}
