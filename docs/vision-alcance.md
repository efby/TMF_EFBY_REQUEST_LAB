# Visión y alcance

## Problema

Los equipos que desarrollan y prueban APIs dependen habitualmente de clientes cloud (Postman, Insomnia) para ejecutar peticiones, gestionar colecciones y compartir entornos. Esto implica:

- Dependencia de servicios externos y cuentas corporativas.
- Dificultad para versionar colecciones junto al código en Git sin fricción.
- Limitaciones al automatizar flujos multi-petición con lógica de negocio visual.
- Falta de un cliente nativo macOS/iPad integrado en el ecosistema Swift del equipo.

## Solución: EFBY Request Lab

Cliente API nativo (macOS + iPad) que ofrece:

- Ejecución HTTP y WebSocket con variables por capas y scripts compatibles con Postman (`pm.*`).
- Importación/exportación Postman Collection v2/v2.1 y OpenAPI 3.x JSON.
- Workspace persistido localmente con sincronización manual vía repositorio Git.
- Orquestación de flujos API mediante editor BPMN integrado.
- Runtime JavaScript parcial con cifrado RSA/AES para escenarios de laboratorio.

## Usuarios objetivo

| Perfil | Necesidad |
|--------|-----------|
| Desarrollador backend | Probar endpoints, scripts pre-request, variables de entorno |
| QA / integración | Ejecutar colecciones, flujos BPMN, validar respuestas |
| DevOps | Compartir colecciones en repo Git, pull/push manual |
| Equipo EFBY | Herramienta interna sin dependencia cloud obligatoria |

## Alcance del producto

### Incluido

- Aplicación macOS funcional (`EfbyRequestLabs`) con DMG distribuible.
- Capas SPM (`EfbyDomain` … `EfbyPresentation`) compartidas con app iPad (`EfbyPostmanPad`).
- Documentación SDD (10 specs Tessl) y documentación del proyecto en `docs/`.
- Suite de tests unitarios en `AppCoreTests` (166 tests) con CI en GitHub Actions.
- Clean Architecture (protocolos, casos de uso, coordinadores, targets SPM).

### Excluido (fuera de alcance actual)

- Sincronización cloud tipo Postman Teams.
- Soporte Windows/Linux.
- Importación OpenAPI YAML (preparado como extensión futura).
- Login multi-usuario o autenticación en la app (es herramienta de escritorio offline).

## Diferenciadores vs Postman

| Aspecto | Postman | EFBY Request Lab |
|---------|---------|------------------|
| Plataforma | Electron multi-OS | Nativo Swift/SwiftUI macOS + iPad |
| Sync | Cloud obligatorio para equipos | Git manual, control total del equipo |
| Flujos | Collection Runner lineal | BPMN con gateways, paralelismo, timers |
| Offline | Limitado | Workspace 100 % local |
| Código | Cerrado | Open source en GitHub |

## Objetivos de ingeniería

1. Mantener **SDD** (Specification-Driven Development) con specs verificables como fuente de verdad.
2. Aplicar **TDD** con matriz de trazabilidad requisito → test.
3. Evolucionar la base hacia **Clean Architecture** sin reescritura total.
4. Distribuir un producto desplegable con documentación completa para cualquier contribuidor.
