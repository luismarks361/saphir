import Foundation

/// Wo Saphir seine Sachen ablegt, und wie es protokolliert.
enum Ablage {
    /// Alles, was die App ausserhalb ihres Pakets besitzt.
    static let ordner: URL = {
        // Nur fuer Tests: ein eigener Ordner, damit sie keine echten Daten anfassen.
        if let pfad = ProcessInfo.processInfo.environment["SAPHIR_HOME"], !pfad.isEmpty {
            return URL(fileURLWithPath: pfad, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".saphir", isDirectory: true)
    }()

    static var protokollDatei: URL { ordner.appendingPathComponent("saphir.log") }
    /// Ablage des Datei-Regals (Task 11).
    static var regal: URL { ordner.appendingPathComponent("regal", isDirectory: true) }

    static func anlegen() {
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
    }
}

enum Protokoll {
    private static let queue = DispatchQueue(label: "saphir.log")
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func info(_ text: String) { schreibe("INFO", text) }
    static func fehler(_ text: String) { schreibe("FEHL", text) }

    private static func schreibe(_ stufe: String, _ text: String) {
        let zeile = "\(format.string(from: Date())) \(stufe) \(text)\n"
        FileHandle.standardError.write(Data(zeile.utf8))
        queue.async {
            Ablage.anlegen()
            let url = Ablage.protokollDatei
            // Damit das Protokoll ueber lange Laufzeiten nicht unbegrenzt waechst.
            if let groesse = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
               groesse > 512_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(zeile.utf8))
                try? handle.close()
            } else {
                try? zeile.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
