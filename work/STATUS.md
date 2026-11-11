# Status

**Data**: 2026-11-11 · **Ciclo**: 0 (fundamentos)

## Feito
- SPEC.md v0.1, docs/PLANO.md, docs/ia.md (provedores portados do fireplaice), AGENTS.md/CLAUDE.md, agentes em `.claude/agents/` (supervisor Opus, design Fable, núcleo Opus, telas/revisão/QA Sonnet).
- P0.2 Projeto: XcodeGen, iOS 26, bundle `br.com.renatocorrea.fitjourney`, HealthKit entitlement, app shell com 4 abas (Liquid Glass nativo), `make build` e `make test` verdes no simulador.

- P0.3 Domínio + persistência integrado (`658d932`): 82 testes verdes; revisão com 7 correções aplicadas (mídia tolerante, Vimeo, seed versionado, desempenho do histórico, âncora do rodízio).
- Protótipo v1 publicado: https://claude.ai/artifact/KVLeypFG56VoBAsVn2dqqh
- Decisões do usuário 11/11 (SPEC §11 D1–D5): laranja; reps opcionais com alvo sempre visível; passo 0,5 kg; propostas aprovadas (treino esquecido, exemplo ABC, notificação de descanso, "Sem registro"), "tela ligada" recusada; **app do Apple Watch com controle da sessão** (SPEC §6.4, ciclo 4b).

## Em andamento
- P0.1/P0.4 revisão 2 (ios-design, Fable): decisões D1–D5, design do Watch (W0), correções da revisão (teclado do stepper, Reduzir Movimento, VoiceOver).
- P2.1 Motor da sessão (core-engineer, Opus): comandos idempotentes + snapshot (`Shared/WatchLink`), `SessionEngine`, treino esquecido, notificação de descanso, exemplo ABC.

## Próximo
- Integrar P0.4 → Ciclo 1 (P1.1–P1.4 telas de treino, Sonnet) ∥ P3.1 editor de dieta.

## Padrões assumidos (SPEC §11)
- "Piso" = piso da faixa de repetições. kg padrão. Semana começa na segunda. Swift puro (KMP só quando o Android começar). IA BYOK na fase 2.
