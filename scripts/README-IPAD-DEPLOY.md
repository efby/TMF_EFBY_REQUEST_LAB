# Compilar e instalar EfbyPostmanPad en iPad (o iPhone)

Flujo recomendado en una sola orden: **`./scripts/install-ipad.sh`** desde la raíz del repo.

**Git remoto:** la app en **iPhone o iPad no hace `git push`** (ni commit al remoto); el envío al repositorio Git es solo en la **app para Mac**.

## Firma y distribución App Store / TestFlight (iPhone e iPad)

**Una sola app:** el target **EfbyPostmanPad** es universal (`TARGETED_DEVICE_FAMILY` iPhone + iPad). Un **.ipa** exportado sirve para ambos; no hay dos notarizaciones separadas.

**Notarización (`notarytool`)** en Apple es **solo para macOS** (`.app` fuera de la Mac App Store, `.dmg`, `.pkg`, etc.). En **iOS/iPadOS** no se «notariza» así: se **firma** el IPA y, si publicas en la tienda, lo subes a **App Store Connect**; Apple aplica sus comprobaciones al recibir el binario (y TestFlight/App Store siguen su flujo).

### Exportar IPA firmado (línea de comandos)

Desde la raíz del repo (necesitas Xcode con la cuenta de desarrollador y equipo configurados, como en Signing & Capabilities):

```bash
chmod +x ./scripts/export-ios-appstore.sh   # una vez
./scripts/export-ios-appstore.sh
```

Opcional: limpiar antes de archivar.

```bash
./scripts/export-ios-appstore.sh --clean
```

Otro método de exportación (p. ej. instalación **ad hoc** en dispositivos registrados):

```bash
EXPORT_METHOD=ad-hoc ./scripts/export-ios-appstore.sh
```

Variables útiles:

| Variable | Valor por defecto | Uso |
|----------|-------------------|-----|
| `DEVELOPMENT_TEAM` | `FYU5QTGXLB` | Team ID de Apple Developer |
| `EXPORT_METHOD` | `app-store` | `app-store` · `ad-hoc` · `development` · `enterprise` |

Salida habitual:

- `Distribution/EfbyPostmanPad.xcarchive`
- `Distribution/EfbyPostmanPad-export/*.ipa` (nombre interno que genera Xcode)
- **`Distribution/EfbyPostmanPad.ipa`** — copia estable del último export (sobrescribe la anterior). Sirve para **AirDrop**, **iCloud Drive**, **correo** o subirla a un almacén compartido. Puedes cambiar la ruta con `IPA_SHARE_PATH=/ruta/personalizada.ipa`.

**Subida a Apple:** **Transporter** (Mac) o **Xcode → Window → Organizer** → *Distribute App*.

### Automatizar distribución (TestFlight / App Store Connect)

Puedes **automatizar la subida del IPA** desde la terminal con **`xcrun altool`** (viene con Xcode). Sigue siendo tu cuenta y tus claves; el script no las guarda en el repo.

1. **Crea una clave API** en [App Store Connect → Integraciones → Claves API](https://appstoreconnect.apple.com/access/integrations/api) (rol *Developer* o *App Manager* basta para subir builds). Descarga el `.p8` una vez y guárdalo fuera del repo (p. ej. `~/private_keys/AuthKey_XXXXXXXXXX.p8`).

2. **Sube solo el IPA** (el que ya generaste en `Distribution/EfbyPostmanPad.ipa` o el que indiques):

```bash
export ASC_API_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export ASC_PRIVATE_KEYS_DIR="$HOME/private_keys"   # carpeta que contiene AuthKey_<ASC_API_KEY_ID>.p8

./scripts/upload-ipa-appstore-connect.sh
# o: ./scripts/upload-ipa-appstore-connect.sh /ruta/otro.ipa
```

3. **Compilar + subir en un paso:**

```bash
export ASC_API_KEY_ID=... ASC_ISSUER_ID=... ASC_PRIVATE_KEYS_DIR=...
./scripts/distribute-ios-testflight.sh
# opcional: ./scripts/distribute-ios-testflight.sh --clean
```

**Alternativa sin clave API:** define `ASC_APPLE_ID` y `ASC_APP_PASSWORD` (contraseña de app de [appleid.apple.com](https://appleid.apple.com)) o `ASC_KEYCHAIN_PASSWORD_ITEM` + contraseña guardada con `xcrun altool --store-password-in-keychain-item` (ver comentarios en `scripts/upload-ipa-appstore-connect.sh`).

**Qué sigue siendo manual en Apple:** crear la app en App Store Connect si aún no existe, rellenar ficha de la tienda, **grupos TestFlight**, enviar a revisión, etc. Lo que automatizamos es **build IPA + upload** al portal (igual que Transporter).

### Compartir el `.ipa` con otras personas (qué permite Apple)

| `EXPORT_METHOD` | ¿Compartir el archivo? | Quién puede instalar |
|-----------------|-------------------------|------------------------|
| **`app-store`** | Sí, puedes enviar el `.ipa` | Solo tú / tu equipo suelen usarlo para **subirlo** a App Store Connect. **No** instala en un iPhone ajeno al abrir el archivo. Para testers externos usa **TestFlight** (subes el build y Apple envía la invitación). |
| **`ad-hoc`** o **`development`** | Sí (p. ej. `EfbyPostmanPad.ipa` por AirDrop) | Solo **iPhone/iPad cuyo UDID esté** en el perfil de ese build (registrados en [Apple Developer → Devices](https://developer.apple.com/account/resources/devices/list)). |
| **`enterprise`** | Según política interna | Dispositivos de la organización con certificado enterprise. |

Resumen: el script ya deja el IPA listo para **compartir el archivo** en `Distribution/EfbyPostmanPad.ipa`. Para **cualquier dispositivo** sin listar UDIDs, el camino habitual es **TestFlight** o publicación en la **App Store**, no el IPA suelto.

### ¿Puedo compartir el IPA **antes** de TestFlight y que **sí** instale?

**Sí, pero no con el IPA “de tienda”.** El que genera `./scripts/export-ios-appstore.sh` por defecto (`app-store-connect`) **no** está hecho para que un amigo lo abra y lo instale: da el error de integridad.

Para que el `.ipa` **funcione** al compartirlo (AirDrop, iCloud, correo → instalar en el dispositivo):

| Objetivo | Qué hacer |
|----------|-----------|
| **Pocas personas / dispositivos conocidos** (UDID) | Registra cada **UDID** en [Apple Developer → Devices](https://developer.apple.com/account/resources/devices/list). Luego: `./scripts/export-ios-shareable-ipa.sh` (export **ad-hoc**). Ese `Distribution/EfbyPostmanPad.ipa` puede instalarse en **esos** iPhone/iPad (Finder, Configurator, etc.). |
| **Solo tus dispositivos** ya usados con Xcode en el mismo team | `./scripts/export-ios-shareable-ipa.sh --development` (equivalente a `--device-install` del otro script, pero dejando claro el uso “compartir en el equipo”). |
| **Cualquiera sin pedir UDID** | No hay IPA mágico: usa **TestFlight** (subes el build a App Store Connect y Apple distribuye la instalación). |

Atajo en el repo:

```bash
./scripts/export-ios-shareable-ipa.sh
# o, para perfil development:
./scripts/export-ios-shareable-ipa.sh --development
```

### App macOS «EFBY IPA» (lanzar el script con interfaz)

En **`Apps/EfbyShareIPALauncher/`** hay un proyecto Xcode **`EfbyShareIPALauncher.xcodeproj`**: app de escritorio que pide la ruta al repo (o usa la guardada), ejecuta **`export-ios-shareable-ipa.sh`** y muestra la salida. Abre el proyecto en Xcode y pulsa **Run (▶)**.

### «No se pudo instalar… no se pudo validar su integridad» (iPhone / iPad)

Ese mensaje de **iOS** casi siempre significa: estás intentando **instalar directamente** (AirDrop, Finder, “toca el .ipa”) un paquete que **no está firmado para esa forma de instalación**.

| Qué IPA usaste | Qué ocurre |
|----------------|-------------|
| Export **`app-store-connect`** / **`app-store`** (el predeterminado del script) | Pensado para **subirlo** a App Store Connect → **TestFlight** o App Store. **No** es un IPA de sideload; el sistema rechaza la “integridad” al instalarlo a mano. |
| **`development`** o **`ad-hoc`** | Solo instala si el **UDID del dispositivo** está en el perfil de aprovisionamiento de ese build (y la firma es válida). |

**Qué hacer según tu objetivo**

1. **Distribuir a testers / clientes sin cable**  
   Sube el IPA con **Transporter** (o Organizer), crea el build en **App Store Connect** y usa **TestFlight** (invitación por correo). No intentes que instalen el `.ipa` crudo.

2. **Instalar en *tus* iPhone/iPad del mismo equipo de desarrollo** (dispositivos ya dados de alta en Xcode / [Devices](https://developer.apple.com/account/resources/devices/list))  
   Genera un IPA **development** desde el repo:

   ```bash
   ./scripts/export-ios-appstore.sh --device-install
   ```

   Luego instala ese `Distribution/EfbyPostmanPad.ipa` con **Finder** (arrastrar al dispositivo), **Apple Configurator** o el flujo que ya uses para `.ipa` de desarrollo.

3. **Varios dispositivos concretos sin TestFlight**  
   Registra sus **UDID** en el portal de desarrollador y exporta con `EXPORT_METHOD=ad-hoc` (perfil que incluya esos UDID).

### macOS (app de escritorio)

Para el **.dmg** de la app Mac del repo, la firma **Developer ID** y la **notarización** siguen el flujo de **`Tools/build_dmg.sh --sign --notarize`** (distinto del IPA iOS).

## Importante: abre el proyecto del iPad (no solo el Swift Package)

Si en Xcode abres la **carpeta raíz del repo** o solo **`Package.swift`**, el esquema suele ser **`EfbyRequestLabs-Package`** (ejecutable del paquete). En simulador eso puede lanzar un binario **sin** `.app` real: entonces el sistema no encuentra `CFBundleIdentifier` y verás errores como **`missing bundleID for main bundle`** apuntando a la carpeta `…/Debug-iphonesimulator` (no a `EfbyPostmanPad.app`).

Si el fallo menciona una ruta **`…/Debug-iphoneos/Algo` sin `.app`** (p. ej. un ejecutable SwiftPM antiguo), Xcode está intentando instalar **un binario suelto**, no **`EfbyPostmanPad.app`**. Eso produce **CoreDeviceError 3002** y **LaunchExecutableValidationErrorDomain** (no es una app firmada para dispositivo).

**Solución:** abre **`Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj`** (no abras solo la carpeta como paquete Swift si Xcode te creaba un esquema paralelo). Esquema **`EfbyPostmanPad`**, destino tu iPad, **Run (▶)**. En el selector de esquema debe figurar el **icono de app** junto a `EfbyPostmanPad`, no un destino “executable” suelto. Si ves un esquema raro residual, **Product → Clean Build Folder** y cierra/reabre el `.xcodeproj`.

## Requisitos

- **Xcode** instalado (herramientas de línea de comandos con `xcrun`, `xcodebuild`, `devicectl`).
- iPad/iPhone **conectado por cable o en red** con estado **connected** en `devicectl`.
- En el dispositivo: **Confiar en este ordenador**, **Modo desarrollador** activado si aplica.
- **Cuenta de desarrollador** con equipo configurado; el script usa por defecto `DEVELOPMENT_TEAM=FYU5QTGXLB` (mismo team que otros scripts del repo). Para otro team:  
  `export DEVELOPMENT_TEAM=TU_TEAM_ID`

## Proceso completo (compilar + instalar + abrir)

Desde la raíz `EFBY_POSTMAN`:

```bash
./scripts/install-ipad.sh
```

Opcional: si tienes varios dispositivos conectados, pasa el **UUID de Core Device** o el **UDID hardware** que quieras:

```bash
./scripts/install-ipad.sh D4014F82-27C6-5A0E-A77D-233938D0FA9E
```

### Qué hace el script

1. Lista dispositivos con `xcrun devicectl list devices` y elige el primero **connected** (o el que coincida con el argumento).
2. Resuelve dos identificadores:
   - **Core Device ID** → `devicectl device install app` y `process launch`.
   - **UDID hardware** → destino `xcodebuild` (`platform=iOS,id=…`).
3. **`xcodebuild`** sobre `Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj`, esquema **EfbyPostmanPad**, **Release**, **iphoneos**, `-derivedDataPath` en `Apps/EfbyPostmanPad/.derivedData`, con **firma automática**, `-allowProvisioningUpdates` y `-allowProvisioningDeviceRegistration`.
4. Instala el `.app` generado en `…/Release-iphoneos/EfbyPostmanPad.app`.
5. Lanza el bundle **`efbypostmanpad.EfbyPostmanPad`** (nombre visible en pantalla: **EFBY Request Lab**).

### Solo compilar (sin instalar)

```bash
./scripts/build-ipad.sh --device
```

Genera el `.app` en DerivedData del proyecto Pad; para instalarlo a mano necesitarías `devicectl device install app` apuntando a ese `.app`, o usar de nuevo **`install-ipad.sh`**, que ya compila e instala.

### Ayuda y listado de dispositivos

```bash
./scripts/install-ipad.sh --help
xcrun devicectl list devices
```

## Si falla la firma o el destino

- Abre `Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj` en Xcode, selecciona el target **EfbyPostmanPad** → **Signing & Capabilities** → **Team**.
- Primera vez en un dispositivo: a veces conviene un **Run (▶)** desde Xcode con el iPad como destino para registrar el dispositivo y perfiles.

## Logs en el iPad (desarrollo)

En iOS **no hay una pantalla del sistema** que muestre el log técnico de tu app (tipo “consola del iPad”). Los mensajes van al **Unified Logging** y solo se ven bien con el **Mac** conectado al iPad.

### Opción A — Xcode (la más simple)

1. Conecta el iPad por **USB** (o en red si ya lo usas así con Xcode).
2. Abre **`Apps/EfbyPostmanPad/EfbyPostmanPad.xcodeproj`**.
3. Arriba elige destino **tu iPad** (no simulador).
4. **Product → Run** (▶) para instalar y arrancar desde Xcode.
5. Abre el área de depuración: **View → Debug Area → Activate Console** (o el panel inferior).
6. Reproduce el fallo (p. ej. descarga Bitbucket). Las trazas aparecen ahí en tiempo real.

Para filtrar: en el cuadro de búsqueda del panel de consola prueba `Bitbucket` o `EFBY`.

### Opción B — Consola.app (Mac, iPad conectado)

1. En el Mac abre **Consola** (`Console.app`, en `/Aplicaciones/Utilidades/`).
2. En la barra lateral, bajo **Dispositivos**, selecciona **tu iPad** (debe estar conectado y confiado).
3. Pulsa **Iniciar** / **Start** en la barra de herramientas si el streaming no está activo.
4. En el campo de **búsqueda** arriba a la derecha escribe, por ejemplo:
   - `subsystem:EFBY.AppCore`  
   - o `BitbucketPadFlow` / `BitbucketImport` / `BitbucketREST`  
5. Usa la app en el iPad; las líneas aparecerán en el Mac.

Esta app también escribe ahí (subsystem **`EFBY.AppCore`**, categorías **`BitbucketPadFlow`**, **`BitbucketImport`** y **`BitbucketREST`**). **No** se registran contraseñas (solo longitud del app password y si hay usuario).

### Qué copiar si pides ayuda

Exporta o copia un **fragmento** de líneas alrededor del error (sin usuario ni app password). El mensaje naranja dentro de la app (`errorMessage`) también ayuda.

## Si `devicectl` muestra «No provider was found» (CoreDeviceError 1002)

El **build** puede haber terminado bien y aun así fallar la **instalación o el launch** por el servicio Core Device. Prueba: desconectar y volver a conectar el cable, desbloquear el iPad, en Xcode **Window → Devices and Simulators** y comprobar que el dispositivo aparece listo; o ejecutar de nuevo `./scripts/install-ipad.sh` cuando el iPad esté estable como **connected**.
