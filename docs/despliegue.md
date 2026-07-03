# Despliegue y distribución

## Resumen

EFBY Request Lab se distribuye como aplicación nativa macOS empaquetada en **DMG**, publicada en **GitHub Releases**.

| Recurso | URL |
|---------|-----|
| Repositorio | https://github.com/efby/TMF_EFBY_REQUEST_LAB |
| Última release | https://github.com/efby/TMF_EFBY_REQUEST_LAB/releases/latest |
| CI | https://github.com/efby/TMF_EFBY_REQUEST_LAB/actions |

## Requisitos de build

- macOS 14+
- Xcode 15+ o Swift 6.3 toolchain
- Command Line Tools instaladas

## Build local (desarrollo)

```bash
cd /ruta/al/repo
swift build
swift test
swift build -c release --product EfbyRequestLabs
.open .build/release/EfbyRequestLabs
```

## Build DMG

Script: [`Tools/build_dmg.sh`](../../Tools/build_dmg.sh)

```bash
# DMG sin firma (desarrollo / CI)
./Tools/build_dmg.sh

# DMG firmado
./Tools/build_dmg.sh --sign

# DMG firmado + notarizado (producción)
./Tools/build_dmg.sh --sign --notarize
```

### Artefactos generados

| Archivo | Ubicación |
|---------|-----------|
| App bundle | `Distribution/EFBY Request Lab.app` |
| DMG | `Distribution/EFBYRequestLab.dmg` |
| ZIP | `Distribution/EFBYRequestLab.zip` |

> `Distribution/` está en `.gitignore`; los binarios se publican solo vía GitHub Releases.

## Firma y notarización (producción)

Para que el DMG se abra en cualquier Mac **sin** “App dañada / no se puede verificar”, hace falta:

1. Firma con certificado **Developer ID Application**
2. Notarización con Apple (`notarytool`)
3. Stapling del ticket en la app y en el DMG

### Local

```bash
# Una vez: guardar credenciales de notarización en el llavero
xcrun notarytool store-credentials efby-requestlabs-notary \
  --apple-id "tu@email.com" \
  --team-id FYU5QTGXLB \
  --password "app-specific-password"

./Tools/build_dmg.sh --sign --notarize
```

### GitHub Actions (Release)

El workflow `.github/workflows/release.yml` firma y notariza automáticamente si existen estos **secrets** del repositorio:

| Secret | Descripción |
|--------|-------------|
| `MACOS_CERTIFICATE_P12_BASE64` | Certificado Developer ID Application exportado como `.p12`, en Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | Contraseña del `.p12` |
| `APPLE_ID` | Apple ID del equipo |
| `APPLE_APP_SPECIFIC_PASSWORD` | Contraseña de app (appleid.apple.com → Seguridad) |
| `APPLE_TEAM_ID` | Team ID (ej. `FYU5QTGXLB`) |

Exportar el certificado a Base64 (en Mac local):

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Si faltan secrets, el release publica un DMG **sin firma** (solo para pruebas).

## GitHub Releases

### Automático (CI)

Workflow `.github/workflows/release.yml`:

1. Trigger: push de tag `v*` (ej. `v1.0.0`)
2. Build release: `swift build -c release --product EfbyRequestLabs`
3. Ejecutar `Tools/build_dmg.sh`
4. Publicar `EFBYRequestLab.dmg` como asset de la release

### Manual

```bash
git tag v1.0.0
git push origin v1.0.0
```

## Instalación para el usuario final

1. Ir a [Releases](https://github.com/efby/TMF_EFBY_REQUEST_LAB/releases/latest).
2. Descargar `EFBYRequestLab.dmg`.
3. Abrir DMG y arrastrar **EFBY Request Lab** a Applications.
4. Primera ejecución: si macOS muestra advertencia, ir a Ajustes → Privacidad y seguridad → Abrir igualmente (solo builds no notarizados).

## App iPad (opcional)

Ver [`Apps/EfbyPostmanPad/README.md`](../../Apps/EfbyPostmanPad/README.md) y [`scripts/README-IPAD-DEPLOY.md`](../../scripts/README-IPAD-DEPLOY.md).

## Datos de la aplicación

| Dato | Ubicación |
|------|-----------|
| Workspace local | `~/Library/Application Support/EFBYPostman/workspace.json` |
| Colecciones Git | `{repo-clonado}/collections/*.json` |

## Credenciales

La aplicación **no requiere login**. Es herramienta de escritorio offline. Las credenciales Git las gestiona el sistema (SSH keys, credential helper).

## Variables de entorno

No se requieren variables de entorno para ejecutar la app. El build DMG usa rutas relativas al repositorio.

## Monitorización post-despliegue

- Issues en GitHub para reportes de usuarios.
- `swift test` en CI como regresión automática.
