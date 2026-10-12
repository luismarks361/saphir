#!/usr/bin/python3
"""Das kleinste Plugin, das alle drei Andockpunkte benutzt.

Saphir startet dieses Programm bei jedem Takt, schreibt eine Anfrage als JSON
auf stdin und liest die Antwort als JSON von stdout. Mehr ist die Schnittstelle
nicht. Der Zaehler steht in einer Datei im Datenordner, den Saphir mitgibt.
"""
import json
import os
import sys

anfrage = json.load(sys.stdin)
datei = os.path.join(anfrage["daten"], "zaehler.txt")


def lies():
    try:
        with open(datei) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return 0


zaehler = lies()
if anfrage["befehl"] == "aktion" and anfrage.get("aktion") == "zaehlen":
    zaehler += 1
    with open(datei, "w") as f:
        f.write(str(zaehler))
    sys.exit(0)

ziel = max(1, int(anfrage["einstellungen"].get("ziel") or 5))
antwort = {
    "live": {
        "links": {"symbol": "puzzlepiece.extension", "farbe": "cyan"},
        "rechts": {"text": f"{zaehler}/{ziel}", "farbe": "cyan"},
    },
    "kachel": {
        "bausteine": [
            {"art": "zeile", "bausteine": [
                {"art": "symbol", "symbol": "puzzlepiece.extension", "farbe": "cyan"},
                {"art": "text", "text": "Beispiel", "stil": "klein"},
            ]},
            {"art": "text", "text": str(zaehler), "stil": "gross"},
            {"art": "balken", "anteil": min(zaehler / ziel, 1), "farbe": "cyan"},
            {"art": "knopf", "text": "Zaehlen", "symbol": "plus", "aktion": "zaehlen"},
        ]
    },
}
if zaehler >= ziel:
    antwort["hud"] = {"id": f"ziel-{ziel}", "symbol": "checkmark.circle.fill",
                      "text": "Ziel erreicht", "farbe": "gruen", "sekunden": 4}
json.dump(antwort, sys.stdout)
