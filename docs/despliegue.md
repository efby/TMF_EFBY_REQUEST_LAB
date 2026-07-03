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

Requisitos locales (no en CI por defecto):

- Certificado **Developer ID Application**
- Perfil notarización `xcrun notarytool store-credentials`
- Team ID configurado en `build_dmg.sh`

El workflow de release en CI genera DMG **sin firma** como artefacto descargable. Para distribución firmada, ejecutar localmente con `--sign --notarize` y subir manualmente o configurar secrets en GitHub.

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
