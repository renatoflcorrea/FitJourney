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

## Em andamento
- P1.1+P1.4 Programas/Hoje (Sonnet) — implementando.
- P1.2 Editor de ficha (Sonnet) — correções da revisão (grupo ao arrastar, R-T2, unidade kg/lb, ProgramStore atômico).
- P5.1+P5.2 Núcleo de IA (Opus).
- P2.2–P2.5 Tela da sessão/encerramento/histórico/acessório (Sonnet).
- P4.1 Apple Health no iPhone (Opus).
- W3a App watchOS (UI + transporte simulado) (Sonnet).

## Próximo
- Integrar P1.1 + ligar abas (Dieta, sessão, `MediaMaintenance.runAtLaunch`, `restore`/`handleForeground`, StarterProgram → SampleProgramFactory) → P4.2/P4.3 (FC, aba Saúde) → W2/W3b (transporte real + HKWorkoutSession no relógio) → P5.3/P5.4 (UI do Coach) → P3.3 lembretes → Ciclo 6 → Cartographer.
- Pedir ao design tokens oficiais de cor de ficha (RoutineColor) e promover `FlowLayout`.
