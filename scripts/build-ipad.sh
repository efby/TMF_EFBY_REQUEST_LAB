#!/usr/bin/env bash
# Compila la app iOS EfbyPostmanPad (.app) vía EfbyPostmanPad.xcodeproj (no el ejecutable SwiftPM).
#
# Simulador: destino por defecto o el que pases como argumento.
# iPad físico:   ./scripts/build-ipad.sh --device
#               Requiere cable o Wi‑Fi, iPad con “Confiar”, Modo desarrollador activado.
#               Firma: por defecto usa el mismo Team que Tools/build_dmg.sh; sobreescribe con DEVELOPMENT_TEAM=…

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="FYU5QTGXLB"
DEVELOPER_ID_APP="Developer ID Application: EFBY SERVICIOS INFORMATICOS LIMITADA ($TEAM_ID)"
: "${DEVELOPMENT_TEAM:=$TEAM_ID}"
PAD="$ROOT/Apps/EfbyPostmanPad"
DERIVED="$PAD/.derivedData"

cd "$PAD"

usage() {
  echo "Uso:"
  echo "  $0                                    # simulador: generic/platform=iOS Simulator"
  echo "  $0 'platform=iOS Simulator,name=…'"  # simulador con nombre exacto"
  echo "  $0 --device                           # iPad/iPhone físico (firma automática)"
  echo "  $0 --device 'id=XXXXXXXX-…'         # dispositivo por UDID (ver xcrun devicectl list devices)"
  echo ""
  echo "Variables de entorno (iPad físico, opcional):"
  echo "  export DEVELOPMENT_TEAM=AB12CD34EF   # si no, se usa TEAM_ID del script ($TEAM_ID)"
  echo ""
  echo "Misma cuenta que Tools/build_dmg.sh:"
  echo "  TEAM_ID=$TEAM_ID"
  echo "  $DEVELOPER_ID_APP"
  echo ""
  echo "Para instalar en un iPad físico: abre Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj en Xcode,"
  echo "elige tu iPad, Signing → Team, Run (▶). No uses solo Package.swift para Run en dispositivo."
  echo ""
  echo "IPA firmado (App Store / TestFlight / ad hoc, iPhone+iPad en un solo .ipa):"
  echo "  ./scripts/export-ios-appstore.sh"
  echo "  (ver scripts/README-IPAD-DEPLOY.md — la notarización notarytool es solo macOS.)"
  exit 0
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
fi

EXTRA=()
SDK=()
DEST=""
if [[ "${1:-}" == "--device" ]]; then
  # Force the iOS device SDK. Without this, xcodebuild can pick the iOS+DriverKit destination and
  # compile against DriverKit (Foundation/SwiftUI “missing”) or use the wrong deployment floor.
  SDK=(-sdk iphoneos)
  EXTRA+=(
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    "-allowProvisioningUpdates"
  )
  if [[ -n "${2:-}" ]]; then
    DEST="$2"
  else
    DEST="generic/platform=iOS"
  fi
else
  DEST="${1:-generic/platform=iOS Simulator}"
fi

echo "→ xcodebuild scheme EfbyPostmanPad"
echo "→ SDK: ${SDK[*]:-"(default)"}"
echo "→ destino: $DEST"
if [[ "${1:-}" == "--device" ]]; then
  echo "→ equipo (firma): DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
fi
echo ""

xcodebuild \
  -project EfbyPostmanPad.xcodeproj \
  -scheme EfbyPostmanPad \
  "${SDK[@]}" \
  -destination "$DEST" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  "${EXTRA[@]}" \
  build

APP=$(find "$DERIVED" -name "EfbyPostmanPad.app" -type d 2>/dev/null | head -1 || true)
if [[ -n "$APP" ]]; then
  echo ""
  echo "Listo. .app generado en:"
  echo "  $APP"
  echo ""
  echo "Para instalarlo en el iPad conectado (Xcode 15+), si devicectl está disponible:"
  echo "  ./scripts/install-ipad-app.sh \"$APP\""
else
  echo ""
  echo "No se encontró EfbyPostmanPad.app en DerivedData; revisa el log de xcodebuild arriba."
  echo "(El build debe usar -project EfbyPostmanPad.xcodeproj y esquema EfbyPostmanPad.)"
fi
