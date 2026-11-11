# Plano de desenvolvimento — FitJourney

Modelo de execução do Manylens/HealthProject, **só Claude**: `fit-supervisor` (Opus 5.5) orquestra ciclos; cada pacote tem contrato, caminhos isolados e critério de aceite; todo código passa por `review-code` antes de integrar.

| Papel | Agente | Modelo | Uso |
|---|---|---|---|
| Orquestração, integração | `fit-supervisor` | **Opus 5.5** | sessão principal |
| Design, fluxos, DesignSystem | `ios-design` | **Fable 5.2** | `DESIGN_DIRECTION.md`, protótipos, `DesignSystem/` |
| Núcleo avançado | `core-engineer` | **Opus 5.5** | SwiftData/migrações, sessão de treino (estado/tempo), HealthKit, IA (streaming/tools) |
| Telas e features | `ios-implementation` | **Sonnet 5.5** | telas SwiftUI, formulários, listas, Charts, localização |
| Revisão | `review-code` | Sonnet 5.5 | só leitura, antes de integrar |
| QA | `qa-accessibility` | Sonnet 5.5 | estados, VoiceOver, Dynamic Type, evidências |

Pacotes independentes rodam em paralelo, cada um em worktree próprio (`.claude/worktrees/<pacote>`); integração sequencial em `main`. Ao fim de cada ciclo: `make build test`, screenshots no simulador, `work/STATUS.md`, evidências em `work/evidence/ciclo-N/`, `/cartographer:cartographer` para atualizar `docs/CODEBASE_MAP.md`.

## Ciclo 0 — Fundamentos

| Pacote | Agente | Depende | Entrega |
|---|---|---|---|
| P0.1 Direção de design | ios-design (Fable) | SPEC | `DESIGN_DIRECTION.md`: princípios, tokens, componentes, todas as telas e estados, fluxos (iniciar/encerrar sessão, criar ficha, registrar refeição), critérios de validação; protótipo HTML em `design/` |
| P0.2 Projeto | supervisor | — | `project.yml` (XcodeGen), iOS 26, app shell com 4 abas, Makefile, testes, git |
| P0.3 Domínio + persistência | core-engineer (Opus) | P0.2 | Modelos SwiftData (SPEC §2–§5, compatíveis com CloudKit), regras puras (agenda do programa, carga atual, volume/1RM, totais da dieta), catálogo inicial de exercícios, dados de exemplo para previews, testes |
| P0.4 DesignSystem | ios-design (Fable) | P0.1, P0.2 | Tokens, `GlassCard`/botões/chips/acessório, componentes base em `FitJourney/DesignSystem/` |

P0.1 ∥ P0.3 (caminhos disjuntos). P0.4 após P0.1.

## Ciclo 1 — Planejamento de treino

| Pacote | Agente | Depende |
|---|---|---|
| P1.1 Treinos: programas (lista, ativo, histórico, duplicar, modos de agenda) | ios-implementation | P0.3, P0.4 |
| P1.2 Editor de ficha: exercícios, reordenar, grupos (bi-set), prescrição série a série / em bloco | ios-implementation | P1.1 |
| P1.3 Biblioteca de exercícios + mídia (foto, YouTube/Vimeo embed, vídeo da galeria) | ios-implementation (mídia: core-engineer) | P0.3 |
| P1.4 Aba Hoje: ficha sugerida pela agenda | ios-implementation | P1.1 |

## Ciclo 2 — Execução da sessão

| Pacote | Agente | Depende |
|---|---|---|
| P2.1 Motor da sessão: snapshot, estado, relógio por datas, descanso, retomada após fechar o app; API por **comandos idempotentes** + snapshot (base do Watch) | core-engineer | P0.3 |
| P2.2 Tela da sessão: séries, check, editar carga/reps, isométrico, cardio, pular/trocar/adicionar | ios-implementation | P2.1 |
| P2.3 Encerrar: resumo, PRs, RPE da sessão, atualizar carga atual | ios-implementation | P2.2 |
| P2.4 Histórico e evolução por exercício (Charts) | ios-implementation | P2.3 |
| P2.5 Acessório flutuante da sessão (`tabViewBottomAccessory`) | ios-implementation | P2.2 |

## Ciclo 3 — Dieta

| Pacote | Agente | Depende |
|---|---|---|
| P3.1 Editor de plano: refeições, itens, substituições, metas, variação por dia | ios-implementation | P0.3 |
| P3.2 Dia: linha do tempo, feita/ajustada/pulada, registro avulso "+", totais x metas, água | ios-implementation | P3.1 |
| P3.3 Lembretes de refeição (notificações locais), favoritos/recentes, histórico | ios-implementation | P3.2 |

## Ciclo 4 — Apple Health

| Pacote | Agente | Depende |
|---|---|---|
| P4.1 HealthKit: permissões, gravar `HKWorkout` + eventos por exercício, `HKWorkoutSession` no iPhone, dedup/vínculo | core-engineer | P2.3 |
| P4.2 FC na sessão + gráfico com faixas por exercício | ios-implementation | P4.1 |
| P4.3 Aba Saúde: dia (FC, treinos, força x aeróbico), tendências | ios-implementation | P4.1 |

Validação real exige iPhone + Apple Watch.

## Ciclo 4b — App do Apple Watch (SPEC §6.4)

| Pacote | Agente | Depende | Entrega |
|---|---|---|---|
| W0 Design do relógio | ios-design (Fable) | P0.1 | Fluxos e telas watchOS em `DESIGN_DIRECTION.md` + quadros no protótipo |
| W1 Protocolo `Shared/WatchLink/` | core-engineer | P2.1 | Comandos idempotentes, snapshot versionado, resumo do programa, codec + testes puros |
| W2 Lado iPhone | core-engineer | W1, P4.1 | Espelhamento de `HKWorkoutSession`, aplicar comandos via `SessionStore`, `applicationContext` |
| W3 App watchOS | core-engineer (sessão/HealthKit) + ios-implementation (telas) | W1 | Alvo watchOS (XcodeGen), lista de fichas, sessão, descanso, Crown, métricas, finalizar |
| W4 QA em aparelho | qa-accessibility | W2, W3 | iPhone + Watch reais: alcance, offline, retomada, latência |

Obs.: o motor da sessão (P2.1) já nasce com comandos idempotentes e snapshot, pensando no relógio.

## Ciclo 5 — Coach IA (fase 2)

| Pacote | Agente | Depende |
|---|---|---|
| P5.1 Núcleo de IA portado do fireplaice + tools + Anthropic nativo (`docs/ia.md`) | core-engineer | — |
| P5.2 Ferramentas locais + schemas `ProgramDraft`/`NutritionPlanDraft` (`contracts/`) | core-engineer | P5.1 |
| P5.3 Aba Coach: conversas, streaming, cartões de proposta → editor | ios-implementation | P5.2 |
| P5.4 Ajustes de provedor/modelo/chave, perfil, privacidade | ios-implementation | P5.1 |

## Ciclo 7 — Copiloto de IA (SPEC §7A)

| Pacote | Agente | Depende | Entrega |
|---|---|---|---|
| C7.1 Design do copiloto | ios-design (Fable) | SPEC §7A | Fluxos e telas (importar, entrevista, revisão, cartões de alteração, Desfazer) em `DESIGN_DIRECTION.md` + protótipo + componentes no DesignSystem |
| C7.2 Núcleo: anexos multimodais, extração por schema, entrevista, ferramentas de escrita propostas | core-engineer (Opus) | — | `Services/AI/` (anexos, `ImportSession`, contratos `program-import-v1`/`nutrition-import-v1`, `propose_*_changes`, `ChangeApplier` com desfazer) |
| C7.3 Telas: botões Importar com IA, fluxo de importação, copiloto de edição com cartões | ios-implementation (Sonnet) | C7.1, C7.2 | `Features/Copilot/` + pontos de entrada em Treinos/Dieta/Hoje/Coach |

## Ciclo 6 — Acabamento

Live Activity de descanso, exportar/importar JSON, localização en, acessibilidade completa, ícone, QA em aparelho.

## Futuro

Plugin/app do ChatGPT (servidor MCP), Android (avaliar KMP), interop HealthProject, iCloud, complicações do Watch, widgets.

## Estrutura alvo

```
FitJourney/
  App/          entrada, AppRoot (tabs), composição
  Domain/       regras puras (sem SwiftUI/SwiftData): agenda, carga, métricas, totais
  Persistence/  @Model SwiftData, container, seed, export
  Services/     Health/, Media/, AI/ (fase 2), Notifications/
  Features/     Today/, Training/, Session/, Nutrition/, Health/, Coach/, Settings/
  DesignSystem/ tokens, vidro, componentes
FitJourneyTests/
contracts/      schemas JSON versionados
```
