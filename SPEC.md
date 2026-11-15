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
| O5b | App do Apple Watch para controlar a sessão (iniciar, ficha, séries, descanso, pausa, finalizar) | v1 (ciclo 4b) |
| O5 | Apple Health: gravar treinos, ler frequência cardíaca, gráfico por sessão com os exercícios marcados, distinguir força x aeróbico | v1 (ciclo 4) |
| O6b | Copiloto de IA: importar treino/dieta de PDF/foto/texto com entrevista e editar por conversa com cartões de alteração | ciclo 7 |
| O6c | Registrar refeições com IA: o dia inteiro por texto livre ou uma refeição por foto do prato (estimativa de itens, quantidades, kcal e macros), com revisão antes de salvar e vínculo ao plano (feita/ajustada/fora da dieta). Proposta: `design/proposals/ai-meal-log.md` | v1.1 |
| O6 | Coach IA em aba própria (chat), com acesso a todo o histórico, que propõe treinos/dietas como rascunho aplicável | fase 2 |
| O7 | Plugin/app do ChatGPT (objetivo, calorias ingeridas/gastas) | futuro |
| O8 | Versão Android | futuro |
| O9 | Interoperar com o HealthProject (`/Users/renato/Code/HealthProject`) | futuro |

Fora de escopo: rede social, marketplace de personal, catálogo licenciado de alimentos/código de barras, prescrição médica, diagnóstico. O app **registra e organiza**; sugestões da IA são sempre rascunhos que o usuário revisa.

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
| Carga | valor + unidade (kg/lb, preferência global; botões −/+ com passo padrão **0,5 kg**, configurável) ou "peso corporal" (com ± lastro/assistência); **% de 1RM** opcional (futuro) |
| Descanso | segundos após a série (padrão por exercício, sobrescrevível por série) |
| Cadência | texto "3-1-1-0" opcional |
| Esforço alvo | RIR (0–5) ou RPE (1–10) opcional |
| Cardio | duração, distância, nível/velocidade/inclinação, zona de FC |
| Observações | livre (ex.: "pegada fechada", "banco 30°") |

- **Carga inicial vs. carga atual** (R-T2): `initialLoad` é a carga prescrita ao criar/editar a ficha (imutável pela execução). `currentLoad` (por série prescrita) é atualizada ao concluir uma sessão em que o usuário usou outra carga — confirmação no fim da sessão: "Atualizar carga atual de Supino para 32 kg?" (padrão: sim, se todas as séries válidas foram concluídas). A próxima sessão pré-preenche com `currentLoad` e mostra "última vez: 3×10 com 32 kg".
  - **Memória de carga (11/11)**: exercício de carga nunca começa com "0 kg" inventado. Sem carga na ficha (nil ou peso 0), a série planejada usa a **última carga válida usada naquele exercício** (qualquer ficha); sem histórico, mostra "Definir carga". A **primeira carga definida** de uma série sem carga na ficha vira `currentLoad` automaticamente ao finalizar ("salva automaticamente" no resumo), sem confirmação. Alterar a carga de uma série propaga para as séries seguintes pendentes do mesmo exercício que mostravam a mesma carga planejada (pirâmides intactas). Peso corporal com delta 0 é carga válida.
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
- **Marcar série**: um toque no check conclui a série com a carga exibida. **Repetições não são obrigatórias** (decisão 11/11): a série sempre exibe o alvo como prescrito ("8–12", "10", "máx."); o campo de reps realizadas começa vazio e é opcional. Série concluída sem reps = "feita dentro do alvo". Editar reps/carga/tempo antes ou depois. Concluir série dispara o **cronômetro de descanso** (do descanso prescrito), com +15 s / −15 s / pular, aviso háptico + som opcional ao terminar, e Live Activity/Dynamic Island (ciclo 6).
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

### 6.4 App do Apple Watch — controle da sessão (decisão 11/11, ciclo 4b)
Objetivo: durante o treino o iPhone pode ficar no bolso/armário; **todo o controle da sessão acontece no Watch**.

**Funções no relógio**
- Ver o programa ativo e as fichas (a do dia em destaque, conforme a agenda §3.1); abrir uma ficha e ver seus exercícios e prescrição.
- **Iniciar treino** pelo relógio (ou continuar o que foi iniciado no iPhone — e vice-versa).
- Exercício atual: nome, "série 2 de 4", alvo como prescrito ("8–12 · 32,5 kg · RIR 2"), carga ajustável pela **Digital Crown** (passo 0,5 kg), reps opcionais.
- **Concluir série** (botão grande; também gesto de toque duplo) → inicia o **descanso**: contagem regressiva, háptico forte ao terminar, +15 s / pular.
- Isométrico: iniciar sustentação com contagem; cardio: cronômetro.
- Próximo exercício / pular / ver lista da ficha; marcar exercício como concluído.
- **Pausar / retomar** a sessão; **finalizar** com RPE 1–10 pela Crown e confirmação de cargas (detalhe completo pode ficar para o iPhone).
- Página de métricas: tempo, FC ao vivo e zona, calorias ativas.

**Arquitetura**
- O relógio roda a `HKWorkoutSession` (FC e calorias nativas, treino gravado com o tipo certo) e a **espelha no iPhone** (`startMirroringToCompanionDevice`); o canal de dados do espelhamento (`sendToRemoteWorkoutSession`) carrega comandos e estado nos dois sentidos durante a sessão.
- **iPhone é a fonte de verdade** (SwiftData). O relógio envia **comandos idempotentes** (`commandID`, `sessionID`, timestamp: concluir série, ajustar carga, iniciar/ajustar/pular descanso, pular exercício, pausar, finalizar); o iPhone aplica pelo mesmo `SessionStore` e devolve um **snapshot versionado** do estado. O relógio renderiza o snapshot e aplica otimisticamente o próprio comando.
- Fora de sessão: `WatchConnectivity` (`applicationContext`) leva um resumo compacto do programa ativo (fichas, exercícios, prescrição, cargas atuais) para o relógio abrir a lista sem o iPhone.
- iPhone fora de alcance: o relógio continua a sessão localmente com o último snapshot, enfileira comandos (`transferUserInfo`) e reconcilia ao reconectar (tempos derivados de timestamps, nunca de contadores).
- Protocolo versionado em código compartilhado (`Shared/WatchLink/`, só Foundation), testável sem aparelho — mesmo padrão do Manylens.
- Validação real exige iPhone + Apple Watch pareados.

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

## 7A. Copiloto de IA — importar e editar (decisão 11/11, ciclo 7)

Objetivo: montar e editar treinos e dietas **conversando com a IA**, inclusive a partir de fichas e dietas prontas (PDF, foto, texto) passadas por personal/nutricionista. **Sem OCR no aparelho**: o arquivo vai ao provedor de IA (multimodal), e o app diz exatamente quais campos quer extrair.

### 7A.1 Importar treino / dieta (prioridade)
- Botões **"Importar com IA"** (símbolo `sparkles`) em: Treinos (criar programa / nova ficha), editor de ficha (adicionar fichas a um programa existente), Dieta (novo plano) e no primeiro uso (Hoje).
- Entrada: **um ou mais arquivos** — PDF, imagens (galeria, câmera, arquivos; HEIC/JPEG/PNG), texto (.txt/.md/colar texto). Limites: até 10 arquivos, 20 MB cada (imagens redimensionadas para ≤ 2048 px antes do envio; PDFs com muitas páginas avisam custo).
- **Extração orientada por schema**: o app envia os arquivos + o **contrato de extração** (`contracts/program-import-v1.schema.json`, `nutrition-import-v1.schema.json`) com campos **obrigatórios** e **opcionais**; a IA devolve a melhor estimativa e, para cada item, `confidence` (alta/média/baixa), `source` (arquivo/página) e `notes` (o que estava ambíguo). Treino: programa (nome, objetivo, agenda sugerida) → **N fichas detectadas** (ex.: "Peito e tríceps", "Ombro", "Perna", "Costas e bíceps") → exercícios (nome como escrito + casamento com o catálogo) → séries (tipo, reps fixas/faixa/AMRAP, carga ou peso corporal, descanso, cadência, RIR/RPE, isometria, cardio, observações). Dieta: metas (kcal/macros se houver), dias/variações, refeições com horário, itens com quantidade/unidade/kcal/macros, substituições.
- **Entrevista (copiloto de montagem)**: depois da extração, uma conversa guiada mostra o que foi entendido e **pergunta só o que falta ou é incerto** (campos obrigatórios ausentes, baixa confiança, exercício sem casamento no catálogo, carga ilegível, "isto é 3×12 ou 3 séries de 12?"). Respostas do usuário atualizam o rascunho. A IA também pode dizer que os arquivos têm **vários treinos diferentes** → o usuário escolhe quais importar (cada ficha com seu cartão, marcável).
- **Revisão final**: cartões por ficha/refeição com tudo preenchido, indicadores de confiança, edição inline e "Criar programa"/"Adicionar ao programa X"/"Criar dieta". Nada é salvo antes. Programa/plano criado **inativo** (`origin = .ai`/`author = .ai`, "importado de N arquivos") com opção "Ativar agora".
- Consentimento: arquivos são enviados ao provedor escolhido; o fluxo exige consentimento do Coach (aviso específico: "o arquivo inteiro vai ao provedor"). Arquivos não são guardados no app depois da importação (só o resultado), salvo opção "manter anexo na ficha".

### 7A.2 Copiloto de edição (conversa)
- No Coach e a partir de qualquer ficha/dieta ("Editar com IA"), o usuário pede mudanças em linguagem natural: "sobe o supino para 34 kg", "troca o crucifixo por voador", "adiciona 30 g de whey no lanche", "registrei um açaí de 300 ml agora".
- A IA usa **ferramentas de escrita propostas** (nunca grava sozinha): `propose_routine_changes`, `propose_nutrition_changes`, `propose_food_log`. Cada proposta vira um **cartão de alteração** na conversa: diff legível (antes → depois), escopo (ficha/refeição/dia), botões **Aplicar** / **Ajustar** / **Descartar**. Aplicar grava pelo store correspondente (mesmas validações do editor) e o cartão vira "Aplicado ✓" com **Desfazer**. Alterações refletem imediatamente no app.
- Regras: nada aplicado sem toque; sessão de treino em andamento não é alterada pelo copiloto (avisa); carga alterada vira `currentLoad` (não mexe em `initialLoad`), salvo pedido explícito.

### 7A.3 Requisitos técnicos
- Camada de IA ganha **anexos multimodais** (`LLMMessage` com partes: texto, imagem base64, PDF/documento) para OpenAI (Chat Completions/Responses com `image_url`/`input_file`), Anthropic (`image`/`document`) e ChatGPT login (Responses `input_image`/`input_file`). Provedor sem suporte a PDF → converter páginas em imagens no aparelho (PDFKit) **apenas para enviar** (não é OCR).
- Extração com JSON Schema estrito (ferramenta `submit_extraction`), validação local e reparo; estado do import persistido (retomável se o app fechar).
- Privacidade: anexos nunca vão para log/backup; redimensionar e remover metadados EXIF/GPS das fotos antes de enviar.

### 7.x Registro de refeições com IA (O6c)

- Entrada: barra "O que você comeu?" (texto + câmera) na aba Dieta e "Preencher com foto" no ajuste de uma refeição. **Recursos de IA só aparecem com a IA configurada** (regra geral do app; sem IA, a Dieta segue com o registro manual).
- Texto do dia ou até 4 fotos (câmera ou galeria) → rascunho `food-log-draft-v1` → revisão editável (itens, quantidades, kcal/macros com faixa de incerteza, vínculo à refeição do plano) → "Registrar" (save único, com Desfazer). Nada é salvo sem confirmação; itens ficam marcados como estimados pela IA.
- Vínculo: com "Dieta" liberada em Coach e IA o plano do dia vai ao provedor; sem isso o vínculo é feito no aparelho por horário e nome, e o app oferece liberar "Dieta" uma vez, sem insistir. "Feita" grava os valores do plano (descarta a estimativa); para registrar o que a foto mostra, "Ajustada".
- Fotos: reduzidas e sem EXIF/GPS antes do envio; **não ficam guardadas no registro** (aviso breve na revisão). Foto tirada pela câmera do app é salva automaticamente em Fotos (permissão só de adicionar); também é possível escolher uma foto já existente da galeria.

## 8. Futuro (arquitetura deve permitir)

- **Plugin/app do ChatGPT** (O7): servidor MCP (Apps SDK) expondo as mesmas ferramentas do §7 e os mesmos schemas `ProgramDraft`/`NutritionPlanDraft`, mais metas de calorias ingeridas/gastas. Requer sincronização/back-end → os schemas JSON ficam versionados em `contracts/` desde já.
- **Android** (O8): domínio sem dependência de UI; contratos JSON versionados; regras puras testáveis (agenda, progressão, totais) isoladas em `Domain/` para portar (ou migrar para KMP como o HealthProject).
- **HealthProject** (O9): exportação/importação JSON versionada (`contracts/fitjourney-export-v1`) alinhada a `TrainingPlanVersion`/`WorkoutSession`/`NutritionPlanVersion`/`FoodEntry`; candidata a provedor das ferramentas `get_workout_history`/`get_nutrition_summary` do HealthProject.
- Sincronização iCloud (CloudKit): modelos SwiftData já compatíveis (propriedades opcionais ou com padrão, sem `@Attribute(.unique)`, relações opcionais).
- Complicações/Smart Stack no Watch, widgets, Live Activities de descanso (Live Activity entra no ciclo 6).

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
| D1 | Cor do treino/app | **laranja** (decisão 11/11); zona Z4 de FC muda de cor |
| D2 | Reps na sessão | sempre exibir o alvo ("8–12"); reps realizadas opcionais (decisão 11/11) |
| D3 | Passo de carga | 0,5 kg (decisão 11/11) |
| D4 | Propostas de design aprovadas | treino esquecido aberto (> 4 h); exemplo ABC no 1º uso; notificação de fim de descanso; refeição passada sem registro = "Sem registro". **Recusada**: manter tela ligada |
| D5 | App do Apple Watch | controle completo da sessão no relógio (§6.4), ciclo 4b |
| Q1 | Unidade padrão de carga | kg |
| Q2 | Semana começa em | segunda-feira |
