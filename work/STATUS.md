# Status

**Data**: 2026-11-11 · **Ciclo**: 0 (fundamentos)

## Feito
- SPEC.md v0.1, docs/PLANO.md, docs/ia.md (provedores portados do fireplaice), AGENTS.md/CLAUDE.md, agentes em `.claude/agents/` (supervisor Opus, design Fable, núcleo Opus, telas/revisão/QA Sonnet).
- P0.2 Projeto: XcodeGen, iOS 26, bundle `br.com.renatocorrea.fitjourney`, HealthKit entitlement, app shell com 4 abas (Liquid Glass nativo), `make build` e `make test` verdes no simulador.

- P0.3 Domínio + persistência integrado (`658d932`): 82 testes verdes; revisão com 7 correções aplicadas (mídia tolerante, Vimeo, seed versionado, desempenho do histórico, âncora do rodízio).
- Protótipo v1 publicado: https://claude.ai/artifact/KVLeypFG56VoBAsVn2dqqh
- Decisões do usuário 11/11 (SPEC §11 D1–D5): laranja; reps opcionais com alvo sempre visível; passo 0,5 kg; propostas aprovadas (treino esquecido, exemplo ABC, notificação de descanso, "Sem registro"), "tela ligada" recusada; **app do Apple Watch com controle da sessão** (SPEC §6.4, ciclo 4b).

- P0.1/P0.4 + W0 integrados (`d88201a`): DESIGN_DIRECTION (iPhone + §9 watchOS), DesignSystem revisado (teclado do stepper, Reduzir Movimento, VoiceOver), AccentColor laranja. Protótipo v2 (com relógio) no mesmo link.
- Padrões assumidos para as perguntas abertas do design (podem mudar): doca espera toque após o descanso; laranja queimado `#D4450C` com texto branco; atenção/recorde amarelos diferenciados por símbolo; relógio com páginas horizontais; Coroa ajusta a próxima carga no descanso; cargas atualizadas pela regra padrão ao finalizar no relógio; treino livre fora do relógio por ora.

- P1.3 Biblioteca + mídia integrada (`0e1b632`), revisão com 3 altas corrigidas (órfãos, rollback do duplicar, WebView endurecido).
- P3.1+P3.2 Dieta integrada (`1dc0a2a`), vigência do plano, parsing pt-BR, regras puras em Domain; aba ainda não ligada no AppRoot (junto com P1.1).
- P2.1 Motor da sessão integrado (`f313870`, 122 testes): idempotência com tombstones, ordem por série, save atômico, compatibilidade de protocolo, comandos add/substitute/reorder.
- Infra: simulador próprio por worktree (AGENTS.md); `FJ-main` para o supervisor.

- P1.2 Editor de ficha integrado (`6eb241b`) + correção de warning e duração com bi-set (`1febc94`).
- P5.1+P5.2 Núcleo de IA integrado (`328b194`): OpenAI-compatível + Anthropic nativo (conferido com a skill claude-api), tools locais com consentimento por categoria (tudo desligado por padrão), drafts com JSON Schema em `contracts/`.
- W3a App watchOS integrado (`a7a36b1`): UI completa, estado otimista com retenção até o 1º snapshot; release usa `UnavailableWatchTransport` até o W2.

- P2.2–P2.5 Sessão/histórico integrados (`7c936c2`); P1.1+P1.4 Hoje/Treinos integrados com todas as telas ligadas (`35c5c13`); P4.1 Apple Health integrado (`e933689`).
- Supervisor ligou sessão + Saúde no app (`37b553c`): sessionHost no AppRoot, Iniciar treino/Ver treino/Histórico reais, HealthWorkoutController acoplado ao motor, FC ao vivo.
- Testes rodam em pt-BR (`da544a0`) — o catálogo traduz para en e os testes esperam o texto-fonte.
- P6.1 passe de design integrado (`9d5a0f5`): FJRoutineColor/FJRoutineBadge/FJFlowLayout, ícone "degraus", DESIGN §4.11–4.14.
- **App navegável de ponta a ponta no simulador**: Hoje → Iniciar treino → sessão → encerrar → histórico; Treinos/editor/biblioteca; Dieta.
- Infra: máquina no limite de simuladores (maxUserProcs) — um simulador por agente, sem desligar os de outros projetos.

- P3.3 Lembretes integrados (`943dba3`) com delegate de notificações e reschedule no App; P5.3+P5.4 Coach integrado (`f2c42c9`) e aba Coach ligada (`e01a244`); P4.2+P4.3 aba Saúde integrada e ligada (`a712480`); P6.2 exportar/importar/apagar integrado com correções de segurança (`56a7316`), `BackupMaintenance` no launch (`02bbed0`).
- Protótipo v3 publicado (mesmo link). 5 abas: Hoje, Treinos, Dieta, Saúde, Coach.
- Incidente: um agente usou `simctl shutdown all` (desligou simuladores de outros projetos). Regra reforçada no AGENTS.md e nos briefs.

- P2.6+W2+W3b integrado (`6473794`) + PhoneWatchLink ligado no App (`5c7b569`): comandos novos do motor, protocolo v2 com IDs determinísticos (UUIDv5), WatchConnectivity, treino gravado no relógio com espelhamento, `.saved` durável.
- P6.3 Ajustes integrado (`0326df0`): perfil, unidades kg/lb no app inteiro, FC máx (zona ao vivo), Saúde/Notificações/IA, Dados (exportar/importar/apagar com reset em duas fases), paleta oficial de fichas. Preferências escondidas até haver consumidor: início da semana, descanso padrão, som.

- P6.4 Live Activity integrada (`9fb2b34`); P2.7 sessão iPhone+relógio com comandos novos integrada (`f8ba486`). iOS e watchOS: build e testes verdes.
- Makefile: `make device TEAM=<TEAM> [DEVICE_ID=<udid>]` (Team não versionado).

- P6.5 preferências integradas (`f7d0cd3`): `AppCalendar` (início da semana), `RestPolicy` no domínio (descanso padrão dos Ajustes; catálogo com descanso opcional), som ao fim do descanso. `DraftApplier` sem 90 fixo (`4eaa08d`).
- P5.5 ChatGPT (login) experimental integrado (`7c28328`): OAuth PKCE + listener loopback endurecido, Responses com ferramentas, refresh serializado.

## Em andamento
- P6.6 (Sonnet): inglês completo (app, relógio, extensão, textos de permissão) + QA de acessibilidade com evidências em `work/evidence/ciclo-6/qa/`.

## Próximo
- `/cartographer:cartographer` → `docs/CODEBASE_MAP.md`.
- **Usuário**: teste em iPhone + Apple Watch (HealthKit, WatchConnectivity, espelhamento, Live Activity, notificações) via `make device TEAM=<TEAM> DEVICE_ID=<udid>`; chave de API ou login ChatGPT para o Coach.
