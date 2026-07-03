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

| ID | Caso de prueba | Estado |
|----|----------------|--------|
| REQ-GIT-001 | `pullAuthFailureReturnsStructuredError` | Automatizado |
| REQ-GIT-002 | `statusReportsModifiedFiles` | Automatizado |
| REQ-GIT-003 | `loadsCollectionsFromManagedDirectory` | Automatizado |

Matriz completa: [traceability-matrix.md](../../../docs/traceability-matrix.md)
