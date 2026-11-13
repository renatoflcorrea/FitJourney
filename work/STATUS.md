# Status

**Data**: 2026-11-13 · **Ciclo**: 7 concluído (pedidos do teste em aparelho)

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

- P6.6 inglês completo + QA de acessibilidade integrado (`377f289`); evidências e pendências em `work/evidence/ciclo-6/qa/RELATORIO.md`.
- `docs/CODEBASE_MAP.md` gerado pelo Cartographer.
- P6.7 pendências de acessibilidade integradas (`331b15f`); P5.6 `get_health_summary` real integrado (`f958e9b`). **Plano de implementação concluído.**

## Ciclo 7 — pedidos do teste em aparelho (11–12/11), tudo integrado e instalado
- C7.1 design do copiloto (fc93e2f), C7.2 núcleo (f884184), C7.3 telas (c2cfdc8): "Importar com IA" (PDF/imagem/texto, várias fichas, entrevista, revisão) e cartões de alteração Aplicar/Desfazer no Coach. SPEC §7A, docs/ia.md.
- P2.8 (68e015f): memória de carga (sem "0 kg"; última carga usada; 1ª definição vira atual; propaga às séries seguintes) + `startWatchApp` (abre o FitJourney no relógio ao iniciar no iPhone). SPEC §3.4.
- Alerta insistente de fim de descanso (09c5f42): vibra a cada 1,8 s até tocar (teto 60 s), relógio e iPhone; "Começar série". DESIGN decisão 34, frames 33/34.
- P6.8 (9cf642e + b985bac): idioma do app (Ajustes › Geral › Idioma: Sistema/Português/English, "Reiniciar agora" escondido durante treino); relógio segue o iPhone; nomes de exercícios harmonizados (iPhone, relógio, VoiceOver, Live Activity, Coach).
- Último estado (ecac268): testes iOS e watch verdes; `make device TEAM=<TEAM> DEVICE_ID=<iphone-udid> WATCH_ID=<watch-udid>` instalou no iPhone 18 Pro Max e no Apple Watch Ultra 2.

- C7.4 (12/11): exercício novo no import sem loop — decisões de exercício guardadas por `asWritten` normalizado e reaplicadas após `reviseWithAI` (com fallback por nome/posição se a IA reescrever `asWritten`); "Criar como novo" com nome digitado (limite 80); IA instruída a não abrir dúvida só por exercício fora do catálogo; exercício da biblioteca fixado por id ao gravar. Integrado, testes verdes, instalado no iPhone e no relógio.

- W4 (12/11): carga no relógio por editor — Coroa não altera mais a carga na Série/Descanso; carga é botão que abre folha com Coroa (detentes relativos), −/+, Salvar/Cancelar; um `adjustLoad` ao salvar; editor fecha se a série muda; fim do descanso com editor aberto só vibra. DESIGN decisão 35. Integrado, testes iOS e watch verdes. **Instalação pendente**: iPhone e relógio estavam "unavailable" no devicectl — rodar `make device TEAM=<TEAM> DEVICE_ID=<iphone-udid> WATCH_ID=<watch-udid>` com o iPhone desbloqueado e na mesma rede/cabo. Conferir no aparelho: foco da Coroa ao abrir a folha, háptico, toque no chip "Próxima", layout em texto grande.

- P1.5 (12/11): copiar fichas para outro programa (só cópia) — DESIGN §4.2.1; folhas "Copiar ficha" e "Adicionar fichas", dias no semanal, nome "(2)", bloqueio por treino no destino, `ProgramStore.copyRoutines` atômico, `cloneRoutine` compartilhado com Duplicar. Integrado, testes verdes. **Instalação pendente** (aparelhos "unavailable"). Pendências: título "Adicionar fichas" trunca com o botão "Adicionar (n)"; Q-CF2 (excluir ficha no detalhe do programa/desfazer), Q-CF3 (marcar todas).

## Retomar aqui (nova sessão)
- **Primeiro passo**: instalar nos aparelhos (W4 + P1.5 ainda não instalados; C7.4 já instalado): `make device TEAM=<TEAM> DEVICE_ID=<iphone-udid> WATCH_ID=<watch-udid>` com o iPhone desbloqueado e visível (`xcrun devicectl list devices`); se o relógio falhar no túnel, repetir só `xcrun devicectl device install app --device <watch-udid> build/device/Build/Products/Debug-watchos/FitJourneyWatch.app`.
- **Nenhum pedido do usuário pendente** além da instalação. Aguardando retorno dos testes em aparelho (importar com exercício novo, editor de carga no relógio, copiar fichas).
- Não verificado em aparelho: `startWatchApp`/adoção da gravação remota; intensidade da vibração e alerta com pulso abaixado; chamadas reais aos provedores no copiloto; reinício por `exit(0)` e troca de `AppleLanguages` no relógio.
- Opcionais: índice por `messageID` no `CopilotChangeStore`; `canUndo` no `FJChangeCard`; API de edição inline no `ImportSession`; perguntas de design Q-RA1 (som do alerta), Q-RA2 (pulso abaixado sem gravação), Q-CP1..7 (padrões adotados) em DESIGN §10.
- Manutenção: rodar `/cartographer:cartographer` (mapa atualizado só parcialmente pelos agentes desde P6.7); republicar o protótipo (artifact KVLeypFG56VoBAsVn2dqqh está na v4, sem os frames 33/34 do alerta); limpar worktrees antigos em `.claude/worktrees/` (todos já integrados).
- Processo: worktree + simulador próprio por agente (nunca `shutdown all`); review-code antes de integrar; conflitos em `.xcstrings` por união de chaves (`python3 scripts/xcmerge.py <arquivo>` durante o merge, usa os stages 1/2/3 do git); supervisor usa o simulador `FJ-main`.

## Loja (13/11) — kit da App Store
- `work/store/`: `store.json` (en-US + pt-BR, Saúde e fitness + Estilo de vida, 1.0.0), telas cruas (`raw/`), 7 capturas de iPhone por idioma (`png/`), 3 do relógio (`watch/`), header e busca (`creatives/`, fontes em `creatives/src/build.py`). `check.py` OK.
- Ganchos DEBUG de demonstração: `-fj.seedDemo` (`App/StoreDemo.swift`), `-fj.demoRoute`, `-fj.demoScrollY`, `-fj.sessionDemo mid`, relógio `-FJWStore`; scripts `scripts/store-screens.sh` e `store-watch-screens.sh`.
- Correções: Release compilava com erro (`#Preview` do Coach fora de DEBUG); nomes de exercício em pt na UI inglesa (Hoje, editor, FC, sessão, copiloto); decimal do copiloto por idioma; "1A" → "1Y"; `PrivacyInfo.xcprivacy` no app e no relógio; MARKETING_VERSION 1.0.0.
- Páginas de suporte/privacidade em `CV_Website/site/FitJourney/` (não commitadas nem publicadas).
- Pendente do dono: criar o app no App Store Connect (en-US, bundle `br.com.renatocorrea.fitjourney`, SKU `fitjourney-ios-001`); autorizar push do CV_Website, upload do build e envio da ficha.
- Ressalvas: pílula de zona do `FJHeartRateBadge` corta com nomes longos (ios-design); "8reps" sem espaço na sessão; "Last time … 5 day…" truncado na Evolução.

## Complicação do relógio e ícone em vidro (13/11)
- Novo target `FitJourneyWatchWidgets` (WidgetKit, watchOS 26): complicação de atalho (circular, canto, retangular, inline), sem dados nem App Group. Arte em vidro nos mostradores de cor cheia; glifo chapado `StairGlyph` nos acentuados.
- Opção de ícone em vidro em `design/icon/glass/` (gerador `make_icon_glass.swift` e `make_complication_glass.swift`); ainda não adotada no app.
- Pendente: validar a complicação em relógio real; novo build para a loja.
