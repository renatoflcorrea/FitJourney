# FitJourney — direção de design

Data: 12 de novembro de 2026
Status: **revisão 5** (pacote P1.5-design, `ios-design`): copiar ficha para outro programa (§4.2.1, §5.16, critérios 28ak–28ar, decisões 36–39). Revisão 4 (pacote C7.1): Copiloto de IA — importar e editar (§4.15), identidade visual da IA (gradiente "aurora"), componentes do copiloto (§8). Revisão 3 (pacote P6.1): paleta oficial de fichas (§2.1.1), ícone do app (§2.6), aba Saúde detalhada (§4.11), Ajustes (§4.12), Coach (§4.13) e Atividade ao Vivo / Dynamic Island (§4.14). Revisão 2 (pacotes P0.1 + P0.4 + W0) — incorpora as decisões do usuário de 11/11 (SPEC §11 D1–D5): laranja como cor do treino, reps realizadas opcionais, passo de carga 0,5 kg, propostas P1/P3/P4/P5 aprovadas e "manter tela ligada" recusada, app do Apple Watch (§9).
Protótipo: [design/prototype.html](design/prototype.html) (abrir no Safari/Chrome; claro e escuro lado a lado; seções 10–23 são da revisão 3; 24–32, do copiloto de IA; 35–37, da cópia de ficha).
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
| Dieta (`nutrition`) | `#18803A` / `#30D158` | `#18803A` / `#1C8540` | Aba Dieta, check de refeição, metas |
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

Contraste dos tons de texto e preenchimento (calculado): `training` sobre branco 5,2:1 e sobre `#1C1C1E` 8,1:1; branco sobre `trainingFill` 4,5:1; branco sobre `nutritionFill` 5,0:1 (claro) e 4,7:1 (escuro; era `#1F8A40`, 4,4:1, corrigido na revisão 3); `attention` sobre branco 6,2:1.

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

### 2.1.1 Cores de ficha (`FJRoutineColor`, `FJRoutineBadge`)

Paleta de **identidade**: serve para distinguir a ficha A da B, e só isso. É separada das cores de área e de estado e nunca carrega significado (verde não é "dieta", amarelo não é "atenção" quando está num selo de ficha). Os nomes são os valores gravados em `Routine.colorName` e não mudam.

| Nome (`colorName`) | Claro: `fill` / `onFill` | Escuro: `fill` / `onFill` | `onFill`:`fill` claro · escuro |
|---|---|---|---|
| `orange` Laranja (padrão) | `#D4450C` / branco | `#D4450C` / branco | 4,5 · 4,5 |
| `green` Verde | `#18803A` / branco | `#1C8540` / branco | 5,0 · 4,7 |
| `pink` Rosa | `#C2256E` / branco | `#C92C75` / branco | 5,6 · 5,1 |
| `blue` Azul | `#0A66C2` / branco | `#1F71CC` / branco | 5,7 · 4,9 |
| `purple` Roxo | `#7C3AED` / branco | `#8349EE` / branco | 5,7 · 5,1 |
| `teal` Turquesa | `#0B7F83` / branco | `#5AD1D6` / tinta `#1A1206` | 4,8 · 10,2 |
| `yellow` Amarelo | `#AD8200` / tinta `#1A1206` | `#FFD23F` / tinta | 5,3 · 12,8 |
| `gray` Cinza | `#5F6B7A` / branco | `#AEB7C2` / tinta | 5,4 · 9,1 |

Regras:

- `onFill` sobre `fill` ≥ 4,5:1 e `fill` ≥ 3:1 sobre `surface` **e** sobre `background`, nos dois temas. `design/tools/routine_palette_check.py` confere os 32 pares; rode ao mudar qualquer valor. Por isso o amarelo do tema claro é um ouro escuro (`#AD8200`): amarelo vivo não chega a 3:1 sobre branco.
- A cor nunca vai sozinha: selo sempre com letra/símbolo; ponto de calendário sempre ao lado do nome ou com a lista do dia abaixo.
- `fill` é para selo, ponto de calendário e marca de legenda. **Não** é cor de texto, de botão nem de gráfico de FC; o trilho do bi-set e o tint das telas continuam no laranja do treino.
- Nome vazio ou desconhecido = `orange`. Ficha nova recebe `FJRoutineColor.suggested(forIndex:)` (A laranja, B azul, C verde, D roxo, E rosa, F turquesa, G amarelo, H cinza, e repete).
- Relógio (sempre escuro) usa os tons `dark`.

**Selo** (`FJRoutineBadge`): quadrado de cantos contínuos (raio = 27% do lado) com a letra em SF Rounded bold.

| Tamanho | Lado | Onde |
|---|---|---|
| `.sm` | 32 pt | Linha do histórico, treinos do dia na Saúde, cartão de proposta do Coach |
| `.md` (padrão) | 44 pt | Cartão de ficha, Hoje, editor de ficha |
| `.lg` | 56 pt | Cabeçalho da ficha e do resumo do treino |

- Conteúdo: `Routine.symbol` — até 2 caracteres em maiúsculas, ou um SF Symbol quando o texto é um nome de símbolo válido; vazio usa a inicial do nome; sem nada, `dumbbell.fill`.
- Cresce com o Dynamic Type até 1,4× (não toma a linha em AX5).
- VoiceOver: decorativo por padrão (o nome da ficha está ao lado). Quando aparece sozinho (dia do calendário, legenda), recebe `accessibilityLabel` ("Ficha A, Peito e tríceps").
- **Seletor** (`FJRoutineColorPicker`): oito amostras circulares de 32 pt em alvos de 44 pt que quebram linha (`FJFlowLayout`, sem rolagem horizontal); selecionada = check + anel; VoiceOver lê o nome da cor e "selecionado".

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
| Alerta insistente de fim de descanso (`FJAlertVibrating`) | vibração longa do sistema (a do timer do iPhone), repetida a cada 1,5 s até um toque; teto de 60 s (§4.5) |
| +/− em carga/reps (`stepUp`/`stepDown`) | incremento / decremento |
| Chip, RPE, segmento (`selection`) | seleção |
| Sessão salva, recorde (`celebration`) | sucesso |
| Erro ao salvar (`error`) | erro |
| Alteração do copiloto aplicada, comida registrada pela conversa (`changeApplied`) | impacto médio |

Desfazer um check não vibra (`fjHaptic(_:trigger:when:)`). A vibração do alerta insistente é a única fora do `sensoryFeedback`: precisa ser sentida com o aparelho no banco ou no bolso, e só toca com a tela da sessão aberta. Hápticos respeitam o ajuste do sistema; "Hápticos na sessão" em Ajustes desliga os da sessão.

### 2.5 Movimento (`FJMotion`, `.fjAnimation(_:value:)`)

| Token | Curva | Uso |
|---|---|---|
| `structure` | `.smooth(duration: 0.4, extraBounce: 0.1)` | Expandir/recolher exercício, doca trocar de modo, minimizar sessão |
| `value` | `.snappy(duration: 0.25)` | Check, barra/anel de progresso, número |
| `press` | `.easeOut(duration: 0.08)` | Resposta ao toque |
| `reduced` | `.easeInOut(duration: 0.2)` | Substitui todas com Reduzir Movimento |

Com Reduzir Movimento: sem zoom/matched geometry na transição sessão ↔ acessório (vira esmaecimento), sem contagem animada de dígitos nem troca animada de símbolo (`.fjNumericTransition()` e `.fjSymbolTransition()` viram identidade — nenhuma tela chama `contentTransition` direto), sem confete no recorde (fica o troféu estático). Nenhuma animação em laço em lugar nenhum — com uma exceção de mesma natureza de um indicador de atividade: enquanto a IA está trabalhando, o "Pensando…" pulsa (§4.13.3) e o orbe do copiloto gira (§4.15.1); param no instante em que a etapa termina e não existem com Reduzir Movimento.

### 2.6 Ícone do app

Motivo **"degraus"**: um caminho branco que sobe em três degraus até um ponto. Lê-se como jornada (um caminho até a meta), como progressão de carga (um degrau por vez) e, de relance, como alguém subindo. Sem halter, sem coração, sem letra.

| Variante | Arquivo | Aparência |
|---|---|---|
| Claro (padrão) | `FitJourney/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | Motivo branco sobre gradiente laranja `#FF8B2B` → `#DB430A`, brilho suave no canto superior direito |
| Escuro | `…/AppIcon-Dark.png` | Motivo em gradiente laranja `#FFA347` → `#EE5A12` sobre quase-preto `#26262A` → `#0D0D0F` |
| Tinted | `…/AppIcon-Tinted.png` | Motivo em cinza (branco → `#B4B4B4`) sobre preto; o sistema aplica a cor |
| watchOS | `FitJourneyWatch/Assets.xcassets/AppIcon.appiconset/AppIcon.png` | Como o claro, com o motivo a 80% para caber na máscara circular |

- Todos 1024 × 1024, opacos, sem cantos arredondados (o sistema aplica a máscara). Os tamanhos menores são gerados pelo Xcode.
- Fonte única: `design/icon/make_icon.swift` (CoreGraphics). `swift design/icon/make_icon.swift` regrava os quatro PNGs e as prévias com máscara em `design/icon/preview-*.png`. Não edite os PNGs à mão.
- Geometria (em 1024): traço de 92 com pontas e cantos redondos pelos pontos (238,770) (420,770) (420,600) (602,600) (602,430) (786,430); ponto de raio 66 em (706,284). Margem mínima de 190 até a borda.
- Dentro do app o motivo aparece só em **Sobre** (Ajustes) e como glifo da Atividade ao Vivo (§4.14), numa cor só. Não é usado como ilustração de estado vazio.

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
└─ Coach (fase 2) ─ Boas-vindas/consentimento → Conversas → Conversa (cartão de proposta → editor em sheet)
                    engrenagem → Coach e IA

Ajustes (sheet a partir do avatar de Hoje, também com a aba Coach):
   Perfil · Unidades · Treino · Dieta · Saúde · Notificações · Coach e IA · Dados · Sobre

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

Título grande "Treinos". Toolbar: "+" (menu: Novo programa, Nova ficha no programa ativo, Adicionar ficha de outro programa — §4.2.1 —, Novo exercício).

1. **Programa ativo** (`FJCard`): nome, etiqueta do objetivo (`FJTag`), modo de agenda com símbolo (Livre `shuffle`, Sequencial `arrow.triangle.2.circlepath`, Semanal `calendar`), "semana 3 de 8", aderência da semana no modo semanal ("2 de 4 treinos"). Menu "…": Editar programa, Duplicar, Arquivar.
2. **Fichas** (seção): um cartão por ficha — selo com letra/cor, nome, "6 exercícios · ~55 min", dias da semana (modo semanal: 7 círculos S T Q Q S S D, os ativos preenchidos), "última vez: seg, 9 nov". Toque abre a **ficha** (pré-visualização somente leitura com `FJPrimaryButton("Iniciar treino")` na base e "Editar" na toolbar). Arrastar reordena (define a sequência no modo rodízio). Menu de contexto: Iniciar, Editar, Duplicar, Copiar para outro programa… (§4.2.1), Excluir.
3. **Atalhos** (lista inset): Biblioteca de exercícios · Histórico · Programas.

**Programas** (push): seções "Ativo", "Anteriores", "Arquivados". Linha: nome, período, nº de fichas, origem (manual/IA/importado/duplicado). Detalhe de um programa anterior é somente leitura, com `FJSecondaryButton` "Duplicar e editar" e "Reativar"; as únicas mudanças que ele aceita são as cópias de ficha do §4.2.1 ("…" de cada ficha para copiar para fora, "…" da toolbar para trazer de outro programa).

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

#### 4.2.1 Copiar ficha para outro programa (P1.5)

Só cópia; não existe "mover". A cópia leva tudo da ficha (exercícios, séries, repetições, cargas, descansos, bi-sets, observações, cor e letra) e a original não muda. Dentro do mesmo programa continua valendo "Duplicar". **Nenhum componente novo**: folha nativa com `List`, `FJRoutineBadge`, os círculos de dia que já existem em "Nova ficha" (`WeekdayPicker`, `WeekdayDots`), `FJTag`, `FJBanner` e `FJEmptyState`. Vidro só na folha, na toolbar e no botão do estado final; as linhas são sólidas. Protótipo: quadros 35–37.

**Entradas**

| Rótulo | Onde | Abre |
|---|---|---|
| **"Copiar para outro programa…"** (`doc.on.doc`) | Treinos › menu de contexto da ficha, depois de "Duplicar" · Editor de ficha › "…" da toolbar (o caminho visível do toque longo, §3) · Detalhe do programa › "…" na linha de cada ficha (`Menu`, `ellipsis`, alvo de 44 pt) | **Fluxo A**, folha "Copiar ficha": uma ficha, escolhe o destino |
| **"Adicionar ficha de outro programa"** (`square.and.arrow.down.on.square`) | Treinos › "+", logo abaixo de "Nova ficha no programa ativo" · Treinos › estado "Programa sem fichas", botão de texto sob "Adicionar ficha" · Detalhe do programa › "…" da toolbar, primeiro item, separado de Arquivar/Excluir | **Fluxo B**, folha "Adicionar fichas": destino fixo, escolhe uma ou mais fichas |

A entrada B fica onde as fichas do programa aparecem, **não** na folha "Editar programa": lá vale Cancelar/Salvar, a cópia grava na hora e o modo de agenda pode estar alterado sem salvar.

**Fluxo A — "Copiar ficha"** (folha `.medium`/`.large`, `NavigationStack`, `List`)

```
│ Cancelar    Copiar ficha    Copiar │  "Continuar" se o destino marcado é semanal
│ [B] Costas e bíceps                │  FJRoutineBadge(.md) · nome
│     7 exercícios · ~60 min         │  resumo
│     de Hipertrofia ABC             │  programa de origem
│ A cópia leva exercícios, séries, … │  rodapé fixo
│ COPIAR PARA                        │
│ Força 5×5                       ✓  │  seleção única, check à direita
│ Sequencial · 3 fichas              │
│ Adaptação            [Arquivado]   │
│ Semanal · 4 fichas                 │
│ ＋ Novo programa…                  │
│ Entra no fim da sequência de …     │  rodapé do destino marcado
```

1. **Linha da ficha** (não tocável): selo, nome, "7 exercícios · ~60 min", "de {Origem}". Rodapé: "A cópia leva exercícios, séries, cargas, descansos e bi-sets, com a mesma cor e letra. A original não muda."
2. Seção **"Copiar para"**: todos os outros programas — ativo primeiro, depois anteriores (mais recente primeiro), depois arquivados. Linha: nome, `FJTag` "Ativo" ou "Arquivado", "{Modo} · {n} fichas". Tocar marca. Última linha: **"Novo programa…"** — abre a folha "Novo programa" por cima; ao salvar, o programa novo entra na lista já marcado.
3. **Rodapé da seção**, conforme o destino marcado:
   - livre: "Entra na lista de fichas de {Destino}."
   - sequencial: "Entra no fim da sequência de {Destino}."
   - semanal: "{Destino} é semanal. No próximo passo você escolhe os dias."
   - nome repetido, mais uma frase: "{Destino} já tem uma ficha com este nome. A cópia entra como {Nome} (2)."
4. **"Copiar"** na toolbar (desabilitado sem destino). Com destino semanal o botão é **"Continuar"** e empurra "Dias da semana", onde o botão volta a ser "Copiar".
5. **Estado final**: o conteúdo da folha troca por `FJEmptyState("Ficha copiada", systemImage: "checkmark.circle.fill")` com a mensagem "{Nome} agora também está em {Destino}. A original não mudou." — com nome trocado, "Entrou em {Destino} como {Nome} (2). A original não mudou." — e a ação **"Ver programa"**. Toolbar só com **"OK"**. "Ver programa" fecha a folha e abre o destino: a raiz de Treinos se ele for o programa ativo, o detalhe do programa nos demais.

**Fluxo B — "Adicionar fichas"** (folha `.large`)

```
│ Cancelar   Adicionar fichas   Adicionar (2) │  "Continuar" se o destino é semanal
│ As fichas marcadas são copiadas para        │
│ Hipertrofia ABC. As originais não mudam.    │  + a frase do encaixe
│ FORÇA 5×5                                   │  um grupo por programa
│ ● [A] Agachamento e supino                  │  marcada: check cheio
│       5 exercícios · ~50 min                │
│ ○ [B] Terra e desenvolvimento               │
│ ADAPTAÇÃO · ARQUIVADO                       │
│ ● [A] Peito e tríceps                       │
│       6 exercícios · ~55 min                │
│       S T Q Q S S D                         │  WeekdayDots (origem semanal)
│       Entra como Peito e tríceps (2)        │  nome repetido
```

1. **Abertura** (linha sem fundo): "As fichas marcadas são copiadas para {Destino}. As originais não mudam." e a frase do encaixe — livre: "Entram na lista de fichas." · sequencial: "Entram no fim da sequência, na ordem desta lista." · semanal: "No próximo passo você escolhe os dias."
2. **Um grupo por programa** que tenha fichas, na ordem do fluxo A; o cabeçalho é o nome do programa, com " · Ativo" ou " · Arquivado" quando for o caso. A linha inteira alterna a marcação: indicador à esquerda (`checkmark.circle.fill` laranja ou `circle`), `FJRoutineBadge(.md)`, nome, resumo (ficha vazia mostra "Sem exercícios" e pode ser copiada), `WeekdayDots` se a origem é semanal e, com nome repetido, "Entra como {Nome} (2)" — contando o destino e as marcadas acima dela.
3. **"Adicionar (n)"** na toolbar ("Adicionar", desabilitado, com zero). Com destino semanal: **"Continuar"** → "Dias da semana" → "Adicionar (n)".
4. Ao confirmar, a folha fecha e as fichas aparecem no fim da lista do destino, que é a tela de baixo. Não há estado final: não há para onde levar.

**Passo "Dias da semana"** (push na mesma folha; só com destino semanal)

- Abertura: "Escolha em que dias a ficha entra em {Destino}. Dois treinos podem cair no mesmo dia." (fluxo B: "…em que dias cada ficha entra…").
- Uma seção por ficha: cabeçalho com `FJRoutineBadge(.sm)` e o nome com que ela entra; `WeekdayPicker` com **os dias da original já marcados** (origem semanal) e o ponto de atenção nos dias ocupados — pelas fichas do destino e pelas outras fichas desta mesma cópia.
- Rodapé da seção, uma linha por caso:
  - "Sugestão: os dias da ficha original."
  - "A ficha original não tem dias marcados."
  - dia ocupado marcado — o aviso que já existe em "Nova ficha": "Dia já usado por outra ficha: Ter (B — Costas e bíceps). Os dois treinos aparecem no mesmo dia."
  - nenhum dia: "Sem dia marcado, a ficha entra no programa, mas não é sugerida em Hoje."
- Nada bloqueia: dia ocupado e ficha sem dia são permitidos.

**Regras**

- **Nome**: comparação sem diferenciar maiúsculas nem acentos, ignorando espaços nas pontas. Repetido vira "{Nome} (2)", depois "(3)"…; nome que já termina em "(n)" incrementa ("Peito (2)" vira "Peito (3)"). Letra e cor nunca mudam, mesmo que o destino já tenha um selo igual.
- **Ordem**: sempre no fim do destino; várias fichas entram na ordem da lista, não na dos toques.
- **Tudo ou nada**: uma falha não deixa cópia parcial.
- **Treino em andamento na origem não bloqueia**: a cópia lê a ficha, não o treino.

| Estado | O que aparece |
|---|---|
| A · sem outro programa | No lugar da lista, `FJEmptyState("Nenhum outro programa", systemImage: "square.stack.3d.up")` · "Crie um programa para receber a cópia desta ficha." · ação **"Novo programa"** |
| B · sem outro programa | `FJEmptyState("Nenhum outro programa", …)` · "Quando houver mais de um programa, as fichas dos outros aparecem aqui para copiar." · sem ação |
| B · outros programas sem fichas | `FJEmptyState("Nenhuma ficha para copiar", systemImage: "rectangle.stack")` · "Os outros programas ainda não têm fichas." Programa sem fichas no meio da lista é omitido |
| A · destino com treino em andamento | `FJBanner` de atenção no topo da folha: "Há um treino em andamento em {Programa}" · "Finalize ou descarte o treino para copiar fichas para esse programa." · **Ver treino** (fecha a folha e abre a sessão). A linha desse programa fica desabilitada, com `FJTag("Treino em andamento", tone: .attention)`; os outros destinos continuam disponíveis |
| B · destino com treino em andamento | A folha não abre. `FJBanner` de atenção no topo da tela, como em §5.5: "Há um treino em andamento" · "Finalize ou descarte o treino em andamento antes de adicionar fichas a {Programa}." · **Ver treino** |
| Treino começou com a folha aberta (pelo relógio) | Ao confirmar, nada é copiado e o mesmo aviso aparece no topo da folha |
| Salvando | Botão de confirmar desabilitado até terminar; sem indicador (é local e imediato) |
| Falha | Alerta "Não foi possível copiar" + o motivo · [OK]; a folha continua com as escolhas |

**Acessibilidade**

- **VoiceOver**
  - Linha de programa (A): um elemento — "Força 5×5, sequencial, 3 fichas", mais "ativo" ou "arquivado" — com o traço *selecionado*; bloqueada: "…, indisponível, treino em andamento".
  - Linha de ficha (B): um elemento — "Peito e tríceps, 6 exercícios, cerca de 55 minutos, dias da semana: segunda, quinta, entra como Peito e tríceps 2" — com o traço *selecionado*; o selo é decorativo. Cabeçalhos de programa e de ficha são títulos (rotor).
  - O botão da toolbar lê "Adicionar 2 fichas", não "Adicionar, 2".
  - Dias: o que `WeekdayPicker` já faz ("terça, selecionado, já usado por outra ficha").
  - O "…" da linha no detalhe do programa lê "Ações de {ficha}"; na lista de Treinos a linha ganha a ação personalizada "Copiar para outro programa".
  - Ao entrar o estado final o foco vai para "Ficha copiada". No fluxo B, ao fechar: anúncio "2 fichas adicionadas a Hipertrofia ABC" ("1 ficha adicionada a…").
- **Dynamic Type até AX5**: nomes quebram em quantas linhas precisarem (sem `lineLimit`). Em tamanhos de acessibilidade a linha empilha com `FJAdaptiveStack` (indicador e selo em cima; nome, resumo, dias e "Entra como…" abaixo) e a etiqueta "Ativo"/"Arquivado" desce para baixo do nome. O selo para em 1,4×. Os sete dias continuam inteiros, com 44 pt cada: se não couberem numa linha, quebram em 4 + 3 (`FJFlowLayout`). Rodapés nunca truncam.
- **Sem depender de cor**: marcado tem check; dia ocupado tem ponto e a frase com o nome da ficha; bloqueado tem etiqueta com texto.
- **Reduzir Transparência / Movimento**: folha, toolbar e push são do sistema; a troca para o estado final usa `FJMotion.structure` (esmaecimento).
- **Hápticos**: marcar programa, ficha ou dia `selection` · cópia concluída `celebration` · bloqueio por treino em andamento `warning` · falha `error`.

**Para quem implementa**

- A cópia segue a regra do "Duplicar": a carga atual vira a carga inicial da cópia; os exercícios do catálogo são referenciados, não duplicados.
- A regra do nome é uma função pura, testável, usada pela folha (para mostrar "Entra como…" antes de confirmar) e pela gravação.
- O bloqueio usa o que já existe (`ProgramStore.ensureNoSession(in:)`, `sessionInProgress`); o aviso de `SessionBlockBanner` precisa aceitar a mensagem deste caso.
- `ProgramEditorSheet` já tem `onSaved`: é por ele que "Novo programa…" marca o programa recém-criado.

### 4.3 Editor de ficha

Push a partir da ficha. `List` nativa em modo de edição permanente (alças de arrastar à direita). Toolbar: "OK"; no "…", "Copiar para outro programa…" (§4.2.1). Base: `FJPrimaryButton("Adicionar exercício")` fixo (abre a Biblioteca como seletor múltiplo).

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
| Descanso | `FJRestTimerView`: "DESCANSO", o que vem a seguir ("Série 3 de 4 · 26 kg · alvo 8–12"), tempo em 60 pt, barra, **−15 s · Pular · +15 s** (52 pt de altura). Ao zerar: háptico + som opcional + anúncio no VoiceOver, rótulo "Descanso concluído", tempo parado em 0:00 e o botão central vira "Continuar"; a doca volta ao modo Série ao tocar em Continuar/qualquer check, ou sozinha após 10 s. A lista continua utilizável durante o descanso (ajustar a próxima carga, informar as reps da série feita). Com o **alerta insistente** ligado (padrão), o fim do descanso abre o alerta abaixo por cima da doca. |
| Sustentação | Antes: `FJPrimaryButton("Iniciar sustentação")`. Durante: contagem regressiva em 60 pt com 3 s de preparação ("3, 2, 1"), botão "Parar" (registra o tempo real e conclui a série); ao zerar: háptico, continua contando o excedente até "Parar". |
| Cardio | Cronômetro em 60 pt, "Iniciar" / "Pausar" / "Concluir". |
| Próximo | Exercício concluído: "Próximo: Crucifixo" (`FJPrimaryButton`), 1 toque expande o próximo. |
| Finalizar | Tudo concluído ou pulado: `FJPrimaryButton("Finalizar treino", "flag.checkered")`. Com pendentes, "Finalizar treino" continua no menu "…". |

**Alerta de fim de descanso** (`FJRestAlertCard`; preferência "Alerta insistente no fim do descanso", ligada por padrão). Pedido do usuário: "igual ao timer do iPhone — vibra várias vezes até eu tocar".

```
┌──────────────────────────────────┐
│░░░░░░░░ lista escurecida ░░░░░░░░│  véu (`FJColor.scrim`): qualquer toque para e fecha
│ ┌──────────────────────────────┐ │
│ │          ((  ◯  ))           │ │  anel laranja pulsando
│ │           +0:12              │ │  tempo desde o fim do descanso
│ │      Descanso concluído      │ │
│ │       Supino inclinado       │ │
│ │ Série 3 de 4 · 26 kg · 8–12  │ │  a próxima série, como prescrita
│ │ [       Começar série      ] │ │  botão principal (56 pt)
│ │ Toque em qualquer lugar para │ │
│ │            parar             │ │
│ └──────────────────────────────┘ │  cartão de vidro no lugar da doca
└──────────────────────────────────┘
```

- **Quando abre**: o descanso zera com a tela da sessão aberta, o app em primeiro plano e nada por cima (folha, diálogo, encerramento). Fora disso vale o de antes: uma vibração (tela minimizada ou folha aberta) ou a notificação/Atividade ao Vivo (app em segundo plano ou bloqueado, §4.14).
- **O que faz**: o iPhone vibra a cada 1,5 s (vibração longa, §2.4) e o cartão cobre a doca — o painel de descanso por baixo não vibra nem anuncia por conta própria (um aviso só); a lista fica escurecida e não recebe toques. O anel pulsa (ondas saindo do anel + contorno do cartão) e o número conta para cima a partir de "+0:00" — o descanso oficial continua parado em 0:00 (decisão 9); aqui se mostra há quanto tempo ele acabou.
- **Como para**: **qualquer toque ou arrasto** na tela para a vibração e fecha o alerta sem enviar nada — a doca aparece como estaria ("Descanso concluído · Continuar" nos primeiros 10 s, depois "Concluir série 3"). **Começar série** faz o mesmo e dispensa o descanso (igual ao "Continuar"). Alerta fechado no relógio ("Começar série" de lá) fecha o do iPhone, e vice-versa.
- **Teto**: 60 s depois do fim do descanso a vibração para sozinha; o cartão fica, sem pulsar e sem a dica, até um toque.
- **Não duplica**: um alerta por descanso. Pular, ±15 s, concluir outra série, pausar ou finalizar (aqui, no relógio ou na Tela Bloqueada) encerram o alerta; +15 s depois do fim abre um novo no novo horário.
- **Som**: o alerta em primeiro plano só vibra. "Som ao fim do descanso" continua valendo para a notificação e a Atividade ao Vivo.
- **Reduzir Movimento**: nada pulsa; o anel vira um disco laranja cheio com o número em branco e o contorno do cartão fica fixo (destaque só por contraste). A vibração continua.
- **Reduzir Transparência**: cartão sólido (`fjGlass`), véu igual.
- **VoiceOver**: ao abrir anuncia "Descanso concluído. Próxima: Supino inclinado, Série 3 de 4 · 26 kg · alvo 8–12."; o cartão é modal (o foco não escapa para a lista); cabeçalho "Descanso concluído, há 12 segundos"; "Começar série" com a dica "Para a vibração e volta à série"; gesto de escape (Z), toque mágico e a ação "Parar vibração" (no cabeçalho e na próxima série, pelo rotor de ações) fecham o alerta.
- **Texto grande (AX)**: sem anel; "Descanso concluído" e "+0:12" em linhas próprias, nome e próxima série quebram linha, botão em largura total.
- **Desligado** (Ajustes › Treino): comportamento anterior — uma vibração e a doca em "Descanso concluído".

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
| Tela bloqueada / segundo plano | Notificação local ao fim do descanso (permissão pedida no contexto, no primeiro descanso; negada = só háptico em primeiro plano). No ciclo 6 a Atividade ao Vivo (§4.14) mostra o descanso na Tela Bloqueada e na Dynamic Island, com +15 s e Pular. |
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

Título grande "Saúde", tint da área saúde. Seletor segmentado **Dia | Tendências**. Navegação de dia como na Dieta (‹ **Hoje, 11 nov** ›; toque abre o calendário; não avança além de hoje) e faixa da semana com um ponto nos dias com treino.

Três regras valem para a aba inteira:

- **Sem dado não é zero.** Um número só aparece quando existe pelo menos uma amostra no período. Soma de nenhuma amostra é "—" com o motivo em texto, nunca "0". O único zero legítimo é o que o próprio FitJourney sabe ("Nenhum treino neste dia").
- **Nunca soma duas vezes.** Minutos e energia de treino do dia usam a **união dos intervalos** de tempo, não a soma dos treinos. Um treino do Watch que se sobrepõe a uma sessão do app não infla o total, esteja vinculado ou não.
- **Comparação sem juízo.** "Hoje x semana" é sempre o valor de hoje contra a **média dos 7 dias anteriores** (hoje fora da média), em texto neutro com seta e número: "↑ 74 kcal acima da sua média", "↓ 2 bpm abaixo da sua média", "na média" (diferença menor que 2%). Sem verde/vermelho e sem "bom/ruim": o app registra, não interpreta.

#### Dia

Rolagem de cartões sólidos, nesta ordem:

1. **Frequência cardíaca** (`FJCard`).
   - Cabeçalho: faixa do dia em `numberHero` ("58–164 bpm") e, à direita, "Repouso 56 bpm". Em hoje, a sobrelinha diz "FREQUÊNCIA CARDÍACA · ATÉ AGORA".
   - Gráfico de 24 h (Swift Charts, 180 pt): uma barra de mín–máx por intervalo de 15 min, cantos redondos, na cor da saúde. Eixo X em 0h · 6h · 12h · 18h; eixo Y à direita com 3 marcas. Intervalo sem leitura fica **vazio** (relógio fora do pulso); nada é interpolado. Em hoje o gráfico termina no horário atual e o resto fica em branco.
   - **Treinos sobrepostos**: faixa vertical atrás das barras, do início ao fim de cada treino — laranja (Força) ou turquesa (Aeróbico) a 18% — com o símbolo do tipo (`dumbbell.fill` / `figure.run`) num selo de 20 pt no topo da faixa. As barras dentro da faixa continuam na cor da saúde. Faixa mais estreita que 20 pt mantém a faixa e centraliza o selo sobre ela.
   - **FC em repouso**: linha horizontal tracejada fina em `textSecondary`, rótulo "repouso" no eixo.
   - **Seleção**: arrastar mostra a régua vertical e troca o cabeçalho (sólido, sem balão) por "14:15 · 72–88 bpm"; dentro de uma faixa de treino acrescenta o nome ("A — Peito e tríceps"). Tocar no selo de um treino abre o detalhe dele.
2. **Treinos do dia** (lista em `FJCard`): uma linha por treino — `FJRoutineBadge(.sm)` para sessões do app ou o símbolo do tipo em quadrado `fill` para treinos de fora; nome ("A — Peito e tríceps", "Corrida ao ar livre"); `FJTag` **Força**/**Aeróbico**; "18:05 · 52 min · FC média 128 · 318 kcal"; origem em `caption` ("FitJourney", "Apple Watch", "FitJourney + Apple Watch" com o símbolo `link`). Toque abre o detalhe. Treino vinculado é **uma** linha. Sugestão de vínculo pendente: ver "Vínculo" abaixo.
3. **Força x aeróbico** (`FJCard`).
   - Hoje: barra empilhada horizontal de minutos (laranja + turquesa, 12 pt de altura) e duas `FJMetricCell` com símbolo e rótulo: "Força 52 min" · "Aeróbico 31 min".
   - Semana: sete barras empilhadas verticais (a semana começa no dia definido em Ajustes), **hoje com opacidade total e rótulo em negrito**, os outros dias a 45%; linha tracejada na média diária. Legenda em texto: "Hoje 83 min · média da semana 46 min por dia". Tocar numa barra navega para aquele dia.
   - Dia sem treino = sem barra (zero real). Dia sem acesso aos dados = traço "—" no lugar da barra.
4. **Energia ativa** e **FC em repouso**: dois cartões lado a lado (`FJAdaptiveStack`; empilham em tamanhos de acessibilidade), mesma anatomia — rótulo com símbolo, valor em `numberLarge` + unidade, minigráfico de 7 dias (barras para energia, linha com pontos para FC em repouso; hoje destacado) e a linha de comparação com a semana. Energia traz ainda "318 kcal em treinos".
5. **Mais** (`FJMetricGrid`): Passos · VFC · Peso (última leitura, com a data se não for de hoje). Cada célula mostra "—" quando não há amostra.

#### Tendências

Fileira de `FJFilterChip` de período (4 sem · 8 sem · 3 m). Três cartões, cada um com o valor atual no cabeçalho e a comparação com o período anterior em texto neutro: **Minutos por tipo** por semana (barras empilhadas Força/Aeróbico), **FC média por treino** (pontos na cor do tipo, com símbolo na legenda), **FC em repouso** (linha, média móvel de 7 dias). Menos de duas semanas de dados: o cartão mostra o que existe e "Continue registrando para ver a tendência".

#### Detalhe do treino (sessão) com faixas por exercício

1. Cabeçalho: `FJRoutineBadge(.lg)`, nome, data e hora, `FJTag` do tipo, origem. Vinculado: linha "Vinculado ao treino do Apple Watch" com `link` e menu "Desvincular".
2. `FJMetricGrid`: Duração · FC média · FC máx · Energia · Volume · RPE.
3. **Gráfico de FC × tempo** (`FJCard`, 240 pt):
   - Linha de FC na cor da saúde, 2 pt; lacunas de dado ficam como lacunas.
   - **Faixas por exercício**: retângulos verticais do início (1ª série) ao fim (última série concluída), alternando dois tons neutros (`fill` e transparente), cada um com o **número do exercício** num selo no topo; a legenda numerada é a lista abaixo. Faixas não usam cor de zona, de área nem de ficha.
   - Faixa mais estreita que 16 pt: o número sai do gráfico e fica só na lista; a faixa continua. Bi-set/circuito: **uma** faixa para o grupo, com "2+3". Exercício pulado: sem faixa; aparece na lista como "pulado". Exercício retomado depois de outro: duas faixas com o mesmo número.
   - **Pausas**: intervalo pausado com hachura diagonal em `fill` e o símbolo `pause.fill` no topo; a linha de FC continua por cima.
   - **Marcadores de série**: pontos de 6 pt sobre a linha no `completedAt` de cada série.
   - **Zonas**: linhas horizontais finas nos limites, com "Z2…Z5" no eixo direito na cor da zona + rótulo.
   - **Seleção**: tocar/arrastar mostra a régua e, no cabeçalho do cartão, "2 · Supino inclinado — série 3 · média 131 · máx 142 bpm". Sem seleção: média e máx do treino. Tocar numa linha da lista de exercícios seleciona a faixa.
   - Treino com mais de 90 min: o gráfico rola na horizontal mostrando 60 min por vez (`chartScrollableAxes`); abre no início.
4. **Tempo em cada zona**: 5 barras horizontais com `FJHeartRateZoneBadge`, minutos e %.
5. **Exercícios**: lista numerada (mesmos números das faixas) com FC média/máx por exercício e as séries.

#### Vínculo com treino do Apple Watch

Quando existe no Saúde um treino de outra origem (app Exercício do Watch) no mesmo horário de uma sessão do FitJourney, os dois são **o mesmo treino**: a sessão fica com as séries do app e com a FC e a energia do relógio. O núcleo classifica o candidato em dois níveis (os limiares são dele; referência: sobreposição ≥ 80% da duração menor e inícios a menos de 10 min = alta).

| Nível | O que o app faz | Onde aparece |
|---|---|---|
| **Alta** | Vincula sozinho, e avisa. Reversível. | `FJBanner` neutro (símbolo `link`) no topo do detalhe, até ser dispensado: "Vinculado ao treino do Apple Watch (18:04–18:57)." · ação **Desfazer**. Na lista do dia: uma linha, origem "FitJourney + Apple Watch". |
| **Incerta** | Não vincula. Pede confirmação. | `FJBanner` de atenção no topo do detalhe **e** na lista do dia (os dois treinos unidos por um colchete tracejado com a etiqueta "Mesmo treino?"). |

Cartão da sugestão incerta (dentro do `FJBanner` de atenção, conteúdo sólido):

```
⚠ Parece o mesmo treino
  FitJourney     18:05–18:57 · 52 min
  Apple Watch    18:20–19:02 · 42 min · Força tradicional
  37 min em comum
  [ Vincular ]   [ Não é o mesmo ]
```

- **Vincular** → háptico de sucesso, as duas linhas viram uma, o detalhe ganha o gráfico de FC. **Não é o mesmo** → os dois ficam separados e a pergunta não volta (decisão guardada no par).
- Mais de um candidato: "Vincular" abre uma sheet `.medium` com a lista (horário, duração, tipo, minutos em comum; seleção única) e "Nenhum destes".
- Manual, a qualquer momento: menu "…" do detalhe da sessão → "Vincular a um treino do Saúde…"; no detalhe de um treino externo → "Vincular a um treino do FitJourney…". Sessão vinculada: "Desvincular".
- A sugestão nunca aparece como alerta nem notificação: fica nos dois lugares fixos (e na linha de estado do encerramento, §4.6).
- Enquanto a sugestão está pendente, os totais do dia já contam o intervalo uma vez só (união).

#### Estados

O HealthKit não informa se a **leitura** foi negada: acesso negado e ausência de dados chegam iguais (nenhuma amostra). Só a permissão de **gravar** é verificável. Por isso os estados de leitura falam do que se vê ("sem dados") e oferecem o caminho para conferir o acesso, em vez de afirmar "permissão negada".

| Estado | O que aparece |
|---|---|
| Saúde nunca conectado | `FJEmptyState` "Conecte ao app Saúde" com 3 linhas do que será lido e `FJPrimaryButton("Conectar ao Saúde", area: .health)`. Abaixo, os treinos do FitJourney do dia continuam visíveis (dados próprios), sem FC. Nenhum eixo de gráfico vazio. |
| Conectado, **sem nenhuma leitura de FC** nos últimos 30 dias, sem Apple Watch pareado | Cartão de FC vira uma linha: símbolo `applewatch.slash`, "Sem Apple Watch", "A frequência cardíaca vem do Apple Watch ou de um sensor pareado." Sem botão. Treinos, força x aeróbico e o que mais houver continuam. |
| Conectado, sem nenhuma leitura de FC nos últimos 30 dias, **com** Apple Watch pareado | `FJBanner` de atenção: "Sem dados de frequência cardíaca" · "Confira se o FitJourney pode ler seus dados em Ajustes › Saúde › Acesso a Dados." · **Abrir Ajustes**. |
| **Sem leituras neste dia** (há em outros dias) | Cartão de FC compacto: "Sem leituras neste dia" em secundário, sem eixos. FC em repouso "—". |
| Leituras parciais no dia | Gráfico com lacunas; legenda "leituras em 9 h do dia". |
| Hoje, dia em curso | Sobrelinha "ATÉ AGORA"; comparações usam o valor parcial e dizem "até agora". |
| Dia sem treino | "Nenhum treino neste dia" na lista; força x aeróbico mostra só a semana. |
| Energia/passos/VFC sem amostra | "—" na célula; a linha de comparação some. Nunca "0 kcal". |
| Média da semana com menos de 3 dias de dados | Valor de hoje sem comparação: "Poucos dias para comparar". |
| Gravação negada (verificável) | `FJBanner` de atenção em Ajustes › Saúde e no encerramento: "Sem acesso para gravar no Saúde — o treino fica só no FitJourney" · **Abrir Ajustes**. A aba Saúde não muda. |
| Carregando | `FJLoadingState` dentro de cada cartão que espera o Saúde ("Lendo dados do Saúde…"); cartões com dados locais aparecem de imediato. Sem esqueleto piscando. |
| Erro de leitura | `FJBanner` destrutivo no cartão + "Tentar de novo". Os outros cartões seguem. |
| Treino sem FC | Detalhe: `FJBanner` neutro no lugar do gráfico ("Sem frequência cardíaca neste treino") e sem "tempo em cada zona". |
| Treino externo sem sessão do app | Gráfico sem faixas por exercício; "Vincular a um treino do FitJourney…" no menu (ou a sugestão, se houver candidato). |
| Saúde indisponível no aparelho / simulador | `FJEmptyState` "Saúde indisponível neste aparelho"; só os treinos do FitJourney. |

Acessibilidade da aba: cada gráfico tem `accessibilityChartDescriptor` (dia: "Frequência cardíaca entre 58 e 164, repouso 56; 2 treinos"; semana: um valor por dia) e os mesmos dados existem em texto nos cartões; a comparação é lida por extenso ("74 quilocalorias acima da sua média de 7 dias"); a sugestão de vínculo é um elemento com as duas ações como botões separados; força/aeróbico sempre com símbolo e rótulo.

### 4.12 Ajustes

Sheet `.large` a partir do avatar em Hoje, com `NavigationStack` próprio; cada grupo grande é um push. Quando a aba Coach existir, a engrenagem da toolbar do Coach abre direto **Coach e IA**. `Form` nativo, sem vidro.

**Raiz**

| Seção | Linhas |
|---|---|
| (topo) | **Perfil** — círculo com as iniciais, "Seu perfil" e o resumo ("34 anos · 78 kg · intermediário") ou "Opcional — ajuda o Coach a conhecer você" → push (§4.13.6) |
| Unidades | Carga (**kg \| lb**, segmentado na linha) · Passo de carga (menu: **0,5** · 1 · 2 · 2,5 · 5; padrão 0,5 kg / 1 lb) · Distância (km \| mi) · Semana começa em (segunda \| domingo). Rodapé: "Mudar a unidade muda só a exibição. O histórico não é alterado." |
| Treino | Descanso padrão · Som ao fim do descanso · **Alerta insistente no fim do descanso** (ligado; relógio e tela do treino vibram até um toque — desligado, uma vibração; vale no relógio a partir da próxima ação na sessão) · Hápticos na sessão · **Atividade ao Vivo** (§4.14) · Sugerir progressão (desligado) · Limite de vídeo |
| Dieta | Tamanho do copo |
| Integrações | **Saúde** (estado à direita: "Conectado" / "Não conectado") → push · **Notificações** (estado: "Permitidas" / "Desativadas") → push · **Coach e IA** (estado: "OpenAI · gpt-5-mini" / "Não configurado") → push (§4.13.5) |
| Dados | **Exportar, importar e apagar** → push |
| Sobre | Versão, privacidade; o motivo do ícone (§2.6) no topo da tela Sobre |

**Unidades kg/lb**: os valores são guardados como foram digitados e convertidos só na exibição; a troca é imediata, sem confirmação. Com lb, o passo padrão vira 1 lb e as cargas exibidas arredondam para o passo. Com sessão em andamento a troca vale na hora (a série atual é reexibida na nova unidade).

**Saúde** (push)

- Estado no topo: `FJBanner` conforme o caso — neutro "Conectado ao Saúde" · atenção "Não conectado" com **Conectar ao Saúde** (abre a sheet do §5.7) · atenção "Sem acesso para gravar" com **Abrir Ajustes**.
- Gravar treinos no Saúde (toggle) · Vincular treinos do Apple Watch automaticamente quando a correspondência for alta (toggle, ligado; desligado = sempre perguntar).
- FC máxima: "Pela idade (186 bpm)" | "Manual" + campo. Sem idade no perfil: "Informe sua idade no Perfil ou digite um valor".
- Zonas: cinco linhas com `FJHeartRateZoneBadge`, faixa em % e em bpm ("Z3 · 70–80% · 130–149 bpm"); toque edita os limites; "Restaurar padrão".
- Rodapé: "Seus dados de saúde ficam neste iPhone. Só vão ao Coach se você ligar 'Saúde' em Coach e IA."

**Notificações** (push)

- Estado do sistema no topo: "Permitidas" · "Ainda não solicitadas" (o pedido acontece ao ligar o primeiro toggle) · `FJBanner` de atenção "Desativadas nos Ajustes do iPhone" + **Abrir Ajustes** (os toggles abaixo ficam desabilitados, mantendo o valor).
- Fim do descanso (toggle; rodapé: "Com a Atividade ao Vivo ligada, o aviso vem por ela.") · Lembretes de refeição (toggle geral + "4 refeições com lembrete · Editar no plano") · Treino em aberto há mais de 4 h (toggle).

**Dados** (push)

1. **Exportar tudo** — linha com `square.and.arrow.up`. Toque → a linha mostra progresso ("Preparando… 62%", cancelável) → folha de compartilhamento com `FitJourney-2026-11-11.json`. Rodapé: "Inclui programas, treinos, dieta, registros e ajustes. Fotos, vídeos e chaves de IA não entram no arquivo."
2. **Importar backup** — `fileImporter` → validação → sheet `.medium` com o resumo antes de qualquer mudança:
   - "Backup de 2 de novembro de 2026 · formato v1"
   - contagens: 3 programas · 142 treinos · 2 dietas · 1.204 registros alimentares
   - modo: **Juntar com o que já existe** (padrão; itens com o mesmo identificador não duplicam, vale o mais recente) | **Substituir tudo** (destrutivo; pede a mesma confirmação em dois passos de "Apagar")
   - [Importar] [Cancelar]. Depois: `FJBanner` de sucesso "Importado: 142 treinos, 3 programas…".
3. **Armazenamento** — "Mídia dos exercícios: 312 MB" (só leitura).
4. **Apagar todos os dados** (destrutivo, em seção própria no fim). Toque → tela "Apagar todos os dados" com a lista do que some (programas e fichas, treinos, dieta e registros, mídia, conversas do Coach, perfil, chaves de IA, ajustes), o aviso "Treinos já gravados no app Saúde continuam lá" e o atalho "Exportar antes". Botão destrutivo **Apagar tudo…** → `confirmationDialog` ("Apagar todos os dados do FitJourney?") → alerta final "Isso não pode ser desfeito." [Apagar definitivamente] [Cancelar]. Depois: o app volta ao primeiro uso (Hoje com convites).

| Estado | O que muda |
|---|---|
| Exportando / importando | Progresso na própria linha, cancelável; as outras linhas de Dados ficam desabilitadas. |
| Arquivo inválido ou de outro app | Alerta com o motivo ("Este arquivo não é um backup do FitJourney"); nada é alterado. |
| Backup de versão mais nova | Alerta "Este backup foi feito por uma versão mais nova do FitJourney. Atualize o app para importar." |
| Falha no meio da importação | Nada é aplicado (tudo ou nada); `FJBanner` destrutivo com "Tentar de novo". |
| Sessão em andamento | "Importar" e "Apagar" desabilitados com a explicação na linha: "Finalize o treino em andamento primeiro"; "Exportar" funciona. |
| Sem nada para exportar | "Exportar" desabilitado: "Ainda não há dados". |

### 4.13 Coach (fase 2)

Aba **Coach** (quinta aba, símbolo `sparkles`, tint azul da área). Tudo sólido: mensagens, cartões de proposta e formulários não usam vidro; vidro só na barra de composição (flutua), nos chips de sugestão e nas toolbars.

#### 4.13.1 Boas-vindas e consentimento

Primeira vez na aba (e enquanto não houver consentimento), no lugar da lista — é a própria tela da aba, não um modal. Duas etapas com a ação principal fixa na base.

**Etapa 1 — o que é e o que sai do aparelho**

1. Símbolo `sparkles` grande na cor do Coach, título "Seu Coach de IA", uma frase: "Converse para montar treinos e dietas. Tudo o que ele propõe é um rascunho que você revisa antes de salvar."
2. `FJCard` **"Para onde vão seus dados"**: "O que você escolher compartilhar é enviado ao provedor de IA que você configurar (OpenAI, Anthropic ou outro), com a sua própria chave. O FitJourney não tem servidor: nada passa por nós."
3. `FJCard` **"Compartilhar com o Coach"** — quatro toggles, todos **desligados** por padrão, cada um com uma linha do que é enviado:
   - Perfil — "idade, peso, nível, objetivo, restrições"
   - Treinos — "programas, fichas e histórico de séries"
   - Dieta — "plano alimentar e registros"
   - Saúde — "resumos de FC, energia e treinos do app Saúde"
4. Linha em `caption`: "O Coach não faz diagnóstico nem substitui médico, nutricionista ou educador físico."
5. Base: `FJPrimaryButton("Concordar e continuar", area: .coach)` · link "Agora não" (a aba fica com um `FJEmptyState` "Ative o Coach quando quiser" + "Começar").

**Etapa 2 — configurar a IA** (pulada se já houver provedor pronto): provedor, chave e modelo, os mesmos campos do §4.13.5 em versão curta, "Testar conexão" e `FJPrimaryButton("Começar a conversar")`. "Fazer isso depois" leva à lista com o aviso de configuração.

#### 4.13.2 Lista de conversas

Título grande "Coach". Toolbar: engrenagem (Coach e IA) e `square.and.pencil` (nova conversa). `.searchable`.

- `List` com seções "Hoje", "7 dias anteriores", "Mais antigas". Linha: título (gerado da primeira mensagem; renomeável), prévia da última mensagem em uma linha, data relativa; à direita, quando houver, `FJTag("Rascunho", systemImage: "doc.badge.plus", area: .coach)` (a conversa tem proposta ainda não salva). Deslizar: Renomear · Apagar (destrutivo, com confirmação).
- Linha com resposta em andamento: prévia "Respondendo…" e indicador de atividade pequeno. Resposta que falhou: símbolo de atenção + "Não foi possível responder".
- Rodapé da lista: "OpenAI · gpt-5-mini · compartilhando Treinos e Dieta" — toque abre Coach e IA.

| Estado | O que muda |
|---|---|
| Sem conversas | `FJEmptyState` "Pergunte ao Coach" + sugestões de prompt em chips de vidro (`FJFlowLayout`): "Monte um ABC de hipertrofia, 4x por semana, 60 min" · "Ajuste minha dieta para 2.200 kcal" · "Como foi minha evolução no supino?" · "O que treinar hoje?". Tocar numa sugestão abre uma conversa nova com o texto no campo (não envia sozinho). |
| IA não configurada | `FJBanner` de atenção no topo: "Falta a chave da OpenAI" (ou "Escolha um modelo", "Endereço inválido") + **Configurar**. Conversas antigas continuam legíveis; o campo de mensagem fica desabilitado com a mesma explicação. |
| Nada compartilhado | `FJBanner` neutro dispensável: "O Coach ainda não vê seus treinos nem sua dieta" + **Escolher o que compartilhar**. |
| Sem rede | Nada muda na lista; o erro aparece ao enviar. |
| Busca sem resultado | `ContentUnavailableView.search`. |

#### 4.13.3 Conversa (chat)

Push a partir da lista; a tab bar some dentro da conversa (como em Mensagens) para a barra de composição ficar na base. Título = título da conversa, subtítulo = modelo. Menu "…": Renomear · O que esta conversa pode ler · Apagar conversa.

```
┌──────────────────────────────────┐
│ ‹ Coach     ABC de hipertrofia  … │  barra (vidro do sistema)
│            gpt-5-mini             │
├──────────────────────────────────┤
│        ┌───────────────────────┐ │
│        │ Monte um ABC de       │ │  você: balão à direita
│        │ hipertrofia, 4x/sem   │ │
│        └───────────────────────┘ │
│ ✦ Pensou por 12 s            ⌄   │  raciocínio (recolhido)
│ ✓ Leu 24 treinos · 90 dias       │  ferramentas (o que foi lido)
│ ✓ Leu o programa ativo           │
│ Montei um ABC com base no que    │  Coach: texto sem balão
│ você vem treinando…              │
│ ┌──────────────────────────────┐ │
│ │ RASCUNHO DE PROGRAMA         │ │  cartão de proposta (§4.13.4)
│ └──────────────────────────────┘ │
├──────────────────────────────────┤
│ ( Pergunte ao Coach…        ) (↑)│  composição (vidro)
└──────────────────────────────────┘
```

**Mensagens**

- **Você**: balão à direita, fundo `coachFill`, texto branco, raio 20 pt contínuo, largura máxima 82% (100% em tamanhos de acessibilidade).
- **Coach**: texto direto sobre o fundo da tela, largura total, sem balão nem avatar; Markdown básico (negrito, listas, títulos curtos, tabelas simples viram lista em telas estreitas); texto selecionável.
- Primeira mensagem de cada conversa é precedida por uma linha em `caption`: "Esta conversa pode ler: Treinos · Dieta. **Alterar**" (ou "Nada do seu histórico está compartilhado. **Alterar**").
- Ações da mensagem (menu de contexto e, na última resposta, uma fileira de botões de ícone de 44 pt): Copiar · Tentar de novo.

**Raciocínio** (quando o provedor envia)

- Durante: linha "✦ Pensando… 8 s" (segundos por data de início; o símbolo pulsa uma vez por segundo, parado com Reduzir Movimento). Tocar expande o texto do raciocínio, que só cresce (nunca é reescrito).
- Depois: "✦ Pensou por 12 s" recolhido por padrão; expandido mostra o texto em `caption`, cor secundária, com um filete de 2 pt à esquerda. Raciocínio omitido pelo provedor: "Raciocínio não disponível", sem expandir.
- O raciocínio nunca é confundido com a resposta: outra cor, outro tamanho, recolhido.

**Ferramentas — o que o Coach leu**

Cada consulta local aparece como uma linha de estado, na ordem em que aconteceu. É a prova, na tela, do que saiu do aparelho.

| Momento | Linha |
|---|---|
| Em andamento | indicador pequeno + "Lendo seu histórico de treinos (últimos 90 dias)…" |
| Concluída | `checkmark` neutro + "Leu 24 treinos · 90 dias" · "Leu o programa ativo" · "Leu a dieta de 4 a 10 de nov" · "Leu o resumo de saúde de 30 dias" |
| Bloqueada pelo compartilhamento | `lock` + "Dieta não compartilhada" + link **Permitir** (abre os toggles; a resposta segue sem esse dado) |
| Falhou | símbolo de atenção + "Não foi possível ler o histórico" |

Mais de três linhas recolhem em "Consultou 5 fontes" (expansível).

**Streaming**

- O texto entra em blocos conforme chega, sem animação letra a letra; um ponto `●` estático marca o fim enquanto a resposta está em curso.
- A tela acompanha o fim do texto **só** se o usuário já estava no fim. Se ele rolou para cima, a rolagem não é puxada: aparece um botão de vidro circular "↓" acima da composição que leva ao fim.
- Durante a resposta o botão de enviar vira **Parar** (`stop.fill`). Parar mantém o que já chegou, com "Interrompida" em `caption` e "Tentar de novo".
- Sem hápticos durante o streaming.

**Composição** (`safeAreaInset(edge: .bottom)`, vidro em cápsula)

- Campo de várias linhas (1 a 6) "Pergunte ao Coach"; botão circular de 44 pt à direita: `arrow.up` em `coachFill` (desabilitado com o campo vazio) ou `stop.fill` durante a resposta.
- Conversa vazia: até quatro sugestões em chips logo acima do campo.
- Rolagem dispensa o teclado de forma interativa; a composição acompanha o teclado.
- Uma resposta por vez: enquanto uma está em curso, enviar outra fica desabilitado (dá para digitar).

**Estados da resposta**

| Estado | O que aparece |
|---|---|
| Aguardando o primeiro bloco | "✦ Pensando…" (mesmo sem raciocínio do provedor) |
| Em streaming | texto + `●`; botão Parar |
| Concluída | texto; fileira Copiar · Tentar de novo na última |
| Interrompida pelo usuário | texto parcial + "Interrompida" · **Tentar de novo** |
| Interrompida ao fechar o app | igual a interrompida (o app nunca reabre "em streaming") |
| Cortada pelo limite de tamanho | texto + `FJBanner` neutro "A resposta atingiu o limite de tamanho" · **Continuar** |
| Recusa / filtro do provedor | `FJBanner` neutro com o texto do erro · "Tente reformular" |
| Limite de consultas atingido | `FJBanner` neutro "O Coach fez consultas demais nesta resposta" · **Tentar de novo** |
| Chave inválida | `FJBanner` destrutivo "A chave da OpenAI foi recusada" · **Abrir Coach e IA** |
| Limite do provedor | `FJBanner` de atenção "Limite do provedor atingido. Tente em 20 s" (contagem por data) · **Tentar de novo** habilita ao fim |
| Sem conexão / erro do servidor | `FJBanner` destrutivo "Sem conexão" / "O provedor está com problemas" · **Tentar de novo**; a mensagem do usuário fica preservada |
| Menção a dor, lesão ou condição de saúde | A resposta segue; o prompt do sistema já orienta a recomendar um profissional. Sem cartão especial. |

#### 4.13.4 Cartão de proposta

Quando a resposta traz um `ProgramDraft` ou `NutritionPlanDraft`, ele aparece dentro da mensagem como um `FJCard` com contorno de 1,5 pt na cor do Coach. É a única coisa na conversa que leva a salvar algo.

**Programa**

```
┌──────────────────────────────────┐
│ ✦ RASCUNHO DE PROGRAMA           │
│ Hipertrofia ABC                  │  cardTitle
│ [Hipertrofia] [Sequencial] [4x/sem]│ FJTag
│ ──────────────────────────────── │
│ [A] Peito e tríceps         ⌄   │  FJRoutineBadge(.sm) + nome
│     6 exercícios · ~55 min       │
│ [B] Costas e bíceps         ›   │
│ [C] Pernas e ombros         ›   │
│ ──────────────────────────────── │
│ [     Revisar e salvar     ]     │  FJPrimaryButton(area: .coach)
│ [ Pedir ajustes ]                │  FJSecondaryButton
└──────────────────────────────────┘
```

- Tocar numa ficha expande os exercícios, um por linha, com a prescrição no formato de sempre ("Supino reto · 4 × 8–12 · 90 s"). Exercício que não existe no catálogo leva `FJTag("novo")` — será criado ao salvar.
- Cores e letras das fichas: as do rascunho; sem cor, `FJRoutineColor.suggested(forIndex:)`.
- **Revisar e salvar** abre o editor normal de programa em sheet `.large`, preenchido, origem "IA". Salvar segue o fluxo de sempre, inclusive "Ativar agora?". **Nada é gravado antes disso.**
- **Pedir ajustes** leva o foco ao campo de mensagem.

**Dieta**: sobrelinha "RASCUNHO DE DIETA", nome, metas em `FJMetricGrid` (kcal · proteína · carboidrato · gordura), refeições em linhas ("07:30 · Café da manhã · 4 itens · 420 kcal") que expandem nos itens; rodapé "Valores estimados pela IA" (grau de estimativa "IA" no plano salvo). Mesmos dois botões; abre o editor de plano.

| Estado | O que muda |
|---|---|
| Montando | Cartão com `FJLoadingState("Montando o rascunho…")`; sem botões. |
| Inválido (não passou no esquema, depois do reparo) | `FJBanner` de atenção no lugar do cartão: "O rascunho veio incompleto" · **Pedir de novo**. Nada para salvar. |
| Salvo | Botões dão lugar a `FJTag("Salvo", tone: .success)` + "Abrir programa". O cartão continua legível. |
| Substituído por um rascunho mais novo na mesma conversa | Recolhido numa linha "Rascunho anterior · Hipertrofia ABC" (expansível, ainda salvável). |
| Sessão em andamento | "Revisar e salvar" funciona; ativar o programa segue a regra do §5.5. |

#### 4.13.5 Coach e IA (Ajustes)

`Form`, push a partir de Ajustes ou da engrenagem do Coach.

1. **Provedor** — lista de seleção única: OpenAI (padrão) · Anthropic · OpenRouter · Compatível com OpenAI (endereço próprio). Cada linha mostra o estado à direita: `checkmark` "Pronto" ou "Falta a chave".
2. **Chave de API** — campo seguro com "Colar"; link "Onde encontro minha chave?" (abre a página do provedor no Safari). Salva: "••••••••3fA2" com **Trocar** e **Remover** (destrutivo). Rodapé: "Guardada no Keychain deste iPhone. Não entra na exportação nem em backups do app."
3. **Modelo** — menu com os sugeridos do provedor + "Outro…" (campo de texto).
4. **Endereço** (só no compatível): URL base e tamanho do contexto. Rodapé: "Aceita endereços https ou da sua rede local (ex.: Ollama no seu computador)."
5. **Testar conexão** — botão na própria seção; resultado na linha: "Conectado · respondeu em 0,8 s" (sucesso) ou o erro em texto (chave recusada, modelo não encontrado, sem conexão, endereço inválido).
6. **Compartilhar com o Coach** — os quatro toggles da boas-vindas, com as mesmas descrições. Rodapé: "Vale para as próximas mensagens. O que já foi enviado continua com o provedor."
7. **Conversas** — "Apagar todas as conversas" (destrutivo, confirmação) · "Desativar o Coach" (desliga os compartilhamentos e volta à boas-vindas; a chave fica até ser removida).

Estados: sem chave (rodapé de atenção "Falta a chave para usar o Coach"), sem modelo, endereço inválido (campo marcado + motivo), testando (indicador na linha, cancelável), Keychain indisponível (alerta "Não foi possível guardar a chave").

#### 4.13.6 Perfil

`Form`, push a partir de Ajustes (linha do topo) e da boas-vindas do Coach. **Tudo opcional**; campo vazio é "não informado", nunca zero.

- Cabeçalho: "Ajuda o Coach a conhecer você. Só é enviado se 'Perfil' estiver ligado em Compartilhar com o Coach."
- **Sobre você**: idade · sexo (Feminino | Masculino | Outro | não informar) · altura (cm) · peso (na unidade de carga dos Ajustes; com o Saúde conectado, "Usar o peso do Saúde · 78,4 kg").
- **Treino**: nível (Iniciante | Intermediário | Avançado, segmentado) · objetivo (texto + chips com as tags do programa) · dias por semana (1 a 7) · minutos por treino (chips 30 · 45 · 60 · 75 · 90) · equipamentos disponíveis (texto; chips de sugestão: Academia completa · Halteres · Elásticos · Peso corporal).
- **Cuidados**: restrições e lesões (texto livre). Rodapé: "Informativo. O Coach não faz diagnóstico."
- **Alimentação**: preferências e alergias (texto livre).
- A idade alimenta também a FC máxima "pela idade" (Ajustes › Saúde).

#### Acessibilidade do Coach

- Cada mensagem é um elemento: "Você: …" / "Coach: …". O raciocínio e as linhas de ferramenta são elementos separados, depois do texto na ordem de leitura; o cartão de proposta é um contêiner com título.
- Streaming: o texto em curso tem `.updatesFrequently` e não interrompe; ao terminar, um anúncio "Resposta do Coach concluída". "Parar" tem rótulo "Parar resposta".
- Dynamic Type até AX5: balões em largura total, chips quebram linha, os botões do cartão empilham; a composição cresce até 6 linhas e depois rola.
- Reduzir Movimento: sem pulso no "Pensando…"; a rolagem para o fim é um salto.
- Contraste: texto branco só sobre `coachFill`; links e símbolos na cor `coach`.

### 4.14 Atividade ao Vivo e Dynamic Island (ciclo 6)

Uma **única** Atividade ao Vivo por sessão: começa em "Iniciar treino", acompanha a sessão inteira e muda de conteúdo conforme o estado — **série**, **descanso**, **descanso concluído**, **pausado** — até o treino ser salvo ou descartado. O descanso é o estado principal (é quando o aparelho está no banco ou no bolso).

Regras:

- O tempo é desenhado pelo sistema (`Text(timerInterval:)`, `ProgressView(timerInterval:)`), a partir das mesmas datas do `SessionClock`. O app atualiza a atividade **só em eventos** (série concluída, descanso ajustado/pulado/terminado, troca de exercício, pausa, retomada, fim) — nunca a cada segundo.
- Fundo e material são os do sistema (sem `activityBackgroundTint`); na Tela Bloqueada as cores seguem claro/escuro (`FJColor.training`, `textPrimary`, `textSecondary`). A ilha é sempre preta: tons do tema escuro (`#FF9A3D`), `keylineTint` laranja.
- Glifo da atividade: o motivo do ícone (§2.6) numa cor só, 20 pt.
- FC não aparece na atividade (ficaria desatualizada; está no relógio e no app).
- Tocar em qualquer área fora dos botões abre o app na sessão em tela cheia.

#### Tela Bloqueada e banner

Altura alvo 132 pt (limite do sistema: 160 pt). Margens de 16 pt.

```
DESCANSO                                  SÉRIE
┌────────────────────────────────────┐    ┌────────────────────────────────────┐
│ ◢ DESCANSO                  32:14  │    │ ◢ Supino inclinado halter   32:14  │
│ 1:15        A seguir               │    │ Série 2 de 4                       │
│             Série 3 de 4           │    │ 26 kg · alvo 8–12 · RIR 2          │
│             26 kg · alvo 8–12      │    │ ▓▓▓▓▓▓▓▓▓░░░░░░░░░  3 de 6         │
│ ▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░ │    └────────────────────────────────────┘
│ [     + 15 s     ] [    Pular    ] │
└────────────────────────────────────┘
```

| Estado | Linha 1 | Corpo | Ações |
|---|---|---|---|
| **Descanso** | glifo + "DESCANSO" (`overline`, laranja) · tempo da sessão à direita (`numberCaption`, secundário) | Contagem regressiva em 44 pt rounded semibold com dígitos monoespaçados; à direita "A seguir" + "Série 3 de 4" + "26 kg · alvo 8–12" (o alvo como prescrito, D2); barra de progresso laranja de 4 pt | **+15 s** (neutro) · **Pular** (preenchido `trainingFill`, texto branco); cápsulas de 44 pt de altura, larguras iguais |
| **Descanso concluído** | `checkmark.circle.fill` (sucesso) + "DESCANSO CONCLUÍDO" | "0:00" sai; a próxima série sobe para o tamanho de título: "Série 3 de 4" + "26 kg · alvo 8–12" | Sem botões (não há o que pular); tocar abre o app |
| **Série** (exercitando) | glifo + nome do exercício (`headline`, 1 linha) · tempo da sessão | "Série 2 de 4" + alvo; barra de progresso da sessão com "3 de 6" exercícios | Sem botões (Q-LA1) |
| **Sustentação / cardio** | glifo + "SUSTENTAÇÃO" ou o nome do exercício | Como o descanso: contagem (regressiva até o alvo na sustentação; progressiva no cardio) + "alvo 0:45" | Sem botões |
| **Entre exercícios** | glifo + "PRÓXIMO" | "Crucifixo" + "3 × 12–15 · 15 kg" | Sem botões |
| **Pausado** | `pause.fill` + "PAUSADO" (secundário) | Tempo da sessão congelado (texto estático) + nome do exercício | Sem botões |
| **Tudo concluído** | glifo + "TREINO COMPLETO" | "Finalize no app para salvar" + tempo da sessão | Sem botões |
| **Treino salvo** (estado final) | `checkmark.circle.fill` + "TREINO CONCLUÍDO" | "52 min · 18 séries · 8.420 kg" | Some em 5 min (ou ao dispensar) |

`−15 s` fica só no app: na Tela Bloqueada dois botões grandes valem mais que três pequenos.

#### Dynamic Island

| Apresentação | Descanso | Série | Pausado | Descanso concluído |
|---|---|---|---|---|
| **Compacta — esquerda** | anel de progresso regressivo laranja (16 pt) | glifo laranja | `pause.fill` branco | `checkmark.circle.fill` verde |
| **Compacta — direita** | contagem "1:15", laranja, dígitos monoespaçados, largura fixa (não faz a ilha pulsar de tamanho) | "2/4" (série de total), branco | tempo da sessão congelado, secundário | "3/4" (a próxima série) |
| **Mínima** (dividindo a ilha com outro app) | o mesmo anel regressivo | glifo laranja | `pause.fill` | `checkmark` verde |

**Expandida** (toque longo; também é o banner em aparelhos sem ilha):

```
┌──────────────────────────────────────┐
│ ◢ DESCANSO                    32:14  │  leading · trailing
│                                      │
│ 1:15         A seguir                │  bottom
│              Série 3 de 4            │
│              26 kg · alvo 8–12       │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░ │
│ [     + 15 s     ]  [    Pular    ]  │
└──────────────────────────────────────┘
```

- `leading`: glifo + rótulo do estado. `trailing`: tempo da sessão. `bottom`: o mesmo corpo da Tela Bloqueada (contagem em 40 pt), barra e botões. `center` fica vazio (evita texto sob a câmera).
- Série expandida: `leading` glifo + "Série 2 de 4"; `bottom` nome do exercício, alvo e barra da sessão; sem botões.
- Nenhum texto encosta na câmera; nada de animação própria — só as transições do sistema.

#### Ações (App Intents)

| Botão | Intent (`LiveActivityIntent`) | Efeito |
|---|---|---|
| **+15 s** | `AdjustRestIntent(seconds: 15)` | Mesmo comando do app e do relógio (idempotente, pelo `SessionEngine`); a contagem e a barra saltam +15 s; a notificação de fim é reagendada. Pode ser tocado várias vezes. |
| **Pular** | `SkipRestIntent` | Encerra o descanso; a atividade passa a **Série**. |

Os intents rodam no processo do app sem abri-lo. Não há estado otimista na atividade: o botão responde quando o app devolve o novo estado (alvo: < 1 s). Se a sessão já acabou quando o toque chega, o intent não faz nada e a atividade é encerrada.

#### Quando o descanso termina

| Situação | O que acontece |
|---|---|
| App ativo ou vivo em segundo plano (`HKWorkoutSession` do iPhone ou espelhada do relógio) | A atividade é atualizada para **Descanso concluído** com alerta ("Descanso concluído" · "Série 3 de 4 · 26 kg"), que acende a tela e expande a ilha. A notificação local daquele descanso é cancelada (um aviso só). Depois de 10 s, ou ao concluir/abrir, passa a **Série**. |
| App suspenso | A atividade tem `staleDate` = fim do descanso: ao vencer, o sistema redesenha e o layout mostra **Descanso concluído** sozinho (`context.isStale`). O aviso sonoro/háptico vem da notificação local já agendada (D4). |
| Atividades ao Vivo desligadas | Tudo como hoje: só a notificação local. |

#### Estados e bordas

| Situação | Comportamento |
|---|---|
| Sessão iniciada no iPhone | A atividade começa em **Série**. |
| Sessão iniciada no relógio com o app do iPhone fechado | Sem atividade (o sistema só deixa iniciar com o app em primeiro plano); ela começa na primeira vez que o app abrir durante a sessão. O relógio é a interface nesse caso. |
| Controlada pelo relógio | A atividade acompanha os snapshots: série concluída no pulso vira **Descanso** na Tela Bloqueada. |
| Desfazer o check da série durante o descanso | Volta a **Série** (o descanso é cancelado). |
| Pausar / retomar | **Pausado** com o tempo congelado; retomar volta ao estado anterior (o descanso em curso foi descartado na pausa, §4.5). |
| Treino descartado | A atividade some na hora. |
| Sessão esquecida | O sistema encerra atividades após 8 h; a sessão segue a regra do treino em aberto (> 4 h, §4.5). |
| Desligada nos Ajustes do iPhone | Ajustes › Treino › Atividade ao Vivo mostra "Desativada nos Ajustes do iPhone" + **Abrir Ajustes**; a sessão não muda. |
| Desligada no FitJourney | Nenhuma atividade; notificação de descanso como hoje. |
| Tela sempre ligada (luminância reduzida) | Contagem e textos em branco (o laranja escurece demais); barra sem preenchimento colorido. |
| StandBy | O layout da Tela Bloqueada ampliado pelo sistema; nada próprio. |
| Apple Watch (Conjunto Inteligente) e CarPlay | Família `.small`: contagem + "Série 3 de 4" (descanso) ou exercício + "2/4" (série). Tocar no relógio abre o app do relógio. |

#### Acessibilidade

- VoiceOver, Tela Bloqueada: um elemento com o estado por extenso — "Descanso, 1 minuto e 15 segundos restantes. A seguir: série 3 de 4, 26 quilos, alvo 8 a 12 repetições" — e os botões "Adicionar 15 segundos" e "Pular descanso". Ilha compacta: "FitJourney, descanso, 1 minuto e 15 segundos".
- Texto grande: a atividade tem altura limitada, então o texto vai até `xxxLarge`; acima disso `ViewThatFits` remove primeiro o tempo da sessão, depois a linha "A seguir". A contagem e os botões nunca saem.
- Contraste: laranja `#FF9A3D` sobre preto 9:1; branco sobre `trainingFill` 4,5:1; o estado sempre tem rótulo ou símbolo além da cor.
- Reduzir Movimento: sem animação própria; os dígitos trocam sem rolagem.
- Alvos: botões de 44 pt de altura e metade da largura cada.

#### Para quem implementa

A atividade vive num alvo de extensão de widget (`FitJourneyLiveActivity/`). Ele deve compilar `FitJourney/DesignSystem/Tokens/FJColor.swift`, `FJFont.swift`, `FJFormat.swift` e `FJLayout.swift` (sem componentes de vidro) para usar os mesmos tokens. O glifo entra como símbolo vetorial no catálogo da extensão, gerado da geometria do §2.6.

---

### 4.15 Copiloto de IA (ciclo 7)

Comportamento: SPEC §7A. O copiloto é a feature mais especial do app e tem de parecer isso **sem deixar de parecer nativo**: a IA ganha uma identidade própria (gradiente "aurora" + `sparkles`), usada com parcimônia; todo o resto continua sólido, limpo e legível. Protótipo: seções 24–32. Código: `FJAI`, `FJAIOrb`, `FJAIBadge`, `FJAIButton`/`.fjAI`, `FJConfidenceBadge`, `FJChangeCard`, `FJQuickReplyChips`, `FJQuestionProgress`, `FJAttachmentThumb`, `FJAttachmentAddTile`, `FJSourceLabel`, `FJAnalysisProgress` (§8).

Três ideias organizam tudo:

1. **O gradiente marca onde a IA entra e o que ela propõe — e some quando a decisão é sua.** Botão "Importar com IA", orbe, contorno de um cartão que ainda espera você. Aplicou, salvou, desfez: o contorno sai e o cartão vira conteúdo comum.
2. **A IA mostra o que entendeu antes de perguntar, e só pergunta o que falta.** Nada de formulário em branco: sempre um palpite pronto, com a confiança à vista.
3. **Nada é gravado sem um toque seu, e todo toque tem volta.** "Criar programa", "Aplicar" → "Aplicado ✓" com **Desfazer**.

#### 4.15.1 Identidade visual da IA

| Token | Claro | Escuro | Uso |
|---|---|---|---|
| `FJColor.aiBlue` → `aiViolet` → `aiPink` | `#0A6FB8` → `#7C3AED` → `#C2256E` | `#5AC8FA` → `#A78BFA` → `#F472B6` | `FJAI.gradient`: símbolo `sparkles`, contorno de 1,5 pt, barra de progresso |
| `aiBlueFill` → `aiVioletFill` → `aiPinkFill` | `#0A6FB8` → `#7C3AED` → `#C2256E` | `#0F78C4` → `#8349EE` → `#C92C75` | `FJAI.fillGradient`: preenchimento com texto branco (botão de IA em destaque) |
| `FJAI.softGradient` | os três tons a 14% | idem | Fundo da etiqueta de IA e do orbe |

- O gradiente começa no **azul do Coach** (a IA continua sendo a área Coach) e termina no rosa; o violeta e o rosa de preenchimento são os mesmos da paleta de fichas, já validados com branco.
- Contraste (calculado ao longo de todo o gradiente): tons de texto ≥ 4,7:1 sobre `background` e ≥ 5,2:1 sobre `surface` no claro, ≥ 6,1:1 no escuro; branco sobre o preenchimento ≥ 5,2:1 (claro) e ≥ 4,6:1 (escuro).
- **Onde pode**: símbolo `sparkles`; botão de IA; orbe; contorno de cartão proposto e ainda não decidido; barra da análise; segmentos do progresso da entrevista. **Onde não pode**: texto corrido, estado (sucesso/erro/atenção), gráficos, selo de ficha, fundo de tela, mais de um botão em destaque por tela. Nunca aparece sem `sparkles` ou rótulo ao lado ("Diferenciar sem cor").
- **Marca** (`FJAIBadge`): `.symbol` (só o `sparkles` em gradiente, decorativo), `.tag` (etiqueta sólida "IA", "Importado com IA", "Sugestão da IA") e `.hero` (orbe de 72 pt).
- **Orbe** (`FJAIOrb`): círculo com fundo suave, anel em gradiente e `sparkles` no centro. É a "cara" do copiloto no topo das folhas, nos estados vazios e na análise. Cresce com o Dynamic Type até 1,3×. Decorativo para o VoiceOver.
- **Botão de IA** (`FJAIButton`, `.buttonStyle(.fjAI(_:))`):
  - `.prominent` — cápsula de 56 pt no gradiente de preenchimento, texto branco, `sparkles` branco. **No máximo um por tela**, e só onde importar é o caminho principal (primeiro uso, estado vazio, folha do copiloto).
  - `.subtle` — vidro neutro de 48 pt com contorno e `sparkles` em gradiente, texto primário. Convive com o botão principal da área ("Criar programa" laranja em cima, "Importar com IA" embaixo) e é a forma de "Editar com IA".
  - Em toolbars e menus do sistema: `Label("Importar com IA", systemImage: "sparkles")` nativo, sem gradiente (o sistema não o aplica; o símbolo basta).
- **Movimento** (única exceção ao "nenhuma animação em laço" do §2.5, nos mesmos termos do "Pensando…" do §4.13.3):
  - **Brilho único** (`fjAISheen`): uma faixa de luz atravessa o botão em destaque **uma vez**, 0,45 s depois de aparecer, em 0,9 s. Não repete, não reage a rolagem.
  - **Orbe ativo**: o anel gira devagar (uma volta a cada 6 s) e o símbolo pulsa **só enquanto a IA está trabalhando** — equivale a um indicador de atividade e para no instante em que a etapa termina.
  - Com **Reduzir Movimento**: sem brilho, anel e símbolo parados; o progresso continua dito em texto e na barra.
- **Reduzir Transparência**: o botão `.subtle` vira sólido (`surfaceElevated`) e mantém o contorno em gradiente; o `.prominent` já é opaco. **Aumentar Contraste**: o gradiente continua acima de 4,5:1; nada depende dele para ser lido.

#### 4.15.2 Pontos de entrada

| Onde | Como aparece | Abre |
|---|---|---|
| **Hoje — primeiro uso** (sem programa) | No cartão de convite, abaixo do texto: `FJAIButton("Importar com IA")` **em destaque** e, abaixo, "Criar do zero" e "Usar exemplo ABC" como secundários. Linha de apoio: "Tem a ficha do seu personal em PDF ou foto? Eu monto para você." | Importar treino |
| **Treinos — sem programa** | `FJEmptyState` + dois botões: "Criar programa" (principal, laranja) e `FJAIButton("Importar com IA", prominence: .subtle)` | Importar treino → novo programa |
| **Treinos — com programas** | Menu "+" da toolbar: Novo programa · **Importar com IA** (`sparkles`) | Importar treino → novo programa |
| **Editor de programa** (lista de fichas) | Depois da última ficha, ao lado de "Adicionar ficha": `FJAIButton("Importar fichas com IA", prominence: .subtle)`; também no menu "…" | Importar treino → **adicionar ao programa X** |
| **Dieta — sem plano** | `FJEmptyState` + "Criar plano" (principal, verde) e `FJAIButton("Importar com IA", prominence: .subtle)` | Importar dieta |
| **Dieta — com plano** | Menu "…" da toolbar: Novo plano · **Importar com IA** | Importar dieta → novo plano |
| **Ficha** (detalhe e editor) | Menu "…": **Editar com IA**; no detalhe, também um `FJAIButton("Editar com IA", prominence: .subtle, fillsWidth: false)` no fim da lista de exercícios | Conversa do Coach já com o escopo "Ficha A · Peito e tríceps" |
| **Dieta — dia / plano** | Menu "…": **Editar com IA** | Conversa do Coach com o escopo "Dieta · plano ativo" |
| **Coach** | Chips de sugestão na conversa vazia: "Importar um treino", "Importar uma dieta"; botão `+` (anexar) na composição | Importar, ou anexar arquivo à conversa |

Regras:

- O rótulo é sempre **"Importar com IA"** ou **"Editar com IA"** (verbo + "com IA"), nunca só "IA" ou "Mágica".
- Nunca dois botões de IA em destaque na mesma tela; fora do primeiro uso e da folha do copiloto, o de IA é o `.subtle`.
- Durante uma **sessão de treino** as entradas de importar continuam disponíveis (não alteram a sessão); "Editar com IA" da ficha em uso abre a conversa com o aviso do §4.15.8.
- Importação interrompida: o ponto de entrada correspondente mostra, acima dos botões, o cartão **"Continuar importação"** (§4.15.9).

#### 4.15.3 Folha do copiloto e seleção de arquivos

A importação inteira vive numa **sheet `.large`** com `NavigationStack` próprio (título "Importar treino" / "Importar dieta"; "Cancelar" à esquerda). As etapas são telas empurradas dentro da folha: **Arquivos → Análise → Entrevista → Fichas encontradas → Revisão**. Arrastar para fechar com algo já selecionado pede confirmação ("Descartar importação?" · Continuar depois · Descartar).

```
┌──────────────────────────────────┐
│ Cancelar    Importar treino       │
├──────────────────────────────────┤
│              (orbe)               │  FJAIBadge(.hero)
│   Traga a ficha como ela está     │  title2
│  PDF, foto ou texto. Eu leio,     │  label, secundário
│  pergunto o que faltar e monto.   │
│                                   │
│ ┌─ PDF ou arquivo ─┐┌─ Fotos ───┐ │  4 fontes: grade 2×2 de
│ └──────────────────┘└───────────┘ │  botões sólidos (FJCard)
│ ┌─ Câmera ─────────┐┌─ Colar ───┐ │  com símbolo + rótulo
│ └──────────────────┘└───────────┘ │
│                                   │
│ 3 de 10 arquivos                  │  numberCaption
│ [pdf 4 pág.] [foto] [foto] [ + ]  │  FJAttachmentThumb / AddTile
│                                   │
│ 🔒 Os arquivos inteiros vão para  │  aviso de privacidade (sólido)
│    a OpenAI para serem lidos.     │
│    Não ficam guardados no app.    │
├──────────────────────────────────┤
│ [   ✦ Analisar 3 arquivos   ]     │  FJAIButton em destaque (fixo na base)
└──────────────────────────────────┘
```

- **Fontes** (quatro botões sólidos em grade 2×2; 1 coluna em tamanhos de acessibilidade): **PDF ou arquivo** (`doc`, `fileImporter`: PDF, imagens, .txt/.md) · **Fotos** (`photo.on.rectangle`, `PhotosPicker` múltiplo) · **Câmera** (`camera`; várias fotos em sequência, "Tirar outra" / "Concluir") · **Colar texto** (`doc.on.clipboard`; abre um editor de texto com "Colar" e contador de caracteres). A permissão de câmera é pedida só ao tocar em Câmera.
- **Miniaturas** (`FJAttachmentThumb`, 84 × 112 pt, proporção de página, em `FJFlowLayout`): prévia da primeira página ou da foto; selo "4 pág." quando há mais de uma página; nome (2 linhas, truncado no meio) e tamanho abaixo; **×** de 24 pt num alvo de 44 pt para remover. O último quadro é `FJAttachmentAddTile` (tracejado, "+ Adicionar", reabre as fontes num menu). Tocar na miniatura abre o Quick Look.
- **Contador** "3 de 10 arquivos". No décimo o quadro "+" some e as fontes ficam desabilitadas com a legenda "Limite de 10 arquivos".
- **Aviso de privacidade** (sempre visível antes de enviar; `FJBanner` neutro com `lock.fill`): "Os arquivos inteiros vão para **{provedor}** para serem lidos. Depois da importação eles não ficam guardados no FitJourney." O nome do provedor é o configurado. Fotos: "Localização e dados da câmera são removidos antes do envio." (linha em `caption`).
- **Opção** "Manter os arquivos anexados à ficha" (toggle, desligado; SPEC §7A.1) fica na revisão final, não aqui.
- **Botão principal** fixo na base: `FJAIButton("Analisar 3 arquivos")` (o número acompanha a seleção; desabilitado com zero arquivos e enquanto algum está em preparo).

| Estado | O que aparece |
|---|---|
| Vazio | Orbe, título, as quatro fontes, aviso de privacidade; botão principal desabilitado ("Escolha um arquivo") |
| Preparando um anexo | Miniatura com indicador pequeno e a prévia esmaecida (redimensionando a foto, contando páginas) |
| Arquivo maior que 20 MB / tipo não aceito | Miniatura com contorno e símbolo de atenção + motivo no lugar do tamanho ("Maior que 20 MB", "Formato não aceito"); não conta no envio; o botão principal segue com os válidos |
| PDF longo (> 20 páginas) | `FJBanner` de atenção: "Este PDF tem 48 páginas. Arquivos longos demoram mais e custam mais no seu provedor." · **Escolher páginas** (abre a grade de páginas, marcáveis) |
| Limite atingido | Fontes desabilitadas + "Limite de 10 arquivos" |
| **Sem provedor configurado** | No lugar do botão principal: `FJBanner` de atenção "Falta configurar a IA" · **Configurar** (empurra "Coach e IA", §4.13.5, dentro da folha); os arquivos escolhidos ficam |
| **Sem consentimento do Coach** | Ao tocar em Analisar, sobe uma folha `.medium` com a etapa 1 do §4.13.1 resumida + o aviso específico em destaque: "**O arquivo inteiro vai ao provedor.** Tudo o que estiver escrito nele (nome, telefone, observações do seu personal) será enviado." · `FJPrimaryButton("Concordar e analisar", area: .coach)` · "Agora não". Aceitar vale como consentimento do Coach (os quatro compartilhamentos continuam desligados: importar não lê seu histórico) |
| Offline | `FJBanner` neutro com `wifi.slash`: "Sem conexão. Os arquivos ficam aqui; analise quando voltar." Botão principal desabilitado |
| Câmera negada | Tocar em Câmera mostra alerta com "Abrir Ajustes"; as outras fontes seguem |

#### 4.15.4 Análise

Tela empurrada, sem barra de busca nem lista: só o que está acontecendo. Componente `FJAnalysisProgress`.

```
              (orbe girando)
           Lendo 3 arquivos…
   Enviados à OpenAI · menos de 1 minuto
          ▓▓▓▓▓▓░░░░░░░░░

  ✓  3 arquivos enviados
     2 PDFs · 1 foto
  ✦  Encontrei 4 fichas
     Peito e tríceps · Ombro · Perna · Costas e bíceps
  ⋯  Lendo exercícios e séries
     Ficha 2 de 4
  ○  Casar com a sua biblioteca

            ( Cancelar )
```

- **Sem spinner genérico.** O título diz o que está sendo lido ("Lendo 3 arquivos…", "Lendo Treino João.pdf…", "Montando as fichas…"); a lista de etapas diz o que já foi feito e **o que foi encontrado** — os achados ("Encontrei 4 fichas", "Encontrei 6 refeições e as metas do dia") entram com `sparkles` em gradiente e em negrito, um a um, conforme a extração avança (se o provedor não transmite parciais, entram ao final de cada chamada).
- **Barra** só quando há fração real (arquivos enviados, páginas convertidas, fichas lidas); nunca uma barra falsa por tempo. Sem fração, fica só o orbe girando.
- **Etapas** (as que se aplicarem): Preparando os arquivos → Enviando ao provedor → Lendo (por arquivo) → Achados → Casando exercícios com a biblioteca / Conferindo calorias → Pronto.
- **Conversão silenciosa**: provedor sem suporte a PDF → as páginas viram imagens no aparelho. Não há alerta nem escolha; aparece só como uma etapa comum "Preparando 4 páginas".
- **Cancelar** (vidro secundário, na metade inferior): para o envio e volta à seleção com os arquivos intactos. Sem confirmação (nada foi criado).
- A tela não bloqueia o app: fechar a folha durante a análise pergunta "Continuar em segundo plano?" · **Continuar** (a análise segue; ao terminar, o cartão "Continuar importação" aparece no ponto de entrada e uma notificação local avisa, se permitidas) · **Cancelar importação**.
- Ao concluir: háptico de sucesso, o orbe para, o título vira "Leitura concluída" por 0,6 s e a folha avança sozinha para a entrevista (ou direto para a revisão se não houver nenhuma dúvida). Com Reduzir Movimento, avança sem a pausa animada.

| Estado | O que aparece |
|---|---|
| Em andamento | Como acima |
| Parcial (alguns arquivos falharam) | Etapa com símbolo de atenção "Foto 2 está ilegível" + "Vou perguntar o que faltou"; a importação segue com o resto |
| **Arquivo ilegível / nada encontrado** | Orbe parado, título "Não encontrei um treino aqui", texto "O arquivo parece ser {o que a IA disse: 'uma nota fiscal', 'uma foto escura'}." · **Trocar arquivos** (principal) · "Tentar de novo" |
| **Erro de leitura** (resposta inválida depois do reparo) | `FJBanner` destrutivo "A leitura veio incompleta" · **Tentar de novo** · "Trocar arquivos". Nada é perdido |
| Erro do provedor (chave, limite, servidor, tamanho) | As mesmas mensagens do §4.13.3, com a saída de cada uma; limite do provedor mostra a contagem para tentar de novo |
| **Offline no meio** | `FJBanner` neutro "Sem conexão. Continuo quando ela voltar." A análise retoma sozinha; **Cancelar** continua disponível |
| Demorando (> 60 s) | Subtítulo vira "Está demorando mais que o normal. Pode fechar: eu aviso quando terminar." |

#### 4.15.5 Entrevista (copiloto de montagem)

Uma **conversa guiada dentro da folha**, com a mesma linguagem da conversa do Coach (§4.13.3: pergunta da IA em texto sem balão, resposta do usuário em balão azul), mas com trilho: a IA pergunta **uma coisa por vez** e só o que falta ou é incerto.

```
┌──────────────────────────────────┐
│ ‹        Importar treino    Pular │
│ ▬▬ ▬▬ ▬▬ ── ──   3 de 5 dúvidas   │  FJQuestionProgress
├──────────────────────────────────┤
│ ✦ Entendi um programa com 4      │  resumo do que entendeu
│   fichas e 27 exercícios.        │  (primeira mensagem)
│   Faltam 5 detalhes.             │
│                                  │
│ No supino reto está "3x12-10-8". │  pergunta
│ Como devo ler?                   │
│ ┌──────────────────────────────┐ │
│ │ 📄 Treino João.pdf · p. 1     │ │  recorte da origem (FJSourceLabel
│ │ [recorte da linha no arquivo] │ │  + imagem do trecho, se houver)
│ └──────────────────────────────┘ │
│ (✓ 3 séries: 12, 10 e 8) (3×12)  │  FJQuickReplyChips
│ (Pirâmide até 8) (Não sei)       │
│ (⌨ Outra resposta)               │
├──────────────────────────────────┤
│ ( Responder…                ) (↑)│  composição (vidro)
└──────────────────────────────────┘
```

- **Abertura**: a primeira mensagem resume o que foi entendido ("Entendi um programa com **4 fichas** e **27 exercícios**. Faltam **5 detalhes**.") com o link "Ver tudo" (abre a revisão a qualquer momento).
- **Progresso** (`FJQuestionProgress`): fixo sob a barra, "3 de 5 dúvidas" + um segmento por dúvida. O total pode crescer se uma resposta abrir outra dúvida; nunca passa de 12 — acima disso a IA agrupa ("Falta a carga de 9 exercícios" → uma pergunta com lista editável).
- **Toda pergunta mostra de onde veio**: `FJSourceLabel` ("Treino João.pdf · p. 1") e, quando existir, o recorte do trecho do arquivo. O usuário responde olhando a ficha original, não de memória.
- **Respostas rápidas** conforme o tipo de dúvida — a primeira opção é sempre o melhor palpite da IA:

| Dúvida | Controle |
|---|---|
| Ambiguidade ("3×12 ou 12×3?", unidade, kg × lb) | `FJQuickReplyChips` (2 a 4 opções + "Não sei" + "Outra resposta") |
| Carga ilegível ou ausente | `NumberStepperField` com o palpite (ou vazio), passo dos Ajustes, e chips "Peso corporal" · "Sem carga por enquanto" · **Confirmar** |
| Descanso, repetições, tempo | `NumberStepperField` + chips com os valores comuns (60 s · 90 s · 120 s) |
| Exercício sem casamento no catálogo | Cartão com o nome como escrito + até 3 sugestões do catálogo (linha com miniatura, nome e grupo muscular, selecionável) · **Buscar no catálogo** (abre a biblioteca em modo de escolha, §4.4) · **Criar "{nome}" como novo** |
| Campo obrigatório ausente (nome do programa, dias por semana) | Campo de texto ou chips (2× · 3× · 4× · 5× · 6×) |
| Várias dúvidas iguais | Uma pergunta com lista: cada linha tem o exercício e o controle; **Confirmar todas** |

- **Texto livre** sempre disponível: o chip "Outra resposta" foca a composição; escrever ali responde à pergunta atual em linguagem natural ("as duas primeiras são aquecimento"). A IA interpreta, mostra o que entendeu numa linha ("Certo: 2 séries de aquecimento + 3 válidas") e segue.
- **Depois de responder**: o chip escolhido vira o balão do usuário; a pergunta respondida recolhe numa linha com `checkmark` ("Supino reto: 3 séries — 12, 10 e 8"), tocável para mudar. A próxima pergunta entra com `FJMotion.structure`.
- **Pular** (toolbar): "Pular esta" mantém o palpite da IA e marca o campo como "Conferir" na revisão; "Pular todas e revisar" vai direto à revisão. Nunca é obrigatório responder para avançar.
- **"Não sei"** é resposta válida: o campo fica vazio (ou com o palpite) e sinalizado na revisão.
- A entrevista **não usa** os compartilhamentos do Coach nem lê o histórico; a linha em `caption` no topo diz "Esta conversa usa só os arquivos que você enviou."
- Hápticos: seleção ao tocar num chip; sem háptico quando a pergunta seguinte aparece.

| Estado | O que aparece |
|---|---|
| Sem dúvidas | A entrevista é pulada; a revisão abre com `FJBanner` de sucesso "Li tudo com clareza. Confira e crie." |
| IA interpretando a resposta livre | "✦ Pensando…" (§4.13.3); chips desabilitados |
| Resposta não entendida | A IA repete a pergunta de outro jeito, com as opções; depois de 2 tentativas oferece "Deixar para a revisão" |
| Erro / offline | `FJBanner` com **Tentar de novo**; as respostas já dadas ficam; "Ir para a revisão" sempre disponível |
| Retomada | Reabre na primeira dúvida sem resposta, com as anteriores recolhidas |

#### 4.15.6 Várias fichas detectadas

Quando a extração encontra mais de uma ficha (ou mais de um treino/dieta diferentes nos arquivos), a folha mostra **um cartão por ficha** antes da revisão. Com uma ficha só, esta tela não aparece.

```
│ Encontrei 4 fichas                │  título grande
│ Escolha as que quer importar.     │
│ ┌──────────────────────────────┐ │
│ │ ☑ [A] Peito e tríceps      ✎ │ │  check 44 pt · FJRoutineBadge(.md) · nome
│ │      7 exercícios · p. 1      │ │  nº de exercícios · origem
│ │      ▮▮▮ Confiança alta       │ │  FJConfidenceBadge(.full)
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ ☑ [B] Ombro                 ✎ │ │
│ │      6 exercícios · p. 2      │ │
│ │      ▮▮▯ Confiança média      │ │
│ │      2 itens para conferir    │ │
│ └──────────────────────────────┘ │
│ ┌──────────────────────────────┐ │
│ │ ☐ [C] Perna                 ✎ │ │  desmarcada: cartão a 60%
│ └──────────────────────────────┘ │
│ [   Continuar com 3 fichas   ]    │  principal, fixo na base
```

- **Cartão** (`FJCard`, a linha inteira alterna a marcação): `FJCheckButton` à esquerda, `FJRoutineBadge(.md)` com a letra e a cor sugeridas (`FJRoutineColor.suggested(forIndex:)`, continuando a sequência do programa de destino), nome, "7 exercícios · ~55 min", `FJSourceLabel` e `FJConfidenceBadge(.full)` com a confiança **geral** da ficha (a menor entre as dos exercícios, se houver baixa; senão a média). Com itens incertos: "2 itens para conferir".
- **Renomear e letra/cor**: o lápis (44 pt) abre uma folha `.medium` com nome, letra/símbolo e `FJRoutineColorPicker` — os mesmos campos do editor de ficha (§4.3). Sem edição inline no cartão, para o toque na linha continuar sendo "marcar".
- Tocar em "7 exercícios" expande a lista (nome + prescrição resumida), só leitura.
- Todas vêm **marcadas**, exceto as que a IA classificou como duplicata de outra ("Parece igual à ficha A" — desmarcada, com o motivo).
- Treinos diferentes nos mesmos arquivos (ex.: dois programas): seções "Programa 1 · Hipertrofia" e "Programa 2 · Adaptação", cada uma com "Marcar todas"; a revisão cria um programa por seção marcada.
- Botão principal: "Continuar com 3 fichas" (desabilitado com zero). Em "adicionar ao programa X", o subtítulo diz "Serão adicionadas a **Hipertrofia ABC**".
- Ordem: arrastar pelo "grip" ou ações "Mover para cima/baixo" (VoiceOver e menu de contexto).

#### 4.15.7 Revisão final

A última tela da folha: **tudo o que será criado**, editável, com a confiança à vista. Nada foi salvo até aqui.

```
┌──────────────────────────────────┐
│ ‹        Revisar            Editar│
├──────────────────────────────────┤
│ ✦ Importado de 3 arquivos         │  FJAIBadge(.tag)
│ Hipertrofia ABCD            ✎     │  nome do programa (editável)
│ [Hipertrofia] [Sequencial] [4×/sem]│
│ ⚠ 3 itens para conferir   Ver ›   │  resumo de confiança (pula entre eles)
│                                   │
│ ┌──────────────────────────────┐ │
│ │ [A] Peito e tríceps      ⌄   │ │  FJRoutineBadge + nome
│ │ 7 exercícios · 📄 p. 1        │ │
│ │ ──────────────────────────── │ │
│ │ Supino reto                  │ │  exercício casado
│ │ 4 × 8–12 · 32 kg · 90 s      │ │  prescrição (toque edita)
│ │ ──────────────────────────── │ │
│ │ Crucifixo inclinado  [novo]  │ │  sem casamento: será criado
│ │ 3 × 12 · — kg · 60 s         │ │
│ │ ▮▯▯ Revisar · carga ilegível │ │  FJConfidenceBadge(.compact) + motivo
│ └──────────────────────────────┘ │
│ ┌ [B] Ombro … ┐ ┌ [C] Perna … ┐  │
│                                   │
│ Ativar agora            ( ○ )     │  toggle
│ Manter os arquivos na ficha ( ○ ) │
├──────────────────────────────────┤
│ [       Criar programa       ]    │  FJPrimaryButton(area: .training)
└──────────────────────────────────┘
```

- **Cabeçalho**: `FJAIBadge("Importado de 3 arquivos")`, nome (toque edita no lugar), etiquetas de objetivo/agenda (toque abre o seletor), e o **resumo de confiança**: "3 itens para conferir" com "Ver" que rola até o primeiro e, a cada toque, ao próximo. Com zero: `FJTag("Tudo lido com clareza", tone: .success)`.
- **Um cartão por ficha** (treino) ou **por refeição** (dieta), sólido, expansível; a primeira ficha e toda ficha com item a conferir vêm abertas.
- **Linha de exercício**: nome (casado com o catálogo; `FJTag("novo")` se será criado) e a prescrição no formato de sempre ("4 × 8–12 · 32 kg · 90 s"). **Tocar na linha abre a edição inline**: a linha expande em `NumberStepperField`s (séries, reps, carga, descanso) + "Trocar exercício" + "Remover" — os mesmos controles do editor de ficha, sem sair da revisão. "Editar" na toolbar liga reordenar/remover em lote.
- **Indicadores de confiança** (`FJConfidenceBadge`) — nunca só cor: três barras (3, 2 ou 1 cheias) + texto; a baixa ganha também o triângulo de atenção.
  - **Alta**: sem selo na linha (silêncio é o padrão; selo em tudo vira ruído). Aparece só no cabeçalho do cartão quando a ficha inteira é alta.
  - **Média**: `▮▮▯ Conferir` + o motivo da IA em `caption` ("li '32' mas pode ser '82'").
  - **Baixa**: `⚠ ▮▯▯ Revisar` + motivo; o campo em dúvida aparece como "—" se não houver palpite. Campo **obrigatório** ausente bloqueia o botão principal e é dito: "Falta a carga de 2 exercícios" (ou marque "Sem carga por enquanto").
  - Editar o campo **remove o selo** (virou decisão do usuário) e decrementa o resumo.
- **Origem**: `FJSourceLabel` no cabeçalho de cada cartão ("Treino João.pdf · p. 1") e, na edição inline de um item a conferir, o recorte do trecho (o mesmo da entrevista). Tocar abre o arquivo na página.
- **Opções** (linhas de formulário no fim): **Ativar agora** (toggle, desligado; ligado segue a regra do §5.5, inclusive o aviso com sessão em andamento) · **Manter os arquivos anexados à ficha** (desligado; rodapé "Desligado, os arquivos são apagados do app depois de criar.").
- **Botão principal** fixo na base, na **cor da área de destino** (a decisão é do usuário; o gradiente já saiu de cena): **"Criar programa"** · **"Adicionar ao programa Hipertrofia ABC"** (nome truncado no meio) · **"Criar dieta"** (verde). Com "Ativar agora" ligado o rótulo vira "Criar e ativar".
- **Depois de criar**: háptico de celebração; a folha fecha e o app mostra o programa/plano criado (inativo, origem "IA", "importado de 3 arquivos"), com um aviso `FJBanner` de sucesso "Programa criado" · **Desfazer** (apaga o que foi criado; disponível até sair da tela).

**Importar dieta** — mesma estrutura, na cor da Dieta:

- Cabeçalho: nome do plano, **metas** em `FJMetricGrid` (kcal · proteína · carboidrato · gordura; "—" se o arquivo não trouxer, com "Calcular pelas refeições"), dias/variações em chips ("Todos os dias", "Treino", "Descanso").
- Um cartão por **refeição**: horário (editável) + nome + total ("420 kcal"), itens em linhas ("Aveia · 40 g · 152 kcal"), **substituições** recolhidas ("2 substituições" expande). Valores que a IA estimou (o arquivo não trazia kcal/macros) levam `FJTag("estimado")` e contam como confiança média; rodapé do cartão "Valores estimados pela IA".
- Itens sem quantidade: "—" + `Revisar`.
- Botão: **"Criar dieta"**; opção **"Ativar agora"** (troca o plano ativo, com a confirmação do §4.10).

| Estado | O que aparece |
|---|---|
| Tudo com confiança alta | Etiqueta de sucesso no cabeçalho; cartões recolhidos (menos o primeiro) |
| Itens a conferir | Resumo "n itens para conferir" + selos nas linhas; o botão principal continua habilitado (conferir é recomendado, não obrigatório) |
| Obrigatório ausente | Botão principal desabilitado + linha de atenção acima dele dizendo o que falta, tocável (rola até o item) |
| **Parcial** (arquivo ilegível, ficha incompleta) | `FJBanner` de atenção no topo: "Não consegui ler a Foto 2. O que veio dela ficou de fora." · **Enviar de novo** (volta à seleção mantendo o resto) |
| Salvando | Botão principal com indicador; conteúdo desabilitado |
| Erro ao salvar | `FJBanner` destrutivo "Não foi possível criar" · **Tentar de novo**; nada é perdido |
| Nome já existe | Campo marcado + "Já existe um programa com este nome" (sugere "… (importado)") |
| Sessão em andamento + "Ativar agora" | Aviso do §5.5: cria inativo e oferece ativar depois do treino |

#### 4.15.8 Copiloto de edição — cartões de alteração

Na conversa do Coach (§4.13.3), aberta pela aba ou por "Editar com IA". Quando a IA propõe mudar algo (`propose_routine_changes`, `propose_nutrition_changes`, `propose_food_log`), a proposta aparece dentro da resposta como um **cartão de alteração** (`FJChangeCard`). É a única coisa na conversa que altera dados — e só com toque.

```
┌──────────────────────────────────┐  contorno em gradiente (espera você)
│ 🏋 Ficha A · Peito e tríceps  ✦ Sugestão da IA │
│ Subir a carga do supino           │  cardTitle
│                                   │
│ Supino reto · carga atual         │  rótulo (caption)
│ 3̶2̶ ̶k̶g̶  →  34 kg                    │  antes riscado → depois em destaque
│ ───────────────────────────────── │
│ Exercício                         │
│ C̶r̶u̶c̶i̶f̶i̶x̶o̶  →  Voador              │
│ ───────────────────────────────── │
│ Tríceps corda                     │
│ ⊕ 3 × 12–15 · 60 s                │  inclusão
│                                   │
│ A carga inicial não muda.         │  nota (regra aplicada)
│ [          ✓ Aplicar          ]   │  na cor da área alterada
│ [   Ajustar   ] [   Descartar   ] │
└──────────────────────────────────┘
```

- **Escopo** na primeira linha, com o símbolo e a cor da área alterada: "Ficha A · Peito e tríceps", "Dieta · Lanche da tarde", "Hoje · 16:20 · fora da dieta". Aberta por "Editar com IA", a conversa mostra o escopo também sob o título ("Editando: Ficha A").
- **Diff legível** — uma linha por mudança, sem jargão e **sem depender de cor**:
  - **Alterado**: rótulo em cima ("Supino reto · carga atual"); embaixo o valor antigo **riscado** em tom secundário, uma **seta** e o novo em **negrito** primário. Em telas estreitas ou texto grande, o novo quebra para a linha de baixo (seta na frente).
  - **Incluído**: `plus.circle.fill` + o que entra. **Removido**: `minus.circle.fill` + o que sai, riscado.
  - Mais de 6 linhas: as 5 primeiras + "Ver mais 4 alterações".
  - Números nos formatos de sempre (§2.2), carga na unidade dos Ajustes.
- **Nota**: uma linha em `caption` com a regra aplicada ou a ressalva da IA — "A carga inicial não muda." (SPEC §7A.2: vira `currentLoad`), "Calorias estimadas.".
- **Ações**: **Aplicar** (`FJPrimaryButton` na cor da área alterada — laranja para ficha, verde para dieta: a cor diz onde a mudança será gravada) · **Ajustar** (foca a composição com o cartão citado; a resposta gera um cartão novo e este recolhe como "Substituída") · **Descartar** (o cartão recolhe numa linha "Sugestão descartada · {título}").
- **Aplicado**: o contorno em gradiente some, a etiqueta vira `Aplicado ✓` (sucesso), os botões dão lugar a **Desfazer** (vidro secundário). O diff continua legível. Háptico `changeApplied` (impacto médio). A mudança aparece no app na hora.
- **Desfazer**: restaura o estado anterior, a etiqueta vira "Desfeito" (neutra), o "depois" perde o destaque e o botão vira **Aplicar de novo**. Sem háptico (regra do §2.4) e sem confirmação. Desfazer fica disponível enquanto o item não tiver sido editado por outro caminho; depois disso o botão some e fica "Aplicado ✓ · alterado depois".
- **Registro rápido de comida** (`propose_food_log`): o mesmo cartão, na cor da Dieta, com uma linha de inclusão — "Açaí · ⊕ 300 ml · 210 kcal (estimado)" — e escopo "Hoje · 16:20 · fora da dieta" (ou a refeição do plano, se casar). **Aplicar** aqui se chama **Registrar**; aplicado: "Registrado ✓" + Desfazer. Valores estimados sempre dizem "(estimado)".
- Várias propostas na mesma resposta: um cartão por escopo (ficha/refeição), na ordem; acima de 2, uma linha "Aplicar as 3" antes do primeiro.

| Estado (`FJChangeCardState`) | O que aparece |
|---|---|
| `proposed` | Contorno em gradiente, etiqueta "Sugestão da IA", Aplicar · Ajustar · Descartar |
| `applying` | Aplicar com indicador; os outros desabilitados |
| `applied` | Sem contorno, "Aplicado ✓", **Desfazer** |
| `undone` | "Desfeito", **Aplicar de novo** |
| `discarded` | Uma linha "Sugestão descartada · {título}" |
| `conflict` — **treino em andamento** | Etiqueta "Não aplicado" + `FJBanner` de atenção "Você está treinando esta ficha agora. Aplique depois de finalizar o treino." Sem Aplicar; Ajustar · Descartar. Quando a sessão termina, o cartão volta a `proposed` |
| `conflict` — item mudou desde a proposta | "Esta ficha mudou depois da sugestão." · **Pedir de novo** (via Ajustar) |
| `conflict` — item não existe mais | "Esta ficha foi apagada." · só Descartar |
| `failed` | `FJBanner` destrutivo "Não foi possível aplicar" + motivo · **Tentar de novo** · Ajustar · Descartar; háptico de erro |
| Proposta inválida (não passou na validação do editor) | No lugar do cartão, `FJBanner` de atenção "A sugestão veio incompleta" · **Pedir de novo** |
| Substituída por um ajuste | Recolhida: "Sugestão anterior · {título}" (expansível, só leitura) |

O cartão de **proposta** do §4.13.4 (rascunho de programa/dieta inteiro) continua existindo e passa a usar o mesmo contorno em gradiente enquanto não é salvo.

#### 4.15.9 Estados gerais do copiloto

| Situação | Onde | O que aparece |
|---|---|---|
| **Sem provedor** | Qualquer entrada | A folha abre normalmente (dá para escolher arquivos); o botão principal dá lugar ao aviso "Falta configurar a IA" · **Configurar** |
| **Sem consentimento** | Ao analisar / ao abrir "Editar com IA" | Folha de consentimento com o aviso específico (§4.15.3); "Editar com IA" usa a tela de boas-vindas do §4.13.1 |
| **Provedor sem imagem** (modelo só de texto) | Seleção | `FJBanner` de atenção "O modelo {nome} não lê fotos nem PDF." · **Trocar modelo** · "Colar o texto" |
| **Provedor sem PDF** | — | Conversão silenciosa em imagens (§4.15.4); nenhum aviso |
| **Offline** | Seleção, análise, entrevista, conversa | Aviso neutro com `wifi.slash`; nada se perde; retoma sozinho na análise |
| **Erro de leitura / arquivo ilegível / parcial** | Análise e revisão | §4.15.4 e §4.15.7 |
| **Retomar importação interrompida** | Ponto de entrada (Treinos, Dieta, Hoje) e aba Coach | Cartão sólido com contorno em gradiente: `sparkles` + "**Continuar importação**" + "Treino · 3 arquivos · parou na revisão · há 2 h" · **Continuar** (principal `.subtle`) · "Descartar" (confirmação). Reabre a folha na etapa em que parou, com respostas e edições preservadas. Só uma importação pendente por tipo; iniciar outra pergunta "Substituir a importação em andamento?" |
| Importação pendente há mais de 7 dias | — | O cartão diz "Os arquivos desta importação serão apagados em 2 dias" (os anexos não ficam para sempre no aparelho) |
| App fechado durante a análise | Reabertura | O cartão "Continuar importação" mostra "A leitura foi interrompida" · **Retomar leitura** (reenvia; avisa que conta de novo no provedor) |
| Sessão de treino em andamento | Importar / editar | Importar funciona; ativar e editar a ficha em uso seguem os avisos de §4.15.7 e §4.15.8 |

#### 4.15.10 Acessibilidade e hápticos do copiloto

**VoiceOver**

- **Botão de IA**: "Importar com IA, botão". O `sparkles` é decorativo; o gradiente não é mencionado.
- **Miniatura de anexo**: um elemento — "Treino João.pdf, PDF, 4 páginas, 1,2 megabytes" — com a ação personalizada **Remover**; com erro: "…, Maior que 20 megabytes".
- **Análise**: título + subtítulo + porcentagem num elemento com `.updatesFrequently` (não interrompe); **cada achado é anunciado** uma vez ("Encontrei 4 fichas"); cada etapa lê "título, detalhe" com o valor "Concluído / Em andamento / Aguardando / Falhou". Ao terminar: anúncio "Leitura concluída. 5 dúvidas."
- **Entrevista**: o progresso lê "Dúvida 3 de 5"; ao entrar uma pergunta o foco vai para ela; os chips são botões com o traço "selecionado"; a origem lê "Origem: Treino João.pdf, página 1".
- **Confiança**: o selo lê **"Confiança média"** (nunca "amarelo" nem só "Conferir") e vem **antes** do motivo; na linha da revisão a ordem é "Supino reto, 4 séries de 8 a 12 repetições, 32 quilos, descanso 90 segundos, confiança média, li 32 mas pode ser 82". Rotor personalizado **"Itens para conferir"** salta entre eles.
- **Cartão de alteração**: contêiner "Alteração proposta: {título}"; cabeçalho = escopo + título; **cada linha do diff é um elemento** lido como frase: "Supino reto, carga atual: de 32 quilos para 34 quilos" · "Adicionar Tríceps corda: 3 séries de 12 a 15 repetições, descanso 60 segundos" · "Remover Mergulho no banco: …" (unidades por extenso via `FJChange.accessibilityLabel`; o riscado e a seta nunca são lidos como símbolos). Depois vêm a nota e os botões. Mudança de estado é anunciada: "Alteração aplicada", "Alteração desfeita", "Sugestão descartada", "Não foi possível aplicar".
- **Várias fichas**: cada cartão é um elemento com valor "marcada/desmarcada" e ações "Renomear", "Mover para cima", "Mover para baixo", "Ver exercícios".

**Dynamic Type até AX5**: a grade de fontes vira 1 coluna; miniaturas crescem até 1,3× e quebram linha; chips quebram linha e o texto do chip quebra em 2+ linhas; no diff o "depois" desce para a linha de baixo; os botões do cartão empilham (Aplicar, Ajustar, Descartar, um por linha); o selo de confiança desce para baixo da prescrição; o orbe cresce até 1,3×. Nada tem altura fixa com texto.

**Reduzir Movimento**: §4.15.1 (sem brilho, sem giro, sem pulso); perguntas e cartões trocam por esmaecimento. **Reduzir Transparência**: chips e botões de vidro viram sólidos com contorno; a seleção continua com check + contorno. **Diferenciar sem cor / Aumentar Contraste**: confiança = barras + texto (+ triângulo na baixa); diff = riscado + seta + símbolos; estados dos cartões = etiqueta com símbolo e texto.

**Alvos**: 44 pt em chips, × da miniatura, lápis e check das fichas; 56 pt no botão principal de cada etapa, sempre na metade inferior.

**Hápticos**

| Evento | Háptico |
|---|---|
| Tocar num chip de resposta, marcar/desmarcar ficha | `selection` |
| +/− em carga, reps, descanso | `stepUp` / `stepDown` |
| Análise concluída (com a folha aberta) | `celebration` (sucesso) |
| Programa/dieta criado | `celebration` |
| Alteração aplicada / comida registrada | `changeApplied` (impacto médio) |
| Desfazer, descartar, pular pergunta | nenhum |
| Erro de leitura, falha ao aplicar ou salvar | `error` |
| Conflito (treino em andamento) | `warning` |
| Durante a análise e o streaming | nenhum |

#### Para quem implementa (C7.3)

- Textos dinâmicos (nomes, valores, frases de etapa) entram nos componentes como `String` **já localizada** (`String(localized:)`); rótulos fixos dos componentes já estão no catálogo (pt-BR/en).
- `FJChangeCard` é controlado: o estado vem de fora (`FJChangeCardState`); o componente cuida do háptico e do anúncio na troca de estado.
- Contorno/selecionado em cima de vidro: desenhe **no conteúdo, antes de `.fjGlass`** — um `overlay` depois do vidro some dentro de `GlassEffectContainer` (é o que `.fjAI(.subtle)` e `FJQuickReplyChips` fazem).
- Nenhuma tela usa o gradiente direto: só `FJAI.*`, `fjAIBorder`, `FJAIBadge`, `FJAIOrb`, `.fjAI`.

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

### 5.8 Vincular um treino do Apple Watch
1. O usuário treina com o FitJourney no iPhone e, em paralelo, grava "Força tradicional" no app Exercício do relógio.
2. Ao salvar, o encerramento mostra a linha de estado do Saúde; o detalhe da sessão abre com a sugestão (§4.11):
   - correspondência **alta** → já vinculado, `FJBanner` neutro "Vinculado ao treino do Apple Watch (18:04–18:57)" · Desfazer;
   - correspondência **incerta** → `FJBanner` de atenção "Parece o mesmo treino" com os dois horários · Vincular · Não é o mesmo.
3. Vincular: a sessão ganha FC e energia do relógio; Saúde › Dia mostra uma linha "FitJourney + Apple Watch". Os minutos do dia não mudam (já contavam o intervalo uma vez).
4. Não é o mesmo: ficam duas linhas; a pergunta não volta. Dá para vincular depois pelo menu "…".

### 5.9 Primeira conversa com o Coach e salvar uma proposta
1. Aba Coach → boas-vindas: ler para onde vão os dados, ligar "Treinos" → [Concordar e continuar].
2. Configurar a IA: provedor, colar a chave, modelo → "Testar conexão" → [Começar a conversar].
3. Tocar na sugestão "Monte um ABC de hipertrofia, 4x por semana, 60 min" → o texto vai para o campo → enviar.
4. "Pensando…" → linhas "Leu 24 treinos · 90 dias", "Leu o programa ativo" → a resposta entra em streaming → cartão **Rascunho de programa**.
5. Expandir uma ficha para conferir → [Revisar e salvar] → editor de programa preenchido (origem IA) → ajustar o que quiser → Salvar → "Ativar *Hipertrofia ABC* agora?".
6. De volta à conversa, o cartão mostra "Salvo" + "Abrir programa". Nada foi gravado antes do passo 5.

### 5.10 Descanso pela Tela Bloqueada (ciclo 6)
1. Concluir a série no app (ou no relógio) e bloquear o iPhone: a Atividade ao Vivo mostra **Descanso** com a contagem e "A seguir: Série 3 de 4 · 26 kg · alvo 8–12".
2. (Opcional) [+15 s] soma tempo; [Pular] encerra o descanso — sem desbloquear.
3. Ao zerar: a tela acende com "Descanso concluído" e a próxima série em destaque; som/háptico conforme os Ajustes.
4. Tocar na atividade abre a sessão em tela cheia, na série atual.

### 5.11 Exportar, importar e apagar
- **Exportar**: Ajustes › Dados › Exportar tudo → progresso na linha → folha de compartilhamento com o JSON.
- **Importar**: Importar backup → escolher o arquivo → resumo (data, contagens) → Juntar (padrão) ou Substituir tudo → [Importar] → aviso de sucesso com as contagens.
- **Apagar**: Apagar todos os dados → lista do que some + "Exportar antes" → [Apagar tudo…] → diálogo → alerta final → o app volta ao primeiro uso.

### 5.12 Importar um treino com IA
Treinos › "+" › Importar com IA (ou Hoje no primeiro uso) → folha: escolher PDF/fotos/câmera/texto (até 10) → [Analisar 3 arquivos] → (consentimento, se for a primeira vez) → análise com os achados → entrevista: só as dúvidas, com respostas rápidas → "Encontrei 4 fichas": marcar, renomear, letra/cor → revisão: conferir os itens sinalizados, editar no lugar → [Criar programa] (opção Ativar agora) → programa aberto, com "Desfazer". Caminho mínimo sem dúvidas: 4 toques depois de escolher os arquivos (Analisar · Continuar · Criar programa · pronto).

### 5.13 Importar uma dieta com IA
Dieta › Importar com IA → mesma folha → análise → entrevista (quantidades, horários, substituições) → revisão por refeição, com metas e valores estimados sinalizados → [Criar dieta] (opção Ativar agora).

### 5.14 Editar pela conversa
Ficha › "…" › Editar com IA (ou aba Coach) → "sobe o supino para 34 kg e troca o crucifixo por voador" → cartão de alteração com o antes → depois → [Aplicar] → "Aplicado ✓" · Desfazer. "Registrei um açaí de 300 ml" → cartão de registro → [Registrar].

### 5.15 Retomar uma importação
Fechar o app no meio da entrevista → reabrir → Treinos mostra "Continuar importação · parou na entrevista" → [Continuar] → mesma pergunta, respostas anteriores preservadas.

### 5.16 Copiar ficha para outro programa (§4.2.1)
- **A partir da ficha**: toque longo na ficha (ou "…" no editor / no detalhe do programa) → "Copiar para outro programa…" → marcar o destino → [Copiar] → "Ficha copiada" · [Ver programa] ou [OK]. Destino semanal: [Continuar] → conferir os dias sugeridos → [Copiar].
- **A partir do destino**: Treinos › "+" › "Adicionar ficha de outro programa" → marcar uma ou mais fichas → [Adicionar (2)] → a folha fecha e as fichas estão no fim da lista. Destino semanal: [Continuar] → dias de cada ficha → [Adicionar (2)].
- Caminho mínimo (destino livre ou em rodízio): 3 toques depois de abrir o menu — item, destino ou ficha, confirmar.

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
16a. Alerta de fim de descanso (§4.5): com a sessão aberta o iPhone vibra repetidamente até um toque em qualquer ponto; "Começar série" fecha e dispensa o descanso; para sozinho em 60 s deixando o cartão; não abre duas vezes para o mesmo descanso; com Reduzir Movimento nada pulsa; desligado em Ajustes, vibra uma vez. A vibração em si só é verificável no aparelho.
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

28a. Sem amostra, o valor é "—" com o motivo; nenhum cartão da aba mostra "0 bpm", "0 kcal" ou um gráfico só com eixos (teste: dia sem leituras, sem Apple Watch, Saúde não conectado).
28b. Um treino do Watch sobreposto a uma sessão do app não aumenta os minutos nem a energia do dia, vinculado ou não.
28c. Correspondência alta aparece já vinculada com "Desfazer"; incerta mostra os dois horários, os minutos em comum e as ações Vincular / Não é o mesmo; depois de "Não é o mesmo" a sugestão não reaparece.
28d. No gráfico do dia, cada treino tem faixa na cor do tipo com o símbolo no topo; hoje destacado nas barras da semana sem depender só de cor (opacidade + rótulo em negrito).
28e. As comparações com a semana são texto neutro com seta e número; nenhuma usa verde ou vermelho.

**Fichas e ícone**
28f. `python3 design/tools/routine_palette_check.py` passa (32 pares). Nenhuma tela usa `RoutineColor`, `RoutineBadge` ou `FlowLayout` fora do DesignSystem; cor de ficha vem só de `FJRoutineColor`.
28g. O selo aparece igual (letra, cor, raio) em Hoje, Treinos, editor, histórico, Saúde e Coach; em AX5 não passa de 1,4× o tamanho base.
28h. O ícone é reconhecível a 29 pt (Ajustes) nas três aparências do iOS e no relógio; nenhum traço encosta na máscara.

**Copiar ficha (§4.2.1)**
28ak. As duas entradas existem em todos os pontos da tabela do §4.2.1 e nenhuma depende só de gesto: "Copiar para outro programa…" também está no "…" do editor de ficha e do detalhe do programa.
28al. A cópia tem os mesmos exercícios, na mesma ordem, com séries, repetições, cargas, descansos, grupos (bi-set), observações, cor e letra; a ficha original e o programa de origem ficam idênticos ao que eram.
28am. Destino livre ou em rodízio: a ficha entra no fim, sem perguntar nada; do item de menu à confirmação são 3 toques. Destino semanal: os dias da original vêm marcados; dia ocupado tem ponto e a frase com o nome da ficha que o ocupa; dá para confirmar com dia ocupado e sem nenhum dia.
28an. Nome repetido entra como "Nome (2)" (depois "(3)") e a folha mostra o nome final antes de confirmar; letra e cor não mudam.
28ao. Destino com treino em andamento: nada é copiado e há aviso com "Ver treino"; no fluxo A os outros destinos continuam disponíveis; treino em andamento na ficha de origem não impede a cópia.
28ap. Estados vazios: sem outro programa o fluxo A oferece "Novo programa" e o fluxo B explica; outros programas sem fichas mostram "Nenhuma ficha para copiar"; programas arquivados aparecem como origem e como destino, identificados em texto.
28aq. O fluxo A termina em "Ficha copiada" com "Ver programa", que abre o destino certo (raiz de Treinos se ativo, detalhe nos demais); o fluxo B fecha a folha e anuncia "n fichas adicionadas a {Destino}".
28ar. VoiceOver lê cada linha como um elemento com o traço *selecionado* e o botão como "Adicionar 2 fichas"; em AX5 nenhum nome, rodapé ou dia é cortado; nenhuma linha das duas folhas usa vidro.

**Coach**
28i. Nenhuma mensagem é enviada antes do consentimento; os quatro compartilhamentos começam desligados.
28j. Toda consulta a dados locais aparece na conversa como linha "Leu …"; categoria desligada aparece como "… não compartilhada", e o dado não é enviado.
28k. Durante o streaming: o botão de enviar vira Parar; rolar para cima não é desfeito pela chegada de texto; VoiceOver não é interrompido e anuncia o fim.
28l. Nada é salvo a partir de uma proposta sem passar pelo editor e pelo "Salvar"; o cartão mostra "Salvo" depois.
28m. Cada erro do provedor (chave, limite, rede, tamanho, recusa) tem mensagem própria e uma saída; a mensagem do usuário nunca se perde.
28n. A chave nunca aparece inteira depois de salva nem entra na exportação.

**Copiloto de IA**
28w. O gradiente de IA só aparece via `FJAI`/`fjAIBorder`/`FJAIBadge`/`FJAIOrb`/`.fjAI` (busca por `aiViolet`/`aiPink` fora de `DesignSystem/` não retorna nada); nenhuma tela tem dois botões de IA em destaque; todo uso vem com `sparkles` ou rótulo.
28x. Com Reduzir Movimento não há brilho, giro nem pulso em nenhuma etapa; sem ele, o brilho do botão acontece uma única vez e o orbe só gira com a análise em curso.
28y. Nenhum arquivo é enviado antes do aviso de privacidade (com o nome do provedor) e do consentimento; sem provedor, a folha oferece "Configurar" sem perder os arquivos escolhidos.
28z. Seleção: 10 arquivos no máximo; arquivo > 20 MB ou de tipo não aceito aparece marcado com o motivo e não é enviado; cada miniatura mostra páginas, nome e tamanho e remove em um toque (alvo ≥ 44 pt).
28aa. A análise nunca mostra só um indicador: há sempre uma frase do que está sendo lido e, ao surgir, cada achado ("Encontrei 4 fichas") aparece na lista e é anunciado pelo VoiceOver; Cancelar volta à seleção com os arquivos.
28ab. A entrevista pergunta só campos obrigatórios ausentes, de confiança baixa/média ou sem casamento; toda pergunta tem resposta rápida, texto livre e origem (arquivo/página); "Pular" leva à revisão com o campo sinalizado; o progresso mostra "n de N dúvidas".
28ac. Com 2+ fichas detectadas há um cartão por ficha com nome, nº de exercícios, confiança e origem; dá para marcar, renomear e trocar letra/cor antes de continuar.
28ad. Na revisão, todo item de confiança média ou baixa tem selo com barras + texto (distinguível em escala de cinza) e o motivo; editar o item remove o selo; campo obrigatório ausente bloqueia o botão e diz o que falta.
28ae. Nada é gravado antes de "Criar programa" / "Adicionar ao programa X" / "Criar dieta"; o resultado nasce inativo, com origem IA, salvo "Ativar agora".
28af. Cartão de alteração: mostra escopo e o diff antes → depois (riscado + seta + símbolos, legível em escala de cinza); nada muda sem "Aplicar"; aplicado mostra "Aplicado" e "Desfazer", e desfazer restaura exatamente o estado anterior.
28ag. Com treino em andamento na ficha alvo, o cartão não oferece Aplicar e explica por quê; ao terminar a sessão, volta a oferecer.
28ah. VoiceOver lê cada linha do diff como frase ("…: de 32 quilos para 34 quilos") e a confiança como "Confiança alta/média/baixa"; mudanças de estado do cartão são anunciadas.
28ai. Fechar o app em qualquer etapa e reabrir mostra "Continuar importação" no ponto de entrada e retoma na mesma etapa, com respostas e edições preservadas.
28aj. AX5: fontes em 1 coluna, chips e botões do cartão empilhados, diff em duas linhas; nada cortado.

**Ajustes e dados**
28o. Trocar kg ↔ lb muda a exibição em todo o app na hora e não altera valores gravados (trocar e voltar mostra os mesmos números).
28p. Importar mostra o resumo antes de alterar qualquer coisa; arquivo inválido não altera nada.
28q. "Apagar todos os dados" exige dois passos de confirmação, lista o que será apagado e fica desabilitado durante uma sessão.

**Atividade ao Vivo** (exige aparelho)
28r. Com o iPhone bloqueado: a contagem do descanso bate com a do app (±1 s); +15 s e Pular funcionam sem desbloquear e refletem na atividade em até 1 s.
28s. Ao fim do descanso há exatamente um aviso (atividade ou notificação, nunca os dois) e a atividade mostra "Descanso concluído" mesmo com o app suspenso.
28t. Ilha compacta: a contagem não muda a largura da ilha a cada segundo; a apresentação mínima mostra o anel regressivo.
28u. Pausar congela o tempo na atividade; descartar a remove na hora; salvar mostra o resumo e some em até 5 min.
28v. VoiceOver lê o estado por extenso e os dois botões com rótulo completo; com o maior tamanho de texto a contagem e os botões continuam inteiros.

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
| `FJRestAlertCard` | `Components/FJRestAlertCard.swift` | Cartão "Descanso concluído" do alerta insistente: anel pulsando, "+0:12", próxima série, "Começar série" (por datas; sem pulsar com Reduzir Movimento) |
| `FJAlertVibrating`, `FJSystemAlertVibration` | `Tokens/FJHaptic.swift` | Vibração longa do alerta insistente (injetável para testes) |
| `FJCheckButton`, `FJRPEScale`, `FJSessionAccessory` | `Components/FJSessionControls.swift` | Check de série/refeição; RPE 1–10; conteúdo do `tabViewBottomAccessory` (recebe `startedAt`, `pausedSeconds`, `pausedAt` do `SessionClock`) |
| `FJHeartRateZoneBadge`, `FJHeartRateBadge` | `Components/FJHeartRate.swift` | Zona e FC ao vivo |
| `FJEmptyState`, `FJLoadingState`, `FJBanner` | `Components/FJStates.swift` | Estados |
| `FJRoutineColor` | `Tokens/FJRoutineColor.swift` | Paleta oficial das fichas (8 cores, `fill`/`onFill`, tons `light`/`dark`, `suggested(forIndex:)`) |
| `FJRoutineBadge`, `FJRoutineColorPicker` | `Components/FJRoutineBadge.swift` | Selo da ficha (`.sm` 32 / `.md` 44 / `.lg` 56 pt); seletor de cor da ficha |
| `FJFlowLayout` | `Modifiers/FJFlowLayout.swift` | Layout que quebra linha (etiquetas, chips, amostras, sugestões de prompt) |
| `FJAI` (`gradient`, `fillGradient`, `softGradient`), `fjAIBorder(in:lineWidth:isVisible:)`, `fjAISheen(in:)`, `FJAIOrb` | `Tokens/FJAIStyle.swift` | Identidade da IA: gradiente "aurora", contorno de cartão proposto, brilho único, orbe (gira só com `isActive`) |
| `FJAIBadge`, `FJAIButton`, `.buttonStyle(.fjAI(_:fillsWidth:))` | `Components/FJAIBadge.swift` | Marca de IA (`.symbol`/`.tag`/`.hero`); botão de IA em destaque (gradiente, 56 pt) ou sutil (vidro + contorno, 48 pt) |
| `FJConfidence`, `FJConfidenceBadge` | `Components/FJConfidenceBadge.swift` | Confiança alta/média/baixa: barras + texto (`.full`, `.compact`, `.glyph`) |
| `FJChange`, `FJChangeCardState`, `FJChangeCard` | `Components/FJChangeCard.swift` | Cartão de alteração: escopo, diff antes → depois, Aplicar/Ajustar/Descartar, Aplicado + Desfazer, conflito, falha |
| `FJQuickReply`, `FJQuickReplyChips`, `FJQuestionProgress` | `Components/FJQuickReplyChips.swift` | Respostas rápidas da entrevista (com "Outra resposta"); "3 de 5 dúvidas" |
| `FJAttachmentThumb`, `FJAttachmentAddTile`, `FJSourceLabel`, `FJAttachmentKind`, `FJAttachmentState` | `Components/FJAttachmentThumb.swift` | Miniatura de arquivo/página com remover; quadro "Adicionar"; origem "arquivo · p. n" |
| `FJAnalysisStep`, `FJAnalysisProgress` | `Components/FJAnalysisProgress.swift` | Análise: orbe, frase, barra real, etapas e achados, Cancelar |
| `DesignSystemGallery` | `DesignSystemGallery.swift` | Todos, para preview e QA |

Componentes de tela (linha de série, cartão de exercício, linha do tempo da dieta, gráfico de FC) ficam em `Features/` e são montados com estes.

---

## 9. Apple Watch (watchOS 26) — pacote W0

Comportamento e arquitetura de dados: SPEC §6.4. Objetivo: o iPhone fica no bolso ou no armário e **todo o controle da sessão acontece no pulso**. Quadros de 41 e 46 mm no protótipo.

### 9.1 Princípios do relógio

1. **Um relance, uma ação.** Cada tela responde "o que faço agora?" com um número grande e um botão. Nada de listas durante a série.
2. **A Coroa só mexe em valor dentro de um editor (W4, substitui "A Coroa é da carga").** Em aparelho, o pulso dobrado durante a série girava a Coroa e mudava a carga sem o usuário perceber. Agora nenhuma tela que fica aberta durante o esforço reage à Coroa: na Série e no Descanso ela não faz nada (com texto grande, só rola). Ela ajusta valores apenas em telas que o usuário abriu de propósito e fecha em seguida: o **editor de carga** (0,5 kg ou 1 lb por detente), o seletor de reps e o RPE do Finalizar. Exceção sem risco: no alerta de fim de descanso, girar a Coroa só para a vibração. As páginas da sessão continuam **horizontais** (`TabView` com `.page`) para a Coroa nunca trocar de página no meio da série. Ver Q-W1.
3. **Toque duplo = ação principal** da tela (`handGestureShortcut(.primaryAction)`): Iniciar, Concluir série, Pular descanso, Iniciar/Parar sustentação, Salvar.
4. **O pulso avisa.** Hápticos distintos são a interface principal entre as séries (§9.6); a tela pode estar apagada.
5. **Nunca trava.** O relógio aplica o próprio comando na hora (otimista) e reconcilia com o snapshot do iPhone. Sem iPhone por perto, continua sozinho.
6. **Fundo preto, vidro só nos botões.** Conteúdo direto sobre preto (OLED); Liquid Glass nativo do watchOS 26 em botões (`.glass`, `.glassProminent`) e na toolbar. Nenhum cartão de vidro.

### 9.2 Tokens no relógio

- **Cor**: as mesmas de §2.1, tons do tema escuro (treino `#FF9A3D`, preenchimento `#D4450C`, zonas, saúde). Texto primário branco; secundário branco 66%.
- **Tipografia**: estilos de texto do sistema, números em SF Rounded com dígitos monoespaçados. Carga: `.largeTitle` rounded bold (≈ 40 pt). Timer de descanso/sustentação: 48 pt (41 mm) / 54 pt (46 mm), `minimumScaleFactor(0.6)`. Nome do exercício: `.headline`, até 2 linhas (1 no 41 mm).
- **Alvos**: botão principal em largura total, 46 pt de altura (41 mm) / 52 pt (46 mm); demais ≥ 44 pt — exceção: os dois botões de vidro do descanso no 41 mm têm 40 pt visíveis com área de toque de 44 pt (é a tela mais apertada). Margens: `scenePadding`.
- **Movimento**: `FJMotion.value` para número e check; sem animação em laço — única exceção: o anel do alerta de fim de descanso (§9.4), que pulsa enquanto o relógio vibra. Tela sempre ligada (Always On): brilho reduzido, timer a 1 Hz, sem animações (o anel também para).
- O código de tokens é compartilhado com o iPhone (`FJColor`, `FJFont`, `FJFormat`, `FJHeartRateZone`); componentes do relógio ficam em um diretório próprio do alvo watchOS.

### 9.3 Arquitetura de telas

```
NavigationStack
├─ Treinos (raiz): ficha do dia em destaque + demais fichas
│    └─ Ficha (exercícios e prescrição) ── [Iniciar]
└─ Sessão (substitui a raiz enquanto houver sessão em andamento)
     TabView horizontal:  Controles ◀ │ SÉRIE (inicial) │ ▶ Métricas │ ▶ Ficha
     ├─ Editor de carga (folha, a partir da Série ou do Descanso): Coroa · − / + · Salvar · ✕
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
│ ╭ 26,0 kg      ± ╮ │  carga = botão de vidro; toque abre o editor
│ alvo 8–12 · RIR 2  │  alvo sempre como prescrito
│ [    Concluir    ] │  botão principal · toque duplo
└────────────────────┘
```

- **Carga (W4)**: botão de vidro (`glassEffect(.regular.interactive())`, cantos de 18 pt, ≥ 48 pt de altura) com o número no tamanho de sempre (36/42 pt rounded bold), a unidade ao lado e um "±" laranja à direita como afordância. **A Coroa não altera nada nesta tela.** Toque abre o **editor de carga**. Sem carga: "Definir carga" em laranja, no mesmo botão. Peso corporal: "PC" ou "PC +10 kg".
- **Alvo** como prescrito: "8–12", "10", "máx.", com RIR/RPE. Reps realizadas não são pedidas aqui (D2).
- **Concluir**: conclui a série com a carga exibida → háptico de sucesso → a página vira **Descanso**. Na última série do exercício o botão diz "Concluir exercício".
- Entre exercícios: "Próximo: Crucifixo · 3 × 12–15 · 15 kg" + `Começar` (toque duplo).

**Sessão · Descanso** (mesma página)

- Título "Descanso" na toolbar (no lugar do tempo da sessão); contagem regressiva grande; barra fina de progresso.
- "Próxima: 26,0 kg ±" — chip de vidro fino (cápsula, altura de uma linha, porque o descanso é a tela mais apertada) que abre o editor de carga da **próxima** série. A área de toque cresce 20 pt para cima, sobre o tempo e a barra (não tocáveis), chegando a ≈ 44 pt. A Coroa não faz nada aqui (responde Q-W2: nem carga, nem tempo).
- Linha de botões de vidro: `+ reps` (abre seletor pela Coroa, começando no piso da faixa; "Limpar" volta a não informado) e `+15 s`. Abaixo, `Pular` em largura total (toque duplo).
- Fim: abre o **alerta "Descanso concluído"** (abaixo). Com "Alerta insistente" desligado no iPhone: háptico forte uma vez (§9.6), "Descanso concluído" por 2 s e volta à Série.

**Sessão · Editor de carga (W4)** — folha em tela cheia, aberta pelo botão de carga da Série ou pelo chip do Descanso

```
┌────────────────────┐
│ (✕)           10:09│  Cancelar (toolbar, sistema) · hora
│     26,0 kg      ▌ │  número 42/48 pt; ▌ = traço laranja da Coroa
│   Série 2 de 4     │  contexto — só 45/46 mm
│ [  −  ]  [  +  ]   │  vidro, 44 pt
│ [ ✓   Salvar     ] │  principal · toque duplo
└────────────────────┘
```

- **Folha, não navegação**: cobre as páginas (nenhum deslize lateral troca de tela no meio do ajuste), tem o "✕" padrão do sistema e já era o padrão das outras escolhas do relógio (reps, RPE). Fica presa à página Série, não ao conteúdo dela: o descanso terminar por baixo não fecha o editor.
- **A Coroa é dele**: detentes de 0,5 kg (1 lb se a carga estiver em libras), com o háptico de detente do sistema — o único lugar da sessão com esse háptico de carga. O traço laranja à direita do número indica que a Coroa está ativa. − / + fazem o mesmo passo. Limites: 0–1000; peso corporal −150…+150.
- **Rascunho**: nada é enviado enquanto se ajusta. **Salvar** (ou toque duplo) envia **um** `adjustLoad` com a diferença até o valor escolhido — mesma regra de hoje, as séries seguintes pendentes acompanham — e volta. **Cancelar** (✕) descarta, sem confirmação (o custo de refazer é um giro). Fechar por qualquer outro motivo (alerta, fim do treino) também descarta.
- **Sem mudança**, Salvar só fecha (nem "acerta" uma carga fora da grade, como 22,25 kg). **Série sem carga** ("Definir carga"): o número parte da última carga usada no exercício, esmaecido; Salvar sem mexer grava esse valor (delta 0, que o iPhone trata do mesmo jeito). Sem histórico (base 0 kg), Salvar fica desabilitado até mexer.
- **Detentes relativos**: cada detente ou toque soma um passo à carga de partida e o resultado vai para a grade de 0,5 — 22,5 lb vira 23,5 lb no primeiro detente, não 23.
- **A série muda por baixo** (concluída no iPhone, exercício pulado, sessão encerrada, trocada ou esquecida): o editor fecha sozinho, como Cancelar; um Salvar atrasado não grava em outra série.
- **Peso corporal**: "PC" pequeno antes do número com sinal ("PC +10 kg", "PC −5 kg"); em zero, "PC". No 46 mm a linha de contexto diz "· lastro" ou "· assistência".
- **Fim do descanso com o editor aberto**: o usuário já está com o relógio na mão — vibra uma vez (como o alerta desligado) e o editor fica; não abre a tela cheia, que fecharia a folha e perderia o ajuste.
- **41/42 mm**: sem título nem linha de contexto (custariam 30% do número). O número é o único elemento compressível (até 70%); nunca rola.

**Sessão · Descanso concluído (alerta)** — tela cheia, no lugar das páginas da sessão

```
┌────────────────────┐
│               10:11│  hora do sistema (sem toolbar, sem páginas)
│      ((  ◯  ))     │  anel laranja pulsando
│       +0:12        │  tempo desde o fim do descanso, dentro do anel
│ Descanso concluído │  laranja
│ Supino · série 3/4 │  "Supino inclinado · série 3 de 4"
│  26 kg · alvo 8–12 │
│ [  Começar série ] │  botão principal · toque duplo
│  Toque para parar  │
└────────────────────┘
```

- **O relógio vibra em laço** (§9.6) desde o fim do descanso até uma interação. A tela substitui a sessão inteira, em qualquer página (Controles, Métricas, Ficha) e fecha a folha que estiver aberta.
- **Para a vibração, a tela fica**: qualquer toque na tela ou giro da Coroa. O anel para de pulsar e vira um disco laranja cheio; a dica some; o tempo continua contando.
- **Começar série** (toque duplo / `handGestureShortcut(.primaryAction)`): para, fecha a tela e abre a página Série na próxima série (pulando a introdução "Próximo: …"); dispensa o descanso vencido no iPhone, o que também fecha o alerta de lá. Sem próxima série o botão diz "Continuar".
- **Teto de 60 s** depois do fim do descanso sem nenhuma interação: a vibração para, a tela cheia fecha e a sessão volta como estava (página Série na próxima série), com o aviso discreto "Descanso concluído" por 2 s no topo. Silenciada por toque, a tela fica até "Começar série".
- **Treino em aberto (> 4 h)**: a tela "Treino em aberto" tem prioridade; o alerta não abre nem continua por baixo dela (vale um háptico e o aviso discreto).
- **Relógio e iPhone são laços independentes**: cada aparelho decide e toca o seu. O relógio vibra sempre que o app dele está rodando; o iPhone só vibra com a tela da sessão à vista (§4.5) — no bolso ou bloqueado, só o relógio insiste (o iPhone manda a notificação/Atividade ao Vivo de sempre). Não há sincronização de pulsos nem de silêncio: tocar na tela de um não cala o outro; o que fecha os dois é "Começar série" (dispensa o descanso) ou qualquer mudança do descanso na sessão.
- **Some sozinha** se o descanso dela deixar de valer: +15 s, série concluída ou "Continuar" no iPhone, pausa, fim do treino.
- **Um alerta por descanso**: descanso pulado não alerta; ajustado alerta uma vez, no novo horário.
- **Pulso abaixado**: com o relógio gravando o treino (`HKWorkoutSession` ativa) o app continua rodando e o laço toca com a tela apagada. Sem gravação no relógio (sessão só controlada) o watchOS suspende o app com o pulso abaixado: o laço só toca com o app em primeiro plano; ao levantar o pulso dentro dos 60 s ele vibra pelo tempo que resta, depois disso avisa uma vez com o aviso discreto, sem tela cheia. Nesse caso o aviso com o pulso abaixado continua sendo a notificação do iPhone espelhada no relógio.
- **Botão lateral e clique da Coroa** não chegam ao app (o watchOS não os entrega): saem para o mostrador e a vibração segue até o teto. Giro da Coroa, toque e toque duplo param.

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
1. **RPE**: "Como foi o treino?", número grande (1–10) com o rótulo ("7 · Muito difícil"), ajustado pela Coroa com detentes (tela aberta de propósito, depois do esforço). `Salvar` (toque duplo) e `Sem nota`.
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
| Detente da Coroa (editor de carga, reps, RPE — nunca na Série/Descanso) | detente do sistema |
| Série concluída | `.success` |
| Fim do descanso (alerta insistente desligado) | `.notification`, duas vezes com 0,4 s |
| Fim do descanso (alerta insistente) | laço a cada 1,8 s alternando `.notification` duplo e `.retry`, até toque/Coroa/"Começar série" ou 60 s |
| "3, 2, 1" (início, sustentação) | `.click` a cada segundo, `.start` no zero |
| Alvo da sustentação atingido | `.directionUp` |
| Parar sustentação / pausar | `.stop` |
| Retomar | `.start` |
| Treino salvo | `.success` |
| Comando rejeitado / erro | `.failure` |

### 9.7 Acessibilidade no relógio

- **VoiceOver**: a página Série é lida como "Supino inclinado, série 2 de 4" → "Carga, 26 quilos, botão. Toque para ajustar" → "alvo 8 a 12 repetições" → "Concluir série 2". Na Série a carga **não** é ajustável (nem por gesto): toque duplo abre o editor. No editor, o número é ajustável ("Carga, série 2 de 4, 26 quilos"; deslizar para cima/baixo = ±0,5 kg ou ±1 lb), − / + são "Diminuir/Aumentar carga", "Salvar carga" (dica: "Grava 27,5 quilos e volta à série") e "Cancelar" (dica: "Descarta a mudança"). No descanso: "Próxima série, 26 quilos. Toque para ajustar". O fim do descanso é anunciado. Páginas têm nome ("Controles", "Série", "Métricas", "Ficha").
- **Texto grande (até AX3 no relógio)**: Série e Descanso viram roláveis e a Coroa só rola (nada nelas reage a ela); a carga continua sendo o botão que abre o editor. O botão principal continua fixo na base. Nenhum texto essencial é truncado: o nome do exercício quebra em até 3 linhas. O editor **não rola** em nenhum tamanho (a Coroa precisa ser da carga): o número tem tamanho fixo e encolhe se faltar espaço, a linha de contexto some, − / + e Salvar ficam.
- **Reduzir Movimento**: sem rolagem de dígitos nem transição de página animada entre série e descanso (esmaecimento); hápticos mantidos. No alerta de fim de descanso nada pulsa: disco laranja cheio com o número em branco (só contraste).
- **Alerta de fim de descanso**: ao abrir, o VoiceOver anuncia "Descanso concluído. Próxima: Supino inclinado, série 3 de 4, 26 quilos, alvo 8 a 12 repetições."; ordem de leitura: tempo ("Descanso concluído, há 12 segundos") → próxima série → "Começar série" (dica: "Para a vibração e volta à série"); toque mágico e a ação "Parar vibração" (no tempo e na próxima série) silenciam sem sair da tela. Texto grande: a tela rola (a Coroa passa a rolar, então não silencia), o botão fica fixo na base e os textos quebram linha.
- **Sem depender de gesto**: toque duplo e Coroa têm sempre um botão equivalente na tela (no editor de carga, − / + e Salvar).
- **Cor nunca sozinha**: zona com "Z3", estado do exercício com símbolo, pausa com texto.
- **AssistiveTouch / uma mão**: toda a sessão é operável só com toque duplo + Coroa, ou só com toques.

### 9.8 Critérios de validação (relógio)

Exigem iPhone + Apple Watch pareados; no simulador vale só layout.

W1. Da face do relógio até a sessão iniciada: no máximo 3 toques (app → ficha do dia → Iniciar).
W2. Concluir uma série = 1 toque ou 1 toque duplo, sem olhar para o iPhone; ajustar a carga em 0,5 kg = toque na carga → 1 detente (ou +) → Salvar/toque duplo. Girar a Coroa na Série, no Descanso, na Sustentação e no Cardio não muda nenhum valor (W4).
W3. O alvo aparece como prescrito ("8–12", "10", "máx."); nenhuma tela exige reps para concluir.
W4. O fim do descanso é sentido com o pulso abaixado e a tela apagada: com o relógio gravando o treino, vibra repetidamente até uma interação (ou 60 s).
W5. Série concluída no relógio aparece no iPhone em até 2 s (e vice-versa) com os dois por perto.
W6. Com o iPhone em modo avião: iniciar, concluir todas as séries e finalizar funcionam; ao reconectar, a sessão no iPhone tem as mesmas séries, cargas e horários (±1 s), sem duplicar.
W7. Sessão iniciada no iPhone aparece no relógio sem tocar em nada além de abrir o app (ou a notificação).
W8. Pausar no relógio congela o tempo no relógio e no iPhone; retomar não conta o intervalo.
W9. Sem permissão de Saúde a sessão inteira funciona e as métricas mostram "—".
W10. Todas as telas cabem em 41 mm sem truncar número, alvo ou botão principal; em 46 mm não sobra área morta acima do botão.
W11. Toda área de toque ≥ 44 pt; botão principal ≥ 46 pt (41 mm).
W12. VoiceOver percorre a página Série em ordem: exercício → série → carga (botão "Toque para ajustar") → alvo → Concluir; no editor a carga é ajustável deslizando para cima/baixo.
W13. Com texto no maior tamanho a carga é ajustável no editor por − / + e pela Coroa (o editor não rola) e nada essencial é cortado.
W14. Finalizar: RPE pela Coroa, "Sem nota" disponível, resumo mostra quantas cargas foram atualizadas.
W15. Alerta de fim de descanso: toque em qualquer ponto ou giro da Coroa para a vibração e mantém a tela; "Começar série" (ou toque duplo) leva à próxima série em 1 ação; a tela cabe em 41 mm sem cortar o tempo, a próxima série ou o botão; descanso pulado ou ajustado não alerta em dobro; desligado no iPhone, volta a uma vibração.
W16. Editor de carga (W4): Cancelar não envia comando e não muda a carga; Salvar envia exatamente um `adjustLoad` e as séries seguintes acompanham; Salvar sem mudança não envia; o editor cabe em 41 mm sem rolar, com número, − / + e Salvar inteiros; o descanso acabar com o editor aberto vibra uma vez e não fecha o editor.

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
11. **Relógio: páginas horizontais.** A parte "Coroa dedicada à carga" foi substituída pela decisão 35.
12. **Cores de ficha são identidade, não significado**: paleta própria de oito cores com par `fill`/`onFill` por tema; todo `fill` tem ≥ 3:1 sobre cartão e fundo, por isso o amarelo do tema claro é ouro escuro (§2.1.1).
13. **Ícone "degraus"**: caminho em três degraus até um ponto, branco sobre laranja; sem halter (§2.6).
14. **Uma Atividade ao Vivo por sessão**, não uma por descanso; na Tela Bloqueada só **+15 s** e **Pular** (o −15 s fica no app); sem FC na atividade (§4.14).
15. **"Descanso concluído" sem depender do app acordar**: `staleDate` no fim do descanso; um único aviso por descanso (atividade ou notificação).
16. **Saúde: sem dado não é zero, e leitura negada é tratada como "sem dados"** com o caminho para conferir o acesso — o HealthKit não revela negação de leitura (§4.11).
17. **Totais do dia pela união dos intervalos**, para que treino do Watch sobreposto nunca some, mesmo antes de vincular.
18. **Vínculo em dois níveis**: alta = vincula e avisa (com Desfazer); incerta = pergunta. Nunca por alerta ou notificação.
19. **Comparação com a semana em texto neutro** (seta + número contra a média dos 7 dias anteriores), sem cor de bom/ruim.
20. **Coach: resposta sem balão, pergunta em balão**; raciocínio recolhido; cada leitura de dados aparece como linha "Leu …" — a transparência do que saiu do aparelho é parte da interface.
21. **Consentimento é a primeira tela da aba Coach**, com os quatro compartilhamentos desligados por padrão.
22. **A tab bar some dentro da conversa** (a composição ocupa a base); a sessão em andamento continua a um "voltar" de distância e avisa pelo descanso (notificação/Atividade ao Vivo).
23. **Ajustes em um `Form` com sub-telas** (Saúde, Notificações, Coach e IA, Dados, Perfil); a troca kg/lb é só de exibição.
24. **`nutritionFill` escuro passou de `#1F8A40` para `#1C8540`**: o anterior dava 4,4:1 com branco.
25. **A IA tem identidade própria: gradiente "aurora"** (azul do Coach → violeta → rosa) + `sparkles`. Marca onde a IA entra e o que ela propõe; some quando o usuário decide (cartão aplicado/salvo perde o contorno). Nunca é estado, texto corrido nem fundo (§4.15.1).
26. **Um botão de IA em destaque por tela, no máximo**; ao lado do botão principal da área, o de IA é o sutil (vidro + contorno). O botão em destaque é a única cápsula com preenchimento próprio (gradiente) em vez de vidro tingido — o vidro não aceita gradiente como tint.
27. **Brilho único e orbe girando só durante o trabalho da IA** — exceção documentada ao "sem laço" (§2.5); nada disso com Reduzir Movimento.
28. **Importação numa folha `.large` com etapas empurradas**, não na conversa do Coach: a entrevista usa a linguagem da conversa, mas com trilho, progresso e saída para a revisão a qualquer momento.
29. **Confiança alta é silenciosa**; selo só em média ("Conferir") e baixa ("Revisar"), sempre com barras + texto e o motivo. Baixa é amarela (atenção), nunca vermelha: não é erro.
30. **A decisão final usa a cor da área de destino, não o gradiente**: "Criar programa" laranja, "Criar dieta" verde, "Aplicar" na cor do que será alterado.
31. **Aplicar não pede confirmação; tem Desfazer.** Desfazer não vibra e não confirma.
32. **Conversão de PDF em imagens é silenciosa** (uma etapa comum da análise), sem alerta nem escolha.
33. **Consentimento para importar não liga nenhum compartilhamento do Coach**: a importação só envia os arquivos escolhidos.
34. **Fim do descanso insiste até um toque** (pedido do usuário): relógio e iPhone vibram em laço com a tela "Descanso concluído", teto de 60 s, ligado por padrão e desligável em Ajustes › Treino. No relógio o toque só silencia (a tela fica com "Começar série"); no iPhone o toque silencia e fecha (a doca já mostra o próximo passo). O alerta em primeiro plano não toca som. Responde à Q4 quando o alerta está ligado: fica até um toque.

35. **W4 — a Coroa não mexe na carga fora do editor** (relato do usuário em aparelho: o pulso dobrado girava a Coroa e mudava a carga durante a série). Na Série e no Descanso a carga é um botão de vidro que abre o editor de carga (folha); só lá a Coroa ajusta, com rascunho, Salvar (um `adjustLoad`) e Cancelar (descarta). Nenhuma tela aberta durante o esforço reage à Coroa; o alerta de fim de descanso continua parando a vibração com ela (§9.1, §9.4). Responde Q-W2.

36. **P1.5 — copiar ficha é só cópia, em uma folha nativa e sem componente novo** (§4.2.1). Duas entradas que terminam no mesmo passo de encaixe: pela ficha (uma ficha, escolhe o destino) e pelo destino (várias fichas, agrupadas por programa).
37. **A entrada do destino fica onde as fichas aparecem** (Treinos › "+", estado sem fichas, "…" do detalhe do programa), não na folha "Editar programa": lá a edição é pendente (Cancelar/Salvar) e a cópia grava na hora.
38. **Confirmação só quando o usuário está longe do destino**: a cópia pela ficha termina em "Ficha copiada" + "Ver programa" dentro da própria folha; a cópia pelo destino só fecha a folha, porque as fichas aparecem na tela de baixo. Sem "Desfazer".
39. **Programas anteriores e arquivados recebem cópias**, como já recebem fichas da importação com IA; o detalhe deles continua somente leitura para todo o resto. Cor e letra da cópia nunca são trocadas; só o nome ganha "(2)".
40. **OpenCode Go: o seletor de modelo lista só modelos que leem imagens e não treinam com os dados**, sugeridos primeiro e depois do que menos gasta o limite do plano; sem selo por linha nem preço (o rodapé explica a ordem). Modelo só de texto continua possível em "Outro modelo", com uma linha de aviso na seção; modelo "-free" ou que treina com os dados é recusado (dados de saúde). Plano em `design/proposals/opencode-go.md`.

Perguntas em aberto:

- Q-CF1. Programas arquivados aparecem como **destino** da cópia (como origem foi pedido). Deixar só ativo e anteriores?
- Q-CF2. Uma ficha copiada para um programa que não é o ativo só sai de lá excluindo o programa (o detalhe não tem "Excluir ficha"). Vale um "Desfazer" no estado final, ou excluir ficha no detalhe do programa?
- Q-CF3. No fluxo pelo destino não há "Marcar todas" por programa (um toque por ficha). Faz falta para trazer um programa inteiro?

- Q-CP1. O botão de IA em destaque usa gradiente sólido (não vidro). Se preferir manter 100% vidro, a alternativa é o estilo sutil em todo lugar (vidro + contorno em gradiente). Qual?
- Q-CP2. No primeiro uso (Hoje), "Importar com IA" é o botão em destaque e "Criar do zero"/"Exemplo ABC" são secundários. Confirma a prioridade?
- Q-CP3. Fechar a folha durante a análise continua em segundo plano e avisa por notificação local. Ou deve cancelar?
- Q-CP4. Importação pendente guarda os arquivos no aparelho por até 7 dias para poder retomar. Prazo aceitável?
- Q-CP5. "Aplicar as 3" (aplicar várias alterações de uma vez) entra no C7.3 ou fica para depois?
- Q-CP6. Aceitar o consentimento na importação vale como consentimento do Coach (com os quatro compartilhamentos desligados). Ou devem ser consentimentos separados?
- Q-CP7. A confiança alta não mostra selo por item (só no cabeçalho). Prefere selo em todos os itens?

- Q4. A doca volta sozinha de "Descanso concluído" para "Concluir série" após 10 s — ou deve ficar até um toque? (Com o alerta insistente ligado o cartão fica até um toque — decisão 34; a pergunta vale só para o alerta desligado.)
- Q-RA1. O alerta do iPhone só vibra. Deve também tocar um som em laço (respeitando "Som ao fim do descanso"), como o timer do sistema?
- Q-RA2. Sem gravação no relógio o laço não toca com o pulso abaixado (o watchOS suspende o app). Vale pedir uma sessão em segundo plano no relógio só para o descanso, ou sempre gravar o treino no relógio?
- Q5. O laranja de preenchimento é queimado (`#D4450C`) para manter texto branco legível. Alternativa: laranja vivo (`#FF9500`) com texto **preto** nos botões. Qual prefere?
- Q6. "Atenção" e "recorde" ficaram na mesma família amarela (diferenciados por símbolo). Aceitável, ou o recorde deve ter outra cor?
- Q-W1. Sessão no relógio em páginas **horizontais** (Coroa livre para a carga), não verticais como sugerido. Confirma?
- ~~Q-W2~~ Respondida pela decisão 35: no descanso a Coroa não ajusta nada; a carga da próxima série se ajusta pelo chip "Próxima".
- Q-W3. Ao finalizar pelo relógio, as cargas atuais são atualizadas pela regra padrão sem perguntar, com revisão no iPhone. Confirma?
- Q-W4. Treino livre (sem ficha) no relógio fica fora do W0. Confirma?
- Q-LA1. Na Tela Bloqueada, o estado **Série** não tem botão. Um "Concluir série" ali fecharia o ciclo sem desbloquear, mas aceita toque acidental no bolso. Incluir?
- Q-LA2. Sessão iniciada pelo relógio com o app do iPhone fechado fica sem Atividade ao Vivo até o app abrir (limite do sistema sem servidor de push). Aceitável?
- Q-S1. Correspondência **alta** vincula sozinha e avisa com "Desfazer" (proposto, e há um toggle em Ajustes › Saúde para sempre perguntar). Ou deve sempre pedir confirmação?
- Q-S2. Limiar de "alta" sugerido: sobreposição ≥ 80% da duração menor e inícios a menos de 10 min. Confirma, ou o núcleo define?
- Q-A1. Importar backup: **Juntar** como padrão e **Substituir tudo** como opção destrutiva. Ou só substituir?
- Q-A2. A exportação não leva fotos e vídeos (só o JSON). Precisa de um pacote com mídia?
- Q-A3. kg ↔ lb só muda a exibição (valores guardados como digitados). Ou converter e regravar as cargas das fichas?
- Q-C1. A tab bar some dentro da conversa do Coach (e com ela o acessório da sessão). Preferível manter a tab bar e pôr a composição acima dela?
- Q-C2. Sugestão de prompt preenche o campo e espera o envio (proposto) ou envia direto?
- Q-I1. Ícone escuro e tinted têm fundo opaco próprio. Se preferir o fundo do sistema (PNG transparente), é uma troca de uma linha no gerador.
