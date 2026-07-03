# EfbyPostmanPad (iOS / iPad)

App iOS **apartada** del Mac: no compila `Sources/EFBYPostman` (solo **`EfbyPresentation`** del repo raíz + UI SwiftUI aquí).

## Mac vs iPad

| Ubicación | Producto | Plataforma |
|-----------|----------|------------|
| Raíz `Package.swift` | `EfbyRequestLabs` | macOS 14+ |
| `EfbyPostmanPad.xcodeproj` | `EfbyPostmanPad` → **`EfbyPostmanPad.app`** | iOS 17+ (iPad) |

En esta carpeta **no** hay `Package.swift` propio: evita que Xcode ofrezca un ejecutable SwiftPM sin `.app` (error CoreDevice **3002** al hacer Run en un iPad).

Dependencia del proyecto Xcode: paquete local **`EFBY_POSTMAN`** (raíz del repo) → producto **`EfbyPresentation`**.

## Compilar en Xcode (recomendado)

**Simulador o iPad físico:**

1. **Xcode → Abrir** `Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj`.
2. Esquema **EfbyPostmanPad**, destino simulador iPad o tu iPad.
3. **Signing & Capabilities** del target → **Team** si es la primera vez en dispositivo.
4. **Run (▶)** o **Product → Build**.

## Compilar en terminal

Simulador (por defecto `generic/platform=iOS Simulator`):

```bash
./scripts/build-ipad.sh
```

Simulador con nombre concreto:

```bash
./scripts/build-ipad.sh 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'
```

### iPad físico (cable o Wi‑Fi)

1. En el iPad: **Ajustes → Privacidad y seguridad → Modo desarrollador** (activado), y al conectar el Mac: **Confiar**.
2. Obtén tu **Team ID** (10 caracteres): [developer.apple.com](https://developer.apple.com) → Membership, o Xcode → Settings → Accounts → equipo → **Team ID**.
3. Compila firmando hacia dispositivo genérico iOS:

```bash
export DEVELOPMENT_TEAM=XXXXXXXXXX
./scripts/build-ipad.sh --device
```

O con UDID explícito (útil si tienes varios dispositivos):

```bash
xcrun devicectl list devices
export DEVELOPMENT_TEAM=XXXXXXXXXX
./scripts/build-ipad.sh --device 'id=00008140-001A60890C80201E'
```

4. Si el `.app` ya está en `Apps/EfbyPostmanPad/.derivedData` y quieres **solo instalar** en el iPad conectado:

```bash
./scripts/install-ipad-app.sh "/ruta/completa/EfbyPostmanPad.app"
```

La forma más directa para instalar en un **iPad físico** es: **`EfbyPostmanPad.xcodeproj`**, destino **tu iPad**, **Team**, **Run (▶)**.

Si ves *iOS … is not installed* o *no destination* en simulador, instala el runtime en **Xcode → Settings → Platforms**.

## Contenido de la app

- `PadShellView`: `NavigationSplitView`, inicio, lista de colecciones/entornos, detalle de colección (solo lectura por ahora), datos del workspace vía `MainViewModel`.

## Notas

- Los recursos BPMN/CodeEditor del Mac no están empaquetados aquí (SwiftPM exige rutas dentro de este paquete). Cuando haga falta el editor web en iPad, añade un `Resources/` local o copia controlada desde el repo.
- Git / Shared Storage en dispositivo: limitaciones de sandbox y de `git` respecto al Mac.
