# Status

**Data**: 2026-11-16 · **Fase**: lançamento na App Store (build 6 no TestFlight, versão 1.0.0 aguardando reenvio pelo dono)

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

## Loja (13/11) — kit da App Store
- `work/store/`: `store.json` (en-US + pt-BR, Saúde e fitness + Estilo de vida, 1.0.0), telas cruas (`raw/`), 7 capturas de iPhone por idioma (`png/`), 3 do relógio (`watch/`), header e busca (`creatives/`, fontes em `creatives/src/build.py`). `check.py` OK.
- Ganchos DEBUG de demonstração: `-fj.seedDemo` (`App/StoreDemo.swift`), `-fj.demoRoute`, `-fj.demoScrollY`, `-fj.sessionDemo mid`, relógio `-FJWStore`; scripts `scripts/store-screens.sh` e `store-watch-screens.sh`.
- Correções: Release compilava com erro (`#Preview` do Coach fora de DEBUG); nomes de exercício em pt na UI inglesa (Hoje, editor, FC, sessão, copiloto); decimal do copiloto por idioma; "1A" → "1Y"; `PrivacyInfo.xcprivacy` no app e no relógio; MARKETING_VERSION 1.0.0.
- Páginas de suporte/privacidade em `CV_Website/site/FitJourney/` (não commitadas nem publicadas).
- Pendente do dono: criar o app no App Store Connect (en-US, bundle `br.com.renatocorrea.fitjourney`, SKU `fitjourney-ios-001`); autorizar push do CV_Website, upload do build e envio da ficha.
- Ressalvas: pílula de zona do `FJHeartRateBadge` corta com nomes longos (ios-design); "8reps" sem espaço na sessão; "Last time … 5 day…" truncado na Evolução.

## Complicação do relógio e ícone em vidro (13/11)
- Novo target `FitJourneyWatchWidgets` (WidgetKit, watchOS 26): complicação de atalho (circular, canto, retangular, inline), sem dados nem App Group. Arte em vidro nos mostradores de cor cheia; glifo chapado `StairGlyph` nos acentuados.
- Ícone em vidro em `design/icon/glass/` (gerador `make_icon_glass.swift` e `make_complication_glass.swift`), adotado no app (claro/escuro/tingido), no relógio, no site e no glifo da Live Activity.
- Pendente: validar a complicação em relógio real.

## Loja e TestFlight (13–16/11)
- Nome na loja: "FitJourney: Gym & Diet Log" (en) / "FitJourney: Treino e Dieta" (pt); nome na tela inicial continua "FitJourney"; bundle inalterado. App ASC 6834532428. Ficha enviada pela API (`~/.claude/skills/app-store-launch/scripts/asc.py`, estado em `work/store/.asc-state.json`). Páginas de suporte/privacidade publicadas no CV_Website.
- Só iPhone (`TARGETED_DEVICE_FAMILY "1"` no app e widgets); `UIBackgroundModes workout-processing` removido do iPhone.
- Repositório no GitHub `git@github.com:renatoflcorrea/FitJourney.git` (histórico limpo de Team ID/UDIDs). Push só com pedido.
- Build 3: crash em loop no Release (caminhos de relacionamento em `#Predicate`/`SortDescriptor`/`@Query` são removidos no Release) — corrigido filtrando em memória; `SwiftDataKeyPathGuardTests` impede regressão. Relógio: timeout de 20 s no "Salvando". Guarda de restauração da sessão (`fj.session.restoreGuard`).
- Versão 1.0.0 foi **rejeitada** (build 3): a Apple pediu um vídeo do app.
- Build 4: cantos da lista de fichas, botão de IA centralizado (Treinos/Dieta), renomear programa, **registro de refeições com IA** (texto do dia, foto do prato; foto não é guardada; câmera salva no Fotos; SPEC §7.x, O6c; proposta em `design/proposals/ai-meal-log.md`), **importação v2 mais rápida** (contratos compactos, correções por remendo, esforço baixo, perguntas de exercício numa lista; `design/proposals/ai-import-speed.md`), tudo de IA só aparece com IA configurada (`AIAvailability`).
- Build 5 (`7afcd9b`): respiro entre o cabeçalho "Fichas" e a lista.
- Build 6 (`6381ef3`): relógio — `WatchButtonStyle` (largura total exata; `.glass`/`.glassProminent` recuavam a forma) em todas as telas; descanso com "+ reps"/"+15 s" a 2/3 da altura e alinhados ao "Pular", "Próxima: carga" maior e em largura total; nota do treino (RPE) pela Coroa e por − / + (sem ScrollView). Conferido no simulador; testes do relógio verdes.
- Build 6 processado e **anexado** à versão 1.0.0 (PREPARE_FOR_SUBMISSION). Não reenviado.

## OpenCode Go (19/11)
- Provedor "OpenCode Go" (assinatura) integrado (`2bcccf5`): plano em `design/proposals/opencode-go.md`, DESIGN decisão 40. Endpoint `opencode.ai/inference/go/openai/v1` (Bearer, `User-Agent: FitJourney/…`, `x-opencode-session` estável), descoberta em `/inference/go/v1/models` com cache de 24 h, seletor só com modelos que leem imagens e não treinam com os dados (padrão `gpt-6-luna`, o mais barato por uso nos testes), PDF sempre rasterizado, erros 402/403 free/429 limite do Go.
- Teste ao vivo (chave de teste do dono, só no scratchpad): importação real dos PDFs da revisão da Apple (`~/Downloads/FitJourney Files`) — 4 fichas/37 exercícios em 57 s; plano de 7 páginas em 34 s; chave inválida detectada.
- Implementação pelo OpenCode (`opencode.json`, `.opencode/prompts/`): Luna para pacotes simples, `-m openai/gpt-6.1-terra` para complexos e revisão. Luna tende a pular testes: pedir lista explícita e conferir.
- A 1.0.0 segue com problemas na revisão da Apple (texto não legível pela API). Build com o OpenCode Go ainda não gerado.

## Retomar aqui (nova sessão)
- **Do dono**: instalar o build 6 pelo TestFlight, gravar o vídeo pedido pela Apple, responder na revisão e clicar "Enviar para revisão" (nunca enviar por ele).
- Commits locais ainda sem push: `7afcd9b`, `64f5c81`, `6381ef3` e este status.
- Validar em aparelho: botões e nota do treino no relógio; registro por foto (câmera, Fotos, análise real); tempo real da importação v2; complicação no mostrador; efeito de tirar o modo de fundo do iPhone.
- Não alterados no relógio (perguntar se quer no mesmo padrão): "Iniciar" na barra inferior da ficha (posição do sistema); grade da página de controles.
- Fluxo de build: `scratchpad` não persiste — archive com `-allowProvisioningUpdates` e chave da API (`~/.appstoreconnect/config.json`, args num array bash), conferir UIDeviceFamily [1], CFBundleVersion e o `.appex` da complicação; depois `asc.py builds` até VALID e `asc.py attach-build work/store/store.json <n>`.
- Opcionais: Cartographer e `docs/ia.md` (registro de refeições/importação v2); extras do registro (toque longo no "+", chip no Coach); progresso parcial por streaming na importação.
- Processo: worktree + simulador próprio por agente (nunca `shutdown all`); review-code antes de integrar; conflitos em `.xcstrings` por união de chaves (`python3 scripts/xcmerge.py`).
