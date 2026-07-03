# Modelo de datos del workspace y persistencia

Especificación conceptual para implementar el **estado global del laboratorio** y cómo debe vivir en disco.

## Agregado raíz: estado del workspace

El documento persistido representa todo lo necesario para reabrir la sesión de trabajo:

- **Versión de esquema** entera (`schemaVersion`): número monotónico que incrementa cuando cambia el formato JSON; el cargador debe **rechazar** archivos de versiones futuras y **migrar** las anteriores hacia la versión actual.
- **Nombre de workspace activo** y metadatos para múltiples espacios de trabajo si el producto los soporta.
- **Colecciones** como árbol de nodos (carpetas y peticiones).
- **Entornos** (perfiles con variables clave-valor, habilitación).
- **Borradores o pestañas** persistidas si el producto guarda sesión de edición.
- **Flujos** del workspace (definición BPMN ligada al workspace, tareas enlazadas a peticiones).
- **Rutas o referencias** a repositorios compartidos o carpetas externas, si aplica.

## Nodos de colección

Cada nodo del árbol tiene al menos:

- Identificador estable (**UUID**).
- Nombre visible y tipo (**carpeta** vs **petición**).
- Para peticiones: modelo de transporte (HTTP vs WebSocket según el dominio), cabeceras, cuerpo, scripts asociados, autenticación.
- Hijos anidados en carpetas.
- Respuestas guardadas opcionales y descripciones.

## Variables

- Entidad **variable**: clave, valor cadena, habilitada.
- Perfil de **entorno**: conjunto de variables con nombre de perfil.
- Variables de **colección** y **globales** según el modelo del workspace.
- Variables **locales** a la ejecución de una petición o pestaña.

## Persistencia en disco

- Formato: **JSON** con fechas en **ISO8601** y claves ordenadas/pretty según política del producto para diffs legibles.
- Ubicación por defecto: subdirectorio bajo **Application Support** del usuario, nombre de app acordado, archivo principal del workspace (por convención del producto).
- Escritura **atómica** (escribir temporal y reemplazar) para no corromper el archivo ante un corte de energía.
- Carga: si no existe archivo, devolver un **estado inicial** (workspace vacío o plantilla) coherente con la UX.

## Migraciones

- Toda versión nueva del esquema debe incluir función de migración desde la versión inmediata anterior (o saltos acumulados documentados).
- Pruebas obligatorias: fixture JSON de cada versión antigua relevante → carga → aserciones sobre el modelo migrado.

## Seguridad del archivo

- El JSON puede contener **tokens** si el usuario los guardó en variables; véase [seguridad-encriptacion.md](../../rules/seguridad-encriptacion.md) (copias de seguridad, cifrado opcional, permisos de archivo).
