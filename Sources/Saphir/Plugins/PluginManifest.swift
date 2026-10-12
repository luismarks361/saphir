import Foundation

/// `plugin.json` im Ordner eines Plugins: wer es ist, wo es sich zeigen darf
/// und was es vom Nutzer wissen will.
///
/// Die Schnittstelle ist versioniert (`schnittstelle`), damit sich Saphir
/// spaeter aendern darf, ohne dass alte Plugins stillschweigend Unsinn zeigen:
/// eine unbekannte Version wird abgelehnt, nicht erraten.
struct PluginManifest: Decodable, Equatable {
    static let schnittstelle = 1

    enum Andockpunkt: String, Decodable { case kachel, live, hud }

    struct Feld: Decodable, Equatable, Identifiable {
        enum Typ: String, Decodable { case text, geheim }

        var schluessel: String
        var name: String
        var typ: Typ
        var standard: String?

        var id: String { schluessel }
    }

    var schnittstelle: Int
    var id: String
    var name: String
    var version: String?
    var symbol: String?
    /// Das Programm, relativ zum Plugin-Ordner. Wird direkt gestartet, braucht
    /// also eine Shebang-Zeile und das Ausfuehrrecht.
    var start: String
    /// Sekunden zwischen zwei Abfragen.
    var takt: Double?
    var andocken: [Andockpunkt]
    var prioritaet: Int?
    /// Breite der Kachel: 1 = halb, 2 = ganz.
    var spalten: Int?
    var einstellungen: [Feld]?

    /// Zu oft abfragen waere unhoeflich gegen den Mac, zu selten laesst eine
    /// Live-Aktivitaet veralten.
    static let taktGrenzen: ClosedRange<Double> = 5...3600
    /// Eine Plugin-Aktivitaet liegt ueber der Musik (10) und unter dem Kalender
    /// (20) und der wartenden Freigabe (30): die duerfen sich nie verdraengen
    /// lassen.
    static let prioritaetGrenzen: ClosedRange<Int> = 11...19

    var taktSekunden: Double { (takt ?? 60).clamped(to: Self.taktGrenzen) }
    var livePrioritaet: Int { (prioritaet ?? 15).clamped(to: Self.prioritaetGrenzen) }
    var kachelSpalten: Int { (spalten ?? 2).clamped(to: 1...2) }
    var felder: [Feld] { einstellungen ?? [] }

    enum Mangel: Error, Equatable, CustomStringConvertible {
        case unlesbar(String)
        case schnittstelle(Int)
        case kennung(String)
        case start(String)
        case ordner(String)

        var description: String {
            switch self {
            case .unlesbar(let grund): return "plugin.json nicht lesbar: \(grund)"
            case .schnittstelle(let n): return "Schnittstelle \(n) kennt diese Saphir-Version nicht"
            case .kennung(let id): return "Kennung \"\(id)\" ungueltig (a-z, 0-9, Bindestrich)"
            case .start(let s): return "Startdatei \"\(s)\" muss im Plugin-Ordner liegen"
            case .ordner(let o): return "Ordner heisst \"\(o)\", die Kennung muss gleich lauten"
            }
        }
    }

    /// Liest und prueft. Der Ordnername muss die Kennung sein: so kann kein
    /// zweites Plugin dieselbe Kennung belegen und fremde Einstellungen erben.
    static func lade(aus ordner: URL) throws -> PluginManifest {
        let datei = ordner.appendingPathComponent("plugin.json")
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: datei))
        } catch {
            throw Mangel.unlesbar(Self.kurz(error))
        }
        guard manifest.schnittstelle == Self.schnittstelle else {
            throw Mangel.schnittstelle(manifest.schnittstelle)
        }
        guard manifest.id.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil else {
            throw Mangel.kennung(manifest.id)
        }
        guard manifest.id == ordner.lastPathComponent else {
            throw Mangel.ordner(ordner.lastPathComponent)
        }
        guard manifest.programm(in: ordner) != nil else {
            throw Mangel.start(manifest.start)
        }
        return manifest
    }

    /// Das Programm, nur wenn es wirklich im Plugin-Ordner liegt. Ein `..` oder
    /// ein absoluter Pfad wuerde sonst jedes beliebige Programm starten.
    func programm(in ordner: URL) -> URL? {
        guard !start.isEmpty, !start.hasPrefix("/") else { return nil }
        let wurzel = ordner.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let ziel = ordner.appendingPathComponent(start).standardizedFileURL.resolvingSymlinksInPath()
        return ziel.path.hasPrefix(wurzel) ? ziel : nil
    }

    private static func kurz(_ fehler: Error) -> String {
        if let f = fehler as? DecodingError {
            switch f {
            case .keyNotFound(let k, _): return "Feld \"\(k.stringValue)\" fehlt"
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                let pfad = c.codingPath.map(\.stringValue).joined(separator: ".")
                return pfad.isEmpty ? c.debugDescription : "\(pfad): \(c.debugDescription)"
            @unknown default: break
            }
        }
        return fehler.localizedDescription
    }
}

extension Comparable {
    fileprivate func clamped(to grenzen: ClosedRange<Self>) -> Self {
        min(max(self, grenzen.lowerBound), grenzen.upperBound)
    }
}
