#!/usr/bin/env bash
# Archiva y exporta EfbyPostmanPad como .ipa firmado (un solo binario universal: iPhone + iPad).
#
# Nota importante: la «notarización» (notarytool) es solo para software macOS (.app/.dmg/.pkg).
# En iOS/iPadOS la equivalencia para distribución pública es: IPA firmado + subida a App Store Connect
# (Transporter o Xcode Organizer); Apple valida el binario en el servidor al subirlo / para TestFlight.
#
# Uso (desde la raíz del repo):
#   ./scripts/export-ios-appstore.sh
#     → IPA para subir a App Store Connect / TestFlight (NO instalar el .ipa directo en el iPhone).
#   ./scripts/export-ios-appstore.sh --device-install
#     → IPA firmado como development (instalable en dispositivos del team ya registrados; AirDrop/Finder).
#   EXPORT_METHOD=ad-hoc ./scripts/export-ios-appstore.sh
#   ./scripts/export-ios-appstore.sh --clean
#
# Tras un export correcto se copia el .ipa a una ruta fija para compartir (AirDrop, Drive, correo):
#   Distribution/EfbyPostmanPad.ipa
#   (sobrescribe la copia anterior). Personaliza con IPA_SHARE_PATH=/ruta/al/archivo.ipa
#
# Subir a App Store Connect / TestFlight (automatizado): ./scripts/upload-ipa-appstore-connect.sh
# Build + subida: ./scripts/distribute-ios-testflight.sh (ver scripts/README-IPAD-DEPLOY.md)
#
# IPA para compartir e instalar en dispositivos (sin TestFlight): ./scripts/export-ios-shareable-ipa.sh
#
# Variables:
#   DEVELOPMENT_TEAM   (por defecto FYU5QTGXLB)
#   EXPORT_METHOD      app-store-connect | app-store | ad-hoc | development | enterprise (por defecto app-store-connect)
#   IPA_SHARE_PATH     destino de la copia «para compartir» (por defecto Distribution/EfbyPostmanPad.ipa)
#
# Requisitos: Xcode, sesión con Apple Developer (Keychain / Xcode Accounts), perfil/certs resolubles
# con firma automática (-allowProvisioningUpdates).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_DEFAULT="FYU5QTGXLB"
: "${DEVELOPMENT_TEAM:=$TEAM_DEFAULT}"

PAD="$ROOT/Apps/EfbyPostmanPad"
SCHEME="EfbyPostmanPad"
DIST="$ROOT/Distribution"
ARCHIVE_PATH="$DIST/EfbyPostmanPad.xcarchive"
EXPORT_DIR="$DIST/EfbyPostmanPad-export"
: "${IPA_SHARE_PATH:=$DIST/EfbyPostmanPad.ipa}"
DERIVED="$PAD/.derivedDataArchiveExport"
EXPORT_PLIST=""

CLEAN=0
EXPORT_METHOD_CLI=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean) CLEAN=1; shift ;;
    --device-install)
      EXPORT_METHOD_CLI="development"
      shift
      ;;
    -h|--help)
      sed -n '1,35p' "$0"
      exit 0
      ;;
    *)
      echo "Argumento desconocido: $1 (usa --clean, --device-install, -h)"
      exit 1
      ;;
  esac
done

if [[ -n "$EXPORT_METHOD_CLI" ]]; then
  EXPORT_METHOD="$EXPORT_METHOD_CLI"
fi
: "${EXPORT_METHOD:=app-store-connect}"

if [[ ! -d "$PAD/EfbyPostmanPad.xcodeproj" ]]; then
  echo "Error: no existe $PAD/EfbyPostmanPad.xcodeproj"
  exit 1
fi

case "$EXPORT_METHOD" in
  app-store-connect|app-store|ad-hoc|development|enterprise) ;;
  *)
    echo "EXPORT_METHOD invalido: $EXPORT_METHOD (usa app-store-connect, app-store, ad-hoc, development o enterprise)"
    exit 1
    ;;
esac

mkdir -p "$DIST"
rm -rf "$EXPORT_DIR"
EXPORT_PLIST="$(mktemp -t efby-postman-export.XXXXXX.plist)"
trap 'rm -f "$EXPORT_PLIST"' EXIT

cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>${EXPORT_METHOD}</string>
	<key>teamID</key>
	<string>${DEVELOPMENT_TEAM}</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>uploadSymbols</key>
	<true/>
	<key>stripSwiftSymbols</key>
	<true/>
</dict>
</plist>
PLIST

if [[ "$CLEAN" == 1 ]]; then
  echo "→ clean + borrar xcarchive anterior"
  rm -rf "$ARCHIVE_PATH" "$DERIVED"
  (cd "$PAD" && xcodebuild -project EfbyPostmanPad.xcodeproj -scheme "$SCHEME" -configuration Release clean >/dev/null) || true
fi

echo "→ archive (Release, generic/platform=iOS, team=$DEVELOPMENT_TEAM)"
xcodebuild archive \
  -project "$PAD/EfbyPostmanPad.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic

echo "→ exportArchive → $EXPORT_DIR (method=$EXPORT_METHOD)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

IPA=$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit || true)
echo ""
echo "Listo."
echo "  Archive: $ARCHIVE_PATH"
if [[ -n "$IPA" ]]; then
  echo "  IPA (export): $IPA"
  mkdir -p "$(dirname "$IPA_SHARE_PATH")"
  cp -f "$IPA" "$IPA_SHARE_PATH"
  echo "  IPA (compartir): $IPA_SHARE_PATH"
  echo ""
  case "$EXPORT_METHOD" in
    app-store|app-store-connect)
      echo "Siguiente paso típico: sube el IPA con Transporter o Xcode → Organizer (App Store / TestFlight)."
      echo "Para repartir el archivo por AirDrop/correo, envia: ${IPA_SHARE_PATH}"
      echo ""
      echo ">>> Si al instalar el .ipa en el iPhone ves «no se pudo validar la integridad»:"
      echo "    Es normal: este IPA es para App Store Connect, no para sideload."
      echo "    Opciones: (1) TestFlight  (2) ./scripts/export-ios-appstore.sh --device-install"
      echo "    (3) EXPORT_METHOD=ad-hoc con UDIDs registrados en developer.apple.com"
      ;;
    ad-hoc|development)
      echo "Este IPA solo instala en dispositivos cuyo UDID este en el perfil de aprovisionamiento del equipo."
      echo "Comparte ${IPA_SHARE_PATH} (AirDrop, Drive); el receptor instala con Apple Configurator, MDM o Finder."
      ;;
    enterprise)
      echo "IPA enterprise: comparte ${IPA_SHARE_PATH} segun la politica interna de tu organizacion."
      ;;
  esac
  echo "  iPhone e iPad: un solo IPA (target universal)."
else
  echo "  (No se encontró .ipa en $EXPORT_DIR; revisa el log de export arriba.)"
fi
