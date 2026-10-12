#!/bin/bash
# Baut Saphir und schnuert daraus ein echtes .app-Paket.
#
#   ./build.sh            Release-Build + Paket
#   ./build.sh debug      schneller Build, gleiches Paket
#   ./build.sh --install  legt es zusaetzlich nach /Applications
#   ./build.sh --universal  auch fuer Intel-Macs
#   ./build.sh --adhoc    ohne Entwicklerzertifikat signieren (fuer Weitergabe)
#   ./build.sh --zip      zusaetzlich dist/Saphir-<Version>.zip packen
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
CONFIG="release"
INSTALL=0
ADHOC=0
ZIP=0
ARCHS=()
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo "0.1.0")"

while [ $# -gt 0 ]; do
  case "$1" in
    debug) CONFIG="debug" ;;
    --install) INSTALL=1 ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    --adhoc) ADHOC=1 ;;
    --zip) ZIP=1 ;;
    --version) shift; VERSION="${1:-}" ;;
  esac
  shift
done

if ! printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Version muss X.Y.Z sein, bekommen: '$VERSION'"; exit 1
fi
printf '%s' "$VERSION" > "$ROOT/VERSION"

APP="$ROOT/dist/Saphir.app"
BIN_NAME="Saphir"

echo "==> Kompiliere ($CONFIG${ARCHS:+, universal})"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/$BIN_NAME"
[ -x "$BIN" ] || { echo "Binary fehlt: $BIN"; exit 1; }

echo "==> Baue App-Paket"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"

if [ -d "$ROOT/Resources" ]; then
  find "$ROOT/Resources" -maxdepth 1 \( -name '*.png' -o -name '*.icns' \) \
    -exec cp {} "$APP/Contents/Resources/" \; 2>/dev/null || true
fi

# Das Waechter-Skript von „Deckel zu": die App kopiert es beim Start nach
# ~/Library/Application Support/Saphir/Deckel (siehe DeckelDienst).
cp "$ROOT/Resources/deckel-backstop.sh" "$APP/Contents/Resources/deckel-backstop.sh"

BUILD_NO="$(date +%Y%m%d%H%M)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Saphir</string>
    <key>CFBundleDisplayName</key><string>Saphir</string>
    <key>CFBundleIdentifier</key><string>com.luismarks.saphir</string>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NO</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Saphir steuert fuer dich Musik und Fenster anderer Apps.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Saphir liest den laufenden Ton mit, damit die Balken neben der Kamera zeigen, was du hoerst.</string>
    <key>NSCalendarsUsageDescription</key>
    <string>Saphir zeigt deine naechsten Termine in der Notch.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>Fuer das Wetter am aktuellen Ort, und damit macOS WLAN-Namen herausgibt, wenn Saphir bei „Deckel zu" dem iPhone-Hotspot beitritt.</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Zeigt verbundene Geraete und ihren Akkustand.</string>
    <key>NSHumanReadableCopyright</key>
    <string>Saphir steht unter der AGPL-3.0. Nachbau von Sapphire, Claude-Sessions aus Agent Island, Deckel-zu-Motor aus Insomnia (MIT, Copyright 2026 Krish Garg). Laeuft vollstaendig lokal.</string>
</dict>
</plist>
PLIST

# Wenn ein Entwicklerzertifikat da ist, damit signieren.
#
# Ad-hoc waere einfacher, aendert aber bei jedem Bau den Pruefwert der App.
# macOS erkennt sie dann als eine andere und wirft die erteilten Freigaben weg:
# die Bedienungshilfen-Freigabe muesste nach jedem Bau neu erteilt werden, und
# ohne sie laufen die Sondertasten-Anzeige und die Tastenkuerzel nicht. Mit
# einem echten Zertifikat bleibt die Identitaet ueber alle Bauten gleich.
# Fuer die Weitergabe (--adhoc) bewusst nicht: die Signatur eines Entwicklerzertifikats
# traegt den Namen und die Mailadresse des Zertifikats in jede ausgelieferte Kopie.
IDENT=""
if [ "$ADHOC" = "0" ]; then
  IDENT=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"' || true)
fi

if [ -n "$IDENT" ]; then
  echo "==> Signiere ($IDENT)"
  codesign --force --deep --sign "$IDENT" --identifier com.luismarks.saphir "$APP" 2>/dev/null || \
    echo "   (Signierung fehlgeschlagen — App startet trotzdem)"
else
  echo "==> Signiere (ad-hoc, Freigaben gelten nur bis zum naechsten Bau)"
  codesign --force --deep --sign - --identifier com.luismarks.saphir "$APP" 2>/dev/null || \
    echo "   (Signierung fehlgeschlagen — App startet trotzdem)"
fi

echo "==> Fertig: $APP"

if [ "$ZIP" = "1" ]; then
  ZIPFILE="$ROOT/dist/Saphir-$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --keepParent "$APP" "$ZIPFILE"
  echo "==> $ZIPFILE"
fi

if [ "$INSTALL" = "1" ]; then
  echo "==> Installiere nach /Applications"
  rm -rf "/Applications/Saphir.app"
  cp -R "$APP" "/Applications/Saphir.app"
  echo "==> /Applications/Saphir.app"
fi
