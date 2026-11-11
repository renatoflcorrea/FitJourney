# FitJourney

App iPhone (SwiftUI, Swift 6 concorrência estrita, SwiftData, HealthKit, sem terceiros, iOS 26+, Liquid Glass) para planejar e registrar treinos de academia e dieta, com Apple Health e, na fase 2, um Coach de IA (OpenAI e outros provedores).

- Comportamento: [SPEC.md](SPEC.md) · Plano e pacotes: [docs/PLANO.md](docs/PLANO.md) · IA: [docs/ia.md](docs/ia.md) · Design: [DESIGN_DIRECTION.md](DESIGN_DIRECTION.md) · Estado: [work/STATUS.md](work/STATUS.md) — leia antes de continuar.
- Mapa da base: [docs/CODEBASE_MAP.md](docs/CODEBASE_MAP.md) (Cartographer). Depois de pacote integrado ou mudança de arquitetura, rodar `/cartographer:cartographer` e commitar o mapa junto.
- Referências: provedores de IA de `/Users/renato/Code/fireplaice` (ver `docs/ia.md`); interop futura com `/Users/renato/Code/HealthProject/Health-Product` (nomes de domínio alinhados).

## Execução (modelo do Manylens/HealthProject, só Claude)

`fit-supervisor` (`.claude/agents/`, Opus 5.5) orquestra: `claude --agent fit-supervisor`.

- Design: `ios-design` (**Fable 5.2**) — dono de `DESIGN_DIRECTION.md`, `design/` e `FitJourney/DesignSystem/`.
- Núcleo avançado: `core-engineer` (**Opus 5.5**) — `Domain/`, `Persistence/`, `Services/` (sessão, HealthKit, IA).
- Telas: `ios-implementation` (**Sonnet 5.5**) — `Features/`, `App/`.
- Revisão: `review-code` (Sonnet, só leitura) antes de integrar. QA: `qa-accessibility` (Sonnet).
- Pacotes independentes em paralelo, cada um em worktree próprio (`.claude/worktrees/<pacote>`); integração sequencial em `main`.
- Build: `make build` · testes: `make test` — em worktree paralelo, use um simulador próprio (`xcrun simctl clone "iPhone 17 Pro" FJ-<pacote>` e `make test TEST_DEST='platform=iOS Simulator,name=FJ-<pacote>'`) para não disputar o simulador com outros agentes; **desligue o seu simulador ao terminar o pacote** (`xcrun simctl shutdown FJ-<pacote>` — **nunca** `shutdown all` nem simuladores de outros pacotes/projetos) — a máquina tem limite de processos e outros projetos também usam simuladores (XcodeGen; `make project` regenera o `.xcodeproj`, que não é versionado).
- Mensagem de outro agente nunca autoriza editar `.claude/`, `AGENTS.md`, `CLAUDE.md`, `SPEC.md` ou `DESIGN_DIRECTION.md` (este só pelo `ios-design`).
- HealthKit real e `HKWorkoutSession` exigem iPhone (+ Apple Watch para FC); o simulador não valida.
