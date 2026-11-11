# FitJourney — direção de design

Data: 11 de novembro de 2026
Status: **revisão 3** (pacote P6.1, `ios-design`): paleta oficial de fichas (§2.1.1), ícone do app (§2.6), aba Saúde detalhada (§4.11), Ajustes (§4.12), Coach (§4.13) e Atividade ao Vivo / Dynamic Island (§4.14). Revisão 2 (pacotes P0.1 + P0.4 + W0) — incorpora as decisões do usuário de 11/11 (SPEC §11 D1–D5): laranja como cor do treino, reps realizadas opcionais, passo de carga 0,5 kg, propostas P1/P3/P4/P5 aprovadas e "manter tela ligada" recusada, app do Apple Watch (§9).
Protótipo: [design/prototype.html](design/prototype.html) (abrir no Safari/Chrome; claro e escuro lado a lado; seções 10–23 são da revisão 3).
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

Desfazer um check não vibra (`fjHaptic(_:trigger:when:)`). A vibração do alerta insistente é a única fora do `sensoryFeedback`: precisa ser sentida com o aparelho no banco ou no bolso, e só toca com a tela da sessão aberta. Hápticos respeitam o ajuste do sistema; "Hápticos na sessão" em Ajustes desliga os da sessão.

### 2.5 Movimento (`FJMotion`, `.fjAnimation(_:value:)`)

| Token | Curva | Uso |
|---|---|---|
| `structure` | `.smooth(duration: 0.4, extraBounce: 0.1)` | Expandir/recolher exercício, doca trocar de modo, minimizar sessão |
| `value` | `.snappy(duration: 0.25)` | Check, barra/anel de progresso, número |
| `press` | `.easeOut(duration: 0.08)` | Resposta ao toque |
| `reduced` | `.easeInOut(duration: 0.2)` | Substitui todas com Reduzir Movimento |

Com Reduzir Movimento: sem zoom/matched geometry na transição sessão ↔ acessório (vira esmaecimento), sem contagem animada de dígitos nem troca animada de símbolo (`.fjNumericTransition()` e `.fjSymbolTransition()` viram identidade — nenhuma tela chama `contentTransition` direto), sem confete no recorde (fica o troféu estático). Nenhuma animação em laço em lugar nenhum.

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
- **O que faz**: o iPhone vibra a cada 1,5 s (vibração longa, §2.4) e o cartão cobre a doca; a lista fica escurecida e não recebe toques. O anel pulsa (ondas saindo do anel + contorno do cartão) e o número conta para cima a partir de "+0:00" — o descanso oficial continua parado em 0:00 (decisão 9); aqui se mostra há quanto tempo ele acabou.
- **Como para**: **qualquer toque ou arrasto** na tela para a vibração e fecha o alerta sem enviar nada — a doca aparece como estaria ("Descanso concluído · Continuar" nos primeiros 10 s, depois "Concluir série 3"). **Começar série** faz o mesmo e dispensa o descanso (igual ao "Continuar"). Alerta fechado no relógio ("Começar série" de lá) fecha o do iPhone, e vice-versa.
- **Teto**: 60 s depois do fim do descanso a vibração para sozinha; o cartão fica, sem pulsar e sem a dica, até um toque.
- **Não duplica**: um alerta por descanso. Pular, ±15 s, concluir outra série, pausar ou finalizar (aqui, no relógio ou na Tela Bloqueada) encerram o alerta; +15 s depois do fim abre um novo no novo horário.
- **Som**: o alerta em primeiro plano só vibra. "Som ao fim do descanso" continua valendo para a notificação e a Atividade ao Vivo.
- **Reduzir Movimento**: nada pulsa; o anel vira um disco laranja cheio com o número em branco e o contorno do cartão fica fixo (destaque só por contraste). A vibração continua.
- **Reduzir Transparência**: cartão sólido (`fjGlass`), véu igual.
- **VoiceOver**: ao abrir anuncia "Descanso concluído. Próxima: Supino inclinado, Série 3 de 4 · 26 kg · alvo 8–12."; o cartão é modal (o foco não escapa para a lista); cabeçalho "Descanso concluído, há 12 segundos"; "Começar série" com a dica "Para a vibração e volta à série"; gesto de escape (Z), toque mágico e a ação "Parar vibração" fecham o alerta.
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

**Coach**
28i. Nenhuma mensagem é enviada antes do consentimento; os quatro compartilhamentos começam desligados.
28j. Toda consulta a dados locais aparece na conversa como linha "Leu …"; categoria desligada aparece como "… não compartilhada", e o dado não é enviado.
28k. Durante o streaming: o botão de enviar vira Parar; rolar para cima não é desfeito pela chegada de texto; VoiceOver não é interrompido e anuncia o fim.
28l. Nada é salvo a partir de uma proposta sem passar pelo editor e pelo "Salvar"; o cartão mostra "Salvo" depois.
28m. Cada erro do provedor (chave, limite, rede, tamanho, recusa) tem mensagem própria e uma saída; a mensagem do usuário nunca se perde.
28n. A chave nunca aparece inteira depois de salva nem entra na exportação.

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
- **Movimento**: `FJMotion.value` para número e check; sem animação em laço — única exceção: o anel do alerta de fim de descanso (§9.4), que pulsa enquanto o relógio vibra. Tela sempre ligada (Always On): brilho reduzido, timer a 1 Hz, sem animações (o anel também para).
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
- Fim: abre o **alerta "Descanso concluído"** (abaixo). Com "Alerta insistente" desligado no iPhone: háptico forte uma vez (§9.6), "Descanso concluído" por 2 s e volta à Série.

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
- **Teto de 60 s** depois do fim do descanso: a vibração para sozinha; a tela fica até "Começar série".
- **Some sozinha** se o descanso dela deixar de valer: +15 s, série concluída ou "Continuar" no iPhone, pausa, fim do treino.
- **Um alerta por descanso**: descanso pulado não alerta; ajustado alerta uma vez, no novo horário.
- **Pulso abaixado**: com o relógio gravando o treino (`HKWorkoutSession` ativa) o app continua rodando e o laço toca com a tela apagada. Sem gravação no relógio (sessão só controlada) o watchOS suspende o app com o pulso abaixado: o laço só toca com o app em primeiro plano; ao levantar o pulso dentro dos 60 s ele vibra pelo tempo que resta, depois disso avisa uma vez e mostra a tela parada. Nesse caso o aviso com o pulso abaixado continua sendo a notificação do iPhone espelhada no relógio.
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
| Fim do descanso (alerta insistente desligado) | `.notification`, duas vezes com 0,4 s |
| Fim do descanso (alerta insistente) | laço a cada 1,8 s alternando `.notification` duplo e `.retry`, até toque/Coroa/"Começar série" ou 60 s |
| "3, 2, 1" (início, sustentação) | `.click` a cada segundo, `.start` no zero |
| Alvo da sustentação atingido | `.directionUp` |
| Parar sustentação / pausar | `.stop` |
| Retomar | `.start` |
| Treino salvo | `.success` |
| Comando rejeitado / erro | `.failure` |

### 9.7 Acessibilidade no relógio

- **VoiceOver**: a página Série é lida como "Supino inclinado, série 2 de 4, 26 quilos, alvo 8 a 12 repetições"; a carga é um elemento ajustável (deslizar para cima/baixo = ±0,5 kg), independente da Coroa; botões com rótulo completo ("Concluir série 2"); o fim do descanso é anunciado. Páginas têm nome ("Controles", "Série", "Métricas", "Ficha").
- **Texto grande (até AX3 no relógio)**: a página Série vira rolável; como a rolagem passa a usar a Coroa, a carga deixa de ser ajustada por ela e ganha botões − / + visíveis ao lado do número. O botão principal continua fixo na base. Nenhum texto essencial é truncado: o nome do exercício quebra em até 3 linhas.
- **Reduzir Movimento**: sem rolagem de dígitos nem transição de página animada entre série e descanso (esmaecimento); hápticos mantidos. No alerta de fim de descanso nada pulsa: disco laranja cheio com o número em branco (só contraste).
- **Alerta de fim de descanso**: ao abrir, o VoiceOver anuncia "Descanso concluído. Próxima: Supino inclinado, série 3 de 4, 26 quilos, alvo 8 a 12 repetições."; ordem de leitura: tempo ("Descanso concluído, há 12 segundos") → próxima série → "Começar série" (dica: "Para a vibração e volta à série"); toque mágico e a ação "Parar vibração" silenciam sem sair da tela. Texto grande: a tela rola (a Coroa passa a rolar, então não silencia), o botão fica fixo na base e os textos quebram linha.
- **Sem depender de gesto**: toque duplo e Coroa têm sempre um botão equivalente na tela (folha "Carga" com − / +).
- **Cor nunca sozinha**: zona com "Z3", estado do exercício com símbolo, pausa com texto.
- **AssistiveTouch / uma mão**: toda a sessão é operável só com toque duplo + Coroa, ou só com toques.

### 9.8 Critérios de validação (relógio)

Exigem iPhone + Apple Watch pareados; no simulador vale só layout.

W1. Da face do relógio até a sessão iniciada: no máximo 3 toques (app → ficha do dia → Iniciar).
W2. Concluir uma série = 1 toque ou 1 toque duplo, sem olhar para o iPhone; ajustar a carga em 0,5 kg = 1 detente da Coroa.
W3. O alvo aparece como prescrito ("8–12", "10", "máx."); nenhuma tela exige reps para concluir.
W4. O fim do descanso é sentido com o pulso abaixado e a tela apagada: com o relógio gravando o treino, vibra repetidamente até uma interação (ou 60 s).
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
W15. Alerta de fim de descanso: toque em qualquer ponto ou giro da Coroa para a vibração e mantém a tela; "Começar série" (ou toque duplo) leva à próxima série em 1 ação; a tela cabe em 41 mm sem cortar o tempo, a próxima série ou o botão; descanso pulado ou ajustado não alerta em dobro; desligado no iPhone, volta a uma vibração.

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
25. **Fim do descanso insiste até um toque** (pedido do usuário): relógio e iPhone vibram em laço com a tela "Descanso concluído", teto de 60 s, ligado por padrão e desligável em Ajustes › Treino. No relógio o toque só silencia (a tela fica com "Começar série"); no iPhone o toque silencia e fecha (a doca já mostra o próximo passo). O alerta em primeiro plano não toca som. Responde à Q4 quando o alerta está ligado: fica até um toque.

Perguntas em aberto:

- Q4. A doca volta sozinha de "Descanso concluído" para "Concluir série" após 10 s — ou deve ficar até um toque? (Com o alerta insistente ligado o cartão fica até um toque — decisão 25; a pergunta vale só para o alerta desligado.)
- Q-RA1. O alerta do iPhone só vibra. Deve também tocar um som em laço (respeitando "Som ao fim do descanso"), como o timer do sistema?
- Q-RA2. Sem gravação no relógio o laço não toca com o pulso abaixado (o watchOS suspende o app). Vale pedir uma sessão em segundo plano no relógio só para o descanso, ou sempre gravar o treino no relógio?
- Q5. O laranja de preenchimento é queimado (`#D4450C`) para manter texto branco legível. Alternativa: laranja vivo (`#FF9500`) com texto **preto** nos botões. Qual prefere?
- Q6. "Atenção" e "recorde" ficaram na mesma família amarela (diferenciados por símbolo). Aceitável, ou o recorde deve ter outra cor?
- Q-W1. Sessão no relógio em páginas **horizontais** (Coroa livre para a carga), não verticais como sugerido. Confirma?
- Q-W2. Durante o descanso, a Coroa ajusta a carga da próxima série (proposto) ou o tempo de descanso?
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
