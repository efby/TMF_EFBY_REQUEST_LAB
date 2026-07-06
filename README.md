# EFBY Request Lab

Cliente API nativo para macOS con compatibilidad Postman, orquestación BPMN y sincronización Git.

**Repositorio:** [github.com/efby/TMF_EFBY_REQUEST_LAB](https://github.com/efby/TMF_EFBY_REQUEST_LAB)

**Vídeo demo:** [youtu.be/Q15wS9GjTJ0](https://youtu.be/Q15wS9GjTJ0)

**Slides (PDF):** [docs/presentacion/EFBY-Request-Lab-Slides.pdf](docs/presentacion/EFBY-Request-Lab-Slides.pdf)

## Descripción

EFBY Request Lab es un laboratorio de APIs de escritorio escrito en Swift. Permite importar colecciones Postman y especificaciones OpenAPI, ejecutar peticiones HTTP y WebSocket con variables por capas, scripts JavaScript compatibles con `pm.*`, y orquestar flujos multi-petición mediante un editor BPMN integrado.

La solución está organizada en capas (`EfbyDomain`, `EfbyApplication`, `EfbyInfrastructure`, `EfbyPresentation`), con 10 especificaciones SDD y 166 tests automatizados.

Documentación: [docs/README.md](docs/README.md)

## Stack tecnológico

| Componente | Tecnología |
|------------|------------|
| Lenguaje | Swift 6.3 (concurrencia estricta) |
| UI macOS | SwiftUI + AppKit |
| UI iPad | SwiftUI (`Apps/EfbyPostmanPad`) |
| Paquetes | Swift Package Manager |
| Red | URLSession, WebSocket nativo |
| Scripts | JavaScriptCore (`pm.*`, RSA/AES) |
| Persistencia | JSON local + Git manual |
| Flujos | BPMN (editor WebView embebido) |
| Dependencias | [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) |
| CI | GitHub Actions (`swift build`, `swift test`) |

## Instalación y ejecución

### Requisitos

- macOS 14 o superior
- Xcode 15+ o Swift 6.3 toolchain

### Opción A — Descargar DMG (recomendado)

1. Ir a [GitHub Releases](https://github.com/efby/TMF_EFBY_REQUEST_LAB/releases/latest)
2. Descargar `EFBYRequestLab.dmg`
3. Arrastrar **EFBY Request Lab** a Applications

### Opción B — Compilar desde fuente

```bash
git clone https://github.com/efby/TMF_EFBY_REQUEST_LAB.git
cd TMF_EFBY_REQUEST_LAB

swift build
swift test
swift build -c release --product EfbyRequestLabs
.open .build/release/EfbyRequestLabs
```

### Build DMG local

```bash
./Tools/build_dmg.sh
# Producción firmada:
./Tools/build_dmg.sh --sign --notarize
```

Ver [docs/despliegue.md](docs/despliegue.md) para detalles.

## Estructura del proyecto

```
EFBY_POSTMAN/
├── Package.swift
├── Sources/
│   ├── AppCore/
│   │   ├── Domain/                 # EfbyDomain — modelos
│   │   └── Application/            # EfbyInfrastructure — HTTP, WS, Git, scripts, persistencia
│   ├── EfbyApplication/            # Puertos y casos de uso
│   ├── EfbyPresentation/           # Presentación
│   │   ├── Composition/            # AppDependencies (composition root)
│   │   ├── Coordinators/           # Orquestación por dominio (Git, flows, entornos, …)
│   │   ├── Support/                # Clipboard, security-scope, scripts de colección
│   │   ├── MainViewModel.swift
│   │   └── RequestTabState.swift
│   ├── EFBYPostman/                # App macOS (SwiftUI)
│   │   ├── Views/
│   │   └── Resources/              # BPMN, editor de código
│   └── FlowDebugRunner/            # CLI de depuración de flujos
├── Tests/AppCoreTests/             # Suite unitaria (166 tests)
├── Apps/EfbyPostmanPad/            # App iPad
├── Examples/                       # JSON de ejemplo Postman / OpenAPI
├── docs/                           # Documentación y ADRs
├── SDD/tile/specs/                 # Especificaciones SDD (10)
├── Tools/build_dmg.sh              # Empaquetado macOS
└── .github/workflows/              # CI y releases
```

### Módulos SPM

| Módulo | Responsabilidad |
|--------|-----------------|
| `EfbyDomain` | Modelos de dominio |
| `EfbyApplication` | Puertos y casos de uso |
| `EfbyInfrastructure` | Implementaciones (red, Git, codecs, repositorios, scripts) |
| `EfbyPresentation` | ViewModel, coordinadores y composición |
| `EfbyRequestLabs` | Aplicación macOS |
| `FlowDebugRunner` | Herramienta CLI para flujos |

La app iPad (`EfbyPostmanPad`) consume el producto `EfbyPresentation` del mismo paquete.

## Funcionalidades principales

- **HTTP** — Editor de peticiones, variables, auth, TLS, scripts pre-request/tests, historial
- **WebSocket** — Conexión, transcript, ping, scripts `onMessage`/`onDone`
- **Variables** — Global, colección, entorno y local con precedencia `{{variable}}`
- **Postman** — Import/export Collection v2.0 y v2.1, entornos
- **OpenAPI** — Importación 3.0/3.1 JSON
- **Git** — Pull/push manual de colecciones en `collections/`
- **BPMN** — Editor visual y ejecución de flujos con gateways y paralelismo
- **Scripts** — Runtime `pm.crypto` (RSA-OAEP-SHA256, AES), utilidades compartidas
- **iPad** — Variante `EfbyPostmanPad` para ejecución móvil

## Autenticación

EFBY Request Lab es una aplicación de escritorio offline sin sistema de login. Las credenciales Git las gestiona el sistema operativo (SSH keys, credential helper).

## Licencia

Uso libre con atribución: puedes utilizar, modificar y distribuir el software siempre que menciones el proyecto original **EFBY Request Lab** y su autor. Ver [LICENSE](LICENSE).
