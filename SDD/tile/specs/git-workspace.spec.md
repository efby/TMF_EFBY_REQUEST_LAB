---
name: Integración Git del workspace
description: Operaciones de repositorio y recuperación asociadas al flujo de trabajo del laboratorio.
targets:
  - ambito:paquete-efby / capa:nucleo / area:git-workspace
---

## Comenzar desde cero

1. Lista las operaciones soportadas (clonar, pull, push si aplica) y los **tipos de error** que la UI debe poder mostrar (auth, conflicto, red).
2. Aísla las llamadas al binario de Git o a la API que uses detrás de una fachada con inyección de dependencias para tests.
3. Define **prompts de credenciales** como modelos de datos puros que el coordinador de pantalla presenta al usuario.
4. Implementa recuperación ante pull con cambios locales: mensaje claro y rutas afectadas sin exponer secretos.
5. Prueba con repositorios temporales creados en el directorio de pruebas del sistema o con mocks de la fachada.

## Operaciones

- Clonar y actualizar deben devolver errores estructurados que el coordinador pueda traducir en diálogos o banners.
  - **Verificación**: simulación de fallos de autenticación y de red con aserciones sobre el modelo de error entregado a la capa de presentación.

## Trazabilidad

### Credenciales y recuperación

- `origin` y sus URLs de push no guardan usuario/contraseña HTTP. Las URLs antiguas se limpian antes de realizar operaciones de red.
- Las credenciales se envían por entrada estándar al helper `osxkeychain`, acotadas a URL/ruta/usuario. Se comprueba su recuperación; si falla el llavero, se informa sin restaurar una URL con contraseña.
- El helper se configura por URL, incluyendo usuario y `useHttpPath`, sin almacenes en texto plano. Las URLs con usuario sin contraseña se limpian; puede ser necesario volver a introducir la autenticación.
- La salida visible y los errores se redactan antes de publicarse, incluso si un secreto llega dividido en fragmentos. Los datos estructurados internos (rutas y referencias) conservan su contenido.
- Los directorios `.*.efby-backup` y `.*.efby-staging` no se agregan a commits ni se eliminan como cambios locales ajenos.
- `GitRepositorySecurityTests` utiliza Git local y un helper simulado: comprueba configuración, entrada estándar, migración de fetch/push, errores del llavero, rutas codificadas, redacción y conservación de respaldos. La autenticación con el llavero real requiere comprobación manual en macOS.

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-GIT-001 | `pullAuthFailureReturnsStructuredError` | Automatizado |
| REQ-GIT-002 | `statusReportsModifiedFiles` | Automatizado |
| REQ-GIT-003 | `loadsCollectionsFromManagedDirectory` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
