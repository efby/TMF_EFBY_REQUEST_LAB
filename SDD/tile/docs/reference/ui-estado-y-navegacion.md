# Interfaz: estado, pestañas y ciclo de vida de la app

Especificación para implementar la **capa SwiftUI** y su coordinador sin duplicar lógica de negocio.

## Coordinador principal (view model)

Responsabilidades mínimas:

- Mantener el **workspace** observable (colecciones, entornos, flujos, mensajes de error/información).
- Gestionar **pestañas de petición**: crear, duplicar, seleccionar, cerrar; cada pestaña posee estado de envío, respuesta, consola y WebSocket.
- Delegar **envío HTTP**, **WebSocket** y **ejecución de flujos** a servicios del núcleo.
- Orquestar **persistencia** (guardar/cargar) a través del repositorio del workspace.
- Exponer banderas para **resaltar nodos** del diagrama durante la ejecución de un flujo.

## Organización de la implementación

- `Sources/EfbyPresentation/MainViewModel.swift` concentra el estado observable, las dependencias y la inicialización. Las acciones se agrupan en extensiones `@MainActor` dentro de `MainViewModel/`: catálogo, entornos, flujos, Git/Bitbucket, peticiones/pestañas, WebSocket y persistencia del workspace.
- Las extensiones trabajan sobre la misma instancia y delegan en los coordinadores existentes. La comparación semántica de borradores pertenece a `RequestTabsCoordinator`.
- `Sources/EFBYPostman/Views/RootView.swift` compone la pantalla. Los componentes se ubican en `Views/Chrome/`, `Sidebar/`, `Workspace/`, `Request/`, `Response/` y `Sheets/`; los controles comunes y el tema, en `Common/` y `Theme/`.
- Al mover o extraer componentes, conservar la propiedad del estado, la identidad de las vistas, los enlaces, el orden de modificadores y las acciones. Esta separación no cambia el contrato observable ni el ciclo de vida de las tareas.

## Estado de pestaña

- Identificador estable de pestaña.
- Referencia opcional al nodo de colección de origen (para “guardar en colección” o seguimiento).
- Tareas `async` cancelables asociadas a envío y a WebSocket; al cerrar pestaña o destruir estado, **cancelar** y limpiar.

## Ciclo de vida de la aplicación macOS

- Al cerrar la **última ventana**, el comportamiento típico es terminar la app; el **delegado de aplicación** debe permitir **volcar estado** (guardar workspace, cerrar conexiones) de forma asíncrona antes de responder “terminar ahora” al sistema.
- Atajos de menú: nueva petición, duplicar, enviar — conectados a métodos del coordinador.

## Web y editores embebidos

- **Editor BPMN**: vista nativa o WebView que comunica cambios al modelo de flujo del workspace.
- **Editor de scripts**: autocompletado y formato enlazados al contrato de [runtime-peticiones-scripts.md](runtime-peticiones-scripts.md).

## Principios

- La UI **no** implementa resolución de variables ni TLS: solo dispara comandos del núcleo y refleja resultados.
- Toda mutación del workspace tras una acción de usuario debe tener un **camino trazable** (método del coordinador o comando explícito).

## Verificación de interfaz macOS

`Tests/UITests/RequestLabUITests.swift` verifica navegación y contenido de paneles, edición y cierre de pestañas, restauración de borradores al cambiar workspace y envío/cancelación mediante controles reales. Incluye cambio de workspace durante una petición pendiente. `Tools/test_ui.sh` ejecuta estos casos con workspaces temporales y un servidor HTTP local controlado; ver [plan de pruebas](../../../../docs/plan-pruebas.md).
