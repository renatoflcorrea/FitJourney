@AGENTS.md

## Visão do código

App iPhone SwiftUI/SwiftData (iOS 26, Liquid Glass) + app do Apple Watch + extensão de Live Activity, para treinos de academia, dieta, Apple Health e Coach de IA. O iPhone é a fonte de verdade da sessão (`SessionEngine`, comandos idempotentes); o relógio conversa pelo protocolo WatchLink v2 (`Shared/`).

**Stack**: Swift 6 (`complete`), SwiftUI, SwiftData, HealthKit, WatchConnectivity, ActivityKit/App Intents, Swift Charts, Swift Testing, XcodeGen. Sem dependências de terceiros.
**Estrutura**: `FitJourney/` (App, Domain, Persistence, Services, Features, DesignSystem), `Shared/`, `FitJourneyWatch/`, `FitJourneyWidgets/`, `contracts/`, testes.

Mapa detalhado, fluxos e armadilhas: [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md).
