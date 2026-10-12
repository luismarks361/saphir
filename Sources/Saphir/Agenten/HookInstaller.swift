import Foundation

/// Writes the bridge script and wires it into `~/.claude/settings.json`.
///
/// The installer never clobbers hooks the user already has (it merges, keyed on
/// our own script path); the backups and the "unreadable file" guard live in
/// `ClaudeEinstellungen`.
enum HookInstaller {

    /// Events we subscribe to. Only `PermissionRequest` blocks; the rest are
    /// fire-and-forget so the agent never waits on us.
    static let events: [(event: String, matcher: String?)] = [
        ("SessionStart", nil),
        ("UserPromptSubmit", nil),
        ("PreToolUse", "*"),
        ("PostToolUse", "*"),
        ("PostToolUseFailure", "*"),
        ("SubagentStart", nil),
        ("PreCompact", nil),
        ("PermissionRequest", nil),
        ("Notification", nil),
        ("Stop", nil),
        ("StopFailure", nil),
        ("SessionEnd", nil)
    ]

    static var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: AgentenPfade.hookSkript.path),
              let hooks = ClaudeEinstellungen.lesenOderLeer()["hooks"] as? [String: Any] else { return false }
        // Consider it installed once the blocking hook is present — that is the
        // one that actually changes behaviour.
        return containsOurHook(in: hooks["PermissionRequest"])
    }

    // MARK: - Install / uninstall

    static func install() throws {
        // Zuerst lesen: ist die Datei kaputt, brechen wir ab, bevor irgendetwas
        // geschrieben ist.
        var settings = try ClaudeEinstellungen.lesen()
        Ablage.anlegen()
        try writeScript()
        ClaudeEinstellungen.raeumeAuf()

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, matcher) in events {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.removeAll { containsOurHook(in: $0) }   // replace our old entry
            entries.append(entry(for: event, matcher: matcher))
            hooks[event] = entries
        }
        settings["hooks"] = hooks

        try ClaudeEinstellungen.schreiben(settings)
        Protokoll.info("Hooks in ~/.claude/settings.json eingetragen")
    }

    static func uninstall() throws {
        var settings = try ClaudeEinstellungen.lesen()
        if var hooks = settings["hooks"] as? [String: Any] {
            for key in hooks.keys {
                guard var entries = hooks[key] as? [[String: Any]] else { continue }
                entries.removeAll { containsOurHook(in: $0) }
                if entries.isEmpty { hooks.removeValue(forKey: key) } else { hooks[key] = entries }
            }
            if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        }
        try ClaudeEinstellungen.schreiben(settings)
        try? FileManager.default.removeItem(at: AgentenPfade.hookSkript)
        Protokoll.info("Hooks entfernt")
    }

    // MARK: - settings.json plumbing

    private static func entry(for event: String, matcher: String?) -> [String: Any] {
        var hook: [String: Any] = [
            "type": "command",
            "command": "\"\(AgentenPfade.hookSkript.path)\" \(event)",
            "statusMessage": "Saphir"
        ]
        // Give the blocking hook room for a human to react; the script enforces
        // its own shorter deadline anyway.
        hook["timeout"] = (event == "PermissionRequest") ? 600 : 10

        var result: [String: Any] = ["hooks": [hook]]
        if let matcher { result["matcher"] = matcher }
        return result
    }

    private static func containsOurHook(in entry: Any?) -> Bool {
        if let dict = entry as? [String: Any] {
            guard let hooks = dict["hooks"] as? [[String: Any]] else { return false }
            return hooks.contains { ($0["command"] as? String)?.contains("saphir-hook.sh") == true }
        }
        if let array = entry as? [[String: Any]] {
            return array.contains { containsOurHook(in: $0) }
        }
        return false
    }

    // MARK: - The bridge script

    private static func writeScript() throws {
        try scriptSource.write(to: AgentenPfade.hookSkript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: AgentenPfade.hookSkript.path)
    }

    /// Deliberately dependency-free: bash, sed and curl only, so it costs a few
    /// milliseconds per hook and degrades to a no-op when the app is not running.
    static let scriptSource = #"""
#!/bin/bash
# Saphir — bridge between an AI coding CLI and the notch app.
# Generated automatically. Safe to delete; the app rewrites it on launch.
#
# Reads the hook payload on stdin, enriches it with terminal context that only
# this child process can see, and forwards it to the app on loopback.
# Prints the app's JSON answer on stdout (that is the hook's return value).
# Never fails the calling agent: any problem ends in a silent exit 0.

set -u
EVENT="${1:-Unknown}"
ENDPOINT="${SAPHIR_HOME:-$HOME/.saphir}/endpoint.json"

payload=$(cat)
[ -f "$ENDPOINT" ] || exit 0
case "$payload" in '{'*) ;; *) exit 0 ;; esac

# Parsed with bash string ops, not sed. This script runs twice per tool call, so
# every fork here is latency the agent pays for: the sed version cost ~38 ms per
# event, this one ~17 ms.
endpoint=$(<"$ENDPOINT")
_p="${endpoint#*\"port\"}"; _p="${_p#*:}"; _p="${_p%%,*}"; _p="${_p%%\}*}"
PORT="${_p//[^0-9]/}"
_t="${endpoint#*\"token\"}"; _t="${_t#*\"}"; TOKEN="${_t%%\"*}"
[ -n "$PORT" ] && [ -n "$TOKEN" ] || exit 0

# Backslashes first, then quotes — the other order would escape our own escapes.
esc() { local v="${1:-}"; v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; printf '%s' "${v//$'\t'/ }"; }

# The controlling terminal of the agent process (our parent), e.g. "ttys004".
TTY_NAME=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
case "$TTY_NAME" in
  ""|"??"|"?") TTY_PATH="" ;;
  /dev/*) TTY_PATH="$TTY_NAME" ;;
  *) TTY_PATH="/dev/$TTY_NAME" ;;
esac

island="\"_saphir\":{\
\"agent\":\"claude\",\
\"event\":\"$(esc "$EVENT")\",\
\"pid\":$PPID,\
\"tty\":\"$(esc "$TTY_PATH")\",\
\"term_program\":\"$(esc "${TERM_PROGRAM:-}")\",\
\"bundle_id\":\"$(esc "${__CFBundleIdentifier:-}")\",\
\"term_session_id\":\"$(esc "${TERM_SESSION_ID:-}")\",\
\"iterm_session_id\":\"$(esc "${ITERM_SESSION_ID:-}")\",\
\"tmux\":\"$(esc "${TMUX:-}")\",\
\"tmux_pane\":\"$(esc "${TMUX_PANE:-}")\",\
\"wezterm_pane\":\"$(esc "${WEZTERM_PANE:-}")\",\
\"kitty_window_id\":\"$(esc "${KITTY_WINDOW_ID:-}")\",\
\"ssh_client\":\"$(esc "${SSH_CLIENT:-}")\",\
\"cwd\":\"$(esc "$PWD")\"},"

# Splice our object in right after the opening brace of the original payload.
body="{${island}${payload#\{}"

URL="http://127.0.0.1:${PORT}/hook"

if [ "$EVENT" = "PermissionRequest" ]; then
  # Synchronous: the agent waits for the user to decide in the notch.
  # An empty answer means "no opinion" and the agent falls back to asking in
  # the terminal, which is exactly what we want if the app goes away.
  #
  # The agent does not wait for us. Answering "yes" in the terminal leaves this
  # script running untouched; "no" or Esc sends it SIGTERM. That signal reaches
  # this shell only, so a curl inside $(...) would live on as an orphan with its
  # connection open, and the app would never learn that the question is gone.
  # Hence curl runs in the background and `wait` lets the trap fire at once.
  out=$(mktemp "${TMPDIR:-/tmp}/saphir-answer.XXXXXX") || exit 0
  curl_pid=""
  trap '[ -n "$curl_pid" ] && kill "$curl_pid" 2>/dev/null; rm -f "$out"; exit 0' TERM INT HUP
  printf '%s' "$body" | curl -sS --max-time 600 \
      -H "Content-Type: application/json" \
      -H "X-Saphir-Token: ${TOKEN}" \
      --data-binary @- "$URL" >"$out" 2>/dev/null &
  curl_pid=$!
  wait "$curl_pid"
  answer=$(<"$out")
  rm -f "$out"
  case "$answer" in
    *hookSpecificOutput*) printf '%s' "$answer" ;;
  esac
  exit 0
fi

# Everything else is fire-and-forget so the agent never blocks on us.
# Note: no stdin redirect on curl — it reads the body from the pipe.
{ printf '%s' "$body" | curl -sS --max-time 5 \
    -H "Content-Type: application/json" \
    -H "X-Saphir-Token: ${TOKEN}" \
    --data-binary @- "$URL" >/dev/null 2>&1 ; } &
exit 0
"""#
}
