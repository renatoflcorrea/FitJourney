# FitJourney — Especificação

Versão 0.1 · 11/11/2026 · Dono do produto: Renato

App iPhone nativo (SwiftUI, Swift 6 concorrência estrita, iOS 26+, Liquid Glass) para **planejar e registrar treinos de academia e dieta**, com integração ao Apple Health / Apple Watch e, numa segunda fase, um **Coach de IA** (OpenAI e outros provedores) que ajuda a montar treinos e planos alimentares a partir de todo o histórico.

Termos: "deve" = requisito da v1; "fase 2" = entra depois da v1; "futuro" = fora do escopo atual, mas a arquitetura não pode impedir.

---

## 1. Objetivos e escopo

| # | Objetivo | Fase |
|---|---|---|
| O1 | Cadastrar programas de treino com várias fichas, exercícios e prescrição completa | v1 |
| O2 | Executar uma ficha no dia: marcar séries/exercícios, ajustar carga, cronometrar descanso, encerrar com intensidade percebida | v1 |
| O3 | Guardar histórico: cada sessão, cada série, evolução de carga; ficha sabe a "carga atual" | v1 |
| O4 | Cadastrar dieta por horário, registrar refeições do plano e qualquer item fora do plano | v1 |
| O5 | Apple Health: gravar treinos, ler frequência cardíaca, gráfico por sessão com os exercícios marcados, distinguir força x aeróbico | v1 (ciclo 4) |
| O6 | Coach IA em aba própria (chat), com acesso a todo o histórico, que propõe treinos/dietas como rascunho aplicável | fase 2 |
| O7 | Plugin/app do ChatGPT (objetivo, calorias ingeridas/gastas) | futuro |
| O8 | Versão Android | futuro |
| O9 | Interoperar com o HealthProject (`/Users/renato/Code/HealthProject`) | futuro |

Fora de escopo: rede social, marketplace de personal, catálogo licenciado de alimentos/código de barras, cálculo de calorias por foto, prescrição médica, diagnóstico. O app **registra e organiza**; sugestões da IA são sempre rascunhos que o usuário revisa.

---

## 2. Conceitos (glossário)

| Termo (UI) | Modelo | Definição |
|---|---|---|
| Programa | `TrainingProgram` | Conjunto de fichas com um modo de agenda. Vários programas formam o histórico; **exatamente um pode estar ativo**. |
| Ficha | `Routine` | Um treino nomeado (ex.: "A — Peito e tríceps") com exercícios ordenados. |
| Exercício (catálogo) | `Exercise` | Definição reutilizável: nome, grupos musculares, equipamento, tipo, mídia. |
| Exercício da ficha | `RoutineExercise` | O exercício dentro de uma ficha, com a prescrição (séries, reps, carga, descanso...) e a **carga atual**. |
| Série prescrita | `SetPrescription` | Uma linha da prescrição: tipo de série, alvo de reps/tempo/carga, descanso. |
| Sessão | `WorkoutSession` | Uma execução de ficha num dia (início, fim, status, intensidade). |
| Série realizada | `SetLog` | O que foi feito de verdade em cada série. |
| Dieta | `NutritionPlan` | Plano alimentar com refeições por horário e metas. **Uma ativa.** |
| Refeição | `Meal` / `MealItem` | Horário + itens (alimento, quantidade, unidade, kcal e macros opcionais) + substituições. |
| Registro alimentar | `FoodEntry` | Algo comido: vinculado a uma refeição do plano ou avulso ("fora da dieta"). |

Nomes de modelo seguem o HealthProject (`TrainingPlanVersion`/`WorkoutSession`/`ExerciseSet`, `NutritionPlanVersion`/`FoodEntry`) onde possível, para facilitar O9. Regra herdada: **planejado nunca é contado como realizado**.

---

## 3. Treinos — planejamento

### 3.1 Programa
- Campos: nome, objetivo (texto livre + tag: hipertrofia, força, resistência, emagrecimento, condicionamento, reabilitação, outro), data de início, data de fim opcional, observações, **modo de agenda**, ativo (bool), arquivado (bool), origem (manual / IA / importado / duplicado de outro programa).
- **Modos de agenda** (R-T1):
  1. **Livre** — tenho N fichas e escolho no dia. "Hoje" mostra todas, destacando a menos recente.
  2. **Sequencial (rodízio)** — A → B → C → A... "Hoje" sugere a próxima da sequência após a última sessão concluída; posso escolher outra.
  3. **Semanal** — cada ficha tem um ou mais dias da semana. "Hoje" mostra a ficha do dia; em dia sem ficha mostra "Descanso" e permite iniciar qualquer uma.
- Ativar um programa desativa o anterior (confirmação). Programas antigos ficam no histórico, somente leitura por padrão, com "Duplicar e editar" e "Reativar".
- Programa pode ter **semanas/fases** (futuro: periodização). A v1 guarda `startDate`/`endDate` e mostra "semana X de Y" quando há fim.

### 3.2 Ficha
- Nome, letra/ícone/cor, dias da semana (modo semanal), duração estimada (calculada: séries × (execução + descanso)), observações, ordem.
- Exercícios ordenados, com **agrupamento** opcional: bi-set, tri-set, circuito (grupo com descanso só ao fim da rodada).
- Ações: reordenar (arrastar), duplicar ficha, mover/copiar exercício para outra ficha, pré-visualizar.

### 3.3 Exercício (catálogo)
- Nome, grupos musculares (primário/secundários), equipamento (barra, halter, máquina, polia, peso corporal, elástico, kettlebell, cardio, outro), lateralidade (bilateral / unilateral — "por lado"), **tipo de medida**:
  - `repsAndLoad` — repetições × carga (padrão);
  - `repsOnly` — peso corporal (carga opcional como lastro: +10 kg; assistência: −20 kg);
  - `isometric` — tempo de sustentação (s) e carga opcional;
  - `timeOrDistance` — cardio: duração, distância, velocidade/inclinação/nível, zona de FC alvo opcional.
- **Mídia** (opcional, várias por exercício):
  - imagem da galeria/câmera (salva no app, comprimida);
  - vídeo por link: **YouTube** e **Vimeo** (detectar e extrair ID; miniatura; player embutido via `WKWebView` com embed oficial, com fallback "abrir no app"); qualquer outra URL abre no Safari;
  - vídeo da galeria (`PhotosPicker`) copiado para o armazenamento do app, com limite configurável (padrão 60 s / 200 MB) e geração de miniatura.
- Catálogo inicial embutido (~60 exercícios comuns em pt-BR/en, sem mídia licenciada) + criados pelo usuário. Busca por nome e filtro por grupo/equipamento.

### 3.4 Prescrição (exercício da ficha)
Cada `RoutineExercise` tem uma lista de `SetPrescription` (pode ser "N séries iguais" com edição em bloco, ou série a série):

| Campo | Observação |
|---|---|
| Tipo de série | aquecimento, preparatória, válida (padrão), drop-set, rest-pause, até a falha, back-off |
| Repetições | número fixo **ou faixa** (mín–máx, ex.: 8–12; o mínimo é o "piso"); "AMRAP" (máximo possível) |
| Tempo de sustentação | para isométricos (s); opcional também por série |
| Carga | valor + unidade (kg/lb, preferência global) ou "peso corporal" (com ± lastro/assistência); **% de 1RM** opcional (futuro) |
| Descanso | segundos após a série (padrão por exercício, sobrescrevível por série) |
| Cadência | texto "3-1-1-0" opcional |
| Esforço alvo | RIR (0–5) ou RPE (1–10) opcional |
| Cardio | duração, distância, nível/velocidade/inclinação, zona de FC |
| Observações | livre (ex.: "pegada fechada", "banco 30°") |

- **Carga inicial vs. carga atual** (R-T2): `initialLoad` é a carga prescrita ao criar/editar a ficha (imutável pela execução). `currentLoad` (por série prescrita) é atualizada ao concluir uma sessão em que o usuário usou outra carga — confirmação no fim da sessão: "Atualizar carga atual de Supino para 32 kg?" (padrão: sim, se todas as séries válidas foram concluídas). A próxima sessão pré-preenche com `currentLoad` e mostra "última vez: 3×10 com 32 kg".
- Progressão automática (ex.: +2,5 kg ao atingir o topo da faixa) — **opcional, desligada por padrão**; quando ligada, só sugere, nunca aplica sozinha.

---

## 4. Treinos — execução (sessão)

### 4.1 Iniciar
- Aba **Hoje** mostra a ficha sugerida pelo programa ativo (§3.1) com botão grande "Iniciar treino", e acesso a "Outra ficha" e "Treino livre" (sessão sem ficha, adicionando exercícios na hora).
- Iniciar cria `WorkoutSession(status: inProgress)` com cópia (snapshot) da prescrição — editar a ficha depois não altera sessões passadas.
- Só **uma sessão em andamento** por vez. Fechar o app não perde nada (persistência a cada mudança); ao reabrir, a sessão continua com o relógio correto (calculado por `startDate`, não por timer em memória).

### 4.2 Durante
- Tela de sessão: cabeçalho com tempo decorrido, progresso (exercícios concluídos/total), FC atual quando disponível (§6).
- Lista de exercícios; o atual expandido mostrando séries com campos pré-preenchidos (carga atual, reps alvo). Mídia do exercício acessível em 1 toque.
- **Marcar série**: um toque no check conclui a série com os valores exibidos; editar reps/carga/tempo antes ou depois. Concluir série dispara o **cronômetro de descanso** (do descanso prescrito), com +15 s / −15 s / pular, aviso háptico + som opcional ao terminar, e Live Activity/Dynamic Island (ciclo 6).
- Isométrico: botão "Iniciar sustentação" com contagem regressiva do tempo alvo e registro do tempo real.
- Cardio: cronômetro e campos de distância/nível.
- **Marcar exercício** como concluído (automático quando todas as séries estiverem concluídas; manual permitido com séries pendentes = "concluído parcialmente"). Pular exercício (com motivo opcional: equipamento ocupado, dor, tempo).
- Adicionar série extra, remover série, trocar exercício por outro (substituição registrada), adicionar exercício não previsto, reordenar na hora.
- Anotação por exercício e por sessão. Registrar **dor/desconforto** opcional (local + 0–10) — sem interpretação.
- Cada `SetLog` guarda `completedAt` (timestamp) — base para alinhar com a FC (§6.3).
- A sessão em andamento aparece como acessório flutuante acima da tab bar (`tabViewBottomAccessory`) quando o usuário navega para outras abas.

### 4.3 Encerrar
- "Finalizar treino" → resumo: duração, volume total (Σ reps × carga das séries válidas), séries concluídas, recordes pessoais (maior carga, maior volume, 1RM estimado — Epley), exercícios pulados.
- **Intensidade percebida da sessão** (obrigatório oferecer, opcional responder): escala RPE de sessão 1–10 (Borg CR-10) com rótulos ("muito leve" … "máximo"), + humor/energia opcional e nota.
- Confirmação de atualização das cargas atuais (R-T2).
- Gravar no Apple Health como `HKWorkout` (força tradicional / funcional / HIIT / cardio conforme a ficha) se autorizado (§6).
- Descartar sessão (confirmação) não grava nada no histórico.

### 4.4 Histórico e evolução
- Calendário/lista de sessões; detalhe com todas as séries, intensidade, notas, gráfico de FC (§6).
- Por exercício: histórico de cargas/reps, melhor série, volume por sessão (Swift Charts).
- Por programa: aderência (sessões feitas x previstas no modo semanal), frequência semanal.
- Editar sessão passada (corrigir uma série) com marca de "editado".

---

## 5. Dieta

### 5.1 Plano alimentar
- Nome, objetivo, vigência (início/fim), autor (eu / nutricionista / IA), **metas diárias** opcionais: kcal, proteína, carboidrato, gordura, fibra, água. Uma dieta ativa (mesma regra dos programas); histórico de dietas.
- Pode variar por dia: "todos os dias" (padrão) ou por dia da semana (ex.: dia de treino x descanso) — `NutritionDay` com refeições próprias.
- **Refeição** (`Meal`): nome (café da manhã, lanche…), horário, lembrete opcional (notificação local), itens ordenados.
- **Item** (`MealItem`): alimento (texto), quantidade + unidade (g, ml, unidade, colher, xícara, fatia, porção), kcal/macros opcionais, observação, **substituições** (lista de alternativas equivalentes).
- Alimentos usados viram **favoritos/recentes** (`FoodItem` local com valores nutricionais por porção, preenchidos pelo usuário ou pela IA). Sem banco de dados licenciado na v1.

### 5.2 Registro do dia
- Aba **Dieta / Hoje**: linha do tempo das refeições do dia com estado: pendente, feita, feita com alteração, pulada. Próxima refeição destacada.
- Marcar refeição como **feita** (1 toque = todos os itens como planejado), **ajustar** (quantidades, trocar por substituição), **pular**.
- **Registro avulso a qualquer momento** ("+" global): o que comi, quantidade, horário (padrão agora, editável), kcal/macros opcionais, vínculo opcional a uma refeição; marcado como **fora da dieta** quando não vinculado.
- Totais do dia x metas (anéis/barras), água (copos), observação do dia (fome, saciedade).
- Grau de estimativa por entrada: informado / estimado / IA. Totais mostram quando há itens sem kcal ("3 itens sem calorias").
- Histórico por dia; aderência semanal.

---

## 6. Apple Health / Apple Watch (HealthKit)

### 6.1 Permissões
- Pedido contextual (não no primeiro abrir): ao ativar "Conectar ao Saúde" em Ajustes ou no primeiro "Finalizar treino". Ler: frequência cardíaca, treinos, energia ativa, FC em repouso, VFC, passos, massa corporal. Escrever: treinos, energia ativa, (futuro) energia ingerida/macros.
- Negação/parcial: tratar como "indisponível", nunca como "zero" (herdado do HealthProject INT-01). Simulador não valida HealthKit real.

### 6.2 Gravação do treino
- Iniciar sessão no iPhone usa `HKWorkoutSession` no iPhone (iOS 26+) quando disponível, para FC ao vivo de Apple Watch/sensores pareados; senão grava `HKWorkout` ao finalizar com início/fim, tipo e energia estimada.
- Tipo do treino derivado da ficha: força tradicional, força funcional, HIIT, core, flexibilidade, ou cardio (corrida, bicicleta, elíptico…) se os exercícios forem `timeOrDistance`.
- Metadados: ID da sessão do FitJourney (`HKMetadataKeyExternalUUID`), nome da ficha. Eventos por exercício (`HKWorkoutEvent` segment) com início/fim de cada exercício.
- Deduplicação: treinos gravados pelo próprio app são identificados pelo UUID externo; treinos do Watch no mesmo horário são **vinculados** à sessão (sugestão com confirmação quando incerto), nunca somados.

### 6.3 Análise
- **Detalhe da sessão**: gráfico de FC × tempo (Swift Charts), com faixas coloridas por exercício (início = 1ª série, fim = última série concluída) e marcadores por série; toque mostra exercício, série, FC média/máx naquele trecho. Zonas de FC (5 zonas por % da FC máx, configurável).
- **Por dia** (aba Saúde): treinos do dia (do app e de outros, ex.: corrida do Watch), FC ao longo do dia com os treinos sobrepostos, energia ativa, tipo **força x aeróbico** (por `HKWorkoutActivityType`), comparação com dias anteriores (semana).
- Resumos: minutos por tipo, FC média por treino, tendência de FC em repouso.

### 6.4 Apple Watch app próprio
- **Futuro.** A v1 usa o Watch apenas como fonte de dados do HealthKit (o usuário pode iniciar "Força Tradicional" no Watch; o app vincula). Companion watchOS para marcar séries vem depois.

---

## 7. Coach de IA (fase 2)

- Aba **Coach**: chat com streaming, histórico de conversas, sugestões de prompt ("Monte um ABC de hipertrofia, 4x/semana, 60 min", "Ajuste minha dieta para 2.200 kcal").
- Provedores via camada de abstração (mesmo desenho do fireplaice; detalhes em `docs/ia.md`): OpenAI (padrão), Anthropic, Gemini, OpenAI-compatível (ex.: Ollama/OpenRouter). Chave do usuário (BYOK) guardada no **Keychain**; modelo escolhível.
- **Ferramentas (function calling)** que o app executa localmente, só leitura por padrão: `get_profile`, `list_programs`, `get_program(id)`, `get_workout_history(range, exercise?)`, `get_exercise_progress(exercise)`, `list_nutrition_plans`, `get_nutrition_log(range)`, `get_health_summary(range)`. Limites de período/quantidade em cada uma.
- **Propostas**: a IA responde com saída estruturada (JSON Schema estrito) `ProgramDraft` ou `NutritionPlanDraft`; o app mostra um cartão de pré-visualização (fichas, exercícios, séries / refeições, metas) → "Revisar e salvar" abre o editor normal com o rascunho. Nada é salvo sem confirmação.
- Perfil do usuário para contexto (opcional): idade, sexo, altura, peso, nível, objetivo, restrições/lesões, equipamentos disponíveis, dias/tempo por semana, preferências alimentares/alergias.
- Privacidade: aviso claro de que o histórico enviado vai ao provedor escolhido; seleção do que compartilhar (treinos, dieta, saúde). Nada vai para servidor próprio na fase 2.
- Linguagem: sem diagnóstico nem prescrição médica; recomenda profissional quando houver dor/lesão/condição de saúde.

---

## 8. Futuro (arquitetura deve permitir)

- **Plugin/app do ChatGPT** (O7): servidor MCP (Apps SDK) expondo as mesmas ferramentas do §7 e os mesmos schemas `ProgramDraft`/`NutritionPlanDraft`, mais metas de calorias ingeridas/gastas. Requer sincronização/back-end → os schemas JSON ficam versionados em `contracts/` desde já.
- **Android** (O8): domínio sem dependência de UI; contratos JSON versionados; regras puras testáveis (agenda, progressão, totais) isoladas em `Domain/` para portar (ou migrar para KMP como o HealthProject).
- **HealthProject** (O9): exportação/importação JSON versionada (`contracts/fitjourney-export-v1`) alinhada a `TrainingPlanVersion`/`WorkoutSession`/`NutritionPlanVersion`/`FoodEntry`; candidata a provedor das ferramentas `get_workout_history`/`get_nutrition_summary` do HealthProject.
- Sincronização iCloud (CloudKit): modelos SwiftData já compatíveis (propriedades opcionais ou com padrão, sem `@Attribute(.unique)`, relações opcionais).
- Companion Apple Watch, widgets, Live Activities de descanso (Live Activity entra no ciclo 6).

---

## 9. Requisitos não funcionais

- **Plataforma**: iPhone, iOS 26.0+, retrato; Swift 6 (`complete`), SwiftUI, SwiftData, Swift Charts, HealthKit, PhotosUI, AVKit, WebKit. **Sem dependências de terceiros** na v1.
- **Offline-first**: tudo local; rede só para vídeos externos e IA.
- **Design**: limpo, Liquid Glass nativo (tab bar, barras, botões flutuantes, sheets, acessório da sessão) — vidro só no que flutua, nunca em listas de dados ou gráficos. Claro/escuro. Detalhes em `DESIGN_DIRECTION.md`.
- **Acessibilidade**: VoiceOver, Dynamic Type até AX5, Reduzir Movimento/Transparência, alvos ≥ 44 pt, contraste. Operável com uma mão durante o treino (ações principais na metade inferior).
- **Localização**: pt-BR (principal) e en, String Catalogs; unidades kg/lb e métricas locais.
- **Dados**: exportar tudo em JSON (`contracts/`) e importar (backup); apagar tudo. Mídia local em `Application Support/Media`.
- **Privacidade**: `PrivacyInfo.xcprivacy`; textos de uso do Saúde/Fotos/Câmera; dados de saúde nunca saem do aparelho exceto por ação explícita (IA).
- **Desempenho**: abrir a sessão < 300 ms; marcar série sem atraso perceptível; histórico com 1.000+ sessões fluido.
- **Qualidade**: lógica de domínio coberta por testes (Swift Testing); build limpo sem warnings de concorrência.

---

## 10. Navegação

Tab bar (Liquid Glass): **Hoje** · **Treinos** · **Dieta** · **Saúde** · **Coach** (fase 2; até lá, Ajustes ficam no avatar do topo de Hoje).

- **Hoje**: treino do dia (iniciar/continuar), próxima refeição, resumo do dia (kcal, treino, FC/energia), atalho "+ registrar comida".
- **Treinos**: programa ativo (fichas) · biblioteca de exercícios · histórico · programas anteriores.
- **Dieta**: dia atual (linha do tempo) · plano ativo · histórico · favoritos.
- **Saúde**: por dia (FC, treinos, força x aeróbico) · tendências.
- **Coach**: conversas.
- **Sessão**: tela cheia (`fullScreenCover`), minimizável para o acessório da tab bar.

---

## 11. Riscos e perguntas

| ID | Risco / pergunta | Padrão assumido |
|---|---|---|
| R1 | "Piso" no pedido original: interpretado como **piso da faixa de repetições** (mín–máx). Se era "peso", já está coberto por carga. | Faixa de reps |
| R2 | `HKWorkoutSession` no iPhone depende de iOS 26 e do Watch para FC ao vivo; sem Watch não há FC. | Degradar: só grava `HKWorkout` ao final |
| R3 | Embed de YouTube/Vimeo em `WKWebView` pode falhar (vídeo sem permissão de embed). | Fallback "Abrir no YouTube/Vimeo" |
| R4 | SwiftData + CloudKit exige modelos sem `unique` e relações opcionais. | Modelar assim desde já |
| R5 | IA BYOK: custo e chave ficam com o usuário; um proxy próprio entra junto com o plugin do ChatGPT. | BYOK na fase 2 |
| R6 | Android/KMP: hoje Swift puro; migração de `Domain/` para KMP decidida quando o Android começar (ADR). | Swift puro |
| Q1 | Unidade padrão de carga | kg |
| Q2 | Semana começa em | segunda-feira |
