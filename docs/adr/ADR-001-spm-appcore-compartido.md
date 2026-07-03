# ADR-001: Swift Package Manager y módulos compartidos

## Estado

Aceptado

## Contexto

El producto incluye una app macOS, una variante iPad y un CLI de depuración. Toda la lógica de negocio (HTTP, variables, Postman, Git, BPMN) debe compartirse entre ellos.

## Decisión

Usar **Swift Package Manager** con módulos por capa:

| Producto | Consumidores |
|----------|--------------|
| `EfbyDomain` | Capas superiores |
| `EfbyApplication` | Infrastructure, Presentation |
| `EfbyInfrastructure` | Presentation, `FlowDebugRunner` |
| `EfbyPresentation` | `EfbyRequestLabs`, `EfbyPostmanPad`, tests |

El código de dominio e infraestructura vive en `Sources/AppCore/Domain` y `Sources/AppCore/Application` (targets `EfbyDomain` y `EfbyInfrastructure`).

## Consecuencias

### Positivas

- Un solo código fuente para macOS e iPad.
- `swift build` / `swift test` sin abrir Xcode para el núcleo.
- Fronteras de compilación entre capas.
- Dependencia externa mínima (ZIPFoundation).

### Negativas

- iPad requiere un proyecto Xcode aparte que referencia el paquete local.
