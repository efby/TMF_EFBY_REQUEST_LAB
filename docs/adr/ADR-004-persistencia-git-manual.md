# ADR-004: Persistencia JSON local + Git manual

## Estado

Aceptado

## Contexto

El equipo necesita versionar colecciones API junto a código en Bitbucket/GitHub sin depender de sync cloud. Cada desarrollador tiene configuración local (historial, pestañas abiertas) que no debe mezclarse con el repo compartido.

## Decisión

**Dos capas de persistencia:**

1. **Local** — `~/Library/Application Support/EFBYPostman/workspace.json` con `schemaVersion` y migraciones automáticas (`WorkspaceRepository`).
2. **Compartida** — directorio `collections/` dentro de un repo Git clonado localmente; sync **manual** Pull/Push (`GitRepositoryService` + `SharedCollectionsRepository`).

No hay servidor backend ni sync automático.

## Consecuencias

### Positivas

- Control total del equipo sobre datos compartidos.
- Funciona offline.
- Compatible con flujos Git existentes (PRs, code review de colecciones).

### Negativas

- Usuario debe ejecutar Pull/Push explícitamente.
- Conflictos Git resueltos fuera de la app (manual).
- Sin colaboración en tiempo real.

## Verificación

Specs `persistencia-workspace` y `git-workspace` + tests de repositorios.
