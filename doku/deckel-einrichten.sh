#!/bin/bash
# Einmalige Einrichtung fuer "Deckel zu": schreibt die sudoers-Regel, ohne die
# Saphir den Ruhezustand nicht abschalten (und nicht wieder einschalten) kann.
#
# Die Regel erlaubt genau diese vier Befehle ohne Passwort, sonst nichts:
#   /usr/bin/pmset -a disablesleep 1 | 0
#   /usr/bin/pmset -b lowpowermode 1 | 0
# Sie gilt fuer jedes Programm, das unter deinem Benutzer laeuft, nicht nur
# fuer Saphir. Das Skript fragt einmal nach deinem Passwort (sudo).
#
# Den Waechter-Job (launchd) und das Waechter-Skript legt die App selbst an,
# sobald sie eine Sitzung startet. Hier ist nichts weiter noetig.
#
# Von Insomnia uebernommen (MIT, Krish Garg), angepasst.
set -euo pipefail

SUDOERS=/etc/sudoers.d/saphir-deckel
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<SUDO
# Installed by Saphir doku/deckel-einrichten.sh. Exactly four commands, nothing else.
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 1
$USER ALL=(root) NOPASSWD: /usr/bin/pmset -b lowpowermode 0
SUDO

echo "==> Schreibe $SUDOERS (fragt einmal nach deinem Passwort)"
/usr/bin/sudo /usr/sbin/visudo -cf "$TMP" >/dev/null
/usr/bin/sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$SUDOERS"
/usr/bin/sudo /usr/sbin/visudo -cf "$SUDOERS" >/dev/null
if /usr/bin/sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  echo "==> Fertig: Regel steht und wirkt. In Saphir unter Einstellungen > Deckel zu auf 'Erneut pruefen' klicken."
else
  echo "Die Regel wurde geschrieben, wirkt aber nicht ('sudo -n pmset' wird abgelehnt). Pruefe $SUDOERS." >&2
  exit 1
fi
