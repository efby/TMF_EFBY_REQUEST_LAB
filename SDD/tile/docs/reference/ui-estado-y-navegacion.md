# Interfaz: estado, pestañas y ciclo de vida de la app

Especificación para implementar la **capa SwiftUI** y su coordinador sin duplicar lógica de negocio.

## Coordinador principal (view model)

Responsabilidades mínimas:

- Mantener el **workspace** observable (colecciones, entornos, flujos, mensajes de error/información).
- Gestionar **pestañas de petición**: crear, duplicar, seleccionar, cerrar; cada pestaña posee estado de envío, respuesta, consola y WebSocket.
- Delegar **envío HTTP**, **WebSocket** y **ejecución de flujos** a servicios del núcleo.
- Orquestar **persistencia** (guardar/cargar) a través del repositorio del workspace.
- Exponer banderas para **resaltar nodos** del diagrama durante la ejecución de un flujo.

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
