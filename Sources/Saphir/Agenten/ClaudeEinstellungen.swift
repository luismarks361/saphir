import Foundation

/// Liest und schreibt Claudes `settings.json`, ohne etwas zu verlieren.
///
/// Die Datei gehoert dem Nutzer. Saphir traegt nur seine Hooks und die
/// Statuszeile ein und haelt sich dabei an drei Regeln:
///
/// * **Unlesbar heisst: nicht anfassen.** Ist die Datei da, aber kein gueltiges
///   JSON (ein Komma zu viel reicht), brechen wir ab. Sonst wuerde ein leeres
///   Objekt mit nur unseren Hooks ihren ganzen Inhalt ersetzen.
/// * **Vorher eine Sicherung**, aber nur bei einer echten Aenderung, und nur die
///   letzten paar verschiedenen Staende bleiben liegen.
/// * **Nichts schreiben, wenn nichts anders ist.** Das Eintragen laeuft bei jedem
///   Start; die Datei soll dabei nicht jedes Mal neu erscheinen.
enum ClaudeEinstellungen {

    enum Fehler: LocalizedError {
        case unlesbar(String)

        var errorDescription: String? {
            switch self {
            case .unlesbar(let pfad):
                return "\(pfad) ist kein gueltiges JSON. Saphir fasst sie nicht an, bis das behoben ist."
            }
        }
    }

    /// Die Einstellungen als Woerterbuch. Fehlt die Datei, ist es leer; ist sie
    /// kaputt, wirft das.
    static func lesen() throws -> [String: Any] {
        let url = AgentenPfade.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let daten = try Data(contentsOf: url)
        // Eine leere Datei ist kein Fehler, sie ist nur leer.
        if daten.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let wurzel = (try? JSONSerialization.jsonObject(with: daten)) as? [String: Any] else {
            throw Fehler.unlesbar(url.path)
        }
        return wurzel
    }

    /// Wie `lesen`, aber ohne Fehler: fuer die Frage „steht unser Eintrag drin?"
    static func lesenOderLeer() -> [String: Any] {
        (try? lesen()) ?? [:]
    }

    static func schreiben(_ einstellungen: [String: Any]) throws {
        let url = AgentenPfade.claudeSettings
        let neu = try JSONSerialization.data(
            withJSONObject: einstellungen,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let alt = try? Data(contentsOf: url)
        if alt == neu { return }

        if let alt { sichere(alt) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try neu.write(to: url, options: .atomic)
    }

    // MARK: - Sicherungen

    private static let sicherungenBehalten = 5
    private static let praefix = "settings-backup-"

    private static func sichere(_ inhalt: Data) {
        // Derselbe Stand nicht zweimal.
        if let juengste = sicherungen().last,
           let vorher = try? Data(contentsOf: juengste), vorher == inhalt { return }

        Ablage.anlegen()
        let stempel = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let ziel = Ablage.ordner.appendingPathComponent("\(praefix)\(stempel).json")
        try? inhalt.write(to: ziel, options: .atomic)
        // Eine Kopie der settings.json kann Zugangsdaten enthalten: nur fuer den Nutzer.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ziel.path)
        raeumeAuf()
    }

    /// Vorhandene Sicherungen, die aelteste zuerst. Der Zeitstempel hat feste
    /// Breite und sortiert als Text chronologisch.
    private static func sicherungen() -> [URL] {
        let alle = (try? FileManager.default.contentsOfDirectory(
            at: Ablage.ordner, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return alle
            .filter { $0.lastPathComponent.hasPrefix(praefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Behaelt die neuesten verschiedenen Staende. Nach Inhalt gezaehlt und nicht
    /// nach Dateien, sonst verdraengen viele gleiche Kopien die anderen.
    static func raeumeAuf() {
        let dateien = sicherungen()
        guard dateien.count > 1 else { return }

        var behalten: [URL] = []
        var gesehen: Set<Data> = []
        for url in dateien.reversed() {
            guard let daten = try? Data(contentsOf: url) else { continue }
            guard gesehen.insert(daten).inserted else { continue }
            behalten.append(url)
            if behalten.count == sicherungenBehalten { break }
        }
        let bleiben = Set(behalten.map(\.path))
        for url in dateien where !bleiben.contains(url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
