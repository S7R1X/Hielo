#!/bin/bash
# Publica una versión de Hielo en un solo paso.
#
#   bash release.sh 1.1.0 [--notes notas.md] [--no-install] [--dry-run]
#
# Hace, en orden:
#   1. Pone la versión en el proyecto de Xcode (MARKETING_VERSION).
#   2. Compila la app en Release.
#   3. La firma con el certificado "Ice Local Signing", de dentro hacia fuera.
#   4. La comprime en Hielo-<versión>.zip y calcula su sha256.
#   5. La instala en /Applications (salvo --no-install).
#   6. Hace commit de la versión, crea la etiqueta v<versión> y sube ambos a GitHub.
#   7. Crea la Release en GitHub con el zip y las notas.
#   8. Actualiza versión y sha256 en el cask del tap de Homebrew y lo sube.
#
# Con --dry-run hace los pasos 1 a 5 y muestra lo que haría en los demás, sin tocar git
# ni GitHub. Las notas de la Release salen de --notes; si no se da, se generan con los
# commits desde la etiqueta anterior.
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
TAP="$PROJ/../homebrew-tap"
APP_NAME="Hielo"
IDENTITY="Ice Local Signing"
REPO="S7R1X/Hielo"

VERSION="${1:-}"
NOTES=""
INSTALL=1
DRY=0
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) NOTES="$2"; shift 2 ;;
    --no-install) INSTALL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "opción desconocida: $1" >&2; exit 2 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---- comprobaciones ----------------------------------------------------------
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "indica la versión como X.Y.Z, por ejemplo: bash release.sh 1.1.0"
[ -d "$TAP/Casks" ] || fail "no encuentro el tap de Homebrew en $TAP"
command -v gh >/dev/null || fail "falta gh (brew install gh)"
gh auth status >/dev/null 2>&1 || fail "gh no tiene sesión: ejecuta gh auth login"
security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY" || fail "no está el certificado \"$IDENTITY\" en el llavero"
cd "$PROJ"
if [ -n "$(git status --porcelain)" ]; then
  echo "Hay cambios sin commit en $PROJ:"; git status --short
  fail "haz commit (o descarta) antes de publicar: la versión debe salir de un árbol limpio"
fi
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "la etiqueta v$VERSION ya existe"
[ -z "$NOTES" ] || [ -f "$NOTES" ] || fail "no existe el archivo de notas $NOTES"

# ---- 1. versión ---------------------------------------------------------------
step "1/9 Versión $VERSION en el proyecto"
# Solo el target Ice lleva la versión de la app (X.Y.Z); MenuBarItemService se queda en 1.0.
CURRENT="$(sed -nE 's/.*MARKETING_VERSION = ([0-9]+\.[0-9]+\.[0-9]+);.*/\1/p' Hielo.xcodeproj/project.pbxproj | head -1)"
[ -n "$CURRENT" ] || fail "no encuentro la versión actual (MARKETING_VERSION X.Y.Z) en el proyecto"
[ "$CURRENT" != "$VERSION" ] || fail "el proyecto ya está en la versión $VERSION"
sed -i '' "s/MARKETING_VERSION = $CURRENT;/MARKETING_VERSION = $VERSION;/g" Hielo.xcodeproj/project.pbxproj
echo "   $CURRENT → $VERSION ($(grep -c "MARKETING_VERSION = $VERSION;" Hielo.xcodeproj/project.pbxproj) entradas)"
# El número de build (CFBundleVersion) sube en uno: es el que Sparkle compara para decidir
# si hay actualización. El mayor de los que haya es el de la app (el servicio tiene 1).
BUILD="$(sed -nE 's/.*CURRENT_PROJECT_VERSION = ([0-9]+);.*/\1/p' Hielo.xcodeproj/project.pbxproj | sort -n | tail -1)"
NEWBUILD=$((BUILD + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $BUILD;/CURRENT_PROJECT_VERSION = $NEWBUILD;/g" Hielo.xcodeproj/project.pbxproj
echo "   build $BUILD → $NEWBUILD"

# ---- 2. compilar --------------------------------------------------------------
step "2/9 Compilando (unos minutos)"
LOG="$(mktemp -t hielo-build).log"
if ! xcodebuild -project Hielo.xcodeproj -scheme Hielo -configuration Release \
    -derivedDataPath build -destination 'generic/platform=macOS' \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
    -skipPackagePluginValidation -skipMacroValidation build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20
  fail "la compilación falló; registro completo en $LOG"
fi
SRC="$PROJ/build/Build/Products/Release/Hielo.app"
BUILT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/Contents/Info.plist")"
[ "$BUILT" = "$VERSION" ] || fail "la app compilada dice $BUILT, no $VERSION"
echo "   BUILD SUCCEEDED ($VERSION)"

# ---- 3. firmar ----------------------------------------------------------------
step "3/9 Firmando con \"$IDENTITY\""
OUT="$(mktemp -d -t hielo-release)"
APP="$OUT/$APP_NAME.app"
cp -R "$SRC" "$APP"
SP="$APP/Contents/Frameworks/Sparkle.framework"
for t in \
  "$SP/Versions/B/XPCServices/Downloader.xpc" \
  "$SP/Versions/B/XPCServices/Installer.xpc" \
  "$SP/Versions/B/Autoupdate" \
  "$SP/Versions/B/Updater.app" \
  "$SP" \
  "$APP/Contents/XPCServices/MenuBarItemService.xpc" \
  "$APP"; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$t" >/dev/null 2>&1 || fail "no pude firmar $t"
done
codesign --verify --deep --strict "$APP" || fail "la firma no verifica"
echo "   firma OK"

# ---- 4. zip + sha256 ----------------------------------------------------------
step "4/9 Comprimiendo"
ZIP="$OUT/$APP_NAME-$VERSION.zip"
(cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "$(basename "$ZIP")")
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "   $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "   sha256 $SHA"

# ---- 5. instalar --------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
  step "5/9 Instalando en /Applications/$APP_NAME.app"
  osascript -e 'quit app id "bo.strix.hielo"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8; do pgrep -x Hielo >/dev/null || break; sleep 1; done
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  open -a "/Applications/$APP_NAME.app"
  echo "   instalada y abierta"
else
  step "5/9 Instalación omitida (--no-install)"
fi

# ---- notas --------------------------------------------------------------------
NOTES_FILE="$OUT/notas.md"
if [ -n "$NOTES" ]; then
  cp "$NOTES" "$NOTES_FILE"
else
  PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  {
    echo "## Cambios"
    if [ -n "$PREV" ]; then git log --format='- %s' "$PREV"..HEAD; else echo "- Primera versión."; fi
    echo
    echo "## Instalación"
    echo "- **Homebrew:** \`brew tap S7R1X/tap && brew trust S7R1X/tap && brew install --cask hielo\`"
    echo "- **Manual:** descarga \`$APP_NAME-$VERSION.zip\`, descomprímelo y mueve \`$APP_NAME.app\` a Aplicaciones."
    echo
    echo "> Hielo no está notarizado por Apple. La primera vez: clic derecho sobre la app → **Abrir** → **Abrir**. Después concede los permisos de **Accesibilidad** y **Grabación de pantalla**."
    echo
    echo "SHA-256 de \`$APP_NAME-$VERSION.zip\`: \`$SHA\`"
  } > "$NOTES_FILE"
fi

if [ "$DRY" = 1 ]; then
  step "Simulación: no se toca git ni GitHub. Haría lo siguiente:"
  echo "   git commit -am 'Versión $VERSION' && git tag -a v$VERSION && git push origin main v$VERSION"
  echo "   gh release create v$VERSION $ZIP --repo $REPO --title '$APP_NAME $VERSION' --latest"
  echo "   cask: version $VERSION, sha256 $SHA  →  commit y push en $TAP"
  echo "   appcast.xml: firmar el zip con la clave de Sparkle y añadir $VERSION  →  commit y push"
  echo
  echo "   Notas que se publicarían:"; sed 's/^/   | /' "$NOTES_FILE"
  echo
  echo "   Deshaciendo el cambio de versión en el proyecto (simulación)."
  git checkout -- Hielo.xcodeproj/project.pbxproj
  exit 0
fi

# ---- 6. git -------------------------------------------------------------------
step "6/9 Commit y etiqueta v$VERSION"
git commit -q -am "Versión $VERSION"
git tag -a "v$VERSION" -m "$APP_NAME $VERSION"
git push origin main "v$VERSION"

# ---- 7. release ---------------------------------------------------------------
step "7/9 Release en GitHub"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "$APP_NAME $VERSION" --notes-file "$NOTES_FILE" --latest

# ---- 8. tap -------------------------------------------------------------------
step "8/9 Cask de Homebrew"
CASK="$TAP/Casks/hielo.rb"
sed -i '' -E "s/^( *version )\"[^\"]+\"/\1\"$VERSION\"/; s/^( *sha256 )\"[^\"]+\"/\1\"$SHA\"/" "$CASK"
grep -E '^ *(version|sha256) ' "$CASK" | sed 's/^/   /'
(cd "$TAP" && git commit -q -am "hielo $VERSION" && git push origin main)

# ---- 9. appcast (actualizaciones desde la app) ---------------------------------
step "9/9 Appcast de actualizaciones (Sparkle)"
GEN="$PROJ/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
[ -x "$GEN" ] || fail "no encuentro generate_appcast en $GEN"
FEED="$OUT/feed"
mkdir -p "$FEED"
cp "$ZIP" "$FEED/"
# Las notas, en HTML sencillo, se incrustan en el appcast y la app las muestra al avisar.
{
  echo "<html><body>"
  sed -E 's/^## (.*)$/<h2>\1<\/h2>/; s/^- (.*)$/<li>\1<\/li>/; s/^> (.*)$/<p><em>\1<\/em><\/p>/; s/`([^`]*)`/<code>\1<\/code>/g; s/\*\*([^*]*)\*\*/<b>\1<\/b>/g' "$NOTES_FILE"
  echo "</body></html>"
} > "$FEED/$APP_NAME-$VERSION.html"
# Firma el zip con la clave privada del llavero y añade la versión al appcast del
# repositorio, conservando las anteriores. La URL de descarga es la de la Release.
"$GEN" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  --full-release-notes-url "https://github.com/$REPO/releases/tag/v$VERSION" \
  --embed-release-notes \
  -o "$PROJ/appcast.xml" "$FEED" 2>&1 | grep -v "^Wrote\|^Written" || true
grep -q "<sparkle:version>$NEWBUILD</sparkle:version>" "$PROJ/appcast.xml" || fail "el appcast no contiene la versión $VERSION (build $NEWBUILD)"
grep -q "Hielo-$VERSION.zip\".*sparkle:edSignature=\"[A-Za-z0-9+/=]\{20,\}\"" "$PROJ/appcast.xml" || fail "la entrada de $VERSION no lleva firma EdDSA: ¿está la clave de Sparkle en el llavero?"
git add appcast.xml
git commit -q -m "Appcast: $APP_NAME $VERSION"
git push origin main
echo "   appcast.xml publicado; la app avisará de $VERSION en su próxima comprobación"

echo
echo "Publicado $APP_NAME $VERSION:"
echo "  https://github.com/$REPO/releases/tag/v$VERSION"
echo "  brew upgrade --cask hielo   (tras: brew update)"
