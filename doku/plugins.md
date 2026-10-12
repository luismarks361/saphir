# Erweiterungen (Plugins)

Eine Erweiterung ist ein Ordner unter `~/.saphir/plugins/<id>/` mit einer `plugin.json` und einem
Programm in beliebiger Sprache. Saphir startet das Programm im Takt, schreibt eine Anfrage als JSON
auf stdin, liest die Antwort als JSON von stdout und malt sie selbst in der eigenen Gestaltung. Eine
Erweiterung zeichnet also nichts, sie beschreibt nur Inhalt, und sieht dadurch immer wie ein
eingebautes Widget aus.

Es gibt keinen Port, kein Token und keine Bibliothek. Ein Plugin, das haengt oder abstuerzt, kostet
hoechstens einen verpassten Takt.

Ein vollstaendiges Beispiel mit allen drei Andockpunkten liegt in `doku/plugins/beispiel/`.

## Installieren

1. Ordner nach `~/.saphir/plugins/<id>/` legen (oder verlinken). Der Ordnername ist die Kennung.
2. Programm ausfuehrbar machen (`chmod +x`) und eine Shebang-Zeile an den Anfang setzen.
3. Einstellungen, Seite **Erweiterungen**: **Neu einlesen**, dann einschalten.

Neue Erweiterungen sind aus. Sie laufen mit deinen Rechten, das soll eine bewusste Entscheidung sein.

## plugin.json

```json
{
  "schnittstelle": 1,
  "id": "termine",
  "name": "Termine",
  "version": "1.0.0",
  "symbol": "briefcase",
  "start": "plugin.py",
  "takt": 30,
  "andocken": ["live", "hud"],
  "prioritaet": 15,
  "spalten": 2,
  "einstellungen": [
    { "schluessel": "adresse", "name": "Adresse", "typ": "text", "standard": "https://..." },
    { "schluessel": "passwort", "name": "Passwort", "typ": "geheim" }
  ]
}
```

| Feld | Bedeutung |
|---|---|
| `schnittstelle` | Muss `1` sein. Eine andere Version wird abgelehnt, nicht erraten. |
| `id` | `a-z`, `0-9`, Bindestrich, hoechstens 32 Zeichen. Muss dem Ordnernamen gleichen. |
| `start` | Programm relativ zum Ordner. Ein `..` oder ein absoluter Pfad wird abgelehnt. |
| `takt` | Sekunden zwischen zwei Abfragen, 5 bis 3600, Standard 60. |
| `andocken` | Wo sich die Erweiterung zeigen darf: `kachel`, `live`, `hud`. Was nicht genannt ist, wird ignoriert. |
| `prioritaet` | Nur fuer `live`, 11 bis 19, Standard 15. Siehe unten. |
| `spalten` | Nur fuer `kachel`: 1 = halbe, 2 = ganze Breite. Standard 2. |
| `einstellungen` | Felder, die Saphir als Formular zeigt. `geheim` liegt im Schluesselbund, `text` in den Einstellungen. |

## Der Lauf

Saphir startet `start` im Plugin-Ordner. Auf stdin steht genau ein JSON-Objekt:

```json
{ "befehl": "abfrage", "einstellungen": { "adresse": "...", "passwort": "..." }, "daten": "/Users/.../.saphir/plugin-daten/sap" }
```

- `befehl` ist `abfrage` oder `aktion`. Bei `aktion` steht der Name des Knopfes in `aktion`.
- `einstellungen` enthaelt jedes Feld aus der `plugin.json`, geheime Felder im Klartext.
- `daten` ist ein Ordner, den das Plugin behalten darf (Zwischenspeicher, Cookies, Zaehler).

Auf stdout kommt bei `abfrage` ein JSON-Objekt, bei `aktion` nichts. Danach beendet sich das Programm.
Saphir fragt nach jeder Aktion sofort neu ab. Leere Ausgabe heisst: nichts anzuzeigen.

Fehler: Exit-Code ungleich 0, der Grund auf stderr. Saphir zeigt ihn in den Einstellungen und nimmt
die Anzeige der Erweiterung weg. Ein Countdown, der nicht mehr stimmt, waere eine Falschmeldung.

Grenzen: 15 Sekunden pro Lauf (danach wird das Programm beendet), 256 KB Ausgabe, Suchpfad
`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`.

## Antwort

Alle drei Teile sind optional. Fehlt ein Teil, verschwindet er an seiner Stelle.

```json
{
  "live":   { "links": { "text": "Anna", "farbe": "blau" }, "rechts": { "text": "8 min", "farbe": "blau" } },
  "hud":    { "id": "m-17", "symbol": "calendar.badge.clock", "text": "Check-in mit Anna, 17:30", "sekunden": 8 },
  "kachel": { "bausteine": [ { "art": "text", "text": "Hallo", "stil": "gross" } ] }
}
```

### live: neben der Kamera

`links` und `rechts` haben je `symbol` (SF-Symbol), `text` (hoechstens 24 Zeichen), `anteil` (0 bis 1,
zeigt einen Balken) und `farbe`. Es zeigt sich immer nur **eine** Aktivitaet, die mit der hoechsten
Prioritaet. Eingebaut: Musik 10, Wach halten 5, Kalender 20, wartende Freigabe 30. Eine Erweiterung liegt
zwischen 11 und 19, also ueber der Musik und nie ueber dem Kalender oder einer Freigabe.

### hud: Zeile unter der Notch

`symbol` und `text` sind Pflicht, dazu `sekunden` (1 bis 30, Standard 5), `anteil` (zeigt einen Balken
mit Zahl) und `farbe` (wirkt nur beim Balken). `id` ist Pflicht: **dieselbe `id` zeigt sich nur einmal**.
Das Plugin darf die Meldung bei jeder Abfrage mitschicken, ohne dass sie ein zweites Mal aufgeht. Eine
neue Meldung braucht eine neue `id`.

### kachel: Widget in der Uebersicht

| `art` | Felder |
|---|---|
| `text` | `text`, `stil` (`gross`, `normal`, `klein`), `farbe` |
| `symbol` | `symbol`, `farbe` |
| `balken` | `anteil` (0 bis 1), `farbe` |
| `knopf` | `text`, `symbol`, `aktion`: ein Klick ruft das Plugin mit `befehl: "aktion"` auf |
| `zeile` | `bausteine` nebeneinander |
| `spalte` | `bausteine` untereinander |

Eine unbekannte `art` bleibt leer, die Kachel kippt nicht.

### Farben

`weiss`, `blau`, `gruen`, `gelb`, `orange`, `rot`, `cyan`, `grau` oder `#RRGGBB`.

## Tipps

- **Zwischenspeicher im Datenordner.** Ein Plugin, das Daten aus dem Netz holt, sollte den letzten guten
  Stand ablegen und bei Netzfehlern damit weiterrechnen. Ein Countdown braucht das Netz nicht, die
  Uhrzeit des Termins aendert sich nicht. Falsche Zugangsdaten dagegen gehoeren gemeldet (Exit 1), nicht
  zugedeckt.
- **Zeit selbst rechnen.** Saphir fragt im Takt, nicht pro Minute: ein Countdown rechnet bei jeder
  Abfrage neu aus der aktuellen Uhrzeit. Takt 30 haelt die Minutenanzeige auf eine halbe Minute genau.
- **Geheimnisse nie in den Plugin-Ordner.** Dafuer gibt es Felder vom Typ `geheim`.

## Pruefen

```sh
echo '{"befehl":"abfrage","einstellungen":{},"daten":"/tmp/x"}' | ~/.saphir/plugins/<id>/plugin.py
```

Die Ausgabe muss gueltiges JSON sein. Den Stand zeigt Einstellungen, Erweiterungen (letzte Antwort
oder Fehlertext), ausfuehrlicher `~/.saphir/saphir.log`.

## Aufbau im Code

`Sources/Saphir/Plugins/`: `PluginManifest` (plugin.json lesen und pruefen), `PluginLauf` (Programm
starten, Frist, Ausgabegrenze), `PluginAntwort` (das Antwortformat), `PluginVerwalter` (finden, im Takt
abfragen, an die Insel haengen), `PluginKachel` (Bausteine malen). Die Insel kennt keine Plugins: eine
Plugin-Kachel liegt im `WidgetRegister`, eine Plugin-Aktivitaet in `LiveAktivitaeten`, mit `plugin`
statt `funktion` als Schalter. Tests: `Tests/SaphirTests/PluginTests.swift`.
