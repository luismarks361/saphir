# Recherche: Sapphire

Stand 07.09.2026. Grundlage für den Nachbau. Zwei Quellen: die Produktseite
`sapphire-app.tech` und das offene Repository `github.com/cshariq/Sapphire`.

## Was Sapphire ist

Eine native macOS-App, die die Notch neuerer MacBooks zur Bedienfläche macht.
Eingeklappt zeigt sie laufende Vorgänge als schmale Live-Aktivität links und rechts
der Kamera, aufgeklappt eine Widget-Fläche. Swift/SwiftUI, Xcode-Projekt,
394 Swift-Dateien, dazu ein privilegierter XPC-Helfer für SMC-Zugriffe.

Lizenz: **AGPL-3.0**. Eigengebrauch ist frei. Wer die Kopie weitergibt, muss den
Quelltext unter AGPL offenlegen.

## Features laut Produktseite

Die Seite markiert jede Funktion mit ihrer Stufe.

### Kostenlos enthalten

| Funktion | Beschreibung laut Seite |
|---|---|
| 60 % Helligkeits-Boost + Spotify im Volume-HUD | 1600-nit-XDR-Reserve für Arbeit in der Sonne, Spotify-Steuerung im Lautstärke-HUD |
| Multi Audio | Lautstärke je App, EQ je App, EQ je Gerät, Ausgabe auf mehrere Geräte gleichzeitig |
| Battery Management | Ladegrenze 80 %, Schutz vor chemischer Alterung, Zyklen-Verfolgung |
| Snap Zones | Raster-Layouts, eigene Layouts, ein Tastenkürzel |
| File Shelf | Dateien in die obere Notch-Rundung ziehen, ablegen, nach Space-Wechsel wieder herausziehen |
| Android Nearby Share | Fotos in Originalauflösung, 4K-Videos, Zip-Archive, Zwischenablage-Text kabellos |
| Music Widget | Wellenform, Songtexte, nächste Titel, Empfehlungen, Scrubbing, Schnellsteuerung |
| Caffeinate & Lock Screen | Ein Klick gegen den Ruhezustand, Musik/Sport/Wetter auf dem Sperrbildschirm |
| Face ID on Mac | Kamerabasierte Gesichtserkennung, Anti-Spoof-Modell, Keychain, Klasse-2-Biometrie |

### „And so much more" (ebenfalls kostenlos)

Quick Notch Notes · Infinite Clipboard History · Interactive Calendar Grid ·
Quick Mirror Camera · Persistent Live Weather · Bluetooth Fast Connect ·
Notch Banner Notifications · Shortcuts & Automation · 20-20-20 Eye Break Reminders ·
Menubar Customization

### Kostenpflichtig

| Funktion | Stufe |
|---|---|
| Blip Live (Bildschirm-Dialog mit KI) | Basic, Pro, Ultra |
| Circle to Search | Pro, Ultra |
| Sports Live Activity | Pro, Ultra |
| Sports Widget | Ultra |
| Finance Widget & Live Activity | Ultra |

## Features laut README

Nearby Share · Now Playing · Advanced Audio Features (Beta) · Eye Break · Weather ·
Gemini · Calendar · Lock Screen · File Shelf · Snap Zones · Music · Bluetooth · Caffeinate

## Aufbau des Originals

```
Sapphire/
  App/            AppDelegate, Onboarding, PermissionsManager, HelperManager, XPCClient
  App Settings/   SettingsView + Sidebar + Panes, LayoutEditor, PlaneEditor, DataViewer, UpdateChecker
  Notch/          CustomNotchShape, NotchController, NotchConfiguration, NotchRuntimeState,
                  NotchHoverMonitor, HiddenNotchRevealMonitor, TrackpadGestureMonitor,
                  DragStateManager, GlobalDragManager, WidgetLayoutPolicy, HapticFeedbackType
  LiveActivities/ LiveActivityManager + Komponenten
  Widgets/        Audio, Battery, Calendar, Clipboard, Focus, Mirror, MusicPlayer, Notes,
                  Shortcuts, Timer, Weather, Zones
  Services/       Audio, Auth, Battery(12), Bluetooth(10), Calendar, Clipboard, Focus(8),
                  Launchpad, LockScreen(9), Menubar(10), Mirror, Music(13), Notes, Shortcuts,
                  Stats, System(12), Weather, Zones(7), FaceID, Gemini
  System/         Display(19 Dateien), PrivateAPIs, SystemHUD, PillHUDController, KeychainHelper
  Stubs/          leere Platzhalter der Bezahlfunktionen (Blip, CircleToSearch, Sports, Finance,
                  SubscriptionCore, ModelSecurity …) — im offenen Repo ohne Inhalt
Volume/           eigener Audio-Stack: Engine(10), Loudness(9), Monitors(7), EQ, AutoEQ, DDC, Keys
Nearby/           Google-Nearby-Protokoll für Android, dazu ProtobufGenerated/
com.shariq.sapphireHelper/  privilegierter Helfer: SMC, XPCServer, Sensornamen
```

Bemerkenswert: die Bezahlfunktionen liegen als leere Stubs im Repo. Ein „exakter"
Nachbau kann sie also ohnehin nicht aus der Quelle übernehmen — sie müssten neu
gebaut werden.

## Was wir bauen und was nicht

**Gebaut wird** alles, was die Seite als kostenlos ausweist, plus die README-Punkte —
mit einer Ausnahme.

**Nicht gebaut:**

| Weggelassen | Grund |
|---|---|
| Face ID | bewusst nicht dabei |
| Blip Live, Gemini | KI-Abo-Funktion, im Repo nur Stub |
| Circle to Search | Bezahlfunktion, im Repo nur Stub |
| Sports Widget + Live Activity | Bezahlfunktion, im Repo nur Stub, braucht kostenpflichtige Sport-API |
| Finance Widget + Live Activity | dito, braucht Börsendaten-Abo |
| Abo-Verwaltung, Analytics, Shopify, Dropbox, OpenBubbles | gehört zum Geschäftsmodell des Originals, nicht zur Funktion |

## Was Agent Island beisteuert

Agent Island ist eine eigene Notch-App für Claude Code (Swift, keine Fremdpakete).
Saphir hat von dort übernommen:

| Von dort | Wofür hier |
|---|---|
| Notch-Geometrie und -Form | wo die Notch physisch sitzt, Maße je Gerät, die gerundete Form |
| Fensteraufbau | Panel über der Menüleiste mit Treffer-Durchlass, Menüleisten-Wächter |
| Klang-Synthese | Klänge ohne Audiodateien |
| Der Motor für die Claude-Sessions | Hook-Server, Freigaben, Terminal-Sprung, Rate-Limits (siehe `agenten-herkunft.md`) |

Was Agent Island **nicht** hat und hier neu entstanden ist: Widget-System, alle
Dienste (Musik, Audio, Batterie, Wetter, Kalender, Bluetooth, Zonen, Regal),
HUD-Ersatz, Drag-Erkennung.
