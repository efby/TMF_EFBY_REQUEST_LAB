# Documentación — EFBY Request Lab

Índice de la documentación del proyecto.

## Visión y diseño

| Documento | Contenido |
|-----------|-----------|
| [vision-alcance.md](vision-alcance.md) | Problema, solución, usuarios y alcance |
| [arquitectura.md](arquitectura.md) | Capas SPM, coordinadores, persistencia |
| [requisitos-no-funcionales.md](requisitos-no-funcionales.md) | Compatibilidad, estabilidad, seguridad, UX |

## Metodología

| Documento | Contenido |
|-----------|-----------|
| [metodologia-sdd.md](metodologia-sdd.md) | Specification-Driven Development y las 10 specs |
| [metodologia-tdd.md](metodologia-tdd.md) | Test-Driven Development, suites y CI |
| [traceability-matrix.md](traceability-matrix.md) | Requisito → spec → test (36 REQ-*) |
| [plan-pruebas.md](plan-pruebas.md) | Tipos de prueba y checklist manual |

## Operación

| Documento | Contenido |
|-----------|-----------|
| [despliegue.md](despliegue.md) | Build, DMG, releases y firma |

## Decisiones de arquitectura (ADR)

| ADR | Tema |
|-----|------|
| [ADR-001](adr/ADR-001-spm-appcore-compartido.md) | SPM y módulos compartidos macOS/iPad |
| [ADR-002](adr/ADR-002-mvvm-vs-clean-architecture.md) | Clean Architecture con presentación MVVM |
| [ADR-003](adr/ADR-003-javascriptcore-runtime.md) | JavaScriptCore para runtime `pm.*` |
| [ADR-004](adr/ADR-004-persistencia-git-manual.md) | Persistencia local + sync Git manual |
| [ADR-005](adr/ADR-005-bpmn-orquestacion.md) | BPMN para orquestación de flujos API |

## Especificaciones SDD

Las specs funcionales viven en `SDD/tile/specs/*.spec.md`. Cada una incluye una sección **Trazabilidad** con IDs `REQ-*` enlazados a la [matriz de trazabilidad](traceability-matrix.md).

## Presentación

| Recurso | Ubicación |
|---------|-----------|
| Slides (PDF, 18 diapositivas) | [presentacion/EFBY-Request-Lab-Slides.pdf](presentacion/EFBY-Request-Lab-Slides.pdf) |
| Fuente HTML (editable) | [presentacion/slides.html](presentacion/slides.html) |

## Enlaces útiles

| Recurso | URL |
|---------|-----|
| Repositorio | https://github.com/efby/TMF_EFBY_REQUEST_LAB |
| Última release (DMG) | https://github.com/efby/TMF_EFBY_REQUEST_LAB/releases/latest |
| CI | https://github.com/efby/TMF_EFBY_REQUEST_LAB/actions |
