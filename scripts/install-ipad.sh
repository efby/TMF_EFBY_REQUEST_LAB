#!/usr/bin/env bash
# Compila, instala y lanza EfbyPostmanPad en un iPad/iPhone conectado.
# Usa EfbyPostmanPad.xcodeproj (bundle .app real). No hay Package.swift en Apps/EfbyPostmanPad.
# Proceso detallado (requisitos, variables, troubleshooting): scripts/README-IPAD-DEPLOY.md
#
# Uso:
#   ./scripts/install-ipad.sh
#   ./scripts/install-ipad.sh D4014F82-27C6-5A0E-A77D-233938D0FA9E   # UUID Core Device o UDID hardware

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEAM_ID="FYU5QTGXLB"
: "${DEVELOPMENT_TEAM:=$TEAM_ID}"
PAD="$ROOT/Apps/EfbyPostmanPad"
DERIVED="$PAD/.derivedData"
XCPROJ="$PAD/EfbyPostmanPad.xcodeproj"
BUNDLE_ID="efbypostmanpad.EfbyPostmanPad"
APP_OUT="$DERIVED/Build/Products/Release-iphoneos/EfbyPostmanPad.app"

usage() {
  echo "Uso: $0 [UUID_o_UDID]"
  echo ""
  echo "Sin argumento: primer dispositivo «connected» (devicectl)."
  echo "Variables opcionales: DEVELOPMENT_TEAM (por defecto $TEAM_ID)."
  exit 0
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
fi

if [[ ! -d "$XCPROJ" ]]; then
  echo "Error: no existe $XCPROJ"
  exit 1
fi

if ! command -v xcrun &>/dev/null; then
  echo "Error: no se encontró xcrun (instala Xcode)."
  exit 1
fi

pick_device_ids() {
  local filter="${1:-}"
  python3 -c "
import json, sys
path, filt = sys.argv[1], sys.argv[2] or None
with open(path) as f:
    d = json.load(f)
for dev in d.get('result', {}).get('devices', []):
    cp = dev.get('connectionProperties') or {}
    if cp.get('tunnelState') != 'connected':
        continue
    core = dev.get('identifier') or ''
    hw = (dev.get('hardwareProperties') or {}).get('udid') or ''
    if filt and filt not in (core, hw):
        continue
    print(core)
    print(hw)
    sys.exit(0)
sys.exit(1)
" "$@"
}

JSON_TMP="$(mktemp)"
xcrun devicectl list devices --json-output "$JSON_TMP" 2>/dev/null || true
if [[ ! -s "$JSON_TMP" ]]; then
  echo "Error: no se pudo listar dispositivos (devicectl)."
  rm -f "$JSON_TMP"
  exit 1
fi

FILTER_ARG="${1:-}"
if ! IDS="$(pick_device_ids "$JSON_TMP" "$FILTER_ARG")"; then
  rm -f "$JSON_TMP"
  echo "Error: no hay dispositivo «connected\"${FILTER_ARG:+ coincidente con $FILTER_ARG}."
  echo "Lista: xcrun devicectl list devices"
  exit 1
fi
rm -f "$JSON_TMP"

CORE_DEVICE_ID="$(echo "$IDS" | sed -n '1p')"
XCODE_DEST_ID="$(echo "$IDS" | sed -n '2p')"
if [[ -z "$CORE_DEVICE_ID" || -z "$XCODE_DEST_ID" ]]; then
  echo "Error: no se pudo resolver identificadores del dispositivo."
  exit 1
fi

echo "→ Core Device (install/launch): $CORE_DEVICE_ID"
echo "→ xcodebuild destination id:   $XCODE_DEST_ID"
echo "→ DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
echo ""

cd "$PAD"
set +e
xcodebuild \
  -project EfbyPostmanPad.xcodeproj \
  -scheme EfbyPostmanPad \
  -sdk iphoneos \
  -destination "platform=iOS,id=$XCODE_DEST_ID" \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build
XC=$?
set -e
if [[ "$XC" -ne 0 ]]; then
  echo ""
  echo "Error: xcodebuild falló (código $XC). Revisa firma / dispositivo en Xcode → Accounts."
  exit "$XC"
fi

if [[ ! -d "$APP_OUT" ]]; then
  echo "Error: no se encontró $APP_OUT tras el build."
  exit 1
fi

echo ""
echo "→ Instalando .app en el dispositivo…"
xcrun devicectl device install app --quiet -d "$CORE_DEVICE_ID" "$APP_OUT"

echo "→ Lanzando $BUNDLE_ID …"
xcrun devicectl device process launch --quiet -d "$CORE_DEVICE_ID" "$BUNDLE_ID"

echo ""
echo "Listo: la app debería abrirse en el iPad (EFBY Request Lab)."
