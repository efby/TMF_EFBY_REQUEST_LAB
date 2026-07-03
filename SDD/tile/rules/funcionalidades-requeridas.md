# Funcionalidades necesarias del sistema

Lista orientativa al **alcance del producto**. Los agentes deben conservar o mejorar estas capacidades salvo instrucción explícita de deprecación.

## Workspace y organización

- Cargar y guardar un **workspace** con colecciones, carpetas, peticiones y entornos; el formato persistido lleva **versión de esquema** entera y debe **migrarse** al abrir versiones antiguas (véase referencia de modelo y persistencia en el tile).
- Navegación por árbol de colecciones y apertura de peticiones en **pestañas**.
- Variables por capas: **global**, **colección**, **entorno** y **local** a la petición, con precedencia clara.

## Peticiones HTTP

- Edición de método, URL, cabeceras, query y cuerpo (tipos de cuerpo que el producto soporte).
- **Enviar** petición, ver respuesta, tiempo, tamaño y cuerpo crudo o formateado según el tipo.
- **Scripts de pre-request** y runtime de utilidades del editor (autocompletado, formato, símbolos) alineados con el contrato documentado en specs.
- **Cifrado en scripts**: API **`pm.crypto`** con **RSA-OAEP-SHA256** (clave pública PEM o certificado) y **AES** nativo (CBC/ECB sin padding en borde); alias **`encryptRsa`**; documentación íntegra en `tile/docs/reference/pm-api-javascript-completa.md`.

## WebSocket

- Conexión, envío y recepción de mensajes, estado de conexión y **ciclo de vida** limpio al cerrar pestañas (sin tareas huérfanas).

## Flujos (BPMN / workspace)

- Editor y ejecución de **flujos** sobre el workspace: validación, gateways, paralelismo según el alcance implementado.
- Logs de ejecución visibles y coherencia entre diagrama y estado en ejecución.

## Interoperabilidad

- **Importación/exportación** compatible con colecciones y entornos estilo Postman.
- **OpenAPI**: importación hacia el modelo interno cuando la función esté presente en el producto.

## Git e integración

- Operaciones de **repositorio Git** acordadas por el producto (clonar, actualizar) con manejo de credenciales y errores guiados al usuario.

## Experiencia de usuario (macOS)

- Ventana principal con tamaño mínimo usable, menús de workspace (nueva petición, duplicar, enviar) y cierre ordenado con volcado de estado si el producto lo define.

## No funcional

- **Compatibilidad**: respetar versión mínima de macOS del manifiesto.
- **Estabilidad**: evitar fugas de memoria y retain cycles en tareas largas o WebSockets.
- **Seguridad**: seguir la guía de cifrado y secretos del documento hermano en `rules/`.

## Cómo usar esta lista en tareas de agente

- Para un **nuevo feature**, indica qué viñeta amplía o añade una viñeta nueva bajo la sección correcta en un mensaje de seguimiento al equipo.
- Para un **bugfix**, identifica qué viñeta regresa a cumplirse cuando el defecto se corrija.
