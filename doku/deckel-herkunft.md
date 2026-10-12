# Deckel zu: Herkunft

Der Motor hinter "Deckel zu" (alles unter `Sources/Saphir/Deckel/` ausser
`DeckelDienst.swift`, dazu `Resources/deckel-backstop.sh`) stammt aus
**Insomnia** von Krish Garg:

- Repo: https://github.com/krishhgg/Insomnia
- Stand: Tag `v0.1.0`, Commit `ea5ce156a90324babfd416e2bfa898f135f4e0db`
- Lizenz: MIT, Copyright (c) 2026 Krish Garg. Der Lizenztext liegt unveraendert
  in `insomnia-LICENSE` und muss bei jeder Weitergabe mitgehen.

## Was uebernommen wurde

Unveraendert in der Logik, nur umbenannt: `Core/`, `System/`, `Model/`,
`Store/` und das Waechter-Skript. Das sind Sitzung mit Ende, Journal und
Wiederherstellung, Waechter-Job (launchd), Zuklappen-Aktionen (Display, Ton,
Einfrieren, Docker), Akku- und Hitze-Grenzen und der Wechsel auf den
iPhone-Hotspot.

## Was Saphir selbst ist

- `Sources/Saphir/Deckel/DeckelDienst.swift`: die einzige Stelle, die Saphir
  und Motor kennt (Start, Beenden, Insel-Anzeige, Einrichtungspruefung).
- Standard: Der Deckel-Modus ist in der Kachel "Wach halten" **an** (`DeckelDienst.modusAn`, Standardwert true); der Menueleisten-Eintrag folgt ihm.
- Die Bedienung: Schalter in der Kachel "Wach halten"
  (`Widgets/WachWidget.swift`) und die Seite "Deckel zu" in den Einstellungen
  (`UI/DeckelSeite.swift`). Insomnias eigene Oberflaeche (Augen-Symbol,
  Dauer-Eingabe, Einstellungsfenster) wurde nicht uebernommen.
- Hilfsskripte: `deckel-einrichten.sh`, `deckel-entfernen.sh`,
  `deckel-simulieren.sh`.

## Aenderung an Saphir selbst, wegen des Motors

- `Dienste/MusikDienst.swift`: Das Musik-Widget fragt Spotify jede Sekunde per
  AppleScript auf dem **Hauptthread**. "Alle anderen Apps einfrieren" friert
  Spotify ein (SIGSTOP), und ein Apple-Event an eine eingefrorene App wartet
  bis zum Timeout (Standard 2 Minuten). Der Hauptthread haengt, und dort laeuft
  auch das Auftauen beim Aufklappen: Saphir wartete auf Spotify, Spotify auf
  Saphir. Jetzt fragt `lies()` mit zugeklapptem Deckel gar nicht
  (`DeckelDienst.shared.deckelZu`), und jedes Skript hat `with timeout of 2 seconds`.
  Beim Test mit simuliertem Zuklappen am 11.10.2026 gefunden: 62 Sekunden
  Stillstand, bis Spotify von Hand aufgetaut war.

## Aenderungen am Motor

- `Paths`: eigene Namen. Ordner `~/Library/Application Support/Saphir/Deckel`,
  Protokoll `~/Library/Logs/Saphir/deckel.log`, Waechter-Job
  `com.luismarks.saphir.deckel.backstop`, Umgebungsvariable
  `SAPHIR_DECKEL_HOME`, Bundle-ID `com.luismarks.saphir` (dadurch schuetzt
  der Freezer Saphir vor dem Einfrieren), Schluesselbund-Dienst
  `saphir-deckel-hotspot`.
- sudoers-Regel: `/etc/sudoers.d/saphir-deckel`, eigene Datei neben der von
  Insomnia, gleiche vier Befehle.
- Benachrichtigungen auf Deutsch, Log-Zeilen bleiben englisch.
- `PmsetSleepGuard.parseLowPowerMode`: Rueckgriff auf `powermode`. macOS 26
  gibt in `pmset -g custom` keine Zeile `lowpowermode` mehr aus, nur
  `powermode` (0 automatisch, 1 Energiesparen, 2 Hochleistung), obwohl
  `pmset -b lowpowermode 1|0` weiter schreibt (geprueft auf 26.6.2). In
  Insomnia v0.1.0 scheitert der Energiesparmodus deshalb auf solchen Macs mit
  "no lowpowermode line under Battery Power". Hochleistung (2) bleibt
  "unbekannt", damit eine Nutzerentscheidung nicht ueberschrieben wird.
  Test dazu in `PmsetParsingTests`.
- `AppServices.init`: Standardwert fuer `locationPermission` als `nil`,
  weil Saphir im Swift-5-Modus baut (Insomnia im 6er-Modus).

## Nachziehen

Insomnia entwickelt sich weiter (Nightlies). Zum Abgleich den Stand im Repo
gegen `v0.1.0` diffen und nur uebernehmen, was die Logik betrifft. Neuere
Staende haben z.B. eine tmux-Markierung (`@insomnia-nudge`), die v0.1.0 noch
nicht kennt.

## Nicht gleichzeitig

Saphir und Insomnia duerfen **nie gleichzeitig eine Sitzung** halten: beide
schalten `pmset disablesleep`, und das Ende der einen hebt die andere auf.
