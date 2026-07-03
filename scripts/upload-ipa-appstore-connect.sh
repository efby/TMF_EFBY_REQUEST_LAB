#!/usr/bin/env bash
# Sube un .ipa a App Store Connect (mismo flujo que Transporter → luego TestFlight / revisión).
#
# Requiere Xcode (incluye altool). Autenticación, una de estas dos:
#
#   A) Clave API de App Store Connect (recomendado en CI y en terminal):
#        export ASC_API_KEY_ID=XXXXXXXXXX
#        export ASC_ISSUER_ID=uuid-del-issuer
#        export ASC_PRIVATE_KEYS_DIR=/ruta/al/directorio/que/contiene/AuthKey_XXXXXXXXXX.p8
#
#   B) Apple ID + contraseña de app (cuenta Apple → claves de app):
#        export ASC_APPLE_ID=tu@correo.com
#        export ASC_APP_PASSWORD=abcd-efgh-ijkl-mnop
#      O contraseña en llavero del Mac:
#        export ASC_APPLE_ID=tu@correo.com
#        export ASC_KEYCHAIN_PASSWORD_ITEM=NombreItemLlavero
#        y usar: -p @keychain:NombreItemLlavero  (el script lo monta si defines ASC_KEYCHAIN_PASSWORD_ITEM)
#
# Uso:
#   ./scripts/upload-ipa-appstore-connect.sh
#   ./scripts/upload-ipa-appstore-connect.sh /ruta/custom.ipa
#   ./scripts/upload-ipa-appstore-connect.sh --validate-only
#
# La app debe existir en App Store Connect con el mismo bundle ID que el IPA (efbypostmanpad.EfbyPostmanPad).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_IPA="$ROOT/Distribution/EfbyPostmanPad.ipa"
IPA="${1:-$DEFAULT_IPA}"
VALIDATE_ONLY=0

if [[ "${1:-}" == "--validate-only" ]]; then
  VALIDATE_ONLY=1
  IPA="${2:-$DEFAULT_IPA}"
elif [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  sed -n '1,45p' "$0"
  exit 0
fi

if ! command -v xcrun &>/dev/null; then
  echo "Error: no se encontró xcrun (instala Xcode)."
  exit 1
fi

if [[ ! -f "$IPA" ]]; then
  echo "Error: no existe el IPA: $IPA"
  echo "Genera uno antes: ./scripts/export-ios-appstore.sh"
  exit 1
fi

AUTH_ARGS=()
if [[ -n "${ASC_API_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  if [[ -z "${ASC_PRIVATE_KEYS_DIR:-}" && -z "${API_PRIVATE_KEYS_DIR:-}" ]]; then
    echo "Error: con ASC_API_KEY_ID y ASC_ISSUER_ID debes definir ASC_PRIVATE_KEYS_DIR (o API_PRIVATE_KEYS_DIR):"
    echo "  directorio que contiene el fichero AuthKey_${ASC_API_KEY_ID}.p8"
    exit 1
  fi
  export API_PRIVATE_KEYS_DIR="${ASC_PRIVATE_KEYS_DIR:-${API_PRIVATE_KEYS_DIR:-}}"
  AUTH_ARGS+=(--api-key "$ASC_API_KEY_ID" --api-issuer "$ASC_ISSUER_ID")
  echo "→ Autenticación: API Key (issuer $ASC_ISSUER_ID, keys en $API_PRIVATE_KEYS_DIR)"
elif [[ -n "${ASC_APPLE_ID:-}" ]]; then
  if [[ -n "${ASC_KEYCHAIN_PASSWORD_ITEM:-}" ]]; then
    AUTH_ARGS+=(-u "$ASC_APPLE_ID" -p "@keychain:${ASC_KEYCHAIN_PASSWORD_ITEM}")
    echo "→ Autenticación: Apple ID + llavero (@keychain:${ASC_KEYCHAIN_PASSWORD_ITEM})"
  elif [[ -n "${ASC_APP_PASSWORD:-}" ]]; then
    AUTH_ARGS+=(-u "$ASC_APPLE_ID" -p "$ASC_APP_PASSWORD")
    echo "→ Autenticación: Apple ID + contraseña de app (variable de entorno)"
  else
    echo "Error: define ASC_APP_PASSWORD o ASC_KEYCHAIN_PASSWORD_ITEM junto con ASC_APPLE_ID"
    exit 1
  fi
else
  echo "Error: falta autenticación. Define una de estas opciones:"
  echo ""
  echo "  Opción A (clave API):"
  echo "    export ASC_API_KEY_ID=..."
  echo "    export ASC_ISSUER_ID=..."
  echo "    export ASC_PRIVATE_KEYS_DIR=/ruta/con/AuthKey_<KEY_ID>.p8"
  echo ""
  echo "  Opción B (Apple ID):"
  echo "    export ASC_APPLE_ID=tu@correo.com"
  echo "    export ASC_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx   # contraseña de app"
  echo ""
  echo "Crea la clave API en: https://appstoreconnect.apple.com/access/integrations/api"
  exit 1
fi

EXTRA=(--show-progress)
[[ "${VERBOSE:-}" == "1" ]] && EXTRA+=(--verbose)

if [[ "$VALIDATE_ONLY" == 1 ]]; then
  echo "→ validate-app: $IPA"
  xcrun altool --validate-app "$IPA" -t ios "${AUTH_ARGS[@]}" "${EXTRA[@]}"
  echo "Validación terminada."
  exit 0
fi

echo "→ upload-package: $IPA"
xcrun altool --upload-package "$IPA" -t ios "${AUTH_ARGS[@]}" "${EXTRA[@]}"

echo ""
echo "Listo. En App Store Connect → tu app → TestFlight debería aparecer el build en procesamiento (varios minutos)."
echo "Invitaciones TestFlight: App Store Connect → TestFlight → grupos / testers externos (tras revisión beta si aplica)."
