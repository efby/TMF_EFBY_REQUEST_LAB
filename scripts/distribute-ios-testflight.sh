#!/usr/bin/env bash
# Una sola pasada: genera el IPA (App Store Connect) y lo sube a App Store Connect.
# Requiere las mismas variables de entorno que ./scripts/upload-ipa-appstore-connect.sh
#
# Uso:
#   export ASC_API_KEY_ID=... ASC_ISSUER_ID=... ASC_PRIVATE_KEYS_DIR=...
#   ./scripts/distribute-ios-testflight.sh
#   ./scripts/distribute-ios-testflight.sh --clean
#
# No uses --device-install aquí (ese IPA no se sube a la tienda).

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/export-ios-appstore.sh" "$@"
"$ROOT/scripts/upload-ipa-appstore-connect.sh"
