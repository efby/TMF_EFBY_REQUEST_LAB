# Flujos de workspace (vocabulario BPMN)

Especificación del **subconjunto de BPMN** que el motor debe entender para ejecutar flujos guardados en el workspace.

## Tipos de nodo soportados (vocabulario)

El modelo de dominio distingue al menos:

- **Evento de inicio**: punto de entrada del proceso.
- **Evento de fin**: conclusión normal de una rama.
- **Evento de fin terminate**: fin del proceso completo y cancelación de ramas paralelas pendientes.
- **Tarea**: paso ejecutable; en este producto se **enlaza** a una petición del workspace (HTTP o WebSocket según el transporte) por UUID o por remapeo por nombre de colección + petición.
- **Evento temporizador**: espera u hora programada según la semántica implementada.
- **Gateway exclusivo**: una sola rama saliente según condición.
- **Gateway paralelo**: bifurcación o unión paralela.
- **No soportado**: marcador para elementos del diagrama que aún no ejecutan (deben manejarse con error claro o ignorado documentado).

## Enlace tarea → petición

- Cada tarea guarda referencias para **reconciliar** la petición si el UUID cambia (import en otra máquina): nombre de colección, nombre de petición, tipo de transporte opcional para desambiguar homónimos.
- Validación previa a ejecución: grafo sin nodos huérfanos críticos, gateways coherentes, tareas con petición resuelta.

## Ejecución

- El motor mantiene **estado de instancia** (tokens, ramas activas, timers programados).
- Los **logs** de ejecución deben ser consumibles por la UI del diagrama (incluido contenido enriquecido como imágenes en línea si el producto lo define).
- Errores de petición dentro de una tarea deben propagarse según política: abortar flujo, seguir a rama de error o marcar incidente en log.

## Editor

- El editor embebido produce o consume la **representación almacenada** del flujo en el workspace; la capa de parseo traduce al modelo de ejecución interno.

## Pruebas mínimas desde cero

1. Flujo lineal inicio → tarea HTTP → fin.
2. Flujo con **gateway exclusivo** y dos ramas con condiciones distintas.
3. Flujo con **paralelo** y sincronización.
4. Tarea con petición remapeada por nombre tras cambiar IDs de importación.
