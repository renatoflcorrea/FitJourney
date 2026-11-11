# P6.6 — Inglês completo + QA de acessibilidade

Simuladores próprios: `FJ-p66` (iPhone 17 Pro) e `FJ-p66w` (Apple Watch Series 11 46 mm), desligados ao final.
Texto grande: `content_size accessibility-extra-extra-large` (na escala do simctl isso é AX4, mais exigente que AX3); no relógio, `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXL` (o simctl não aceita `content_size` em watchOS).

## Capturas (esta pasta)
- iPhone, en: `en-{light,dark,ax3}-{hoje,treinos,editor-ficha,dieta,saude,coach,ajustes,sessao-set,sessao-rest,sessao-finish}.png` (30). `ax3` = claro + texto grande.
- iPhone, pt-BR (claro): `pt-light-*.png` (10).
- Relógio 46 mm: `w-en-*` (normal), `w-pt-*` (normal), `w-en-ax-*` (texto grande); cenas: list, detail, series, rest, controls, metrics, routine, finish, summary, intro, hold, cardio (+ unreachable em pt).
- Ganchos DEBUG usados: `-fj.seedSample`, `-fj.startTab training|nutrition|coach|health` (health é novo), `-fj.openSettings root`, `-fj.openFirstRoutine`, `-fj.sessionDemo set|rest|finish` (novo: inicia a 1ª ficha; rest conclui a 1ª série; finish abre o encerramento), `-fj.session.restPermissionExplained YES` (suprime o alerta de avisos), e `-FJWScene` no relógio.

## Inglês / localização — feito
- Catálogo do app: o catálogo estava defasado (526 chaves sem `en` e outras ~526 usadas no código mas ausentes). Agora todas as chaves extraídas do build (app e extensão de widgets) têm `en`; verificado com o extrator do Xcode (`.stringsdata`): 0 chaves faltando. Plurais (`one`/`other`) em en e pt-BR para "%lld itens", "%lld itens sem calorias", "%lld mídias", "%lld refeições", "%lld séries iguais".
- Termos: set, rep, rest, RPE, RIR, superset/tri-set/circuit, workout, meal plan, routine (ficha), program.
- Frases montadas por concatenação de fragmentos localizados corrigidas: `RoutineEditorLogic.spoken` (fragmentos " de %lld repetições", ", com %@ %@", ". Descanso de %@" viraram frases completas), `SessionPresentation.spokenTarget`/`cardioDetailText` ("segundos", "minutos", "quilômetros", "%"), `ExerciseLibraryView.accessibilityText` (", N mídias").
- Relógio: criado `FitJourneyWatch/Localizable.xcstrings` (208 chaves, pt-BR e en, plurais) e `FitJourneyWatch/InfoPlist.xcstrings`; literais `String` do relógio (`WatchFormat`, `WatchPrimaryButton`, `WatchEmptyState`, `control(...)`, status de exercício, avisos, rótulos de VoiceOver) passaram a `String(localized:)`/`LocalizedStringResource`. `WatchFormat.locale` deixou de ser `pt_BR` fixo (agora o idioma do aparelho: "26.0 kg" em en). "PC" vira "BW" em en. Teste `WatchSessionModelTests` ajustado para não depender do idioma.
- `FitJourney/InfoPlist.xcstrings` e `FitJourneyWatch/InfoPlist.xcstrings`: textos de uso (Saúde leitura/gravação, Fotos, Câmera, rede local) em pt-BR e en. Os valores de `INFOPLIST_KEY_*` no `project.yml` continuam como pt-BR (idioma de desenvolvimento); o catálogo sobrepõe por idioma.
- Extensão de widgets: strings da Atividade ao Vivo e dos intents já usam o catálogo do app; todas com `en`.
- Mescla com `main` (P5.5): `Localizable.xcstrings` mesclado em JSON válido; Coach, AISettings e login ChatGPT cobertos pela tradução.

## Acessibilidade — corrigido
1. Relógio, Série em texto grande: valor da carga truncado ("…") com − / + ao lado; agora valor numa linha e − / + embaixo (`FitJourneyWatch/Views/SeriesPage.swift`, `loadRow`/`loadValueButton`).
2. Reduzir Movimento ignorado em `withAnimation(FJMotion.value|structure)` direto: `ExerciseEditorView.swift` (3 pontos) e `ExerciseMediaView.swift` (zoom da foto) agora usam `FJMotion.resolve(..., reduceMotion:)`.
3. `FJRestTimerView.swift` (~linha 62): linha "Série X de Y · carga · alvo" do descanso cortava em texto grande; agora até 3 linhas.
4. Auditoria estática (script em varredura de `Features/`, `DesignSystem/`, `FitJourneyWatch/`, `FitJourneyWidgets/`): botões só com ícone sem `accessibilityLabel` — nenhum (os candidatos têm rótulo no `Button` pai); `Chart` sem descritor — nenhum; `Image` decorativa sem `accessibilityHidden` — só falsos positivos dentro de `Label`/`Button` com rótulo; `Reduzir Transparência` tratado em `FJGlass`.

## Pendências (não corrigidas)
- `Features/Today/TodayView.swift:57` — `navigationSubtitle` da data trunca em texto grande ("Wednesday, November…"); é do sistema (sem `lineLimit`). Opção: formato abreviado em AX.
- `Features/Settings/SettingsRootView.swift:133` — `Picker` segmentado kg/lb não cresce com Dynamic Type (alvo visual ~30 pt de altura em AX; o toque segue a altura do controle do sistema).
- `Features/RoutineEditor/RoutineEditorView.swift` (campo do nome da ficha) — `TextField` de uma linha corta nomes longos em AX; é campo editável (rolagem horizontal), baixo impacto.
- Doca/descanso e controles flutuantes cobrem boa parte da tela em AX4 (`Features/Session/SessionView.swift`, `FJRestTimerView.swift`); a sessão rola, mas a doca ocupa ~40 % da altura — avaliar versão compacta em AX.
- Relógio, descanso em texto grande: `+ reps`/`+15 s` ficam atrás de "Pular" até rolar (`SeriesPage.swift`, `RestView`); a página rola e o botão primário é o certo, mas vale revisar a ordem.
- `FitJourneyWatch/Views/WatchRootView.swift:22` — aviso "Atualizado pelo iPhone" usa `.animation(.easeInOut)` só de opacidade (aceitável com Reduzir Movimento; sem troca para identidade).
- Dados de exemplo `-fj.seedSample` (DEBUG) são semeados em pt-BR; nomes do catálogo de exercícios são pt-BR (há `englishName` para busca, sem exibição localizada). Fora do escopo do catálogo de strings.
- Alvos < 44 pt: nenhum controle interativo encontrado abaixo de 44 pt (swatches de cor, dia da semana e botões de série usam `FJSize.minTap`/área de toque ≥ 44).
- `Services/AI/` (não alterado): prompts e esquemas em pt-BR (`DraftSchemas.swift:151`, `FitnessToolbox.swift:99`) são dados para o modelo, não UI; mensagens de erro (`AIError`) já passam por `String(localized:)`.

## Não verificado
- VoiceOver real (ordem de leitura, rotor, `accessibilityAdjustableAction` na Coroa): exige aparelho.
- Atividade ao Vivo / Dynamic Island em en (strings têm tradução; captura não refeita).
- Telas de AISettings/login ChatGPT e Coach com conversa em AX (sem gancho de navegação; só tradução e auditoria estática).
- Contraste: inspeção visual em claro/escuro, sem medição por ferramenta; nenhum problema evidente.
