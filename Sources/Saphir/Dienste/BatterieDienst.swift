import AppKit
import IOKit.ps
import SwiftUI

/// Ein einzelner Stand. AirPods haben drei davon: links, rechts, Etui.
struct Akkustand: Identifiable, Equatable {
    let id: String
    /// Symbol fuer diesen Teil, oder nil wenn das Geraet nur einen Stand hat.
    let symbol: String?
    let prozent: Int
}

/// Ein Geraet mit Ladestand.
struct Akku: Identifiable, Equatable {
    let id: String
    let name: String
    let symbol: String
    let staende: [Akkustand]
    var laedt: Bool = false
    /// Verbleibende Minuten, nur beim Mac bekannt.
    var restMinuten: Int?

    /// Der niedrigste Stand. Danach richtet sich die Farbe.
    var niedrigster: Int { staende.map(\.prozent).min() ?? 100 }
}

/// Ladestand des Macs und der verbundenen Bluetooth-Geraete.
///
/// Der Mac kommt aus IOKit, die Geraete aus `system_profiler`. Fuer die
/// AirPods gibt es keinen oeffentlichen Weg an die drei Einzelstaende — die
/// Bluetooth-Voreinstellungen fuehren sie auf diesem Mac gar nicht, und der
/// direkte Weg ueber CoreBluetooth koennte nur lesen, was gerade in
/// Funkreichweite antwortet. `system_profiler` liefert genau das, was auch das
/// Kontrollzentrum zeigt.
@MainActor
final class BatterieDienst: ObservableObject {
    static let shared = BatterieDienst()

    @Published private(set) var mac: Akku?
    @Published private(set) var geraete: [Akku] = []

    private var takt: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .saphirFunktionGeaendert, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.taktPruefen() }
        }
        taktPruefen()
    }

    func taktPruefen() {
        if Einstellungen.shared.istAn(.batterie) { starte() } else { stoppe() }
    }

    private func starte() {
        guard takt == nil else { return }
        lies()
        // Zwei Minuten reichen: Ladestaende bewegen sich in Prozentschritten,
        // nicht in Sekunden.
        takt = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { _ in
            MainActor.assumeIsolated { BatterieDienst.shared.lies() }
        }
    }

    private func stoppe() {
        takt?.invalidate()
        takt = nil
        mac = nil
        geraete = []
    }

    func lies() {
        mac = Self.macAkku()
        Task.detached(priority: .utility) {
            let gefunden = Self.bluetoothAkkus()
            await MainActor.run { BatterieDienst.shared.geraete = gefunden }
        }
    }

    // MARK: - Mac

    private static func macAkku() -> Akku? {
        guard let roh = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let liste = IOPSCopyPowerSourcesList(roh)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for quelle in liste {
            guard let werte = IOPSGetPowerSourceDescription(roh, quelle)?.takeUnretainedValue()
                    as? [String: Any],
                  let jetzt = werte[kIOPSCurrentCapacityKey] as? Int,
                  let voll = werte[kIOPSMaxCapacityKey] as? Int, voll > 0 else { continue }

            let laedt = (werte[kIOPSIsChargingKey] as? Bool) ?? false
            let rest = laedt ? werte[kIOPSTimeToFullChargeKey] as? Int
                             : werte[kIOPSTimeToEmptyKey] as? Int
            return Akku(id: "mac",
                        name: Host.current().localizedName ?? "Mac",
                        symbol: "laptopcomputer",
                        staende: [Akkustand(id: "mac", symbol: nil,
                                            prozent: Int(round(Double(jetzt) / Double(voll) * 100)))],
                        laedt: laedt,
                        // -1 heisst „wird noch berechnet".
                        restMinuten: (rest ?? -1) > 0 ? rest : nil)
        }
        return nil
    }

    // MARK: - Bluetooth

    private nonisolated static func bluetoothAkkus() -> [Akku] {
        let werkzeug = Process()
        werkzeug.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        werkzeug.arguments = ["SPBluetoothDataType", "-json"]
        let rohr = Pipe()
        werkzeug.standardOutput = rohr
        werkzeug.standardError = FileHandle.nullDevice

        do {
            try werkzeug.run()
        } catch {
            return []
        }
        let daten = rohr.fileHandleForReading.readDataToEndOfFile()
        werkzeug.waitUntilExit()

        guard let wurzel = try? JSONSerialization.jsonObject(with: daten) as? [String: Any],
              let bloecke = wurzel["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        var gefunden: [Akku] = []
        for block in bloecke {
            guard let verbunden = block["device_connected"] as? [[String: Any]] else { continue }
            for eintrag in verbunden {
                for (name, roh) in eintrag {
                    guard let felder = roh as? [String: Any],
                          let akku = akku(name: name, felder: felder) else { continue }
                    gefunden.append(akku)
                }
            }
        }
        return gefunden.sorted { $0.name < $1.name }
    }

    private nonisolated static func akku(name: String, felder: [String: Any]) -> Akku? {
        var staende: [Akkustand] = []
        let kennung = felder["device_address"] as? String ?? name

        func lies(_ schluessel: String, symbol: String?, teil: String) {
            guard let roh = felder[schluessel] as? String else { return }
            let zahl = roh.replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let prozent = Int(zahl) else { return }
            staende.append(Akkustand(id: "\(kennung).\(teil)", symbol: symbol, prozent: prozent))
        }

        let pro = name.lowercased().contains("pro")
        lies("device_batteryLevelLeft", symbol: pro ? "airpodpro.left" : "airpod.left", teil: "l")
        lies("device_batteryLevelRight", symbol: pro ? "airpodpro.right" : "airpod.right", teil: "r")
        lies("device_batteryLevelCase",
             symbol: pro ? "airpodspro.chargingcase.wireless.fill" : "airpods.chargingcase.fill",
             teil: "etui")
        // Geraete mit nur einem Akku: Maus, Tastatur, Kopfhoerer.
        if staende.isEmpty {
            lies("device_batteryLevelMain", symbol: nil, teil: "haupt")
            lies("device_batteryLevel", symbol: nil, teil: "haupt")
        }
        guard !staende.isEmpty else { return nil }

        return Akku(id: kennung, name: name,
                    symbol: symbol(name: name, felder: felder), staende: staende)
    }

    private nonisolated static func symbol(name: String, felder: [String: Any]) -> String {
        let klein = name.lowercased()
        if klein.contains("airpods max") { return "airpods.max" }
        if klein.contains("airpods pro") { return "airpods.pro" }
        if klein.contains("airpods") { return "airpods.gen3" }
        if klein.contains("magic mouse") || klein.contains("mouse") { return "magicmouse.fill" }
        if klein.contains("keyboard") { return "keyboard.fill" }
        if klein.contains("watch") { return "applewatch" }
        if klein.contains("iphone") { return "iphone" }
        if klein.contains("ipad") { return "ipad" }
        if (felder["device_minorType"] as? String) == "Headphones" { return "headphones" }
        return "wave.3.right"
    }

    /// Rot unter zehn, gelb unter zwanzig Prozent — sonst weiss.
    static func farbe(_ prozent: Int) -> Color {
        if prozent <= 10 { return .red }
        if prozent <= 20 { return .yellow }
        return .white
    }
}
