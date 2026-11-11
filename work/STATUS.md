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

## Em andamento
- P1.1+P1.4 Hoje/Treinos — correções + integração das telas (Dieta, editor, biblioteca, starter, SessionEngine no App).
- P2.2–P2.5 Sessão/histórico — em revisão.
- P4.1 Apple Health — correções (duplicação com espelho, ordem de gravação, matcher, gates).
- P5.3+P5.4 UI do Coach + Ajustes de IA.
- P3.3 Lembretes de refeição, favoritos, histórico da dieta.
- P6.2 Exportar/importar/apagar tudo (contrato `fitjourney-export-v1`).
- P6.1 Passe de design: ícone, paleta oficial de fichas, Live Activity, Saúde, Coach/Ajustes.

## Próximo
- P2.6 + W2 + W3b (Opus): lacunas do engine (anotação/dor/humor/nota, remover série, tipo da série, cardio com pausa, skipRest vencido), IDs determinísticos, appliedCommandIDs/restTotalSeconds/foco no snapshot, startCardio; WatchConnectivity + espelhamento + HKWorkoutSession no relógio.
- P4.2/P4.3 FC na sessão e aba Saúde (Sonnet) após P4.1.
- Ajustes gerais (unidades, Saúde, notificações, dados, IA) após P6.1/P6.2/P5.4.
- Ciclo 6: Live Activity, localização en, QA, Cartographer.
