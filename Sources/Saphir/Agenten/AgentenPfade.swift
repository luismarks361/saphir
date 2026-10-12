import Foundation

/// Wo der Agenten-Motor seine Dateien ablegt und was er in Claude Codes
/// Einstellungen anfasst.
///
/// Alles liegt im Punktordner der App (`~/.saphir`), weil das Hook-Skript den
/// Pfad fest und ohne Aufwand kennen muss. `SAPHIR_HOME` und
/// `SAPHIR_CLAUDE_SETTINGS` verlegen beides fuer Tests, damit ein Testlauf nie
/// an die echte `~/.claude/settings.json` kommt.
enum AgentenPfade {
    static var ordner: URL { Ablage.ordner }

    static var hookSkript: URL { ordner.appendingPathComponent("saphir-hook.sh") }
    static var statuszeilenSkript: URL { ordner.appendingPathComponent("saphir-statusline.sh") }
    /// Der Befehl, den es vor Saphir als Statuszeile gab. Er bleibt gueltig und
    /// bekommt dieselbe Eingabe.
    static var vorherigeStatuszeile: URL { ordner.appendingPathComponent("statusline-inner") }
    static var endpoint: URL { ordner.appendingPathComponent("endpoint.json") }
    static var token: URL { ordner.appendingPathComponent("token") }
    static var rateLimits: URL { ordner.appendingPathComponent("rate-limits.json") }

    static var claudeSettings: URL {
        if let pfad = ProcessInfo.processInfo.environment["SAPHIR_CLAUDE_SETTINGS"], !pfad.isEmpty {
            return URL(fileURLWithPath: pfad)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Von Claude Code gefuehrt: eine kleine Datei je laufender Session.
    static var claudeSessions: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
    }
}
