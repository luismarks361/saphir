#!/bin/bash
# Spielt das Zu- und Aufklappen des Deckels vor, ohne ihn anzufassen: die
# laufende Sitzung fuehrt dieselben Aktionen aus wie bei einem echten
# Deckelereignis (Display dunkel, Ton stumm, Apps einfrieren, ...) und macht
# sie bei "open" wieder rueckgaengig. Wirkt nur waehrend einer Sitzung.
#
#   doku/deckel-simulieren.sh closed|open
#
# Von Insomnia uebernommen (MIT, Krish Garg), angepasst.
set -euo pipefail

APP_SUPPORT="${SAPHIR_DECKEL_HOME:-$HOME/Library/Application Support/Saphir/Deckel}"
TRIGGER="$APP_SUPPORT/simulate-lid"

[[ $# -eq 1 && ( "$1" == closed || "$1" == open ) ]] || { echo "usage: $(basename "$0") closed|open" >&2; exit 2; }
[[ -d "$APP_SUPPORT" ]] || { echo "Kein Ordner $APP_SUPPORT. Saphir einmal starten." >&2; exit 1; }

# Neben das Ziel schreiben und umbenennen, damit der Beobachter nie eine halbe
# oder leere Datei liest.
tmp="$APP_SUPPORT/.simulate-lid.tmp.$$"
printf '%s\n' "$1" > "$tmp"
mv -f "$tmp" "$TRIGGER"
echo "Deckel $1: Ausloeser nach $TRIGGER geschrieben"
