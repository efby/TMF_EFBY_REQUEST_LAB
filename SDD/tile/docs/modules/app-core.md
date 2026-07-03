# Módulo AppCore

Biblioteca principal sin dependencia de la UI gráfica: dominio, servicios y coordinación reutilizables por la aplicación de escritorio y por el ejecutable de depuración de flujos.

Para contratos detallados (persistencia, runtime HTTP/scripts, flujos, integraciones), usa la carpeta [reference/](../reference/) del tile.

## Comenzar desde cero

1. Abre el manifiesto del paquete en la raíz del repo y confirma el nombre del **target** de la biblioteca de núcleo.
2. Añade o modifica tipos en la capa de **dominio** solo si representan reglas de negocio estables (peticiones, respuestas, workspace, flujos).
3. Implementa comportamiento nuevo en la capa de **aplicación** como servicios con dependencias explícitas (red, scripts, persistencia).
4. Expón a la UI solo lo necesario a través del **coordinador de pantalla** (view model), manteniendo efectos secundarios acotados.
5. Tras cada cambio, ejecuta `swift test` y amplía pruebas que describan el contrato del servicio o del modelo.
6. Actualiza la spec correspondiente bajo `SDD/tile/specs/` si cambias un contrato observable por el usuario o por otros módulos.

## Dominio

- Modelos de **HTTP**: petición, cabeceras, cuerpo, respuesta y metadatos de transporte.
- Modelos de **flujo**: nodos, transiciones y datos necesarios para ejecutar el grafo.
- Modelos de **workspace**: colecciones, carpetas, entornos y agregación del estado guardado.
- Tipos auxiliares para **presentación de logs de flujo** (incluido contenido rico como imágenes en línea).

## Aplicación (servicios por área)

| Área | Responsabilidad |
|------|-----------------|
| Ejecución HTTP | Orquestar variables, scripts previos, red y materialización del resultado. |
| WebSocket | Conexión, mensajes, ping/keep-alive y transcript por pestaña. |
| Flujo BPMN | Validar, interpretar y ejecutar el grafo; condiciones de gateway; logs. |
| Scripts | Motor de ejecución de scripts de petición y utilidades del editor (sugerencias, formato, símbolos). |
| Variables | Sustitución y precedencia entre capas (global, colección, entorno, local). |
| Postman | Lectura/escritura de colecciones y entornos en formato compatible. |
| OpenAPI | Importación desde descripciones OpenAPI hacia el modelo interno. |
| Persistencia y Git | Carga/guardado del workspace y operaciones de repositorio remoto. |

## Presentación (en el núcleo)

- **Coordinador principal**: pestañas, workspace activo, envío de peticiones, ejecución de flujos, mensajes de error e información para paneles.

## Soporte

- Errores unificados traducibles a mensajes de usuario en la capa de interfaz.
