#!/bin/zsh
# Bygger Fotoalbum.app.
#
#   tools/build-app.sh               bygg og installer i /Applications
#   tools/build-app.sh --no-install  bare bygg (havner i dist/Fotoalbum.app)
#
# En .app er en mappe med fast oppbygning:
#   Fotoalbum.app/Contents/Info.plist        navn, ID, versjon og teksten når appen ber om tilgang
#   Fotoalbum.app/Contents/MacOS/Fotoalbum   selve programmet

set -euo pipefail
cd "${0:A:h}/.."

[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

BUNDLE_ID=no.okse.fotoalbum
VERSION=1.0
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

echo "Bygger …"
swift build -c release --product Fotoalbum 2>&1 | grep -E "error|Build complete" || true
BIN=$(swift build -c release --show-bin-path)

APP=dist/Fotoalbum.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Fotoalbum" "$APP/Contents/MacOS/Fotoalbum"
# Ressursene (delstatskartet) ligger i en egen bundle som programmet finner ved siden av seg.
cp -R "$BIN/Fotoalbum_Fotoalbum.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Fotoalbum</string>
    <key>CFBundleDisplayName</key>          <string>Fotoalbum</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>           <string>Fotoalbum</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD</string>
    <key>CFBundleDevelopmentRegion</key>    <string>nb</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSPhotoLibraryUsageDescription</key>
    <string>Fotoalbum leser dato og sted fra iPhone-bildene dine for å kopiere dem til de analoge bildene. Ingenting endres i Bilder.</string>
</dict>
</plist>
PLIST

if [[ "${1:-}" != "--no-install" ]]; then
    rm -rf /Applications/Fotoalbum.app
    cp -R "$APP" /Applications/
    echo "Installert i /Applications/Fotoalbum.app"
else
    echo "Bygget: $APP"
fi
