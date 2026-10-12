#!/bin/bash
# Nimmt "Deckel zu" vom Mac: beendet eine liegengebliebene Sitzung (das
# Waechter-Skript setzt alles zurueck), und erst wenn das sauber geklappt hat,
# werden Waechter-Job und sudoers-Regel entfernt. Bleibt etwas offen, bleibt
# alles stehen, damit der Waechter es weiter versuchen kann.
#
# config.json, Protokoll und Journal bleiben liegen.
set -euo pipefail

APP_SUPPORT="${SAPHIR_DECKEL_HOME:-$HOME/Library/Application Support/Saphir/Deckel}"
LABEL=com.luismarks.saphir.deckel.backstop
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS=/etc/sudoers.d/saphir-deckel

if [[ -f "$APP_SUPPORT/backstop.sh" ]]; then
  echo "==> Setze eine liegengebliebene Sitzung zurueck"
  if ! /bin/bash "$APP_SUPPORT/backstop.sh" --force; then
    echo "Es blieb etwas offen (siehe ~/Library/Logs/Saphir/deckel.log). Nichts wurde entfernt." >&2
    echo "Saphir oeffnen, damit es Helligkeit und Ton zuruecksetzt, dann nochmal." >&2
    exit 1
  fi
fi

echo "==> Entferne den Waechter-Job"
/bin/launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST"

echo "==> Entferne $SUDOERS (fragt nach deinem Passwort)"
/usr/bin/sudo /bin/rm -f "$SUDOERS"
echo "==> Fertig."
