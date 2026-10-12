import Foundation

/// Registers a statusline script in `~/.claude/settings.json`.
///
/// The statusline is the only channel through which Claude Code publishes the
/// real rate-limit numbers, so the app needs one even though it does not really
/// want to own the terminal's status row. Two consequences shape this installer:
///
/// * **A statusline that was already there keeps working.** Its command is put
///   aside in `statusline-inner`, and our script feeds it the same payload and
///   prints its output verbatim. Removing us restores it.
/// * **The row stays useful.** With no previous statusline we print the same
///   figures the notch shows, which is what someone asking for their limits
///   wants anyway. Turning "Kontingent" off in the settings makes it print
///   nothing, and the app still gets its data.
enum StatuslineInstaller {

    static var script: URL { Ablage.ordner.appendingPathComponent("saphir-statusline.sh") }
    static var innerCommand: URL { Ablage.ordner.appendingPathComponent("statusline-inner") }

    static var isInstalled: Bool {
        guard let line = ClaudeEinstellungen.lesenOderLeer()["statusLine"] as? [String: Any],
              let command = line["command"] as? String else { return false }
        return command.contains("saphir-statusline.sh")
    }

    static func install() throws {
        var settings = try ClaudeEinstellungen.lesen()
        Ablage.anlegen()
        try scriptSource.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)

        if let existing = settings["statusLine"] as? [String: Any],
           let command = existing["command"] as? String,
           !command.contains("saphir-statusline.sh") {
            // Somebody else's statusline — keep it and chain it.
            try? command.write(to: innerCommand, atomically: true, encoding: .utf8)
            Protokoll.info("Bestehende Statusline uebernommen und weitergereicht")
        } else if settings["statusLine"] == nil {
            // Es gibt keine fremde Statuszeile (mehr). Ein Rest vom letzten Mal
            // wuerde sonst weiter laufen und die eigene Zeile verdraengen.
            try? FileManager.default.removeItem(at: innerCommand)
        }

        guard !isInstalled else { return }
        settings["statusLine"] = ["type": "command", "command": script.path, "padding": 0]
        try ClaudeEinstellungen.schreiben(settings)
        Protokoll.info("Statusline in ~/.claude/settings.json eingetragen")
    }

    static func uninstall() throws {
        var settings = try ClaudeEinstellungen.lesen()
        guard isInstalled else { return }
        if let previous = try? String(contentsOf: innerCommand, encoding: .utf8),
           !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings["statusLine"] = ["type": "command", "command": previous]
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try ClaudeEinstellungen.schreiben(settings)
        try? FileManager.default.removeItem(at: script)
        try? FileManager.default.removeItem(at: innerCommand)
        Protokoll.info("Statusline entfernt")
    }

    // MARK: - The script

    /// Same spirit as the hook bridge: bash and curl, no JSON parsing in shell.
    /// The app receives the payload and answers with the line to print, so all
    /// the formatting lives in one place. App not running → prints nothing and
    /// the status row simply stays empty.
    static let scriptSource = #"""
#!/bin/bash
# Saphir — statusline bridge.
# Generated automatically. Safe to delete; the app rewrites it on launch.
#
# Claude Code hands its real rate-limit figures to statusline scripts and to
# nowhere else. This forwards the payload to the app and prints back the line
# the app wants shown. If a statusline was configured before Saphir, its
# command is in ~/.saphir/statusline-inner and wins.

set -u
ENDPOINT="${SAPHIR_HOME:-$HOME/.saphir}/endpoint.json"
INNER="${SAPHIR_HOME:-$HOME/.saphir}/statusline-inner"

payload=$(cat)

if [ -f "$ENDPOINT" ]; then
  PORT=$(sed -n 's/.*"port"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$ENDPOINT" | head -1)
  TOKEN=$(sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ENDPOINT" | head -1)
  if [ -n "$PORT" ] && [ -n "$TOKEN" ]; then
    line=$(printf '%s' "$payload" | curl -sS --max-time 3 \
      -H "Content-Type: application/json" \
      -H "X-Saphir-Token: ${TOKEN}" \
      --data-binary @- "http://127.0.0.1:${PORT}/statusline" 2>/dev/null)
  fi
fi

if [ -s "$INNER" ]; then
  # Somebody else's statusline was here first; it decides what is shown.
  printf '%s' "$payload" | eval "$(cat "$INNER")"
  exit 0
fi

[ -n "${line:-}" ] && printf '%s' "$line"
exit 0
"""#
}
