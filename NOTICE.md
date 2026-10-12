# Herkunft und Lizenzen

Saphir steht als Ganzes unter der **GNU Affero General Public License v3.0**
(siehe `LICENSE`). Copyright (C) 2026 Luis Marks.

## Woher der Code kommt

| Teil | Quelle | Lizenz |
|---|---|---|
| Aufbau und Oberfläche der Insel, die meisten Widgets | Nachbau von [Sapphire](https://github.com/cshariq/Sapphire) von Shariq Charolia (Maße, Abläufe und Verhalten wurden am Original abgeglichen) | AGPL-3.0 |
| Claude-Sessions, Hook-Server, Freigaben, Terminal-Sprung | Agent Island, eine eigene Notch-App für Claude Code vom selben Autor (siehe `doku/agenten-herkunft.md`) | AGPL-3.0 |
| Deckel zu (Motor hinter dem Wach halten bei zugeklapptem Deckel) | [Insomnia](https://github.com/krishhgg/Insomnia) von Krish Garg, Tag v0.1.0 (siehe `doku/deckel-herkunft.md`) | MIT, Lizenztext in `doku/insomnia-LICENSE`, muss bei jeder Weitergabe mitgehen |

Die MIT-Lizenz von Insomnia ist mit der AGPL vereinbar. Wer Saphir weitergibt oder
als Dienst im Netz anbietet, muss den Quelltext (auch den veränderten) unter der AGPL
zugänglich machen.

## Marken und Abgrenzung

- **Claude** und **Claude Code** sind Marken von Anthropic. Die Claude-Marke in
  `Resources/ClaudeMark.png` steht nicht unter der AGPL und gehört Anthropic. Saphir
  zeigt sie nur, um die eigenen Sessions von Claude Code zu kennzeichnen. Wer sie nicht
  mitliefern will, löscht die Datei: ohne sie fällt Saphir auf ein typografisches
  Zeichen zurück.
- Saphir ist **kein Produkt von Anthropic, Sapphire oder den Insomnia-Autoren** und
  weder von ihnen geprüft noch empfohlen.
- Der Name Saphir ist die deutsche Schreibweise von Sapphire und kein Hinweis auf eine
  Verbindung zum Original.
