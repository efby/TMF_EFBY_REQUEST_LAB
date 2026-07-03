# ADR-002: Clean Architecture con presentación MVVM

## Estado

Aceptado

## Contexto

El cliente concentra ejecución HTTP/WebSocket, variables, import Postman/OpenAPI, Git y flujos BPMN. Hace falta separar dominio, casos de uso e infraestructura de la UI, manteniendo un ViewModel claro para SwiftUI.

## Decisión

Aplicar **Clean Architecture** en targets SPM y **MVVM** en la capa de presentación:

1. Protocolos (ports) en `EfbyApplication/Ports/`
2. Casos de uso explícitos en `EfbyApplication/UseCases/`
3. Implementaciones en `EfbyInfrastructure`
4. `MainViewModel` + coordinadores en `EfbyPresentation`
5. Composition root en `AppDependencies`

## Consecuencias

### Positivas

- Dependencias hacia el dominio.
- Tests de use cases y coordinadores sin UI.
- UI macOS e iPad sobre la misma presentación.

### Negativas

- `MainViewModel` concentra estado de UI y orquestación de alto nivel.

## Alternativas rechazadas

- **Solo MVVM con servicios concretos**: acopla UI e infraestructura y dificulta el testing.
- **Clean Architecture sin ViewModel**: menos ergonómico con SwiftUI y bindings.
