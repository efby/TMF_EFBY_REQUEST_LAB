#!/usr/bin/env bash
# Instala un .app ya firmado en un iPad/iPhone conectado (USB o red).
# Requiere Xcode 15+ (herramienta devicectl) y que el dispositivo aparezca como “connected”.

set -euo pipefail

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]] || [[ $# -lt 1 ]]; then
  echo "Uso: $0 /ruta/a/EfbyPostmanPad.app [nombre_o_udid_dispositivo]"
  echo ""
  echo "Para el paquete Swift EfbyPostmanPad (binario sin .app), usa en su lugar:"
  echo "  ./scripts/install-ipad.sh"
  echo ""
  echo "Ejemplo si ya tienes un .app firmado:"
  echo "  $0 \"\$HOME/.../EfbyPostmanPad.app\""
  echo ""
  echo "Lista dispositivos:"
  echo "  xcrun devicectl list devices"
  exit 0
fi

APP="$1"
DEVICE_FILTER="${2:-}"

if [[ ! -d "$APP" ]]; then
  echo "Error: no existe el bundle: $APP"
  exit 1
fi

if ! xcrun devicectl help &>/dev/null; then
  echo "Error: no se encontró devicectl (instala una versión reciente de Xcode)."
  exit 1
fi

echo "Dispositivos (busca el tuyo en “connected”):"
xcrun devicectl list devices 2>/dev/null | head -40 || true
echo ""

if [[ -n "$DEVICE_FILTER" ]]; then
  echo "→ xcrun devicectl device install app -d \"$DEVICE_FILTER\" …"
  xcrun devicectl device install app --quiet -d "$DEVICE_FILTER" "$APP"
else
  echo "→ xcrun devicectl device install app (un solo dispositivo conectado)"
  xcrun devicectl device install app --quiet "$APP"
fi
echo "Instalación enviada. En el iPad: confía en el certificado de desarrollador si iOS lo pide."
