# Tests y especificaciones

## Comenzar desde cero

1. Ejecuta siempre `swift test` desde la **raíz del repositorio** tras cambios en el núcleo.
2. Añade pruebas en el **target de tests** que el manifiesto del paquete asocie a la biblioteca de núcleo (misma dependencia que la app para tipos públicos internos de prueba).
3. Prioriza pruebas **deterministas**: evita red real salvo tests de integración explícitos con endpoints controlados o mocks.
4. Cuando documentes un requisito en `SDD/tile/specs/`, describe el **criterio de verificación** en texto (tabla de casos, checklist manual o nombre lógico del caso de prueba) sin citar rutas de archivos de implementación.
5. Si usas Tessl con enlaces `[@test]`, apunta solo a **artefactos de prueba estables** que tu equipo acuerde (por ejemplo identificadores de suite en CI), no a rutas locales de código.
6. Antes de publicar un tile, ejecuta el lint del CLI de Tessl sobre la carpeta del tile cuando tengas la herramienta instalada.
7. **Persistencia**: guarda fixtures JSON por cada versión de esquema del workspace que siga soportándose; prueba migración y carga con archivo ausente (véase [modelo-datos-y-persistencia.md](modelo-datos-y-persistencia.md)).
8. **Red**: usa `URLProtocol` registrado, sesiones inyectadas o servidores locales ephemeral según el patrón ya usado en el proyecto; no dependas de APIs públicas inestables.

## Ubicación

Las pruebas automatizadas del paquete viven en el directorio de tests definido en el manifiesto; el comando `swift test` los descubre y ejecuta.

## Especificaciones Tessl

Los archivos bajo `SDD/tile/specs/` usan frontmatter con `name`, `description` y `targets` como **ámbitos lógicos** (etiquetas de producto o módulo), no como rutas a archivos de código.

## Mantenimiento

1. Nueva capacidad en el núcleo: añade o amplía un `.spec.md` en `SDD/tile/specs/` con requisitos claros y sección “Comenzar desde cero” si el flujo de trabajo es no obvio.
2. Añade pruebas que fallen si se rompe el contrato; mantén nombres de casos legibles en informes de CI.
3. Revisa la documentación del tile si cambia el comportamiento visible para integraciones o agentes.
