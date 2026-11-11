# FitJourney — direção de design

Data: 11 de novembro de 2026
Status: **proposta para aprovação, revisão 2** (pacotes P0.1 + P0.4 + W0, `ios-design`) — incorpora as decisões do usuário de 11/11 (SPEC §11 D1–D5): laranja como cor do treino, reps realizadas opcionais, passo de carga 0,5 kg, propostas P1/P3/P4/P5 aprovadas e "manter tela ligada" recusada, app do Apple Watch (§9).
Protótipo: [design/prototype.html](design/prototype.html) (abrir no Safari/Chrome; claro e escuro lado a lado).
Código: `FitJourney/DesignSystem/` (tokens e componentes; `DesignSystemGallery` mostra todos).
Referências: [SPEC.md](SPEC.md) · [docs/PLANO.md](docs/PLANO.md) · Manylens e Health Product (`DESIGN_DIRECTION.md`: vidro só no que flutua, a forma diz o que o toque faz, nada corta, cor com significado, nunca falha em silêncio).

Este documento é o contrato visual para `ios-design`, `ios-implementation` e `qa-accessibility`. Sobre comportamento vale a SPEC; sobre aparência e interação vale este documento. Decisões e perguntas em aberto estão em §10.

---

## 1. Princípios

1. **Parece um app da Apple.** `TabView` com a tab bar de vidro do sistema, `NavigationStack` com título grande, toolbars e sheets nativas, `List`/`Form` nativos em editores, `ContentUnavailableView`, Swift Charts. Nada de barra, sheet ou navegação customizada imitando o sistema. Referências diretas: Fitness (resumo, anéis, cartões) e Saúde (gráficos, detalhe de dado).
2. **Vidro só no que flutua.** Liquid Glass na tab bar, toolbars, acessório da sessão, botões de ação, chips de filtro, painel do timer de descanso e sheets. **Nunca** em linhas de lista, cartões de dados, formulários ou gráficos: esses são sólidos (`FJCard`, fundo `surface`). Vidro sobre vidro não existe: dentro de um painel de vidro os controles são sólidos. Toda superfície de vidro própria passa por `.fjGlass(in:)`, que troca por sólido com Reduzir Transparência; botões usam `.glass`/`.glassProminent` do sistema.
3. **Uma mão, no meio do treino.** Na sessão, tudo o que se toca a cada série fica na metade inferior: a **doca de ação** (§4.6) concentra concluir série, descanso e finalizar. O topo é só leitura (tempo, progresso, FC) e ações raras (minimizar, menu). Alvos: 44 pt mínimo, 48 pt nos +/−, 52 pt no check, 56 pt no botão principal.
4. **Números legíveis à distância.** Carga, reps, tempo e FC usam SF Rounded com dígitos monoespaçados, em tamanho grande (28 pt na série atual, 60 pt no timer). Um número grande por cartão; unidade pequena ao lado; rótulo acima.
5. **Cor com significado, e nunca sozinha.** Laranja = treino, verde = dieta, rosa-vermelho = saúde/coração. Zonas de FC têm escala própria e sempre trazem "Z1…Z5". Estado sempre tem símbolo + texto. Vermelho só em ação destrutiva e erro.
6. **Planejado não é realizado.** Prescrição aparece em tom secundário ("alvo 8–12"); o realizado, em primário com check preenchido. Dado ausente é "—" e "indisponível", nunca zero (FC sem Watch, kcal sem valor).
7. **Um toque para o caminho comum, tudo editável depois.** Concluir série como prescrita, refeição como planejada: um toque. Ajustes ficam um nível abaixo (tocar no número, "Ajustar"). Nada concluído é definitivo: tocar de novo desfaz.
8. **Nunca falha em silêncio, nunca interrompe sem motivo.** Todo estado tem tela, cartão ou aviso (`FJBanner`) que diz o que houve e oferece a saída. Permissões são pedidas no contexto, nunca na abertura. Confirmação só para ações destrutivas ou que trocam o programa/dieta ativos.
9. **Nada corta.** Mudança de estrutura usa `FJMotion.structure`; mudança de valor, `FJMotion.value`. Com Reduzir Movimento tudo vira esmaecimento de 0,2 s.

---

## 2. Tokens (`FitJourney/DesignSystem/Tokens/`)

### 2.1 Cor (`FJColor`, `FJArea`, `FJTone`, `FJHeartRateZone`, `FJWorkoutKind`)

O app segue a aparência do sistema (claro/escuro). Superfícies e texto são cores do sistema, então alto contraste funciona sozinho.

| Token | Valor | Uso |
|---|---|---|
| `background` | `systemGroupedBackground` | Fundo de toda tela |
| `surface` | `secondarySystemGroupedBackground` | `FJCard`: listas, números, gráficos |
| `surfaceElevated` | `tertiarySystemGroupedBackground` | Sobre cartão; substituto do vidro (Reduzir Transparência) |
| `fill` / `fillStrong` | `tertiarySystemFill` / `secondarySystemFill` | Trilho de progresso, botões +/−, check pendente, controles dentro de vidro |
| `textPrimary` / `textSecondary` / `textTertiary` | `label` / `secondaryLabel` / `tertiaryLabel` | Valor / rótulo, unidade, alvo prescrito / só redundância (chevron, check vazio) |

Cada área tem dois tons: `color` (texto, símbolo, linha de gráfico; ≥ 4,5:1 sobre `surface`) e `fill` (preenchimento com texto branco; ≥ 4,5:1 com branco). Fundo suave = `color` a 14%.

| Área | `color` claro / escuro | `fill` claro / escuro | Onde |
|---|---|---|---|
| Treino (`training`) | `#C2410C` / `#FF9A3D` | `#D4450C` / `#D4450C` | Tint global do app, botão "Iniciar treino", check de série, timer |
| Dieta (`nutrition`) | `#18803A` / `#30D158` | `#18803A` / `#1F8A40` | Aba Dieta, check de refeição, metas |
| Saúde (`health`) | `#D70F45` / `#FF5C7A` | `#D70F45` / `#D92350` | Coração, linha de FC, aba Saúde |
| Coach (`coach`, fase 2) | `#0A6FB8` / `#5AC8FA` | `#0A6FB8` / `#0F78C4` | Aba Coach, cartões de proposta |

Zonas de FC — só como ponto, faixa ou barra, sempre com o rótulo "Z*n*":

| Zona | % FC máx (padrão, configurável) | Nome | Claro / escuro |
|---|---|---|---|
| Z1 | 50–60% | Muito leve | cinza `#7D8998` / `#98A2B3` |
| Z2 | 60–70% | Leve | azul `#1E88D6` / `#4DB5FF` |
| Z3 | 70–80% | Moderada | verde `#1F9D49` / `#3DD56D` |
| Z4 | 80–90% | Intensa | amarelo `#B88A00` / `#FFD23F` |
| Z5 | 90–100% | Máxima | magenta `#B5179E` / `#F06ADB` |

A escala vai de cinza a magenta **sem laranja nem vermelho**: o laranja é do treino (D1) e o vermelho é só destrutivo. Todas as cinco têm ≥ 3:1 sobre `surface` nos dois temas (claro: 3,6 · 3,8 · 3,5 · 3,2 · 5,9).

Contraste dos tons de texto e preenchimento (calculado): `training` sobre branco 5,2:1 e sobre `#1C1C1E` 8,1:1; branco sobre `trainingFill` 4,5:1; `attention` sobre branco 6,2:1.

Tipo de treino (`FJWorkoutKind`): **Força** = laranja do treino, símbolo `dumbbell.fill`; **Aeróbico** = turquesa `#0B7F83` / `#5AD1D6`, símbolo `figure.run`. Sempre com rótulo.

Estados (`FJTone`): a cor vai no símbolo e no fundo a 14%; o texto continua primário.

| Tom | Claro / escuro | Significa | Exemplos |
|---|---|---|---|
| `success` | `#18803A` / `#30D158` | Concluído, salvo | Refeição feita, treino gravado no Saúde, descanso concluído |
| `attention` | `#7A5D00` / `#FFD60A` | Ajustado, parcial, precisa de você | Feita com alteração, concluído parcialmente, Saúde não conectado, sessão antiga em aberto |
| `destructive` | `#D12B20` / `#FF6259` | Só destrutivo e erro | Descartar sessão, apagar tudo, falha ao salvar |
| `record` | `#8F6400` / `#FFD60A` | Recorde pessoal (mesma família amarela de `attention`; o troféu e o texto diferenciam) | Troféu no resumo e no histórico |
| `neutral` | `secondaryLabel` | Sem juízo | Pendente, pulada, fora da dieta, aquecimento |

"Fora da dieta" e "pulada" são **neutros** de propósito: o app registra, não julga.

### 2.2 Tipografia (`FJFont`)

Só estilos de texto do sistema (Dynamic Type até AX5). Números: SF Rounded + `monospacedDigit()`; mudança de número usa `contentTransition(.numericText())`.

| Token | Estilo | Uso |
|---|---|---|
| `numberHero` | largeTitle rounded bold (34) | Tempo da sessão, kcal do dia, RPE escolhido |
| `numberLarge` | title rounded semibold (28) | Carga da série atual (`NumberStepperField`) |
| `numberMedium` | title3 rounded semibold (20) | `FJMetricCell`, séries não atuais, células do RPE |
| `numberBody` | body rounded medium (17) | Número em linha de lista, FC ao vivo, acessório |
| `numberCaption` | footnote rounded medium (13) | Eixos, legendas, "96 / 150 g" |
| `unit` | subheadline rounded medium | "kg", "reps", "bpm", "s" |
| `timer(size:)` | 60 pt semibold rounded, `@ScaledMetric` relativo a largeTitle, teto 96 pt, `minimumScaleFactor(0.5)` | Descanso, sustentação, cronômetro de cardio |
| `screenTitle` / `sectionTitle` / `cardTitle` | largeTitle bold / title3 semibold / headline | Títulos |
| `body` / `label` / `caption` / `overline` | body / subheadline / footnote / caption semibold | Texto, rótulos, metadados, "DESCANSO" |

Formatos: carga com vírgula decimal local e sem zeros à direita ("32,5 kg"); tempo "m:ss" ou "h:mm:ss" (`FJFormat.clock`); prescrição "4 × 8–12"; faixa com meia-risca; peso corporal "PC", "PC +10 kg", "PC −20 kg"; AMRAP "máx.".

### 2.3 Espaçamento, raios, tamanhos (`FJSpacing`, `FJRadius`, `FJSize`)

| Token | Valor |
|---|---|
| `FJSpacing` xxs / xs / s / m / l / xl / xxl | 2 / 4 / 8 / 12 / 16 / 24 / 32 pt |
| `screenMargin` · `cardGap` · `sectionGap` | 16 · 12 · 24 pt |
| `FJRadius` chip / field / card / panel | 10 / 12 / 20 / 28 pt, sempre contínuos; cápsula em botões e chips de vidro |
| `FJSize.minTap` | 44 pt |
| `FJSize.stepperButton` | 48 pt |
| `FJSize.setCheck` | 52 pt |
| `FJSize.secondaryButton` · `FJSize.primaryButton` | 48 · 56 pt (alturas mínimas) |
| `FJSize.progressRing` | 72 pt |

### 2.4 Hápticos (`FJHaptic`, via `sensoryFeedback`)

| Evento | Háptico |
|---|---|
| Série concluída (`setCompleted`) | impacto médio |
| Exercício concluído (`exerciseCompleted`) | impacto forte |
| Descanso/sustentação terminou (`timerFinished`) | aviso (duplo) + som opcional (Ajustes) |
| +/− em carga/reps (`stepUp`/`stepDown`) | incremento / decremento |
| Chip, RPE, segmento (`selection`) | seleção |
| Sessão salva, recorde (`celebration`) | sucesso |
| Erro ao salvar (`error`) | erro |

Desfazer um check não vibra (`fjHaptic(_:trigger:when:)`). Hápticos respeitam o ajuste do sistema; "Hápticos na sessão" em Ajustes desliga os da sessão.

### 2.5 Movimento (`FJMotion`, `.fjAnimation(_:value:)`)

| Token | Curva | Uso |
|---|---|---|
| `structure` | `.smooth(duration: 0.4, extraBounce: 0.1)` | Expandir/recolher exercício, doca trocar de modo, minimizar sessão |
| `value` | `.snappy(duration: 0.25)` | Check, barra/anel de progresso, número |
| `press` | `.easeOut(duration: 0.08)` | Resposta ao toque |
| `reduced` | `.easeInOut(duration: 0.2)` | Substitui todas com Reduzir Movimento |

Com Reduzir Movimento: sem zoom/matched geometry na transição sessão ↔ acessório (vira esmaecimento), sem contagem animada de dígitos nem troca animada de símbolo (`.fjNumericTransition()` e `.fjSymbolTransition()` viram identidade — nenhuma tela chama `contentTransition` direto), sem confete no recorde (fica o troféu estático). Nenhuma animação em laço em lugar nenhum.

---

## 3. Arquitetura de informação e navegação

```
TabView (vidro do sistema, tabBarMinimizeBehavior(.onScrollDown))
├─ Hoje ──────── avatar → Ajustes (sheet) · "+" → Registrar comida (sheet)
├─ Treinos ───── Programa ativo → Ficha → Editor de ficha → Prescrição
│                Biblioteca → Exercício (mídia, evolução)
│                Histórico → Sessão (detalhe, gráfico de FC)
│                Programas → Programa (duplicar, reativar) · "+" Criar programa (sheet)
├─ Dieta ─────── Dia (linha do tempo) · "+" Registrar comida · Plano → Editor de plano
│                Histórico · Favoritos
├─ Saúde ─────── Dia | Tendências → Treino (detalhe com gráfico de FC)
└─ Coach (fase 2; quando entrar, Ajustes continua no avatar de Hoje)

Sessão de treino: fullScreenCover sobre o TabView
   ⇅ minimiza para tabViewBottomAccessory (FJSessionAccessory), visível em todas as abas
   └─ Encerramento (push dentro da sessão) → fecha a sessão
```

Regras:

- Cada aba tem seu `NavigationStack` e título grande; a aba ativa tinge com a cor da área (`.tint`). Tocar na aba já selecionada volta à raiz.
- **Sheets** para criar/registrar (programa, exercício, registro de comida, ajustes): `.large`, com "Cancelar" e ação de confirmar na toolbar; arrastar para fechar pede confirmação se houver alterações. **Push** para detalhar e editar algo existente.
- **"+" global** (SPEC §5.2): botão "+" na toolbar de **Hoje** e de **Dieta**, abrindo a sheet "Registrar comida". Sem botão flutuante, para não competir com o acessório da sessão.
- **Sessão**: uma só. Enquanto existe sessão em andamento, o acessório fica acima da tab bar em todas as abas; tocar nele reabre a tela cheia. "Iniciar treino" em qualquer lugar vira "Continuar treino".
- Menus de contexto (`contextMenu`) e ações de deslizar repetem ações que também existem visíveis em outro lugar; nada é exclusivo de gesto.

---

## 4. Telas

Estados usados em todas: **vazio/primeiro uso** (`FJEmptyState`: símbolo, uma frase, uma ação), **carregando** (`FJLoadingState` dentro do cartão que espera dado; dados locais do SwiftData não mostram carregamento — só Saúde, mídia e importação), **erro** (`FJBanner` destrutivo com "Tentar de novo"; alerta só se a ação do usuário falhou), **permissão negada** (`FJBanner` de atenção com "Abrir Ajustes"; o resto da tela funciona), **conteúdo**, **em andamento/retomada**.

### 4.1 Hoje

Título grande "Hoje" com a data por extenso como subtítulo ("quarta, 11 de novembro"). Toolbar: "+" (registrar comida) e avatar (Ajustes). Rolagem de cartões, nesta ordem:

1. **Treino do dia** (`FJCard`, o maior da tela).
   - Sobrelinha: nome do programa · "semana 3 de 8" quando há fim.
   - Letra da ficha em selo quadrado na cor da ficha + nome ("A — Peito e tríceps") em `cardTitle`.
   - Linha de metadados: "6 exercícios · ~55 min · última vez há 3 dias".
   - Até 3 exercícios em uma linha cada ("Supino reto · 4 × 8–12 · 32,5 kg"), depois "+3".
   - `FJPrimaryButton("Iniciar treino", "play.fill")`; abaixo, par de `FJSecondaryButton`: "Outra ficha" (sheet com as fichas do programa) e "Treino livre".
2. **Próxima refeição** (`FJCard`): horário em `numberMedium`, nome, resumo dos itens em uma linha, `FJCheckButton` verde à direita ("Feita") e link "Ajustar". Toque no cartão vai para a aba Dieta com a refeição expandida.
3. **Resumo do dia** (`FJCard`): anel de kcal (ingerido/meta) + `FJGoalBar` de proteína e água à direita; abaixo, `FJMetricGrid`: Treino (min), Energia ativa (kcal), FC em repouso (bpm).

| Estado | O que muda |
|---|---|
| Primeiro uso (sem programa e sem dieta) | Cartão 1 vira `FJEmptyState` "Monte seu primeiro programa" + ação "Criar programa" e link "Começar com um exemplo (ABC)"; "Treino livre" continua disponível. Cartão 2 vira "Cadastre sua dieta" + "Criar dieta". Cartão 3 mostra só o que existe. Nenhum pedido de permissão. |
| Modo livre | Cartão 1 lista todas as fichas (linha tocável cada), a menos recente primeiro com etiqueta "Há mais tempo"; o botão principal inicia a destacada. |
| Modo sequencial | Etiqueta "Próxima da sequência" na ficha sugerida. |
| Modo semanal, dia sem ficha | Cartão "Descanso" (símbolo `moon.zzz`), texto "Próximo treino: quinta — B". Sem botão principal; `FJSecondaryButton("Treinar mesmo assim")` abre a escolha de ficha. |
| Sessão em andamento | Cartão 1 vira "Treino em andamento": tempo decorrido em `numberHero`, "3 de 6 exercícios", `FJPrimaryButton("Continuar treino")`. |
| Sessão concluída hoje | Cartão 1 compacto: check + "Treino concluído" + duração, volume, RPE; toque abre o detalhe; link "Iniciar outro treino". |
| Sem dieta ativa | Cartão 2 vira convite discreto; anel de kcal mostra só o ingerido, sem meta (`progress: nil`). |
| Todas as refeições resolvidas | Cartão 2: "Refeições do dia concluídas" + total. |
| Saúde não conectado | Energia e FC em repouso mostram "—"; uma linha "Conectar ao Saúde" no rodapé do cartão 3 (dispensável; não é um bloqueio). |
| Saúde negado | Mesmo "—"; a linha vira "Sem acesso ao Saúde · Abrir Ajustes". |
| Itens sem kcal | Sob o anel: "3 itens sem calorias" em `caption`. |

### 4.2 Treinos

Título grande "Treinos". Toolbar: "+" (menu: Novo programa, Nova ficha no programa ativo, Novo exercício).

1. **Programa ativo** (`FJCard`): nome, etiqueta do objetivo (`FJTag`), modo de agenda com símbolo (Livre `shuffle`, Sequencial `arrow.triangle.2.circlepath`, Semanal `calendar`), "semana 3 de 8", aderência da semana no modo semanal ("2 de 4 treinos"). Menu "…": Editar programa, Duplicar, Arquivar.
2. **Fichas** (seção): um cartão por ficha — selo com letra/cor, nome, "6 exercícios · ~55 min", dias da semana (modo semanal: 7 círculos S T Q Q S S D, os ativos preenchidos), "última vez: seg, 9 nov". Toque abre a **ficha** (pré-visualização somente leitura com `FJPrimaryButton("Iniciar treino")` na base e "Editar" na toolbar). Arrastar reordena (define a sequência no modo rodízio). Menu de contexto: Iniciar, Editar, Duplicar, Excluir.
3. **Atalhos** (lista inset): Biblioteca de exercícios · Histórico · Programas.

**Programas** (push): seções "Ativo", "Anteriores", "Arquivados". Linha: nome, período, nº de fichas, origem (manual/IA/importado/duplicado). Detalhe de um programa anterior é somente leitura, com `FJSecondaryButton` "Duplicar e editar" e "Reativar".

**Criar/editar programa** (sheet `.large`, `Form`):

1. Nome (obrigatório), objetivo (chips de seleção única + texto livre), início, fim opcional, observações.
2. **Modo de agenda**: três cartões de opção empilhados, cada um com símbolo, título e uma frase, seleção com check:
   - Livre — "Escolho a ficha no dia."
   - Sequencial — "A → B → C → A… O app sugere a próxima."
   - Semanal — "Cada ficha tem seus dias da semana."
3. **Fichas**: lista com "Adicionar ficha" (nome, letra, cor). No modo semanal cada ficha mostra os 7 círculos de dia (semana começa na segunda); dia já usado por outra ficha aparece com ponto e pode ser compartilhado. Reordenar define o rodízio.
4. "Salvar". Se já existe programa ativo: diálogo "Ativar *Novo* agora? *Atual* vai para o histórico." [Ativar] [Só salvar].

| Estado | O que muda |
|---|---|
| Sem programa | `FJEmptyState` "Nenhum programa ainda" + "Criar programa"; atalhos continuam (Biblioteca funciona sem programa). |
| Programa sem fichas | Cartão do programa + `FJEmptyState` "Adicione a primeira ficha". |
| Ficha sem exercícios | Cartão com aviso "Sem exercícios" e ação "Editar"; "Iniciar" abre treino livre com o nome da ficha. |
| Sessão em andamento | A ficha em execução mostra etiqueta "Em andamento"; "Iniciar" nas outras fica desabilitado com explicação ao toque ("Finalize o treino em andamento primeiro"). |
| Programa vencido (fim no passado) | `FJBanner` de atenção no cartão: "Este programa terminou em 31/10" + "Estender" / "Criar novo". |
| Nome vazio ao salvar | Campo marcado, "Salvar" desabilitado, rodapé "Dê um nome ao programa". |

### 4.3 Editor de ficha

Push a partir da ficha. `List` nativa em modo de edição permanente (alças de arrastar à direita). Toolbar: "OK". Base: `FJPrimaryButton("Adicionar exercício")` fixo (abre a Biblioteca como seletor múltiplo).

- **Cabeçalho**: nome, letra/cor, dias (modo semanal), observações, duração estimada calculada ("~55 min").
- **Linha de exercício**: miniatura da mídia (ou símbolo do equipamento), nome, resumo da prescrição em uma linha ("4 × 8–12 · 32,5 kg · 90 s"), etiquetas de tipo de série quando não for "válida". Toque abre a **prescrição**. Deslizar: Duplicar, Mover/copiar para outra ficha, Remover.
- **Agrupar** (bi-set, tri-set, circuito): "Selecionar" na toolbar → marcar 2+ exercícios vizinhos → "Agrupar". O tipo sai da contagem (2 = bi-set, 3 = tri-set, 4+ = circuito). O grupo aparece com um trilho vertical laranja à esquerda unindo as linhas, rótulo "Bi-set" no topo e a linha "Descanso ao fim da rodada: 90 s". "Desagrupar" no menu do rótulo.

**Prescrição do exercício** (push, `Form`):

1. Topo: nome, mídia em 1 toque, "carga atual 32,5 kg · inicial 30 kg".
2. Seletor segmentado **"Séries iguais" | "Série a série"**.
   - **Iguais (em bloco)**: número de séries (stepper), tipo de série (menu), repetições, carga, descanso. Editar aqui aplica a todas.
   - **Série a série**: tabela de linhas "1 · Aquecimento · 12 × 20 kg · 60 s"; toque expande a linha com os mesmos campos; "Adicionar série"; deslizar remove; "Aplicar a todas" no menu da linha. Trocar de "série a série" para "iguais" com séries diferentes pede confirmação.
3. Campos (mudam com o tipo de medida do exercício):
   - **Tipo de série**: aquecimento, preparatória, válida, drop-set, rest-pause, até a falha, back-off.
   - **Repetições**: segmentado **Fixas | Faixa | AMRAP**. Fixas: um `NumberStepperField`. Faixa: dois (mín. "piso" e máx.), validação mín < máx. AMRAP: sem campo, texto "máximo possível".
   - **Isometria** (`isometric`, ou "Sustentação" opcional por série): `NumberStepperField` em segundos, passo 5.
   - **Carga**: `NumberStepperField` com passo **0,5 kg** (D3; configurável em Ajustes). Segmentado **kg (ou lb) | Peso corporal**. Peso corporal mostra `NumberStepperField` com sinal ("Lastro +10 kg", "Assistência −20 kg", 0 = só o corpo). Unilateral mostra "por lado".
   - **Descanso**: chips 30 · 45 · 60 · 90 · 120 · 180 s + "Outro" (stepper de 5 s).
   - **Cadência**: campo curto com máscara "3-1-1-0", opcional.
   - **Esforço alvo**: segmentado Nenhum | RIR | RPE + stepper (RIR 0–5, RPE 1–10).
   - **Cardio** (`timeOrDistance`): duração (min), distância (km), nível/velocidade/inclinação, zona de FC alvo (seletor Z1–Z5 com `FJHeartRateZoneBadge`).
   - **Observações**: texto livre.

| Estado | O que muda |
|---|---|
| Ficha nova | `FJEmptyState` "Adicione exercícios" + botão principal. |
| Exercício sem prescrição | Linha mostra "Definir séries" em atenção; a ficha pode ser salva; na sessão começa com 1 série vazia. |
| Faixa inválida | Campo marcado, rodapé "O mínimo deve ser menor que o máximo"; não bloqueia sair, mas não salva a linha inválida (mantém o valor anterior). |
| Sessão em andamento desta ficha | `FJBanner` neutro: "Mudanças valem para os próximos treinos. O treino em andamento não muda." |
| Programa somente leitura | Sem alças, sem botão principal; `FJBanner` "Programa anterior — Duplicar e editar". |

### 4.4 Biblioteca de exercícios e detalhe

**Lista**: `.searchable` (busca por nome, pt-BR/en), fileira horizontal de `FJFilterChip` (grupo muscular; menu "Equipamento") logo abaixo da barra, `List` com seções "Meus exercícios" e "Catálogo". Linha: miniatura 56 pt (ou símbolo do equipamento em fundo `fill`), nome, "Peitoral · Barra". Toolbar "+" cria exercício (sheet: nome, grupos primário/secundários, equipamento, lateralidade, tipo de medida explicado com exemplo). Como seletor (vindo do editor ou da sessão): seleção múltipla com check e botão "Adicionar (3)".

**Detalhe**:

1. **Mídia** no topo: carrossel paginado 16:9 com cantos 20 pt. Foto abre em tela cheia; vídeo da galeria toca com `VideoPlayer`; YouTube/Vimeo mostram miniatura com botão de play e o selo do serviço — tocar carrega o embed no lugar. Sem mídia: área tracejada "Adicionar foto ou vídeo".
2. Menu "Adicionar mídia": Foto da galeria · Câmera · Vídeo da galeria · Link de vídeo (campo de URL; reconhece YouTube/Vimeo e mostra a miniatura antes de salvar; outra URL vira "Abrir no Safari").
3. Informações: grupos (etiquetas), equipamento, lateralidade, tipo de medida, observações.
4. **Evolução** (resumo): melhor série, última vez, minigráfico; "Ver evolução" abre §4.8.
5. "Usado em": fichas que contêm o exercício.

| Estado | O que muda |
|---|---|
| Busca sem resultado | `ContentUnavailableView.search` + "Criar exercício '*texto*'". |
| Copiando vídeo da galeria | Miniatura com progresso circular e "Copiando…"; cancelável. |
| Vídeo acima do limite (60 s / 200 MB) | Alerta: "Vídeo maior que o limite (60 s). Corte no Fotos ou aumente o limite em Ajustes." |
| Embed falhou / sem rede | No lugar do player: miniatura esmaecida + "Não foi possível tocar aqui" + `FJSecondaryButton("Abrir no YouTube")`. |
| Fotos/Câmera negados | `FJBanner` de atenção na folha de mídia + "Abrir Ajustes"; link de vídeo continua funcionando. |
| Exercício do catálogo | Nome e classificação não editáveis; mídia e observações do usuário sim; "Duplicar para editar". |

### 4.5 Sessão de treino — a tela mais importante

`fullScreenCover`. Três regiões fixas; só o meio rola.

```
┌──────────────────────────────────┐
│ (⌄)   32:14 · 3/6      ♥ 128 Z3 (…)│  barra superior (vidro do sistema): leitura
├──────────────────────────────────┤
│ ✓ Supino reto        4 × 10 · 32,5│  concluído (recolhido)
│ ┌──────────────────────────────┐ │
│ │ ▶ Supino inclinado halter  ▣ │ │  exercício atual (expandido)
│ │   última vez: 3 × 10 com 24 kg│ │
│ │ 1  24 kg · alvo 8–12     (✓) │ │
│ │ 2  alvo 8–12 · RIR 2         │ │  série atual: carga grande
│ │    (−)   26 kg   (+)     ( ) │ │
│ │    [+ reps]                  │ │  reps realizadas: opcional
│ │ 3  24 kg · alvo 8–12     ( ) │ │
│ │ + Série   Anotação           │ │
│ └──────────────────────────────┘ │
│ ○ Crucifixo          3 × 12–15   │  pendentes (recolhidos)
├──────────────────────────────────┤
│  [      Concluir série 2      ]  │  doca de ação (vidro), metade inferior
└──────────────────────────────────┘
```

**Barra superior** (toolbar do sistema, só leitura + ações raras):
- Esquerda: `chevron.down` — minimizar (também arrastar a tela para baixo).
- Centro: tempo decorrido (`numberBody` semibold, calculado por `startDate`) e "3/6" exercícios; barra de progresso fina (2 pt) na borda inferior da barra.
- Direita: `FJHeartRateBadge` (bpm + zona; "—" com `heart.slash` quando indisponível — tocar explica: "Sem dados do Apple Watch agora") e menu "…": Pausar treino · Adicionar exercício · Reordenar · Anotação da sessão · Dor/desconforto · Finalizar treino · Descartar treino (destrutivo).

**Lista de exercícios** (`ScrollView` de `FJCard`s; rola sozinha para o exercício atual):
- **Recolhido**: símbolo de estado (○ pendente, ✓ concluído preenchido, ◐ parcial, » pulado), nome, resumo ("4 × 8–12 · 32,5 kg"; concluído mostra o realizado). Toque expande e o torna o atual.
- **Expandido (atual)**:
  - Cabeçalho: nome em `cardTitle`; miniatura da mídia à direita (1 toque abre a mídia em sheet `.medium`); etiquetas (Bi-set, Unilateral); linha "última vez: 3 × 10 com 24 kg" e observação da prescrição ("banco 30°"); cadência e esforço alvo quando houver ("3-1-1-0 · RIR 2").
  - **Linhas de série**: número (ou etiqueta do tipo: "Aq", "Drop"…), valores, `FJCheckButton` à direita (52 pt).
    - **Série atual** (a primeira pendente, ou a que o usuário tocou): linha alta com **um** `NumberStepperField` de Carga em destaque (28 pt, passo 0,5 kg — D3) e o check à direita. O **alvo aparece sempre como prescrito** — "alvo 8–12", "alvo 10", "alvo máx." — com RIR/RPE e cadência quando houver (D2). Abaixo, discreto, `FJOptionalNumberField` "**+ reps**": reps realizadas começam vazias e são opcionais; tocar abre o teclado numérico (com OK); preenchido mostra "10 reps" e um × para limpar. Tocar no número da carga abre o teclado decimal com "OK" na barra do teclado.
    - **Outras séries**: compactas, uma linha. Pendente: "24 kg · alvo 8–12" em secundário. Concluída sem reps: "24 kg · alvo 8–12" em primário com check (vale "feita dentro do alvo"). Concluída com reps informadas: "24 kg × 9". Tocar nos valores torna a série a atual (editar depois de concluída mantém o check e o `completedAt`).
    - Check: um toque conclui a série **com a carga exibida** (sem exigir reps) → háptico → a doca vira **descanso**; o "+ reps" continua acessível na série recém-concluída durante o descanso. Tocar de novo desfaz (sem confirmação, sem háptico; o descanso em curso é cancelado).
    - Deslizar a linha: Remover série · Mudar tipo.
  - Rodapé do cartão: "+ Série" (copia a última), "Anotação", menu "…" do exercício: Trocar exercício (abre a Biblioteca filtrada pelo mesmo grupo; a substituição fica registrada: "no lugar de Supino reto") · Pular (motivo opcional em chips: Equipamento ocupado, Dor, Tempo, Outro) · Marcar como concluído (com pendentes = "Concluído parcialmente") · Dor/desconforto (local + 0–10) · Ver evolução.
- **Bi-set/circuito**: cartões do grupo unidos pelo trilho laranja e rótulo "Bi-set · rodada 2 de 3". A série atual alterna A → B; o descanso só dispara ao fim da rodada (entre A e B a doca mostra "Agora: B — Tríceps corda").
- **Isométrico**: a série atual mostra `NumberStepperField` "Sustentação" (s) e carga opcional; a doca oferece "Iniciar sustentação".
- **Cardio**: a linha atual mostra campos Distância e Nível/Velocidade/Inclinação; a doca vira cronômetro.

**Doca de ação** (`safeAreaInset(edge: .bottom)`, vidro; é onde o polegar está). Um modo por vez, transição com `FJMotion.structure`:

| Modo | Conteúdo |
|---|---|
| Série | `FJPrimaryButton("Concluir série 2")` — faz o mesmo que o check da série atual. Sublinha acima: "Supino inclinado · 26 kg · alvo 8–12". |
| Descanso | `FJRestTimerView`: "DESCANSO", o que vem a seguir ("Série 3 de 4 · 26 kg · alvo 8–12"), tempo em 60 pt, barra, **−15 s · Pular · +15 s** (52 pt de altura). Ao zerar: háptico + som opcional + anúncio no VoiceOver, rótulo "Descanso concluído", tempo parado em 0:00 e o botão central vira "Continuar"; a doca volta ao modo Série ao tocar em Continuar/qualquer check, ou sozinha após 10 s. A lista continua utilizável durante o descanso (ajustar a próxima carga, informar as reps da série feita). |
| Sustentação | Antes: `FJPrimaryButton("Iniciar sustentação")`. Durante: contagem regressiva em 60 pt com 3 s de preparação ("3, 2, 1"), botão "Parar" (registra o tempo real e conclui a série); ao zerar: háptico, continua contando o excedente até "Parar". |
| Cardio | Cronômetro em 60 pt, "Iniciar" / "Pausar" / "Concluir". |
| Próximo | Exercício concluído: "Próximo: Crucifixo" (`FJPrimaryButton`), 1 toque expande o próximo. |
| Finalizar | Tudo concluído ou pulado: `FJPrimaryButton("Finalizar treino", "flag.checkered")`. Com pendentes, "Finalizar treino" continua no menu "…". |

| Estado | O que muda |
|---|---|
| Treino livre (sem ficha) | Lista vazia: `FJEmptyState` "Adicione o primeiro exercício"; doca: `FJPrimaryButton("Adicionar exercício")`. |
| Abrindo | Sem tela de carregamento: a sessão abre com o snapshot local (< 300 ms). |
| FC ao vivo indisponível (sem Watch, negado, simulador) | Badge "—"; nada mais muda. Nunca "0 bpm". |
| FC conectando | Coração pulsando uma vez + "—" (sem laço com Reduzir Movimento). |
| Falha ao salvar uma série | A linha volta ao estado anterior, háptico de erro, `FJBanner` destrutivo no topo da lista: "Não foi possível salvar. Tente de novo." |
| Retomada (app fechado e reaberto) | Volta como estava (tela cheia ou minimizada), tempo e descanso recalculados por data; descanso que venceu fora do app aparece como "Descanso concluído". |
| Pausada (pelo relógio ou pelo menu "…") | Tempo congelado com "Pausado" na barra superior; a doca mostra `FJPrimaryButton("Retomar treino")`; o descanso em curso congela e some da doca. O acessório mostra o símbolo de pausa e "pausado". |
| Sessão antiga em aberto (> 4 h sem série) | Ao abrir o app: sheet "Você tem um treino em aberto desde ontem, 19:40" — Continuar · Finalizar na hora da última série · Descartar. |
| Minimizada | `FJSessionAccessory` acima da tab bar: símbolo, nome da ficha, "Supino inclinado · série 2 de 4", tempo; durante o descanso mostra a contagem regressiva e "descanso". Toque reabre. |
| Tela bloqueada / segundo plano | Notificação local ao fim do descanso (permissão pedida no contexto, no primeiro descanso; negada = só háptico em primeiro plano). No ciclo 6 a Live Activity assume. |
| Controlada pelo Apple Watch | Nada muda na tela: o estado chega por snapshot e a lista/doca acompanham (série concluída no relógio aparece marcada aqui). Selo `applewatch` ao lado da FC enquanto o relógio está conectado. |


### 4.6 Encerramento

Push dentro da sessão ao tocar "Finalizar treino" (o relógio para na última série concluída ou no toque — o que vier depois; "Voltar ao treino" na toolbar desfaz). Rolagem de cartões; `FJPrimaryButton("Salvar treino")` fixo na base.

1. **Resumo**: nome da ficha, data, `FJMetricGrid`: Duração · Volume (kg) · Séries (18/20) · Exercícios (5/6) · FC média · Energia (as duas últimas "—" sem Saúde).
2. **Recordes** (só se houver): linhas com troféu (`record`): "Supino reto — maior carga: 34 kg", "Agachamento — 1RM estimado: 112 kg". Háptico de sucesso ao aparecer.
3. **Pulados/parciais** (só se houver): lista neutra com o motivo.
4. **Como foi o treino?** — `FJRPEScale` (1–10, duas fileiras de 5, células de 52 pt; valor escolhido grande + rótulo: 1 Muito leve · 2 Leve · 3 Moderado · 4 Um pouco difícil · 5–6 Difícil · 7–8 Muito difícil · 9 Quase máximo · 10 Máximo). Opcional: tocar de novo desmarca. Abaixo: "Energia" (5 símbolos de bateria/rosto neutro, opcional) e "Nota" (texto).
5. **Atualizar carga atual**: uma linha por exercício cuja carga usada difere da atual — "Supino reto: 30 → 32,5 kg" com `Toggle`. Ligado por padrão só se todas as séries válidas foram concluídas; caso contrário desligado, com "nem todas as séries concluídas". Sem diferenças: o cartão não aparece.
6. **Saúde**: linha de estado — "Será gravado no Saúde como Força tradicional" (conectado) · "Conectar ao Saúde" (primeira vez: explica em uma frase e abre o pedido do sistema ao tocar; salvar sem conectar é permitido) · "Sem acesso ao Saúde — o treino fica só no FitJourney" (negado).

Menu "…": Descartar treino (destrutivo; diálogo "Descartar este treino? Nada será salvo no histórico.").

| Estado | O que muda |
|---|---|
| Nenhuma série concluída | Em vez do resumo: "Nenhuma série registrada" + "Descartar treino" como ação principal e "Voltar ao treino". |
| Salvando | Botão com `isLoading`; se a gravação no Saúde falhar, o treino é salvo no app e um aviso diz "Salvo. Não foi possível gravar no Saúde" + "Tentar de novo" no detalhe. |
| Salvo | A sessão fecha com esmaecimento/zoom para o cartão "Treino concluído" em Hoje. |
| Treino do Watch no mesmo horário | Depois de salvar, no detalhe: `FJBanner` "Encontramos um treino do Apple Watch no mesmo horário" — Vincular · Não é o mesmo. Nunca soma. |

### 4.7 Histórico

Push a partir de Treinos. Topo: seletor segmentado **Lista | Calendário**.

- **Lista**: seções por mês; linha: dia ("seg 9"), selo da ficha, nome, "52 min · 8.420 kg", RPE ("RPE 7"), troféu se houve recorde, coração se há FC, "editado" quando corrigido.
- **Calendário**: mês com ponto na cor da ficha nos dias treinados; tocar no dia lista as sessões abaixo. Rodapé: frequência semanal (barras das últimas 8 semanas) e aderência no modo semanal ("3 de 4 previstos").
- **Detalhe da sessão**: resumo (`FJMetricGrid`), gráfico de FC com faixas por exercício (§4.11), intensidade e nota, exercícios com todas as séries (realizado em primário, alvo em secundário), pulados, substituições, dor/desconforto. Toolbar "Editar": as séries viram editáveis (`NumberStepperField` em sheet por série); ao salvar, etiqueta "editado" + data. Menu: Excluir sessão (destrutivo).

| Estado | O que muda |
|---|---|
| Vazio | `FJEmptyState` "Seus treinos aparecem aqui" + "Iniciar treino". |
| Muitas sessões (1.000+) | Lista preguiçosa por mês; sem carregamento visível. |
| Sem FC | No lugar do gráfico: `FJBanner` neutro "Sem frequência cardíaca neste treino". |
| Sessão de programa arquivado | Abre normalmente; nome do programa em secundário. |

### 4.8 Evolução por exercício

Push a partir do exercício, da sessão ou do histórico.

1. Seletor segmentado de métrica: **Carga | Volume | 1RM est.**; fileira de `FJFilterChip` de período: 1M · 3M · 6M · 1A · Tudo.
2. Gráfico (Swift Charts, dentro de `FJCard`): linha + pontos na cor do treino; recordes com ponto maior e troféu; arrastar seleciona um ponto e mostra data + valor no cabeçalho do cartão (não em balão de vidro). Eixo Y começa perto do mínimo real, não em zero, para carga/1RM; em zero para volume.
3. **Melhor série** e **Última vez** (`FJMetricCell`): "34 kg × 8", "32,5 kg · há 3 dias" (reps só quando informadas).
4. Lista de sessões: data, séries realizadas em uma linha ("32,5 kg · 4 séries" ou, com reps informadas, "32,5 × 10, 10, 9, 8").

Estados: um único registro → ponto isolado + "Registre mais treinos para ver a evolução"; nenhum → `FJEmptyState`. Isométrico troca Carga por Tempo; cardio mostra Distância | Duração | Ritmo.

### 4.9 Dieta — dia

Título grande "Dieta". Toolbar: "+" (registrar comida), menu "…" (Plano, Histórico, Favoritos). Sob o título: navegação de dia (‹ **Hoje, 11 nov** ›, toque abre calendário) e faixa da semana com ponto por dia (aderência).

1. **Totais do dia** (`FJCard`): anel de kcal 72 pt com o valor no centro ("1.420" e "de 2.200 kcal") + três `FJGoalBar`: Proteína, Carboidrato, Gordura (fibra em "ver mais"). Rodapé quando houver: "3 itens sem calorias" e a origem ("inclui 2 estimados").
2. **Água** (`FJCard` compacto): "1,2 / 3,0 L", fileira de copos (toque no próximo copo soma 250 ml; `−` desfaz), tamanho do copo em Ajustes.
3. **Linha do tempo**: trilho vertical à esquerda com a hora de cada refeição; cada refeição é um `FJCard`:
   - Recolhida: hora (`numberBody`), nome, resumo dos itens, kcal quando houver, etiqueta de estado.
   - **Próxima** (destacada: contorno de 1,5 pt na cor da dieta e etiqueta "Agora"/"Próxima"): expandida, itens um por linha (alimento, quantidade, kcal), substituições disponíveis com símbolo `arrow.left.arrow.right`; ações na base do cartão: `FJCheckButton` verde grande + rótulo "Feita" · "Ajustar" · "Pular".
   - **Ajustar** (sheet `.medium`→`.large`): cada item com `Toggle` (comi/não comi), quantidade em `NumberStepperField`, "Trocar por…" (substituições), "Adicionar item". Salvar marca como "Feita com alteração".
   - Registros avulsos aparecem na linha do tempo no horário em que foram comidos, com etiqueta neutra **"Fora da dieta"** (ou dentro da refeição vinculada, com "+").
4. **Observação do dia**: fome e saciedade (dois seletores de 5 pontos) + texto, opcionais.

Estados da refeição — forma + texto, não só cor:

| Estado | Marca |
|---|---|
| Pendente | círculo vazio, texto secundário |
| Próxima | contorno verde + etiqueta "Próxima" |
| Feita | check verde preenchido + "Feita 12:40" |
| Feita com alteração | check verde + etiqueta `attention` com lápis "Ajustada" |
| Pulada | símbolo » neutro + "Pulada", itens riscados |
| Atrasada (passou 1 h do horário, pendente) | continua pendente, hora em `attention` com relógio; sem alarme |

**Registrar comida** (sheet do "+", também em Hoje): campo "O que você comeu?" com foco automático e sugestões de favoritos/recentes abaixo (toque preenche tudo); quantidade (`NumberStepperField`) + unidade (menu: g, ml, unidade, colher, xícara, fatia, porção); horário (padrão agora); "Calorias e macros" recolhido (opcional); "Vincular a uma refeição" (menu; padrão "Nenhuma — fora da dieta"); grau: Informado | Estimado. `FJPrimaryButton("Registrar", area: .nutrition)`. Só o nome é obrigatório.

| Estado | O que muda |
|---|---|
| Sem dieta ativa | Totais mostram só o ingerido (sem metas); no lugar da linha do tempo: `FJEmptyState` "Cadastre sua dieta" + "Criar dieta"; o "+" funciona (tudo entra como avulso, sem a etiqueta "fora da dieta"). |
| Dia sem refeições no plano (variação por dia) | "Nenhuma refeição planejada para hoje" + registros avulsos. |
| Dia passado | Mesma tela, editável; refeições pendentes aparecem como "Sem registro" (neutro), não "pulada". |
| Dia futuro | Somente leitura do plano; sem checks. |
| Metas ausentes | `FJGoalBar` sem trilho, só o valor. |
| Lembretes negados | Em Plano: `FJBanner` "Notificações desativadas" + "Abrir Ajustes"; a linha do tempo não muda. |

### 4.10 Editor de plano alimentar

Push a partir de Dieta → Plano (ou sheet ao criar). `Form`:

1. **Plano**: nome, objetivo, início/fim, autor (Eu | Nutricionista | IA).
2. **Metas diárias** (todas opcionais): kcal, proteína, carboidrato, gordura, fibra, água — campos numéricos com unidade; vazio = sem meta.
3. **Variação**: segmentado **Todos os dias | Por dia da semana**. Por dia: abas roláveis Seg…Dom com "Copiar de…" para replicar um dia.
4. **Refeições** (lista ordenada por horário): hora, nome, nº de itens, kcal. Toque abre a refeição: nome (sugestões: Café da manhã, Lanche, Almoço…), horário, lembrete (`Toggle`; primeiro uso pede notificações no contexto), itens (arrastar reordena).
5. **Item**: alimento (com sugestões de favoritos), quantidade + unidade, kcal/macros opcionais, observação, **Substituições** (lista de alternativas com os mesmos campos).
6. Salvar → se há dieta ativa: "Ativar *Nova* agora? *Atual* vai para o histórico."

Estados: plano sem refeições (`FJEmptyState` "Adicione a primeira refeição"); horário duplicado (permitido; ordena pelo nome); dieta anterior somente leitura com "Duplicar e editar" / "Reativar".

### 4.11 Saúde

Título grande "Saúde". Seletor segmentado **Dia | Tendências**; navegação de dia como na Dieta.

**Dia**:

1. **Frequência cardíaca do dia** (`FJCard`): gráfico 24 h (Swift Charts) — barras de mín–máx por intervalo de 15 min na cor da saúde; **treinos sobrepostos** como faixas verticais atrás do gráfico (laranja = Força, turquesa = Aeróbico, 18% de opacidade) com o símbolo do tipo no topo da faixa. Cabeçalho: "58–164 bpm" e FC em repouso. Arrastar mostra hora + bpm no cabeçalho.
2. **Treinos do dia**: linha por treino — símbolo, nome ("A — Peito e tríceps" ou "Corrida ao ar livre"), `FJTag` **Força**/**Aeróbico**, origem ("FitJourney" · "Apple Watch"), duração, FC média, kcal. Toque abre o detalhe.
3. **Força x aeróbico**: barra empilhada de minutos do dia + as duas `FJMetricCell`; abaixo, comparação com a semana (7 barras empilhadas, hoje destacado).
4. **Energia ativa** e **Passos** (`FJMetricGrid`).

**Tendências**: minutos por tipo por semana (barras empilhadas, 8 semanas), FC média por treino (pontos), FC em repouso (linha, 30/90 dias), cada um em seu `FJCard` com o valor atual no cabeçalho.

**Detalhe do treino (sessão) com gráfico de FC por exercício**:

1. Cabeçalho: nome, data, hora, `FJTag` do tipo, origem.
2. `FJMetricGrid`: Duração · FC média · FC máx · Energia · Volume · RPE.
3. **Gráfico de FC × tempo** (`FJCard`, 240 pt de altura):
   - Linha de FC na cor da saúde, 2 pt; lacunas de dado ficam como lacunas (sem interpolar).
   - **Faixas por exercício**: retângulos verticais do início (1ª série) ao fim (última série concluída), alternando dois tons neutros (`fill` e transparente), cada um com o **número do exercício** em um selo no topo; a legenda numerada fica na lista abaixo. Faixas não usam cor de zona nem de área.
   - **Marcadores de série**: pontos de 6 pt sobre a linha no `completedAt` de cada série.
   - **Zonas**: linhas horizontais finas nos limites, com "Z2…Z5" no eixo direito na cor da zona + rótulo.
   - **Seleção**: tocar/arrastar mostra régua vertical e, no cabeçalho do cartão (sólido), "2 · Supino inclinado — série 3 · média 131 · máx 142 bpm". Sem seleção, o cabeçalho mostra média e máx do treino.
4. **Tempo em cada zona**: 5 barras horizontais com `FJHeartRateZoneBadge`, minutos e %.
5. **Exercícios**: lista numerada (mesmos números das faixas) com FC média/máx por exercício e séries; tocar numa linha seleciona a faixa no gráfico.

| Estado | O que muda |
|---|---|
| Saúde nunca conectado | A aba mostra `FJEmptyState` "Conecte ao app Saúde" com 3 linhas do que será lido e `FJPrimaryButton("Conectar ao Saúde", area: .health)`; abaixo, os treinos do FitJourney do dia (dados próprios) continuam visíveis sem FC. |
| Permissão negada/parcial | `FJBanner` de atenção "Sem acesso a frequência cardíaca" + "Abrir Ajustes"; cada cartão sem dado mostra "Indisponível", nunca zero nem gráfico vazio com eixo. |
| Carregando | `FJLoadingState` dentro de cada cartão ("Lendo dados do Saúde…"); os cartões com dados locais aparecem de imediato. |
| Dia sem treino | "Nenhum treino neste dia"; gráfico de FC do dia continua. |
| Treino sem FC (sem Watch) | Detalhe mostra `FJBanner` neutro no lugar do gráfico e esconde "tempo em zona". |
| Treino externo (Watch) sem sessão do app | Gráfico sem faixas por exercício; `FJBanner` "Vincular a um treino do FitJourney" quando há candidato. |
| Erro de leitura | `FJBanner` destrutivo no cartão + "Tentar de novo". |
| Simulador | Tratado como indisponível. |

### 4.12 Ajustes

Sheet `.large` a partir do avatar em Hoje. `Form` nativo:

- **Unidades**: carga (kg | lb), passo de carga (**0,5** · 1 · 2 · 2,5 · 5; padrão 0,5 kg / 1 lb), distância (km | mi), semana começa em (segunda | domingo).
- **Treino**: descanso padrão, som ao fim do descanso, notificação ao fim do descanso, hápticos na sessão, sugerir progressão (desligado), limite de vídeo.
- **Saúde**: estado ("Conectado" / "Não conectado" / "Sem acesso — abrir Ajustes do iPhone"), "Conectar ao Saúde", gravar treinos (toggle), FC máxima (calculada pela idade ou manual) e limites das 5 zonas (com `FJHeartRateZoneBadge`).
- **Dieta**: lembretes, tamanho do copo.
- **Dados**: Exportar tudo (JSON) → `ShareLink`; Importar backup (mostra o resumo do que será importado antes de confirmar); **Apagar todos os dados** (destrutivo, diálogo com o que será apagado + confirmação em dois passos).
- **Sobre**: versão, privacidade.

Estados: exportando/importando (progresso na linha, cancelável); importação inválida (alerta com o motivo, nada é alterado); sessão em andamento bloqueia "Apagar" e "Importar" com explicação.

---

## 5. Fluxos

### 5.1 Primeiro uso
1. Abre direto em **Hoje** — sem telas de boas-vindas, sem login, sem permissões.
2. Cartão de treino: "Monte seu primeiro programa" → [Criar programa] ou "Começar com um exemplo (ABC)". Cartão de dieta: "Cadastre sua dieta" → [Criar dieta]. "Treino livre" disponível desde já.
3. Criar programa segue §5.2; ao salvar, o primeiro programa é ativado sem perguntar.
4. Hoje passa a mostrar a ficha sugerida. Saúde só é oferecido no primeiro "Finalizar treino" ou na aba Saúde/Ajustes.

### 5.2 Criar programa e fichas
1. Treinos → "+" → Novo programa (sheet).
2. Nome, objetivo, datas → escolher modo de agenda (3 cartões) → "Adicionar ficha" (nome, letra, cor; dias no modo semanal) — repetir.
3. Salvar → (se havia ativo) "Ativar agora?" → volta para Treinos com o programa no topo.
4. Tocar numa ficha → "Editar" → "Adicionar exercício" → Biblioteca em seleção múltipla → "Adicionar (n)".
5. Cada exercício entra com 3 séries iguais, descanso padrão e reps 8–12 (ou o último uso dele em outra ficha). Tocar na linha → Prescrição → ajustar em bloco ou série a série.
6. Selecionar dois vizinhos → "Agrupar" para bi-set. "OK" fecha o editor.

### 5.3 Iniciar → executar → encerrar
1. Hoje → "Iniciar treino" → a sessão sobe em tela cheia, primeiro exercício expandido, série 1 atual, doca "Concluir série 1".
2. (Opcional) ajustar a carga com +/− (0,5 kg por toque). Tocar no check ou em "Concluir série" → háptico → doca vira **Descanso** (90 s, −15/Pular/+15).
3. (Opcional) durante o descanso, tocar em "+ reps" na série feita e informar quantas saíram. Descanso zera → háptico/som → doca volta a "Concluir série 2". Repetir.
4. Última série → exercício marca concluído (háptico forte), recolhe; doca: "Próximo: Crucifixo" → 1 toque.
5. Desvios a qualquer momento pelo menu do exercício: Trocar · Pular · + Série · Anotação · Dor; pelo menu da sessão: Adicionar exercício · Reordenar.
6. Minimizar (`chevron.down`) para ver a dieta ou a biblioteca; o acessório mostra o tempo/descanso; tocar volta.
7. Tudo resolvido → doca "Finalizar treino" → **Encerramento**: resumo, recordes, RPE (1 toque), cargas atuais (toggles), Saúde → "Salvar treino".
8. Sessão fecha; Hoje mostra "Treino concluído".

### 5.4 Retomar sessão após fechar o app
1. Usuário fecha (ou o sistema encerra) o app no meio do descanso.
2. Reabre: Hoje aparece com a sessão **no mesmo modo em que estava** — tela cheia reabre sem animação de entrada; minimizada volta com o acessório.
3. Tempo decorrido correto (por `SessionClock`: início, pausas e fim); descanso mostra o restante ou "Descanso concluído"; série atual e campos editados preservados.
4. Se a última série foi há mais de 4 h: sheet "Treino em aberto" (Continuar · Finalizar na hora da última série · Descartar).

### 5.5 Trocar o programa ativo
1. Treinos → Programas → tocar num anterior → "Reativar" (ou criar/duplicar um novo e salvar).
2. Diálogo: "Ativar *Força 5×5*? *Hipertrofia ABC* vai para o histórico." [Ativar] [Cancelar].
3. Com sessão em andamento: "Finalize ou descarte o treino em andamento antes de trocar de programa." [Ver treino].
4. Treinos e Hoje passam a mostrar o novo programa; o histórico de sessões não muda.

### 5.6 Registrar refeição do plano e item fora da dieta
- **Do plano, como planejado**: Hoje (cartão Próxima refeição) ou Dieta → tocar no check → "Feita 12:40", totais sobem, a próxima refeição ganha o destaque.
- **Do plano, com alteração**: "Ajustar" → desligar um item, mudar quantidade ou "Trocar por…" → Salvar → etiqueta "Ajustada".
- **Pular**: "Pular" → estado neutro "Pulada" (desfazer no mesmo lugar).
- **Fora da dieta**: "+" (Hoje ou Dieta) → digitar "brigadeiro" (ou tocar num recente) → quantidade → [Registrar]. Entra na linha do tempo no horário, com etiqueta "Fora da dieta"; se sem kcal, o total avisa "1 item sem calorias".
- **Extra dentro de uma refeição**: mesmo "+", escolhendo a refeição em "Vincular a".

### 5.7 Conectar ao Saúde (permissão contextual)
1. Gatilhos: primeiro "Finalizar treino" (linha "Conectar ao Saúde" no encerramento), aba Saúde vazia, Ajustes → Saúde, linha no resumo de Hoje.
2. Toque → sheet própria de uma tela: o que será lido (FC, treinos, energia, FC em repouso, VFC, passos, peso), o que será gravado (treinos, energia), "Seus dados ficam neste iPhone". [Continuar] abre a folha de permissão do sistema; [Agora não] fecha sem insistir (o convite reaparece só nos lugares fixos, nunca como alerta).
3. Autorizado: os cartões passam de "—" para `FJLoadingState` e depois dados.
4. Negado/parcial: `FJBanner` "Sem acesso a …" + "Abrir Ajustes" nas telas de Saúde; no encerramento, "o treino fica só no FitJourney". O fluxo de treino nunca é bloqueado.

---

## 6. Acessibilidade

- **VoiceOver**
  - Linha de série é um elemento com ações: rótulo "Série 2 de 4, válida, 32,5 quilos, alvo 8 a 12 repetições" (com reps informadas: "…, 9 repetições feitas") · valor "pendente/concluída/pulada" · ações personalizadas "Editar carga", "Informar repetições", "Remover série". Sem dicas redundantes ("toque duas vezes…"): o VoiceOver já as dá. Unidades por extenso (quilos, segundos, batimentos por minuto), nunca "kg".
  - `NumberStepperField` é ajustável (deslizar para cima/baixo = +/−) e tem a ação "Digitar valor"; o teclado fecha pelo "OK" da barra do teclado. `FJBanner` expõe o texto como um elemento e o botão de ação como outro.
  - Timer de descanso: anuncia "Descanso, 1 minuto e 30 segundos" ao iniciar e "Descanso concluído" ao terminar (`AccessibilityNotification.Announcement`); o texto que muda a cada segundo tem `.updatesFrequently` e não interrompe.
  - Ordem de foco na sessão: barra superior → exercício atual → doca; ao concluir uma série o foco vai para a doca.
  - Gráficos: `accessibilityChartDescriptor` com resumo ("FC entre 92 e 164, média 128") e navegação por exercício; a lista numerada abaixo do gráfico traz os mesmos dados em texto.
  - Estados sempre em texto: "Feita, com alteração", "Zona 3, moderada", "Indisponível".
- **Dynamic Type até AX5**: só estilos de texto; nenhuma altura fixa em linha com texto. Em tamanhos de acessibilidade: `FJAdaptiveStack` empilha (o `NumberStepperField` põe rótulo, valor e botões em três linhas, sem truncar o rótulo; métricas em 1 coluna; botões secundários em coluna); linha do tempo da dieta põe a hora acima do cartão; a doca cresce e a lista rola por trás. O timer tem teto de 96 pt e reduz até 50% para caber.
- **Reduzir Transparência**: `.fjGlass` vira `surfaceElevated` com contorno; barras e botões do sistema seguem o sistema. Nenhuma informação depende do desfoque.
- **Reduzir Movimento**: §2.5.
- **Aumentar Contraste / Diferenciar sem cor**: superfícies e texto são cores do sistema; estados têm símbolo e texto; selecionado tem check ou contorno além da cor; zonas têm "Z*n*"; força/aeróbico têm símbolo e rótulo.
- **Contraste**: texto ≥ 4,5:1; texto colorido só com os tons `color`; branco só sobre `fill`; símbolos e trilhos de gráfico ≥ 3:1. Texto nunca fica diretamente sobre vidro com conteúdo colorido atrás sem o vidro do sistema (que garante a legibilidade).
- **Alvos**: 44 pt mínimo (inclusive ações de texto como "Ajustar"); 48/52/56 pt na sessão; 8 pt entre alvos vizinhos.
- **Sem depender de gesto**: arrastar, deslizar e segurar sempre têm alternativa visível (menu, botão, modo "Reordenar").
- **Uma mão**: nada essencial à série no terço superior; confirmações destrutivas usam `confirmationDialog` (parte inferior).

---

## 7. Critérios de validação

Verificáveis por `qa-accessibility` no simulador (iPhone 17 Pro e o menor iPhone com iOS 26), claro e escuro.

**Geral**
1. Nenhuma linha de lista, formulário, cartão de dado ou gráfico usa vidro; busca por `glassEffect` fora de `DesignSystem/` não retorna nada (telas usam `.fjGlass`, `FJ*Button`, `.glass`/`.glassProminent`).
2. Nenhuma cor literal (`Color(red:…)`, hex, `.blue`) nem `Font.system(size:)` fora de `DesignSystem/`.
3. Toda tela da §4 tem implementados os estados da sua tabela; cada um tem preview nomeado.
4. Todo número de treino/dieta/saúde usa um token `FJFont.number*`.
5. Dado ausente aparece como "—"/"Indisponível" e nunca como 0 (teste: Saúde negado, item sem kcal, sessão sem FC).
6. Com Reduzir Transparência não há desfoque em superfícies próprias; com Reduzir Movimento não há zoom, mola nem contagem animada.
7. AX5: nenhuma tela corta texto essencial ou sobrepõe elementos; tudo é alcançável por rolagem.
8. Todos os alvos interativos ≥ 44 × 44 pt (Accessibility Inspector); check de série ≥ 52 pt; botão principal ≥ 56 pt de altura.
9. Contraste de texto ≥ 4,5:1 nos dois temas (Accessibility Inspector), inclusive texto colorido e branco sobre `fill`.
10. VoiceOver lê todo controle com rótulo em pt-BR, sem "botão" sem nome e sem siglas de unidade.

**Sessão**
11. Do toque em "Iniciar treino" à sessão interativa: < 300 ms com ficha de 12 exercícios.
12. Concluir uma série prescrita = **1 toque**, sem informar reps; ajustar a carga em um passo (0,5 kg) e concluir = **2 toques**; nenhum desses toques acima da metade da tela. A série concluída sem reps mostra o alvo como prescrito.
13. Com o polegar da mão que segura o aparelho (zona inferior de 50% da tela) é possível: concluir série, ajustar o descanso, pular o descanso, ir ao próximo exercício e finalizar.
14. A carga da série atual e o timer são legíveis a 1,5 m (≥ 28 pt e ≥ 60 pt no tamanho de texto padrão).
15. Fechar o app à força durante o descanso e reabrir após 2 min: mesma série atual, tempo decorrido correto (±1 s), descanso mostrado como concluído.
16. Minimizar mostra o acessório em todas as abas; tocar reabre no mesmo ponto de rolagem.
17. Desfazer um check restaura o estado pendente sem perder os valores editados.
18. VoiceOver na linha de série lê "Série *n* de *N*, *tipo*, *carga*, alvo *reps*, *estado*"; desfazer um check não vibra.
19. Sem Apple Watch, a sessão inteira funciona e o badge de FC mostra "—". Com a sessão pausada, o tempo da barra e do acessório não avança.
19a. Todo teclado numérico aberto por um campo do DesignSystem fecha pelo "OK" da barra do teclado; digitar "32.5" ou "32,5" resulta em 32,5 kg nos dois locales.

**Encerramento**
20. RPE pode ficar sem resposta e o treino é salvo; tocar no valor escolhido desmarca.
21. "Atualizar carga atual" vem ligado só quando todas as séries válidas do exercício foram concluídas.
22. Descartar pede confirmação e não deixa rastro no histórico.

**Dieta**
23. Marcar refeição como feita = 1 toque em Hoje e em Dieta; registrar item avulso recente = 3 toques ("+", item, Registrar).
24. Os cinco estados da refeição são distinguíveis em escala de cinza.
25. Item avulso sem vínculo aparece com "Fora da dieta" no horário certo; total mostra "n itens sem calorias" quando aplicável.

**Saúde**
26. Nenhuma permissão é pedida antes de uma ação do usuário que a justifique.
27. No gráfico da sessão, cada faixa de exercício tem número legível, coincide com o intervalo 1ª–última série (±1 s) e a seleção mostra exercício, série, FC média e máx.
28. Força e Aeróbico são distinguíveis sem cor (símbolo + rótulo).

**Build**
29. `make build` sem erros nem avisos de concorrência; `DesignSystemGallery` renderiza em claro, escuro e AX3.

---

## 8. Componentes (`FitJourney/DesignSystem/`)

| Componente | Arquivo | Uso |
|---|---|---|
| `fjGlass(in:tint:interactive:)` | `Modifiers/FJGlass.swift` | Único acesso a `glassEffect` em superfícies próprias |
| `FJCard`, `.fjCard()`, `.fjScreenBackground()`, `FJAdaptiveStack` | `Modifiers/FJCard.swift` | Cartão sólido; fundo de tela; pilha que empilha em AX |
| `FJPrimaryButton`, `FJSecondaryButton`, `FJIconButton`, `.buttonStyle(.fjPrimary(area))`, `.buttonStyle(.fjSecondary())` | `Components/FJButtons.swift` | Botões de ação em vidro (`fjGlass` tingido/neutro) com altura mínima por token (56 / 48 / 44 pt). Toolbars do sistema continuam com os botões nativos. |
| `FJTag`, `FJFilterChip` | `Components/FJChip.swift` | Etiqueta sólida em conteúdo; chip de filtro em vidro (selecionado = check + contorno, texto primário) |
| `FJProgressRing`, `FJGoalBar` | `Components/FJProgress.swift` | Metas |
| `FJMetricCell`, `FJMetricGrid` | `Components/FJMetricCell.swift` | Valor + unidade + rótulo |
| `FJSectionHeader` | `Components/FJSectionHeader.swift` | Cabeçalho de seção com ação |
| `NumberStepperField`, `FJOptionalNumberField`, `.fjKeyboardDone(_:)` | `Components/NumberStepperField.swift` | Carga, tempo, lastro com +/−; campo opcional discreto ("+ reps"); botão OK na barra do teclado |
| `FJRestTimerView` | `Components/FJRestTimerView.swift` | Painel de descanso (por datas; para de atualizar e anuncia ao terminar) |
| `FJCheckButton`, `FJRPEScale`, `FJSessionAccessory` | `Components/FJSessionControls.swift` | Check de série/refeição; RPE 1–10; conteúdo do `tabViewBottomAccessory` (recebe `startedAt`, `pausedSeconds`, `pausedAt` do `SessionClock`) |
| `FJHeartRateZoneBadge`, `FJHeartRateBadge` | `Components/FJHeartRate.swift` | Zona e FC ao vivo |
| `FJEmptyState`, `FJLoadingState`, `FJBanner` | `Components/FJStates.swift` | Estados |
| `DesignSystemGallery` | `DesignSystemGallery.swift` | Todos, para preview e QA |

Componentes de tela (linha de série, cartão de exercício, linha do tempo da dieta, gráfico de FC) ficam em `Features/` e são montados com estes.

---

## 9. Apple Watch (watchOS 26) — pacote W0

Comportamento e arquitetura de dados: SPEC §6.4. Objetivo: o iPhone fica no bolso ou no armário e **todo o controle da sessão acontece no pulso**. Quadros de 41 e 46 mm no protótipo.

### 9.1 Princípios do relógio

1. **Um relance, uma ação.** Cada tela responde "o que faço agora?" com um número grande e um botão. Nada de listas durante a série.
2. **A Coroa é da carga.** Na sessão, girar a Digital Crown ajusta a carga em passos de 0,5 kg (e o RPE ao finalizar). Por isso as páginas da sessão são **horizontais** (`TabView` com `.page`), não verticais: paginação vertical disputaria a Coroa com a carga. Ver Q-W1.
3. **Toque duplo = ação principal** da tela (`handGestureShortcut(.primaryAction)`): Iniciar, Concluir série, Pular descanso, Iniciar/Parar sustentação, Salvar.
4. **O pulso avisa.** Hápticos distintos são a interface principal entre as séries (§9.6); a tela pode estar apagada.
5. **Nunca trava.** O relógio aplica o próprio comando na hora (otimista) e reconcilia com o snapshot do iPhone. Sem iPhone por perto, continua sozinho.
6. **Fundo preto, vidro só nos botões.** Conteúdo direto sobre preto (OLED); Liquid Glass nativo do watchOS 26 em botões (`.glass`, `.glassProminent`) e na toolbar. Nenhum cartão de vidro.

### 9.2 Tokens no relógio

- **Cor**: as mesmas de §2.1, tons do tema escuro (treino `#FF9A3D`, preenchimento `#D4450C`, zonas, saúde). Texto primário branco; secundário branco 66%.
- **Tipografia**: estilos de texto do sistema, números em SF Rounded com dígitos monoespaçados. Carga: `.largeTitle` rounded bold (≈ 40 pt). Timer de descanso/sustentação: 48 pt (41 mm) / 54 pt (46 mm), `minimumScaleFactor(0.6)`. Nome do exercício: `.headline`, até 2 linhas (1 no 41 mm).
- **Alvos**: botão principal em largura total, 46 pt de altura (41 mm) / 52 pt (46 mm); demais ≥ 44 pt — exceção: os dois botões de vidro do descanso no 41 mm têm 40 pt visíveis com área de toque de 44 pt (é a tela mais apertada). Margens: `scenePadding`.
- **Movimento**: `FJMotion.value` para número e check; sem animação em laço. Tela sempre ligada (Always On): brilho reduzido, timer a 1 Hz, sem animações.
- O código de tokens é compartilhado com o iPhone (`FJColor`, `FJFont`, `FJFormat`, `FJHeartRateZone`); componentes do relógio ficam em um diretório próprio do alvo watchOS.

### 9.3 Arquitetura de telas

```
NavigationStack
├─ Treinos (raiz): ficha do dia em destaque + demais fichas
│    └─ Ficha (exercícios e prescrição) ── [Iniciar]
└─ Sessão (substitui a raiz enquanto houver sessão em andamento)
     TabView horizontal:  Controles ◀ │ SÉRIE (inicial) │ ▶ Métricas │ ▶ Ficha
     └─ Finalizar:  RPE (Coroa) → Resumo
```

A página **Série** muda de conteúdo conforme o estado: série → descanso → (sustentação | cardio) → próximo exercício. As outras páginas estão sempre a um deslize.

### 9.4 Telas

**Treinos (raiz)** — título "Treinos".
- Primeiro item em destaque (altura dupla, contorno laranja): sobrelinha conforme a agenda — "HOJE" (semanal), "PRÓXIMA" (sequencial), "HÁ MAIS TEMPO" (livre) —, selo com a letra, nome da ficha, "6 exercícios · ~55 min". Toque abre a ficha.
- Abaixo, as outras fichas do programa ativo (selo + nome). Dia de descanso no modo semanal: linha neutra "Descanso hoje" no topo, sem destaque; todas as fichas continuam iniciáveis.
- Rodapé: nome do programa e "atualizado há 5 min" (idade do resumo recebido do iPhone).

**Ficha** — título "A · Peito e tríceps".
- Lista dos exercícios: nome + prescrição em uma linha ("4 × 8–12 · 32,5 kg"); bi-set unido por trilho laranja.
- `Iniciar` (`.glassProminent` laranja) fixo na base (toolbar inferior). Toque duplo inicia. Início: contagem "3, 2, 1" com hápticos, como no app Exercício.

**Sessão · Série** (página inicial)

```
┌────────────────────┐
│ 32:14         10:09│  tempo da sessão (toolbar) · hora do sistema
│ Supino inclinado   │  nome (headline)
│ Série 2 de 4       │  + tipo quando não for "válida"
│   ◉  26,0 kg       │  carga grande; ◉ = Coroa ativa
│ alvo 8–12 · RIR 2  │  alvo sempre como prescrito
│ [    Concluir    ] │  botão principal · toque duplo
└────────────────────┘
```

- **Carga**: gira a Coroa → ±0,5 kg por detente, com háptico de detente; o indicador da Coroa (traço laranja à direita do número) mostra que ela está ativa. Tocar no número abre a folha "Carga" com − / + grandes (alternativa sem Coroa). Peso corporal mostra "PC", "PC +10 kg" e a Coroa ajusta o lastro.
- **Alvo** como prescrito: "8–12", "10", "máx.", com RIR/RPE. Reps realizadas não são pedidas aqui (D2).
- **Concluir**: conclui a série com a carga exibida → háptico de sucesso → a página vira **Descanso**. Na última série do exercício o botão diz "Concluir exercício".
- Entre exercícios: "Próximo: Crucifixo · 3 × 12–15 · 15 kg" + `Começar` (toque duplo).

**Sessão · Descanso** (mesma página)

- Título "Descanso" na toolbar (no lugar do tempo da sessão); contagem regressiva grande; barra fina de progresso.
- "Próxima: 26,0 kg" — a Coroa continua ajustando a carga, agora da próxima série (Q-W2).
- Linha de botões de vidro: `+ reps` (abre seletor pela Coroa, começando no piso da faixa; "Limpar" volta a não informado) e `+15 s`. Abaixo, `Pular` em largura total (toque duplo).
- Fim: háptico forte (§9.6), "Descanso concluído" por 2 s e volta à Série. Com o pulso abaixado o háptico toca do mesmo jeito.

**Sessão · Sustentação** (isométrico)
- "Sustentação · alvo 0:45" + `Iniciar` (toque duplo) → "3, 2, 1" com cliques → cronômetro grande contando o tempo sustentado, marca do alvo na barra; háptico ao atingir o alvo; `Parar` (toque duplo) registra o tempo real e conclui a série.

**Sessão · Cardio**
- Cronômetro grande, FC e zona logo abaixo, `Concluir`. Distância/nível ficam para o iPhone.

**Sessão · Ficha** (página à direita)
- Lista dos exercícios com estado (○ pendente, ● atual em laranja, ✓ concluído, » pulado) e "2/4" séries. Toque abre ações: **Ir para este** · **Concluir exercício** · **Pular** (motivo opcional: Ocupado · Dor · Tempo).

**Sessão · Métricas** (página à direita da Série)
- Tempo decorrido (maior), FC ao vivo com `Z3` e o ponto da zona, calorias ativas, "Exercício 3 de 6 · série 2 de 4". Sem dado: "—".

**Sessão · Controles** (página à esquerda, como no app Exercício)
- Grade 2 × 2 de botões de vidro com rótulo: **Pausar/Retomar** · **Finalizar** · **Próximo** · **Pular exercício**.
- Pausado: a página Série mostra "Pausado" com o tempo congelado e `Retomar` (toque duplo).

**Finalizar**
1. **RPE**: "Como foi o treino?", número grande (1–10) com o rótulo ("7 · Muito difícil"), ajustado pela Coroa com detentes. `Salvar` (toque duplo) e `Sem nota`.
2. **Resumo**: check, duração, séries (18/20), calorias, FC média, "1 recorde". Cargas atuais: o relógio aplica a regra padrão do SPEC §3.4 (atualiza só quando todas as séries válidas foram concluídas) e mostra "2 cargas atualizadas · revise no iPhone" (Q-W3). `OK` volta a Treinos.
- Finalizar sem nenhuma série concluída: "Descartar treino?" — Descartar (destrutivo) · Voltar.

### 9.5 Estados

| Estado | O que o relógio mostra |
|---|---|
| Primeiro uso, nunca sincronizou | "Abra o FitJourney no iPhone para trazer seus treinos" + símbolo do iPhone. Sem botões mortos. |
| Sem programa ativo | "Nenhum programa ativo. Crie ou ative um no iPhone." Treino livre fica fora do W0 (Q-W4). |
| Sincronizando | Lista anterior continua utilizável; indicador pequeno de atividade ao lado de "atualizado…". Nunca uma tela só de carregamento se já existe resumo. |
| Resumo antigo (> 24 h) | Rodapé em tom de atenção: "atualizado ontem" — iniciar continua permitido. |
| iPhone fora de alcance (antes de iniciar) | Inicia normalmente com o último resumo; selo `iphone.slash` na toolbar. |
| iPhone fora de alcance (na sessão) | Selo `iphone.slash` na toolbar; tudo funciona; comandos ficam na fila. Ao reconectar: selo some, sem interromper. Nenhum alerta modal. |
| Comando ainda não confirmado | Sem marca visível (otimista). Só se o iPhone rejeitar: o valor volta e aparece "Atualizado pelo iPhone" por 2 s com háptico leve. |
| Sessão iniciada no iPhone | O relógio abre direto na Sessão (pede para iniciar a `HKWorkoutSession` espelhada). Se o app do relógio estava fechado: notificação "Treino em andamento · Abrir". Na raiz, o destaque vira "EM ANDAMENTO · Continuar". |
| Sessão iniciada no relógio | O iPhone mostra a mesma sessão (tela cheia ou acessório) com o selo `applewatch`. |
| Sessão já em andamento ao tocar Iniciar em outra ficha | "Há um treino em andamento" — Continuar · Finalizar aquele. |
| Sem permissão de Saúde (negada ou não pedida) | Na primeira vez, antes de iniciar: tela "Permitir Saúde" explicando FC e calorias → pedido do sistema. Negado: a sessão funciona sem `HKWorkoutSession`; Métricas mostra "—" e a linha "Sem acesso ao Saúde · ajuste no iPhone". Nunca "0 bpm". |
| FC ainda sem leitura | "—" com o coração esmaecido; sem animação em laço. |
| Sessão antiga em aberto (> 4 h) | Ao abrir: "Treino em aberto desde 19:40" — Continuar · Finalizar · Descartar (mesma regra do iPhone). |
| Erro ao salvar no fim, sem iPhone | "Salvo no relógio. Será enviado ao iPhone quando conectar." O treino do Saúde já está gravado pelo relógio. |
| Bateria/Modo Pouca Energia | Sem mudança de layout; FC pode ficar menos frequente → "—" quando ausente. |

### 9.6 Hápticos do relógio

| Evento | Háptico (`WKHapticType`) |
|---|---|
| Detente da Coroa (carga, reps, RPE) | detente do sistema |
| Série concluída | `.success` |
| Fim do descanso | `.notification`, duas vezes com 0,4 s |
| "3, 2, 1" (início, sustentação) | `.click` a cada segundo, `.start` no zero |
| Alvo da sustentação atingido | `.directionUp` |
| Parar sustentação / pausar | `.stop` |
| Retomar | `.start` |
| Treino salvo | `.success` |
| Comando rejeitado / erro | `.failure` |

### 9.7 Acessibilidade no relógio

- **VoiceOver**: a página Série é lida como "Supino inclinado, série 2 de 4, 26 quilos, alvo 8 a 12 repetições"; a carga é um elemento ajustável (deslizar para cima/baixo = ±0,5 kg), independente da Coroa; botões com rótulo completo ("Concluir série 2"); o fim do descanso é anunciado. Páginas têm nome ("Controles", "Série", "Métricas", "Ficha").
- **Texto grande (até AX3 no relógio)**: a página Série vira rolável; como a rolagem passa a usar a Coroa, a carga deixa de ser ajustada por ela e ganha botões − / + visíveis ao lado do número. O botão principal continua fixo na base. Nenhum texto essencial é truncado: o nome do exercício quebra em até 3 linhas.
- **Reduzir Movimento**: sem rolagem de dígitos nem transição de página animada entre série e descanso (esmaecimento); hápticos mantidos.
- **Sem depender de gesto**: toque duplo e Coroa têm sempre um botão equivalente na tela (folha "Carga" com − / +).
- **Cor nunca sozinha**: zona com "Z3", estado do exercício com símbolo, pausa com texto.
- **AssistiveTouch / uma mão**: toda a sessão é operável só com toque duplo + Coroa, ou só com toques.

### 9.8 Critérios de validação (relógio)

Exigem iPhone + Apple Watch pareados; no simulador vale só layout.

W1. Da face do relógio até a sessão iniciada: no máximo 3 toques (app → ficha do dia → Iniciar).
W2. Concluir uma série = 1 toque ou 1 toque duplo, sem olhar para o iPhone; ajustar a carga em 0,5 kg = 1 detente da Coroa.
W3. O alvo aparece como prescrito ("8–12", "10", "máx."); nenhuma tela exige reps para concluir.
W4. O fim do descanso é sentido com o pulso abaixado e a tela apagada.
W5. Série concluída no relógio aparece no iPhone em até 2 s (e vice-versa) com os dois por perto.
W6. Com o iPhone em modo avião: iniciar, concluir todas as séries e finalizar funcionam; ao reconectar, a sessão no iPhone tem as mesmas séries, cargas e horários (±1 s), sem duplicar.
W7. Sessão iniciada no iPhone aparece no relógio sem tocar em nada além de abrir o app (ou a notificação).
W8. Pausar no relógio congela o tempo no relógio e no iPhone; retomar não conta o intervalo.
W9. Sem permissão de Saúde a sessão inteira funciona e as métricas mostram "—".
W10. Todas as telas cabem em 41 mm sem truncar número, alvo ou botão principal; em 46 mm não sobra área morta acima do botão.
W11. Toda área de toque ≥ 44 pt; botão principal ≥ 46 pt (41 mm).
W12. VoiceOver percorre a página Série em ordem: exercício → série → carga (ajustável) → alvo → Concluir.
W13. Com texto no maior tamanho a carga é ajustável por botões e nada essencial é cortado.
W14. Finalizar: RPE pela Coroa, "Sem nota" disponível, resumo mostra quantas cargas foram atualizadas.

### 9.9 Fora do W0

Complicação e widget do Conjunto Inteligente, treino livre e edição de fichas no relógio, dieta no relógio, distância/nível de cardio, anotações e dor/desconforto (ficam no iPhone).

---

## 10. Decisões e pontos em aberto

Decididas pelo usuário em 11/11 (SPEC §11):

- **D1** Laranja é a cor do treino e o tint do app. Consequências: Z4 passou a amarelo e Z5 a magenta (escala sem laranja nem vermelho); o tom "atenção" passou de laranja-escuro a amarelo (§2.1).
- **D2** Na sessão o alvo aparece sempre como prescrito; reps realizadas são opcionais e começam vazias; o check conclui com a carga exibida (§4.5).
- **D3** Passo padrão de carga 0,5 kg, configurável (§4.3, §4.12).
- **D4** Aprovadas: treino em aberto há mais de 4 h, exemplo ABC no primeiro uso, notificação ao fim do descanso, refeição passada sem registro = "Sem registro". Recusada: manter tela ligada (removida).
- **D5** App do Apple Watch com controle completo da sessão (§9).

Decididas neste documento:

1. **Claro e escuro pelo sistema** no iPhone (os apps irmãos são só escuros); relógio sempre escuro.
2. **Laranja em dois tons**: `#C2410C`/`#FF9A3D` para texto e símbolo, `#D4450C` para preenchimento com texto branco — é um laranja queimado, o mais claro que mantém 4,5:1 com branco (Q5).
3. **Doca de ação** na sessão além do check por linha: o check atende a SPEC; a doca garante o uso com uma mão.
4. **Reps opcionais como campo discreto "+ reps"**, disponível antes e depois de concluir a série; nunca no caminho do check.
5. **"+" de registrar comida na toolbar** de Hoje e Dieta, não como botão flutuante.
6. **"Fora da dieta", "pulada" e "sem registro" são neutros**, sem cor de alerta.
7. **Faixas de exercício no gráfico de FC em tons neutros e numeradas**; cor fica reservada para a linha de FC e as zonas.
8. **Sem onboarding**: primeiro uso é a própria tela Hoje com convites.
9. **Descanso para em 0:00** ("Descanso concluído"), sem contar o excedente.
10. **Botões de ação próprios** usam `fjGlass` (vidro nativo tingido) com altura por token, em vez de `.glassProminent`, para garantir 56/48/44 pt exatos e o substituto sólido; toolbars e o relógio usam os estilos nativos.
11. **Relógio: páginas horizontais** e Coroa dedicada à carga.

Perguntas em aberto:

- Q4. A doca volta sozinha de "Descanso concluído" para "Concluir série" após 10 s — ou deve ficar até um toque?
- Q5. O laranja de preenchimento é queimado (`#D4450C`) para manter texto branco legível. Alternativa: laranja vivo (`#FF9500`) com texto **preto** nos botões. Qual prefere?
- Q6. "Atenção" e "recorde" ficaram na mesma família amarela (diferenciados por símbolo). Aceitável, ou o recorde deve ter outra cor?
- Q-W1. Sessão no relógio em páginas **horizontais** (Coroa livre para a carga), não verticais como sugerido. Confirma?
- Q-W2. Durante o descanso, a Coroa ajusta a carga da próxima série (proposto) ou o tempo de descanso?
- Q-W3. Ao finalizar pelo relógio, as cargas atuais são atualizadas pela regra padrão sem perguntar, com revisão no iPhone. Confirma?
- Q-W4. Treino livre (sem ficha) no relógio fica fora do W0. Confirma?
