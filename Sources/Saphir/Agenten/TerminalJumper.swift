import AppKit
import Foundation

/// Brings the user back to the exact terminal tab / pane a session runs in.
///
/// The precision we can reach depends on how scriptable the terminal is:
/// Terminal.app and iTerm2 can be driven down to the individual tab, tmux down
/// to the pane, and everything else gets its window raised.
enum TerminalJumper {
    private static let queue = DispatchQueue(label: "saphir.jump", qos: .userInitiated)

    static func jump(to origin: TerminalOrigin, cwd: String) {
        queue.async {
            if origin.isRemote {
                // Nothing local to focus; at least raise whatever terminal holds the SSH client.
                activateBundle(origin.bundleID ?? bundleID(forTermProgram: origin.app ?? ""))
                return
            }

            // tmux first: selecting the pane is what actually changes what you see,
            // then the surrounding terminal window needs raising anyway.
            if let pane = origin.tmuxPane, !pane.isEmpty {
                selectTmuxPane(pane, socket: origin.tmuxSocket)
                activateBundle(origin.bundleID ?? bundleID(forTermProgram: origin.app ?? ""))
                return
            }

            // The tty is the tab. If the hook could not report one, ask the CLI
            // process itself — that is what makes a jump work for rows we only
            // learned about mid-session.
            let tty = resolvedTTY(for: origin)
            let program = origin.app ?? ""

            switch program {
            case "iTerm.app":
                if let sid = origin.itermSessionID, jumpITerm(sessionID: sid) { return }
                if let tty, jumpITerm(tty: tty) { return }
            case "Apple_Terminal":
                if let tty, jumpAppleTerminal(tty: tty) { return }
            case "WezTerm":
                if let pane = origin.weztermPane,
                   runShell("/usr/bin/env", ["wezterm", "cli", "activate-pane", "--pane-id", pane]) { break }
            case "kitty":
                if let win = origin.kittyWindowID,
                   runShell("/usr/bin/env", ["kitty", "@", "focus-window", "--match", "id:\(win)"]) { break }
            case "vscode":
                openInEditor(bundle: "com.microsoft.VSCode", cwd: cwd)
                return
            default:
                // Terminal unknown, but a tty still identifies the tab in the two
                // terminals that can be scripted. Only ask apps that are already
                // running — talking to a stopped one would launch it.
                if let tty {
                    if isRunning("com.apple.Terminal"), jumpAppleTerminal(tty: tty) { return }
                    if isRunning("com.googlecode.iterm2"), jumpITerm(tty: tty) { return }
                }
            }

            // No exact tab. Raising the terminal is still the best we can do, but
            // it lands on whatever tab is in front — so say so instead of letting
            // it look like the wrong session was opened.
            if let bundle = origin.bundleID ?? bundleID(forTermProgram: program), !bundle.isEmpty {
                activateBundle(bundle)
                announce(tty == nil
                         ? "\(origin.appLabel): Tab unbekannt"
                         : "\(origin.appLabel): Tab nicht mehr da")
            } else {
                announce("Kein Terminal bekannt")
            }
        }
    }

    /// The tty of the session's tab: what the hook reported, or failing that the
    /// controlling terminal of the CLI process.
    private static func resolvedTTY(for origin: TerminalOrigin) -> String? {
        if let tty = origin.tty, !tty.isEmpty { return tty }
        guard let pid = origin.pid, pid > 0 else { return nil }
        guard let raw = shellOutput("/bin/ps", ["-o", "tty=", "-p", String(pid)]) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != "??", name != "?" else { return nil }
        return name.hasPrefix("/dev/") ? name : "/dev/" + name
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// One line under the notch, so a jump that could not land is visible.
    private static func announce(_ text: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                AgentenMotor.shared.beiHinweis?("terminal", text, 4)
            }
        }
    }

    /// True when we can put the user on the exact tab rather than just the app.
    static func precision(for origin: TerminalOrigin) -> String {
        if origin.isRemote { return "SSH" }
        if origin.tmuxPane != nil { return "tmux-Pane" }
        // A pid stands in for a missing tty: we can still look the tab up.
        let knowsTab = origin.tty != nil || origin.pid != nil
        switch origin.app {
        case "iTerm.app" where origin.itermSessionID != nil || knowsTab: return "Tab"
        case "Apple_Terminal" where knowsTab: return "Tab"
        case "WezTerm" where origin.weztermPane != nil: return "Pane"
        case "kitty" where origin.kittyWindowID != nil: return "Fenster"
        case nil where knowsTab: return "Tab"
        default: return "App"
        }
    }

    // MARK: - Per-terminal implementations

    private static func jumpITerm(sessionID raw: String) -> Bool {
        // ITERM_SESSION_ID looks like "w0t1p0:8A9F-…"; the UUID is what AppleScript exposes.
        let uuid = raw.contains(":") ? String(raw.split(separator: ":").last!) : raw
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            try
              repeat with t in tabs of w
                try
                  repeat with s in sessions of t
                    if (id of s) is "\(uuid)" then
                      select w
                      select t
                      select s
                      activate
                      return "ok"
                    end if
                  end repeat
                end try
              end repeat
            end try
          end repeat
        end tell
        return "miss"
        """
        return runAppleScript(script) == "ok"
    }

    /// Same idea as above, but keyed on the tty — the only handle we have when
    /// the session was first seen without its `ITERM_SESSION_ID`.
    private static func jumpITerm(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
          repeat with w in windows
            try
              repeat with t in tabs of w
                try
                  repeat with s in sessions of t
                    try
                      if (tty of s) is "\(tty)" then
                        select w
                        select t
                        select s
                        activate
                        return "ok"
                      end if
                    end try
                  end repeat
                end try
              end repeat
            end try
          end repeat
        end tell
        return "miss"
        """
        return runAppleScript(script) == "ok"
    }

    private static func jumpAppleTerminal(tty: String) -> Bool {
        // Every level gets its own `try`: Terminal keeps phantom windows in its
        // AppleScript collection that answer no `tabs` at all, and a single
        // error there used to abort the whole search. Whether the jump worked
        // then depended on where that window sat in the window order — which is
        // exactly why clicking a row sometimes did nothing and sometimes just
        // raised the frontmost window, i.e. some other session.
        let script = """
        tell application "Terminal"
          repeat with w in windows
            try
              repeat with t in tabs of w
                try
                  if (tty of t) is "\(tty)" then
                    set selected of t to true
                    try
                      set miniaturized of w to false
                    end try
                    set frontmost of w to true
                    activate
                    return "ok"
                  end if
                end try
              end repeat
            end try
          end repeat
        end tell
        return "miss"
        """
        return runAppleScript(script) == "ok"
    }

    private static func selectTmuxPane(_ pane: String, socket: String?) {
        // TMUX is "<socket-path>,<pid>,<session>".
        var args: [String] = ["tmux"]
        if let socket, let path = socket.split(separator: ",").first, !path.isEmpty {
            args += ["-S", String(path)]
        }
        _ = runShell("/usr/bin/env", args + ["select-window", "-t", pane])
        _ = runShell("/usr/bin/env", args + ["select-pane", "-t", pane])
    }

    private static func openInEditor(bundle: String, cwd: String) {
        guard !cwd.isEmpty else { activateBundle(bundle); return }
        _ = runShell("/usr/bin/open", ["-b", bundle, cwd])
    }

    // MARK: - Primitives

    private static func activateBundle(_ bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        DispatchQueue.main.async {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let app = apps.first {
                app.activate(options: [.activateAllWindows])
            } else {
                _ = runShell("/usr/bin/open", ["-b", bundleID])
            }
        }
    }

    private static func bundleID(forTermProgram program: String) -> String? {
        switch program {
        case "Apple_Terminal": return "com.apple.Terminal"
        case "iTerm.app": return "com.googlecode.iterm2"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "WezTerm": return "com.github.wez.wezterm"
        case "kitty": return "net.kovidgoyal.kitty"
        case "Alacritty": return "org.alacritty"
        case "Hyper": return "co.zeit.hyper"
        case "vscode": return "com.microsoft.VSCode"
        case "zed": return "dev.zed.Zed"
        case "Tabby": return "org.tabby"
        case "rio": return "com.raphaelamorim.rio"
        default: return nil
        }
    }

    @discardableResult
    private static func runShell(_ launchPath: String, _ args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs a command and hands back its standard output.
    private static func shellOutput(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            // -1743 is "not authorised to send Apple events" — the user has to grant
            // Automation access once per target app.
            Protokoll.fehler("AppleScript: \(error[NSAppleScript.errorMessage] ?? error)")
            return nil
        }
        return result.stringValue
    }
}
