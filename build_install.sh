#!/bin/bash
# Compila Hielo (fork de Ice con soporte para macOS 27), lo firma con el certificado
# "Ice Local Signing" sin hardened runtime, lo instala en /Applications/Hielo.app y lo
# relanza. Con ese certificado los permisos de macOS se conservan entre builds.
set -e

PROJ="/Users/mau/Projects/Strix/Ice-1001"
APP="/Applications/Hielo.app"
cd "$PROJ"

echo "==> 1/5 Compilando (puede tardar unos minutos)..."
rm -rf build
xcodebuild -project Hielo.xcodeproj -scheme Hielo -configuration Release \
  -derivedDataPath build -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -skipPackagePluginValidation -skipMacroValidation \
  clean build | tail -3

SRC="$PROJ/build/Build/Products/Release/Hielo.app"
if [ ! -d "$SRC" ]; then echo "ERROR: no se generó el .app"; exit 1; fi

echo "==> 2/5 Cerrando Ice actual..."
killall Ice 2>/dev/null || true
killall MenuBarItemService 2>/dev/null || true
sleep 2

echo "==> 3/5 Instalando en /Applications..."
rm -rf "$APP"
cp -R "$SRC" "$APP"

echo "==> 4/5 Firmando con 'Ice Local Signing' SIN hardened runtime (inside-out)..."
SP="$APP/Contents/Frameworks/Sparkle.framework"
for t in \
  "$SP/Versions/B/XPCServices/Downloader.xpc" \
  "$SP/Versions/B/XPCServices/Installer.xpc" \
  "$SP/Versions/B/Autoupdate" \
  "$SP/Versions/B/Updater.app" \
  "$SP" \
  "$APP/Contents/XPCServices/MenuBarItemService.xpc" \
  "$APP"; do
  codesign --force --sign "Ice Local Signing" --timestamp=none "$t" >/dev/null 2>&1 && echo "   firmado: $(basename "$t")"
done
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> 5/5 Verificando y relanzando..."
codesign --verify --deep --strict "$APP" && echo "   firma OK"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" | sed 's/^/   version: /'
open -a "$APP"
sleep 3
if pgrep -f 'Hielo.app/Contents/MacOS/Hielo' >/dev/null; then
  echo ">>> LISTO: Hielo corriendo en macOS 27"
else
  echo ">>> Hielo no quedó corriendo; revisa ~/Library/Logs/DiagnosticReports/ por crash logs"
fi
