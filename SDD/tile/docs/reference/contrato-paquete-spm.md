# Contrato del paquete (SPM) y layout

Referencia para reconstruir o auditar el proyecto **desde cero** sin abrir aún el código fuente.

## Manifiesto del paquete

- **swift-tools-version**: debe coincidir con la toolchain instalada en CI y en desarrollo (línea inicial del manifiesto en la raíz del repo).
- **Plataforma**: solo **macOS**, versión mínima declarada en el manifiesto (hoy macOS 14).
- **Modo de lenguaje**: Swift **v6** (concurrencia estricta) cuando el manifiesto lo fije así.

## Productos que debe exponer el paquete

| Producto | Tipo | Rol |
|----------|------|-----|
| Biblioteca de núcleo | library | Dominio, servicios de red, flujos, importación, persistencia; sin SwiftUI. |
| App de escritorio | executable | Interfaz principal del laboratorio de peticiones; depende del núcleo. |
| Depurador de flujos | executable | Herramienta de línea de comandos o mínima UI para ejecutar flujos sin la app completa; depende del núcleo. |

## Targets y dependencias

- El ejecutable de la **app** y el de **depuración de flujos** declaran dependencia del **target de la biblioteca de núcleo**.
- El target de **pruebas** declara dependencia del núcleo y agrupa pruebas automatizadas del dominio y servicios.

## Recursos embebidos (app)

- El ejecutable de la app declara recursos copiados para el **editor BPMN** y el **editor de código** (activos estáticos, no generados en build salvo que el pipeline lo añada).

## Comandos mínimos de verificación

```bash
swift build
swift test
swift build -c release --product EfbyRequestLabs
```

Sustituye el nombre del producto de la app si el manifiesto usa otro identificador.

## Convención de carpetas (alto nivel)

- Código del **núcleo** en un único target de biblioteca bajo la raíz de fuentes del paquete.
- Código de la **app** bajo otra carpeta de fuentes del ejecutable, con recursos hermanos.
- Código del **depurador de flujos** en su propia carpeta de fuentes.
- **Pruebas** en carpeta de tests del paquete, un target de test por convención del repo.
