# Proposta: registrar refeições com IA

Data: 15 de novembro de 2026 · Autor: `ios-design` · Status: **proposta, nada implementado**
Mockups: [ai-meal-log/](ai-meal-log/) (PNG 1206 × 2622, pt-BR). Fonte: `ai-meal-log/src/build.py`.

Pedido do dono: (1) registrar o dia inteiro de refeições conversando com a IA; (2) registrar uma refeição por foto do prato.

## 1. Recomendação

**Uma folha própria "Registrar com IA" na aba Dieta, com um campo único de texto (e fotos) que vira um rascunho estruturado, revisado e editado na mesma folha. Não é a conversa do Coach.**

Por quê:

1. **Registrar é tarefa de utilidade, várias vezes por dia.** Precisa estar a um toque na Dieta, na metade inferior, e terminar num botão "Registrar". A conversa do Coach tem histórico, laço de ferramentas (até 6 voltas, lê `list_nutrition_plans` antes) e só funciona com "Dieta" compartilhada.
2. **A revisão precisa de edição estruturada.** Quantidade com stepper, vínculo com a refeição, estado (feita, ajustada, fora da dieta). O cartão do Coach (`FJChangeCard`) é um diff só de leitura: cada correção custa outra ida ao modelo. Num dia com 4 refeições e 12 itens isso não serve.
3. **O `propose_food_log` de hoje não marca refeição.** Ele grava por `NutritionStore.logFood`, que cria registro parcial sem estado; não existe caminho para "feita" ou "ajustada".
4. **Coerência com a decisão 28** (importação numa folha com etapas, não na conversa).
5. **Privacidade mais simples.** A folha envia só o texto e as fotos, com aviso próprio; não depende dos quatro compartilhamentos do Coach.

O Coach continua existindo para o caso avulso dentro de uma conversa ("registrei um açaí agora"). Na fase 2 o cartão dele ganha "Revisar", que abre esta mesma revisão.

## 2. O que já existe (lido no código)

| Peça | Estado hoje |
|---|---|
| `LogFoodSheet` | Registro manual de um item; grau Informado, Estimado, IA. |
| `AdjustMealSheet` + `NutritionDayModel.saveAdjusted` | Ajuste por refeição; igual ao plano vira "Feita", senão "Ajustada". |
| `NutritionStore` | `markMealDone`, `logAdjustedMeal(adjusted:)`, `skipMeal`, `logFood(save:)`, `resetMeal`. Só `logFood` aceita `save: false`. |
| `FoodEntry` | `mealID`, `mealStatus` (done, adjusted, skipped), `plannedItemID`, `estimation` (informed, estimated, ai), kcal e macros opcionais. Sem campo de foto. |
| Coach | `propose_food_log` (até 10 itens, exige `Sharing.nutrition`), cartão "Registrar" e "Desfazer". A conversa **não tem anexos** na UI. |
| Importador | `AttachmentPreparer` (reduz, remove EXIF e GPS), `AttachmentCapabilities` (visão por provedor), câmera e galeria em `ImportFilesView`, folha de consentimento, `FJAnalysisProgress`, `FJConfidenceBadge`. |
| Hoje | O código só tem a seção de treino. O "+" e o cartão "Próxima refeição" do §4.1 ainda não existem. |

**Conflito com a SPEC:** o §1 lista "cálculo de calorias por foto" como fora de escopo. Esta proposta precisa que o dono altere a SPEC (§1, §5.2 e §7A). Eu não editei a SPEC nem o `DESIGN_DIRECTION.md`.

## 3. Pontos de entrada

| Onde | O quê | Decisão |
|---|---|---|
| **Dieta, base da tela** | Barra de vidro "O que você comeu?" (contorno e `sparkles` em gradiente, estilo sutil) + botão circular de câmera, acima da tab bar. Mockup 01. | Entrada principal. **Uma para o dia**, não uma por refeição. Aparece em hoje e em dias passados; some em dia futuro. |
| Dieta, "+" da toolbar | Continua abrindo o registro manual em um toque. Toque longo: Registrar comida · Registrar com IA · Foto do prato. | O caminho manual não ganha passo. |
| `AdjustMealSheet` | Botão sutil "Preencher com foto" no topo. | É o caminho por refeição, já vinculado. Evita um quarto botão no cartão da refeição. |
| Hoje | Só pelo menu do "+" quando ele existir, e um botão de câmera no cartão "Próxima refeição" quando ele for implementado. | Sem barra em Hoje: a base da tela é do treino e do acessório da sessão. |
| Coach | Chip "Registrar o que comi" na conversa vazia abre esta folha. | Um modelo mental: registrar é folha, conversar é Coach. |

A barra é um `safeAreaInset(edge: .bottom)` da aba Dieta, dentro de um `GlassEffectContainer`. Com treino em andamento ela fica acima do acessório da sessão. Visível quando o Coach está ativado (consentimento dado); antes disso a entrada fica só no menu do "+", para não empurrar IA a quem não quer.

## 4. Fluxo de texto (dia inteiro)

Folha `.large` com `NavigationStack`: **Compor → Analisar → Revisar → fecha com aviso e Desfazer**. Mockups 02, 07 e 08.

1. **Compor** (02): dia do registro (padrão: o dia aberto na Dieta); campo de texto livre, até 2.000 caracteres, ditado pelo teclado do sistema; chips com as refeições do plano, que inserem "Almoço: " no texto; fotos opcionais (até 4); aviso de privacidade sempre visível; `FJAIButton("Analisar")` em destaque na base.
2. **Analisar**: uma chamada ao modelo. Mesmo componente da importação (`FJAnalysisProgress`), sem promessa de tempo; mostra o tempo decorrido e os achados conforme chegam.
3. **Revisar** (07): total do dia em destaque, separando informado de estimado; um cartão por refeição com horário, estado e itens; a incerteza aparece no próprio item, com respostas rápidas ("200 ml · 300 ml · 500 ml"). Não há etapa de entrevista separada.
4. **Corrigir por texto** (menu "…" da revisão): "o arroz era integral, sem feijão" refaz só o rascunho.
5. **Registrar**: um save só; a folha fecha e a Dieta mostra "4 refeições registradas · Desfazer" (08).

Refeição não citada continua como estava (pendente ou "Sem registro"); a revisão diz isso numa linha.

## 5. Fluxo de foto

Mockups 03, 04, 05, 06.

1. **Captura** (03): câmera do sistema (a mesma da importação), com uma dica sobreposta: "Prato inteiro, de cima, com boa luz". Sem visor próprio. Galeria pelo seletor do sistema.
2. **Antes de enviar** (04): a foto, um campo opcional "Algo que a foto não mostra?", a refeição sugerida pelo horário (trocável) e o aviso de privacidade. `FJAIButton("Analisar foto")`. Esta etapa existe porque o aviso tem de aparecer antes do envio.
3. **Análise** (05): achados em sequência ("Encontrei 4 alimentos").
4. **Revisão da estimativa** (06):
   - **Total com incerteza**: "≈ 545 kcal", barra de faixa "entre 450 e 660 kcal", macros com "≈".
   - **Registrar como**: refeição vinculada + segmentado **Feita | Ajustada | Fora da dieta**, com uma frase dizendo o que cada um grava.
   - **Itens**: nome, quantidade e kcal com "≈". Tocar abre a edição no lugar (`NumberStepperField`, unidade, kcal e macros, remover); mudar a quantidade recalcula os valores na proporção. Confiança alta é silenciosa; média mostra "Conferir" e baixa "Revisar", com o motivo.
   - "Adicionar item" e a linha "Não aparecem na foto: óleo de preparo e bebida".
   - Botão **Registrar** verde. O gradiente sai de cena na decisão (decisão 30).

**Como o estado é escolhido** (regra local, o usuário sempre pode trocar):

| Situação | Padrão | O que grava |
|---|---|---|
| Sem plano no dia | sem seletor | `logFood`, avulso |
| Itens iguais aos do plano (mesmos alimentos, quantidade a ±25%, sem item extra) ou "como no plano" no texto | **Feita** | `markMealDone` com os itens e valores do plano, grau informado |
| Refeição pendente a até 90 min, itens diferentes | **Ajustada** | `logAdjustedMeal`, grau IA, `plannedItemID` quando o nome casa |
| Nenhuma refeição pendente perto | **Fora da dieta** | `logFood` sem `mealID`, grau IA |

## 6. Revisão antes de salvar

- Nada é gravado antes de "Registrar". Fechar a folha com conteúdo pergunta "Continuar depois" ou "Descartar".
- Item sem quantidade bloqueia o botão e diz o que falta. Kcal desconhecida fica "—" (ausente não é zero).
- Refeição que já tem registro fica **fora** do rascunho por padrão, com "Substituir o registro" (porque `logAdjustedMeal` apaga o anterior).
- Depois de registrar: sem gradiente; os itens levam "estimado pela IA" em texto neutro e os totais dizem "inclui 7 itens estimados pela IA".
- Desfazer apaga as entradas criadas e restaura as substituídas. Sem confirmação e sem háptico (decisão 31).

## 7. Estados

Mockups 09 e 10.

| Estado | O que aparece |
|---|---|
| Primeiro uso | A folha abre com o orbe e uma frase; sem tutorial. |
| IA não configurada | A folha abre e aceita texto; no lugar de "Analisar": "Falta configurar a IA" · Configurar · Registrar à mão. |
| Sem consentimento do Coach | Ao analisar, folha `.medium`: "O texto e as fotos vão ao provedor". Aceitar vale como consentimento com os quatro compartilhamentos desligados (como a decisão 33). |
| **Dieta não compartilhada** | Não bloqueia. O plano não é enviado; o vínculo é feito no aparelho por horário e nome. Dica na revisão: "A IA não vê o seu plano" · Permitir comparar com o plano. |
| Offline | Aviso neutro; o texto fica guardado; "Analisar" desabilitado; registro manual disponível. |
| Carregando | Orbe, tempo decorrido, achados; "Cancelar" na metade inferior. |
| Erro do provedor | Mesmas mensagens do §4.13.3, com "Tentar de novo"; texto e fotos preservados. |
| Foto ilegível ou sem comida | "Não encontrei comida nesta foto" + o motivo dito pela IA · Tirar outra · Descrever por texto. |
| Baixa confiança | Selo "Revisar" no item; se mais da metade das kcal vem de itens de confiança baixa, aviso de atenção no topo. O botão continua habilitado. |
| Modelo sem visão | Câmera desabilitada + "O modelo X não lê fotos" · Trocar modelo. |
| Câmera negada | Alerta com "Abrir Ajustes"; galeria e texto seguem. |
| Rascunho por terminar | A barra vira "Continuar rascunho · 4 refeições". Guarda texto e rascunho, nunca as fotos. |
| Treino em andamento | Funciona; não toca na sessão. |
| Dia futuro | Barra escondida. |

## 8. Privacidade

- **Vai ao provedor:** o texto digitado; as fotos reencodadas em JPEG, reduzidas, sem EXIF nem GPS, com nome genérico; a data e a hora do registro.
- **Só com "Dieta" ligada:** as refeições do plano daquele dia (nome, horário, itens), para a IA comparar. Nunca outros dias.
- **Nunca vai:** histórico, perfil, saúde, favoritos, localização.
- **Não fica guardado:** as fotos vivem em memória até a análise; não entram em log, backup nem no registro. Guardar a foto no `FoodEntry` fica para depois (pergunta aberta).
- **Avisos:** aviso fixo na composição com o nome do provedor; consentimento no primeiro envio; rodapé na revisão "Valores estimados pela IA. Não é orientação nutricional."; a dica da câmera pede só o prato no quadro.

## 9. Escopo técnico sugerido (não implementado)

**Novo**

- `contracts/food-log-draft-v1.schema.json` + cópia em `Services/AI/Drafts/DraftSchemas.swift` (teste de identidade) + `Services/AI/Drafts/FoodLogDraft.swift`.
- `Services/AI/Copilot/MealLogSession.swift` (`composing → analyzing → reviewing → applying → done/failed`): uma chamada com a ferramenta `submit_food_log`, saída curta, esforço de raciocínio baixo, fotos em até 1.280 px.
- `Domain/MealLogMatcher.swift` (puro, testável): vincula às refeições do plano e escolhe o estado padrão.
- `MealLogApplier` + `save: Bool` em `markMealDone` e `logAdjustedMeal`, para um save único e um registro de desfazer.
- `Features/Nutrition/MealLog/`: barra, folha, análise, revisão, `MealLogPresentation`.
- DesignSystem: `FJEstimateRange` (faixa com "≈") e `FJComposerBar` (barra de vidro com contorno de IA).

**Schema (resumo; estrito, todos os campos obrigatórios, nulos permitidos)**

```json
{
  "status": "ok | no_food | unreadable",
  "reason": "string | null",
  "meals": [{
    "slot": "breakfast | morning_snack | lunch | afternoon_snack | dinner | supper | other",
    "label": "string | null",
    "time": "HH:MM | null",
    "plannedMealId": "string | null",
    "asPlanned": true,
    "items": [{
      "name": "string", "quantity": 150, "unit": "grams | milliliters | unit | tablespoon | cup | slice | serving",
      "kcal": 185, "kcalMin": 150, "kcalMax": 235,
      "protein": 4, "carbs": 38, "fat": 1.5, "fiber": null,
      "confidence": "high | medium | low", "note": "string | null", "plannedItemId": "string | null"
    }]
  }],
  "notSeen": ["óleo de preparo", "bebida"]
}
```

Limites: 8 refeições, 20 itens por refeição. A faixa total e a faixa de quantidade são calculadas no aparelho. O formato é curto de propósito: ver `ai-import-speed.md`.

**Reutilizar do importador:** `AttachmentPreparer`, `AttachmentCapabilities`, câmera e galeria (extrair de `ImportFilesView`), folha de consentimento (texto parametrizado), `ImportProviderInfo`, `ImportNetworkMonitor`, `FJAnalysisProgress`, `FJConfidenceBadge`, `FJAIButton`, `DraftValidation`, `ChatStreamCollector`. Da Dieta: `AdjustDraftItem` (escala dos valores), `NumberStepperField`, `FoodUnitPicker`, `NutrientFields`.

**Fases:** 1) folha com texto e foto, revisão, aplicar e desfazer; 2) entradas em Hoje e no Coach, "Revisar" no cartão do `propose_food_log`; 3) guardar a foto, atalho de câmera.

## 10. Critérios de validação

1. Da Dieta ao "Registrar" de uma foto: no máximo 4 toques, todos na metade inferior.
2. Nenhum `FoodEntry` é criado antes de "Registrar"; Desfazer devolve o dia ao estado anterior.
3. Nenhum pedido sai sem o aviso com o nome do provedor na tela; com "Dieta" desligada o corpo do pedido não contém dado do plano (teste).
4. Foto enviada sem EXIF nem GPS (teste já existente do `AttachmentPreparer`).
5. Toda estimativa mostra "≈"; confiança média e baixa têm barras, texto e motivo, nunca só cor.
6. VoiceOver lê o item como frase: "Arroz integral, cerca de 150 gramas, cerca de 185 quilocalorias, confiança média, porção entre 120 e 190 gramas".
7. Em AX5 o segmentado empilha, os chips quebram linha e nada corta.
8. Reduzir Transparência: barra e chips sólidos com contorno. Reduzir Movimento: orbe parado.
9. Claro e escuro: texto sobre `nutritionFill` e sobre o gradiente a 4,5:1 ou mais.

## 11. Perguntas abertas

- Q-ML1. A barra aparece só com o Coach ativado, ou sempre?
- Q-ML2. Guardar a foto no registro (muda `FoodEntry`, backup e contrato)?
- Q-ML3. Com "Dieta" desligada, o vínculo local por horário e nome é suficiente, ou vale pedir o compartilhamento na primeira vez?
- Q-ML4. "Feita" grava os valores do plano e descarta a estimativa da foto. Confirma?

## 12. Mockups

| Arquivo | Tela |
|---|---|
| `01-dieta-entrada.png`, `01-dieta-entrada-escuro.png` | Aba Dieta com a barra "O que você comeu?" e a câmera |
| `02-folha-texto.png` | Folha: texto do dia, chips, fotos, aviso, Analisar |
| `03-captura-foto.png` | Câmera do sistema com a dica sobreposta |
| `04-foto-anexada.png` | Foto anexada, observação, refeição sugerida, aviso |
| `05-analisando.png` | Análise com achados |
| `06-revisao-foto.png`, `06-revisao-foto-escuro.png` | Revisão da estimativa da foto |
| `07-revisao-dia.png` | Revisão do dia a partir do texto |
| `08-registrado.png` | Dieta depois de registrar, com Desfazer |
| `09-estados-antes.png`, `10-estados-depois.png` | Quadros de estados |

Os mockups são ilustrações: o vidro é simulado, o prato é um desenho vetorial e os valores nutricionais são exemplos. Para regerar: `python3 design/proposals/ai-meal-log/src/build.py` (Chrome headless, uma instância por vez, perfil temporário).
