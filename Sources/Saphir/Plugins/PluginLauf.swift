import Foundation

/// Wie ein Plugin laeuft: einmal starten, Anfrage auf stdin, Antwort auf stdout,
/// Programm beendet sich.
///
/// Kein Dauerlaeufer, kein Port, kein Token. Ein Plugin, das haengt oder
/// abstuerzt, kostet hoechstens einen verpassten Takt; Saphir selbst haengt
/// nicht daran. Und es braucht keine Bibliothek: jedes Skript, das JSON lesen
/// und drucken kann, ist ein Plugin.
enum PluginLauf {
    enum Fehler: Error, Equatable, CustomStringConvertible {
        case nichtGestartet(String)
        case zeit(Double)
        case zuGross
        case beendet(Int32, String)
        case unlesbar(String)

        var description: String {
            switch self {
            case .nichtGestartet(let grund): return "Start fehlgeschlagen: \(grund)"
            case .zeit(let s): return "Keine Antwort nach \(Int(s)) s"
            case .zuGross: return "Antwort zu gross"
            case .beendet(let code, let meldung):
                return meldung.isEmpty ? "Beendet mit Code \(code)" : "Code \(code): \(meldung)"
            case .unlesbar(let grund): return "Antwort nicht lesbar: \(grund)"
            }
        }
    }

    /// Was eine Abfrage hoechstens dauern darf. Danach wird das Programm beendet.
    static let frist: Double = 15
    /// Groesser wird keine Kachel. Wer mehr druckt, hat sich verlaufen.
    static let maxAusgabe = 256 * 1024

    /// Die Anfrage, die das Plugin auf stdin bekommt.
    struct Anfrage: Encodable {
        /// `abfrage` oder `aktion`.
        var befehl: String
        var aktion: String?
        var einstellungen: [String: String]
        /// Ein Ordner, in dem das Plugin Dinge ueber den Lauf hinaus ablegen darf.
        var daten: String
    }

    /// Blockiert, darum nie auf dem Hauptthread aufrufen.
    static func fuehreAus(programm: URL, ordner: URL, anfrage: Anfrage,
                          frist: Double = PluginLauf.frist) -> Result<Data, Fehler> {
        let prozess = Process()
        prozess.executableURL = programm
        prozess.currentDirectoryURL = ordner
        // Aus der Oberflaeche gestartet, haette ein Plugin sonst fast keinen
        // Suchpfad: Homebrew-Programme (node, python) wuerden nicht gefunden.
        prozess.environment = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "de_DE.UTF-8",
            "SAPHIR_PLUGIN_DATEN": anfrage.daten
        ]
        let ein = Pipe(), aus = Pipe(), fehler = Pipe()
        prozess.standardInput = ein
        prozess.standardOutput = aus
        prozess.standardError = fehler

        do { try prozess.run() } catch {
            return .failure(.nichtGestartet(error.localizedDescription))
        }

        let stand = LaufStand()
        // Erst SIGTERM, wer das ignoriert, bekommt eine Sekunde spaeter SIGKILL.
        let ablauf = DispatchWorkItem {
            guard prozess.isRunning else { return }
            stand.setze(abgelaufen: true)
            prozess.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if prozess.isRunning { kill(prozess.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + frist, execute: ablauf)

        if let daten = try? JSONEncoder().encode(anfrage) {
            try? ein.fileHandleForWriting.write(contentsOf: daten)
        }
        try? ein.fileHandleForWriting.close()

        let gruppe = DispatchGroup()
        let ausgabe = Puffer(), meldung = Puffer()
        for (rohr, puffer, begrenzt) in [(aus, ausgabe, true), (fehler, meldung, false)] {
            gruppe.enter()
            Thread.detachNewThread {
                while let stueck = try? rohr.fileHandleForReading.read(upToCount: 65536),
                      !stueck.isEmpty {
                    puffer.haengeAn(stueck)
                    if begrenzt, puffer.groesse > maxAusgabe {
                        stand.setze(zuGross: true)
                        prozess.terminate()
                        break
                    }
                }
                gruppe.leave()
            }
        }

        prozess.waitUntilExit()
        // Haelt ein Enkelprozess das Rohr offen, wuerde das Lesen ewig warten.
        _ = gruppe.wait(timeout: .now() + 1)
        ablauf.cancel()

        if stand.abgelaufen { return .failure(.zeit(frist)) }
        if stand.zuGross { return .failure(.zuGross) }
        guard prozess.terminationStatus == 0 else {
            let text = String(decoding: meldung.daten.suffix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.beendet(prozess.terminationStatus, text))
        }
        return .success(ausgabe.daten)
    }

    /// Die Antwort als Struktur. Leere Ausgabe heisst: nichts anzuzeigen.
    static func lies(_ daten: Data) -> Result<PluginAntwort, Fehler> {
        if daten.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return .success(PluginAntwort())
        }
        do {
            return .success(try JSONDecoder().decode(PluginAntwort.self, from: daten))
        } catch let fehler as DecodingError {
            switch fehler {
            case .keyNotFound(let k, _): return .failure(.unlesbar("Feld \"\(k.stringValue)\" fehlt"))
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                let pfad = c.codingPath.map(\.stringValue).joined(separator: ".")
                return .failure(.unlesbar(pfad.isEmpty ? c.debugDescription : "\(pfad): \(c.debugDescription)"))
            @unknown default: return .failure(.unlesbar("unbekannt"))
            }
        } catch {
            return .failure(.unlesbar(error.localizedDescription))
        }
    }
}

/// Zwei Faeden schreiben hinein, der dritte liest: ein Schloss reicht.
private final class LaufStand: @unchecked Sendable {
    private let schloss = NSLock()
    private var _abgelaufen = false
    private var _zuGross = false

    var abgelaufen: Bool { schloss.withLock { _abgelaufen } }
    var zuGross: Bool { schloss.withLock { _zuGross } }
    func setze(abgelaufen: Bool) { schloss.withLock { _abgelaufen = abgelaufen } }
    func setze(zuGross: Bool) { schloss.withLock { _zuGross = zuGross } }
}

private final class Puffer: @unchecked Sendable {
    private let schloss = NSLock()
    private var _daten = Data()

    var daten: Data { schloss.withLock { _daten } }
    var groesse: Int { schloss.withLock { _daten.count } }
    func haengeAn(_ stueck: Data) { schloss.withLock { _daten.append(stueck) } }
}
