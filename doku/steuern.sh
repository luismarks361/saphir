#!/bin/bash
# Insel von aussen auf- und zuklappen. Braucht keine Berechtigung.
#   doku/steuern.sh auf | zu | einstellungen [bereich] | seite <name> | wach [minuten|aus] | deckel [minuten|aus] | brille | auge | nacht [an|aus|angebot] | freigabe [erlauben|ablehnen|immer] | agenten [verbinden|trennen|status] | bibliothek
#
# Seiten: start agenten musik regal kalender zwischenablage notizen zonen einstellungen
OBJ="nil"
case "${1:-auf}" in
  auf)           N="com.luismarks.saphir.oeffnen" ;;
  zu)            N="com.luismarks.saphir.schliessen" ;;
  einstellungen) N="com.luismarks.saphir.einstellungen"; OBJ="\"${2:-}\"" ;;
  deckel)        N="com.luismarks.saphir.deckel"; OBJ="\"${2:-60}\"" ;;
  seite)         N="com.luismarks.saphir.seite"; OBJ="\"${2:-start}\"" ;;
  wach)          N="com.luismarks.saphir.wach"; OBJ="\"${2:-0}\"" ;;
  brille)        N="com.luismarks.saphir.brille" ;;
  auge)          N="com.luismarks.saphir.auge" ;;
  funktion)      N="com.luismarks.saphir.funktion"; OBJ="\"${2} ${3:-an}\"" ;;
  nacht)         N="com.luismarks.saphir.nacht"; OBJ="\"${2:-an}\"" ;;
  freigabe)      N="com.luismarks.saphir.freigabe"; OBJ="\"${2:-erlauben}\"" ;;
  agenten)       N="com.luismarks.saphir.agenten"; OBJ="\"${2:-status}\"" ;;
  bibliothek)    N="com.luismarks.saphir.bibliothek" ;;
  *)   echo "auf | zu | einstellungen [bereich] | seite <name> | wach [minuten|aus] | deckel [minuten|aus] | brille | auge | nacht [an|aus|angebot] | funktion <name> [an|aus] | freigabe [erlauben|ablehnen|immer] | agenten [verbinden|trennen|status] | bibliothek"; exit 1 ;;
esac
swift -e "import Foundation
DistributedNotificationCenter.default().postNotificationName(.init(\"$N\"), object: $OBJ, userInfo: nil, deliverImmediately: true)"
