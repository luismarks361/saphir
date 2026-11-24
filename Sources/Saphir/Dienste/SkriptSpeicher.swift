import Foundation

/// Haelt fertig kompilierte AppleScripts, damit ein Skript, das jede Sekunde
/// laeuft, nicht jede Sekunde neu uebersetzt wird.
///
/// `NSAppleScript` kompiliert beim ersten Ausfuehren und behaelt das Ergebnis.
/// Wer jedes Mal ein neues Objekt anlegt, zahlt die Uebersetzung jedes Mal, und
/// auf aktuellen macOS-Versionen schickt jede Uebersetzung den Text zusaetzlich
/// durch den XProtect-Scan: im Sekundentakt waren das rund zehn Prozent CPU.
///
/// Nur fuer den Hauptfaden: `NSAppleScript` ist nicht fuer mehrere Faden gebaut.
final class SkriptSpeicher {
    private var skripte: [String: NSAppleScript] = [:]

    var anzahl: Int { skripte.count }

    /// Das Skript zu diesem Quelltext: das gemerkte, oder ein neues.
    func skript(fuer quelle: String) -> NSAppleScript? {
        if let bekannt = skripte[quelle] { return bekannt }
        guard let neu = NSAppleScript(source: quelle) else { return nil }
        skripte[quelle] = neu
        return neu
    }

    /// Nach einem Fehler vergessen: beim naechsten Mal wird frisch uebersetzt, so
    /// wie vorher jedes Mal. Aendert sich eine App (Update, Neustart), kann ein
    /// altes Uebersetzungsergebnis nicht dauerhaft falsch bleiben.
    func vergiss(_ quelle: String) {
        skripte[quelle] = nil
    }
}
