#!/usr/bin/env bash
# Genera un IPA pensado para COMPARTIR e INSTALAR en dispositivos físicos **antes** de TestFlight.
# No uses este flujo para subir a App Store Connect (para eso: ./scripts/export-ios-appstore.sh sin esto).
#
# Apple solo permite instalar un .ipa “suelto” si la firma incluye ese dispositivo:
#
#   • ad-hoc (por defecto): cada iPhone/iPad debe tener el UDID registrado en
#     https://developer.apple.com/account/resources/devices/list
#     **antes** de exportar (o regenera el IPA tras añadir nuevos UDID).
#
#   • development (--development): dispositivos del equipo que Xcode ya haya registrado
#     al depurar; útil para pocos aparatos tuyos del mismo Apple Developer Team.
#
# Uso:
#   ./scripts/export-ios-shareable-ipa.sh
#   ./scripts/export-ios-shareable-ipa.sh --development
#   ./scripts/export-ios-shareable-ipa.sh --clean
#
# Salida: Distribution/EfbyPostmanPad.ipa (misma ruta que el otro export; sobrescribe).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
METHOD="ad-hoc"
ARGS=()
for a in "$@"; do
  case "$a" in
    --development) METHOD="development" ;;
    *) ARGS+=("$a") ;;
  esac
done

echo "→ EXPORT_METHOD=$METHOD (IPA instalable por AirDrop/Finder en dispositivos del perfil)"
echo ""

export EXPORT_METHOD="$METHOD"
if [[ ${#ARGS[@]} -gt 0 ]]; then
  exec "$ROOT/scripts/export-ios-appstore.sh" "${ARGS[@]}"
else
  exec "$ROOT/scripts/export-ios-appstore.sh"
fi
