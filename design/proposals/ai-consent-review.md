# Proposta: consentimento de IA, demonstração para a revisão e modelos atuais

Data: 19 de novembro de 2026 · Autor: `ios-design` · Status: **proposta + componente do DesignSystem (`FJConsent.swift`, compila com `make build`)**. Nada mais de Swift foi alterado. Decisões 41–48 no `DESIGN_DIRECTION.md` (§4.16).

Motivo: a 1.0.0 foi rejeitada pelas diretrizes 5.1.1(i)/5.1.2(i). O app não dizia **o que** vai, **para quem** vai, nem pedia permissão **antes** do envio. Também foi rejeitada pela 2.1(a): faltava conteúdo de demonstração. O revisor ainda viu modelos antigos da OpenAI no seletor.

---

## 0. Resumo em uma página

- **Um único sistema de consentimento por destino.** O destino é a empresa que recebe de fato, com nome: OpenAI, Anthropic, OpenRouter + criador do modelo, OpenCode + criador do modelo, "o servidor em <host>" ou OpenAI (conta ChatGPT). O consentimento vale para três **usos**: Importar com IA, Registrar refeições e Coach. Também vale para quatro **categorias** do histórico (Perfil, Treinos, Dieta, Saúde), que o Coach e o registro podem ler. Tudo começa desligado.
- **Trocar de destino pede de novo.** Isso vale para trocar de provedor, de criador do modelo num roteador ou de host na URL própria. Trocar de modelo do mesmo criador não pede. Voltar a um destino já autorizado restaura o que foi permitido.
- **Uma folha "Antes de enviar"** (`FJConsentView`, já no DesignSystem) é igual nos três usos. Ela mostra a pergunta com o nome do destino, "O que é enviado" (inclusive o que **não** vai), "Para quem" (cadeia de destinos com links para as políticas de privacidade), a nota de que o app não tem servidor, e **Permitir / Não permitir**. Na aba Coach, o mesmo conteúdo é a própria tela da aba, com os quatro toggles.
- **Não permitir** não envia nada e mantém o que o usuário escolheu. O app segue inteiro sem IA: importação manual, registro manual e Coach desligado com "Rever".
- **Ajustes › Coach e IA › "O que é enviado e para quem"** mostra o destino atual, os três usos e as quatro categorias (toggles), "Revogar tudo" e os outros provedores já autorizados.
- **A checagem fica na fronteira da rede**: `ImportSession`, `MealLogSession` e `CoachConversationService`. Ela vale em todo envio, inclusive correções e "Tentar de novo". O consentimento global antigo (`coach.consent.v1`) deixa de valer, e quem já usava o app é perguntado uma vez.
- **Demonstração**: o botão "Experimentar com um exemplo" na folha de importação adiciona uma ficha fictícia empacotada no app (imagem), e "Adicionar as outras 3 fichas" completa o programa. Na dieta, há um plano de exemplo (PDF de 7 páginas) e um texto de exemplo no registro de refeições. O exemplo passa pelo mesmo consentimento.
- **Modelos atuais**: descoberta pelo endpoint de modelos de cada provedor, com a chave do usuário. A lista atualiza ao abrir Ajustes de IA e ao puxar a tela. O padrão é o modelo leve mais novo. As listas estáticas de reserva foram atualizadas.

---

## 1. Auditoria: tudo o que sai do aparelho para a IA

Requisitos da Apple: **A** dizer o que vai · **B** dizer para quem · **C** pedir permissão antes · **D** política de privacidade (fora do app).

| # | Caminho | O que é enviado | Consentimento hoje | Lacunas (A/B/C/D) |
|---|---|---|---|---|
| 1 | **Coach: mensagens** (`SendMessage.swift:203-216`, `CoachRootView.swift:110`) | Prompt do sistema, todas as mensagens da conversa que cabem na janela, resultados das ferramentas e nomes de ficha/plano ao usar "Editar com IA" (`RoutineEditorView.swift:57`, `TrainingRootView.swift:309`, `PlanEditorView.swift:79` só põem o texto no compositor) | Um booleano global `coach.consent.v1` (`CoachProfile.swift:84`), dado na boas-vindas (`CoachWelcomeView.swift:95-97`) | **B**: o aviso diz "o provedor de IA que você configurar" (`CoachWelcomeView.swift:76`) e o consentimento é dado **antes** de escolher o provedor. **C**: trocar de provedor não pede de novo, e a conversa antiga (com o histórico) vai para o novo destino. **A**: não diz que o histórico da conversa vai junto. |
| 2 | **Coach: categorias** (`FitnessToolbox.swift:86-99`, `:172`) | Perfil (idade, sexo, altura, peso, nível, objetivo, restrições/lesões, equipamentos, preferências), Treinos (programas, até 90 dias/50 sessões, evolução de 1 ano), Dieta (planos, registros de até 31 dias), Saúde (agregados diários de até 31 dias: treinos, minutos, FC média/repouso, energia, passos) | Toggles globais `CoachProfile.sharing`, desligados por padrão (bom) | **A incorreto**: "Saúde — Resumo do app Saúde (passos, FC, sono)" (`CoachWelcomeView.swift:125`). O app não envia sono e não cita energia nem treinos. **B**: nenhum destino nomeado. **C**: os toggles valem para qualquer provedor futuro. |
| 3 | **Importar: análise** (`ImportSession.swift:246-262`, `CopilotPrompt.swift:61-63`) | Arquivos inteiros (PDF, imagens ≤ 2048 px sem EXIF/GPS, texto), nota do usuário e nomes do catálogo semeado (não pessoais) | `hasConsented()` global. A folha `ImportConsentSheet` (`ImportFilesView.swift:334`) é aberta por `ImportFilesView.swift:76-82, 219-220` | Nomeia o provedor (bom), mas: **C** a aceitação grava o consentimento global do **Coach** (`ImportFilesView.swift:78`) e vale para qualquer provedor depois. **B** OpenRouter/OpenCode não dizem a quem repassam e a URL própria aparece só como "Compatível com OpenAI". Sem link de política. Os botões dizem "Concordar e analisar"/"Agora não" e não "Permitir/Não permitir". |
| 4 | **Importar: revisão com IA** (`ImportSession.swift:769`) | Extração compacta (JSON) + respostas da entrevista | Mesmo booleano global | Igual ao item 3. As respostas não são citadas no aviso (**A**). |
| 5 | **Registro de refeição** (`MealLogSession.swift:192`, `:228-231`) | Texto, até 4 fotos (reduzidas, sem EXIF), data/hora e o plano do dia se "Dieta" estiver ligada | Booleano global. `MealLogConsentSheet.swift:19-22` nomeia o provedor | **C**: grava o consentimento global do Coach (`MealLogPreferences.swift:43-47`). **A**: não cita data/hora nem o plano. **B**: igual ao item 3. |
| 6 | **Registro: correção** (`MealLogSession.swift:237-258`) | Texto da correção + rascunho + texto original (+ plano) | **Nenhuma checagem de consentimento** | **C**: se o consentimento for revogado durante a revisão, a correção ainda é enviada. |
| 7 | **Registro: "Permitir comparar com o plano"** (`MealLogReviewView.swift:429-438`, `MealLogPreferences.swift:27-39`) | Liga "Dieta" (o plano do dia e, no Coach, planos e registros de 31 dias) | Um toque no banner. **Concede o consentimento global do Coach** se não houver (`MealLogPreferences.swift:35`) | **A/B**: não diz para quem vai nem que vale também para o Coach. |
| 8 | **Descoberta de modelos** (`OpenCodeModels.swift:96`, `ChatGPTModelLister.swift:41`, `AISettingsView.swift:407,433`) | Só a credencial (não é dado pessoal) | Não precisa | Nenhuma. |
| 9 | **ChatGPT (login) · experimental** (`ChatGPTResponsesGateway`) | O mesmo do 1-5, numa conta de consumidor | Igual | **D/proteção equivalente**: a conta ChatGPT de consumidor pode treinar modelos conforme os controles de dados da conta. Não dá para afirmar "proteção equivalente". Ver Q-AC1. |
| 10 | **OpenRouter** (`ProviderFactory.swift:34-36`) | Tudo do 1-5 | — | **B/D**: o OpenRouter repassa a hosts que podem guardar ou treinar com os dados. Não enviamos `provider.data_collection: "deny"`. |
| 11 | **Política de privacidade** (CV_Website `en/privacy`) | — | — | **D**: não nomeia cada provedor, não diz que dados de saúde podem ir, não traz a declaração de proteção equivalente e não diz que o consentimento é por destino. |

Lacunas transversais: (a) o consentimento não está ligado ao destino. (b) A checagem é feita pela UI e não em todo envio (item 6). (c) A cópia de Saúde está errada. (d) Não há link de política no app. (e) "Não permitir" não existe como opção nomeada.

---

## 2. Modelo de consentimento (decisões 41–44)

### 2.1 Destino (`AIRecipient`)

Chave estável = `provedor` + `criador` (roteadores) + `host` (URL própria).

| Provedor | Chave | Cadeia "Para quem" (elos) | Link(s) |
|---|---|---|---|
| OpenAI (chave) | `openAI` | **OpenAI**, que executa o modelo `{modelo}` | Política de privacidade: https://openai.com/policies/privacy-policy/ |
| Anthropic | `anthropic` | **Anthropic**, que executa o modelo `{modelo}` | https://www.anthropic.com/legal/privacy |
| OpenRouter | `openRouter:{criador}` (prefixo do id, ex. `google`) | **OpenRouter**, que recebe e repassa a um serviço que executa o modelo e não guarda seus dados → **{Criador}**, que criou o modelo `{id}` | https://openrouter.ai/privacy · "Quem executa este modelo" → `https://openrouter.ai/{id}` |
| OpenCode Go | `openCode:{criador}` (pelo id: `gpt-`→OpenAI, `claude-`→Anthropic, `glm-`→Z.ai, `qwen`→Alibaba (Qwen), `mimo-`→Xiaomi, `deepseek-`→DeepSeek, `kimi-`→Moonshot AI, `hy`→Tencent, `minimax-`→MiniMax, `gemini-`→Google, `grok-`→xAI; sem mapa = o próprio id) | **OpenCode (Anomaly)**, que recebe e repassa ao serviço que executa o modelo → **{Criador}**, que criou o modelo `{id}` | https://opencode.ai/legal/privacy-policy |
| URL própria, rede local | `custom:{host}` | **{host}**: servidor na sua rede local, configurado por você | — (nota: "O FitJourney não sabe quem opera este servidor nem como ele trata os dados.") |
| URL própria, internet | `custom:{host}` | **{host}**: servidor que você configurou | — (mesma nota) |
| ChatGPT (login) | `chatGPT` (diferente de `openAI`) | **OpenAI (sua conta ChatGPT)** | Política da OpenAI. Nota: "Os controles de dados da sua conta ChatGPT valem para estes envios." |

Artigo em pt-BR (`{destino}`): "a OpenAI", "a Anthropic", "o OpenRouter", "o OpenCode", "o servidor em {host}", "a OpenAI (conta ChatGPT)". Em en: "OpenAI", "Anthropic", "OpenRouter", "OpenCode", "the server at {host}". A tabela de criadores traz o artigo pt: a OpenAI, a Anthropic, o Google, a Z.ai, a Alibaba, a Xiaomi, a DeepSeek, a Moonshot AI, a Tencent, a MiniMax, a xAI. As URLs da OpenAI (403 para robôs) e as dos criadores não estão conferidas. O núcleo confere antes de integrar (§9, P-C1).

### 2.2 Usos e categorias

- **Usos** (`AIFeature`): `importFiles` (Importar com IA, inclusive a revisão com IA), `mealLog` (análise e correção) e `coach` (mensagens, "Tentar de novo" e "Editar com IA").
- **Categorias** (`AIDataCategory`): `profile`, `workouts`, `nutrition`, `health`, por destino. Elas só vão para o destino se o uso que as lê também estiver permitido. O Coach lê as quatro. O registro de refeições lê `nutrition` (o plano do dia).
- **Gravação**: `coach.aiConsent.v2` (prefixo `coach.`, apagado por "Apagar tudo"; nunca exportado nem importado). Formato: `[chaveDoDestino: {features: [feature: Date], categories: Set, displayName, updatedAt}]`.
- **Negar não é gravado.** Cada toque em Analisar/Enviar sem permissão mostra a folha de novo (sempre por ação do usuário, nunca sozinha).
- **Migração**: `coach.consent.v1` deixa de valer (não nomeava destino). Os toggles antigos de `CoachProfile.sharing` viram apenas a **pré-seleção** dos toggles da primeira tela de consentimento do Coach. Nada vale até o usuário tocar em Permitir.

### 2.3 Onde é checado

`AIConsentGate.require(feature, recipient, categories)` roda imediatamente antes de montar a requisição:
- `ImportSession.analyze()` e `reviseWithAI()`;
- `MealLogSession.analyze()` e `correct()` (lacuna do item 6);
- `CoachConversationService.run` antes de **cada** volta, porque o destino pode mudar no meio. As ferramentas usam as categorias do destino atual (`FitnessToolbox.specs` e `execute`).

O erro carrega o destino: `AIConsentRequired(feature:recipient:)`. A UI abre a folha certa, com o nome certo.

### 2.4 OpenRouter

Em toda requisição de chat, o corpo leva `"provider": {"data_collection": "deny"}`: só hosts que não guardam nem treinam com os dados. Se o OpenRouter devolver "nenhum host disponível", a mensagem diz: "Nenhum serviço que executa este modelo atende à exigência de não guardar seus dados. Escolha outro modelo." É isso que sustenta a frase da cadeia e a declaração de proteção da política.

---

## 3. Telas e textos

`{destino}` = nome com artigo (pt) / sem artigo (en). `{Empresa}` = nome sem artigo. As folhas usam `FJConsentView` (`.presentationDetents([.large])`, arrastar para fechar = Não permitir, sem "×").

### 3.1 Folha "Antes de enviar": Importar com IA

```
┌──────────────────────────────────┐
│              (orbe)               │
│   Enviar a ficha para a OpenAI?   │  aiConsent.title
│ Para ler a ficha, o FitJourney usa│
│ um serviço de IA de outra empresa.│
│ Nada é enviado sem a sua permissão│
│ O QUE É ENVIADO                   │
│ ┌──────────────────────────────┐ │
│ │ [doc] O arquivo que você     │ │
│ │       escolheu               │ │
│ │       Tudo o que estiver     │ │
│ │       escrito ou visível…    │ │
│ │ ──────────────────────────── │ │
│ │ [💬] Suas respostas às        │ │
│ │       dúvidas da importação  │ │
│ │ ──────────────────────────── │ │
│ │ [≡] Nomes de exercícios do   │ │
│ │       catálogo do app        │ │
│ │ ──────────────────────────── │ │
│ │ ⊘ Não vão: seus treinos, sua │ │
│ │   dieta, dados do app Saúde… │ │
│ └──────────────────────────────┘ │
│ PARA QUEM                         │
│ ┌──────────────────────────────┐ │  aiConsent.recipient
│ │ (🏢) OpenAI                   │ │
│ │      Executa o modelo         │ │
│ │      gpt-6-luna.              │ │
│ │      ↗ Política de privacidade│ │  aiConsent.policyLink.primary
│ └──────────────────────────────┘ │
│ Sua escolha vale para as próximas │
│ importações com a OpenAI…         │
├──────────────────────────────────┤
│ [          Permitir          ]    │  aiConsent.allow (azul do Coach)
│ [        Não permitir        ]    │  aiConsent.deny (vidro neutro)
└──────────────────────────────────┘
```

Roteador (OpenCode/OpenRouter): o cartão "Para quem" tem dois elos ligados por um filete:

```
│ (⑂) OpenCode (Anomaly)                      │
│     Recebe e repassa ao serviço que executa │
│     o modelo.  ↗ Política de privacidade    │
│  │                                          │
│ (▣) Anthropic                               │
│     Criou o modelo claude-haiku-5-5.        │
```

| Elemento | pt-BR | en-US |
|---|---|---|
| Título (treino) | Enviar a ficha para {destino}? | Send the workout sheet to {Company}? |
| Título (dieta) | Enviar a dieta para {destino}? | Send the meal plan file to {Company}? |
| Mensagem | Para ler o arquivo, o FitJourney usa um serviço de IA de outra empresa. Nada é enviado sem a sua permissão. | To read the file, FitJourney uses an AI service from another company. Nothing is sent without your permission. |
| Linha 1 (1 / n) | O arquivo que você escolheu / Os {n} arquivos que você escolheu | The file you chose / The {n} files you chose |
| Detalhe 1 | Tudo o que estiver escrito ou visível neles, inclusive nomes, telefones e observações. Fotos vão reduzidas e sem localização. | Everything written or visible in them, including names, phone numbers and notes. Photos are resized, with location removed. |
| Linha 2 | Suas respostas às dúvidas da importação | Your answers to the import questions |
| Detalhe 2 | Só se a IA precisar perguntar algo. Os arquivos não são reenviados. | Only if the AI needs to ask something. The files aren't sent again. |
| Linha 3 (só treino) | Nomes de exercícios do catálogo do app | Exercise names from the app's catalog |
| Detalhe 3 | Para casar a ficha com a sua biblioteca. Não são dados seus. | To match the sheet to your library. This isn't your data. |
| Não vão | Não vão: seus treinos, sua dieta, dados do app Saúde nem a localização das fotos. | Not sent: your workouts, your diet, Apple Health data or photo locations. |
| Papel (empresa) | Executa o modelo {modelo}. | Runs the {model} model. |
| Papel (roteador) | Recebe e repassa ao serviço que executa o modelo. | Receives the request and forwards it to the service that runs the model. |
| Papel (OpenRouter) | Recebe e repassa a um serviço que executa o modelo e não guarda seus dados. | Receives the request and forwards it to a service that runs the model and doesn't store your data. |
| Papel (criador) | Criou o modelo {modelo}. | Created the {model} model. |
| Papel (rede local) | Servidor na sua rede local, configurado por você. | A server on your local network that you set up. |
| Papel (servidor) | Servidor que você configurou. | A server you set up. |
| Nota servidor | O FitJourney não sabe quem opera este servidor nem como ele trata os dados. | FitJourney doesn't know who runs this server or how it handles your data. |
| Nota ChatGPT | Os controles de dados da sua conta ChatGPT valem para estes envios. | Your ChatGPT account's data controls apply to these requests. |
| Link | Política de privacidade (rótulo VO: "Política de privacidade: {Empresa}") | Privacy Policy (VO: "Privacy Policy: {Company}") |
| Link OpenRouter | Quem executa este modelo | Who runs this model |
| Rodapé | Sua escolha vale para as próximas importações com {destino}; trocar de provedor pergunta de novo. O FitJourney não tem servidor: nada passa pelo desenvolvedor. Os dados são tratados conforme a política de privacidade de quem recebe e os termos da sua conta. Os arquivos não ficam guardados no app. | Your choice applies to future imports with {Company}; switching providers asks again. FitJourney has no server: nothing goes through the developer. Your data is handled under the recipient's privacy policy and your account terms. Files aren't kept in the app. |
| Permitir | Permitir | Allow |
| Não permitir | Não permitir | Don't Allow |
| Dica VO de Permitir | Envia agora e lembra a sua escolha para {destino}. | Sends now and remembers your choice for {Company}. |

Depois de Permitir, a folha fecha e a análise começa sozinha (sem segundo toque).

### 3.2 Registro de refeição

| Elemento | pt-BR | en-US |
|---|---|---|
| Título | Enviar a refeição para {destino}? | Send your meal to {Company}? |
| Mensagem | Para estimar itens, porções e calorias, o FitJourney usa um serviço de IA de outra empresa. | To estimate items, portions and calories, FitJourney uses an AI service from another company. |
| Linha | O texto que você escreveu | The text you wrote |
| Linha + detalhe | As fotos que você escolher (até 4) · Reduzidas e sem localização nem dados da câmera. | The photos you choose (up to 4) · Resized, with location and camera data removed. |
| Linha + detalhe | A data e a hora do registro · Para separar as refeições do dia. | The date and time of the entry · To place meals in your day. |
| Se Dieta permitida | As refeições planejadas do dia · Porque você permitiu Dieta para {destino}. | Today's planned meals · Because you allowed Diet for {Company}. |
| Não vão (sem Dieta) | Não vão: seu plano alimentar, seus treinos nem dados do app Saúde. | Not sent: your meal plan, your workouts or Apple Health data. |
| Rodapé | Sua escolha vale para as próximas análises de refeições com {destino}; trocar de provedor pergunta de novo. As fotos não ficam guardadas no registro. O FitJourney não tem servidor… (como em 3.1) | Your choice applies to future meal analyses with {Company}; switching providers asks again. Photos aren't kept in your log. FitJourney has no server… |

### 3.3 Coach: tela da aba (inline) e folha na conversa

Ordem nova da aba: (1) sem provedor pronto, a boas-vindas atual com "Configurar provedor e chave" (ainda não há a quem pedir); (2) com o provedor pronto, o `FJConsentView` como conteúdo da aba, com os toggles.

```
│ Enviar suas mensagens para a OpenAI?         │
│ O QUE É ENVIADO                              │
│ [💬] Suas mensagens e o histórico da conversa │
│ O Coach também pode ler, se você ligar:      │  caption
│ [👤] Perfil                          [ ○ ]    │  coach.consent.toggle.profile
│ [🏋] Treinos                         [ ○ ]    │  …workouts
│ [🍴] Dieta                           [ ○ ]    │  …nutrition
│ [♥] Saúde                            [ ○ ]    │  …health
│ ⊘ Nada do seu histórico vai sem você ligar.  │
│ PARA QUEM  (cartão)                          │
│ [ Permitir ]  [ Não permitir ]               │
```

| Elemento | pt-BR | en-US |
|---|---|---|
| Título | Enviar suas mensagens para {destino}? | Send your messages to {Company}? |
| Mensagem | O Coach responde com um serviço de IA de outra empresa. Tudo o que ele propõe é um rascunho que você revisa antes de salvar. | The Coach answers using an AI service from another company. Everything it proposes is a draft you review before saving. |
| Linha + detalhe | Suas mensagens e o histórico da conversa · Inclui o que você escrever e o nome de fichas ou planos ao usar Editar com IA. | Your messages and the conversation history · Includes what you type, and routine or plan names when you use Edit with AI. |
| Rótulo do grupo | O Coach também pode ler, se você ligar: | The Coach can also read, if you turn on: |
| Perfil | Idade, sexo, altura, peso, nível, objetivo, restrições e lesões, equipamentos e preferências alimentares. | Age, sex, height, weight, level, goal, restrictions and injuries, equipment and food preferences. |
| Treinos | Programas, fichas e treinos feitos, com séries e cargas (até 1 ano por exercício). | Programs, routines and completed workouts, with sets and loads (up to 1 year per exercise). |
| Dieta | Planos alimentares e o que você registrou (até 31 dias). Também vale para o registro de refeições. | Meal plans and what you logged (up to 31 days). Also used by meal logging. |
| Saúde | Do app Saúde, por dia: treinos, minutos, FC média e em repouso, energia ativa e passos (até 31 dias). | From Apple Health, per day: workouts, minutes, average and resting heart rate, active energy and steps (up to 31 days). |
| Não vão | Nada do seu histórico vai sem você ligar acima. | None of your history is sent unless you turn it on above. |
| Rodapé | O Coach não faz diagnóstico nem substitui médico, nutricionista ou educador físico. Sua escolha vale para {destino}; trocar de provedor pergunta de novo. O FitJourney não tem servidor: nada passa pelo desenvolvedor. | The Coach doesn't diagnose and doesn't replace a doctor, dietitian or trainer. Your choice applies to {Company}; switching providers asks again. FitJourney has no server: nothing goes through the developer. |
| Linha extra (folha na conversa, destino mudou) | O histórico desta conversa, que começou com {outro} | This conversation's history, which started with {Other} |
| Negado (estado vazio da aba) | O Coach está desligado · Nada é enviado. Os outros recursos do app funcionam normalmente. · **Rever** | The Coach is off · Nothing is sent. The rest of the app works as usual. · **Review** |
| 1ª linha da conversa | Enviando para {Empresa}. Esta conversa pode ler: Treinos · Dieta. **Alterar** | Sending to {Company}. This conversation can read: Workouts · Diet. **Change** |
| Rodapé da lista | {Empresa} · {modelo} · lendo Treinos e Dieta | {Company} · {model} · reading Workouts and Diet |

Folha na conversa: aparece ao enviar quando o destino atual não tem `coach` permitido (provedor trocado). O texto digitado fica no campo.

### 3.4 Dieta para o registro (categoria)

O banner da revisão ("A IA não vê o seu plano" · **Permitir comparar com o plano**) abre a folha de categoria:

| pt-BR | en-US |
|---|---|
| Título: Permitir que {destino} veja sua dieta? | Let {Company} see your diet? |
| Linha: Dieta · Planos alimentares e o que você registrou (até 31 dias). Também vale para o Coach. | Diet · Meal plans and what you logged (up to 31 days). Also used by the Coach. |
| Permitir / Não permitir | Allow / Don't Allow |

### 3.5 Depois de "Não permitir"

| Onde | pt-BR | en-US |
|---|---|---|
| Importar (banner neutro no lugar do aviso de privacidade; arquivos ficam; Analisar continua ativo e pergunta de novo) | Nada foi enviado · Sem permissão, a IA não lê seus arquivos. Você ainda pode criar o programa à mão. | Nothing was sent · Without permission, the AI won't read your files. You can still create the program yourself. |
| Registro | Nada foi enviado · Sem permissão, registre os itens à mão pelo +. | Nothing was sent · Without permission, log items yourself with +. |
| Coach | estado vazio do 3.3 | |

### 3.6 Avisos que mudam

| Onde | pt-BR | en-US |
|---|---|---|
| Importar, aviso fixo | Os arquivos vão para {destino} para serem lidos · Tudo o que estiver escrito neles é enviado. Depois da importação eles não ficam guardados no FitJourney. | Your files go to {Company} to be read · Everything written in them is sent. After the import, they aren't kept in FitJourney. |
| Importar, roteador (2ª linha) | {Roteador} repassa ao serviço que executa o modelo ({Criador}). | {Router} forwards them to the service that runs the model ({Creator}). |
| Análise, subtítulo | Enviados para {destino} · menos de 1 minuto | Sent to {Company} · under a minute |

### 3.7 Ajustes › Coach e IA › "O que é enviado e para quem"

Em Ajustes de IA, as seções "O que o Coach pode ler" e "Revogar consentimento" (`AISettingsView.swift:111-112, 360-384`) dão lugar a uma seção **Privacidade** com uma linha:

| pt-BR | en-US |
|---|---|
| O que é enviado e para quem · valor: "OpenAI · Importar, Coach (Treinos, Dieta)" / "Nada permitido" | What's shared and with whom · "OpenAI · Import, Coach (Workouts, Diet)" / "Nothing allowed" |
| Rodapé: O FitJourney não tem servidor. O que você permitir vai direto deste iPhone para quem recebe. | FitJourney has no server. What you allow goes straight from this iPhone to the recipient. |

Tela empurrada (`Form`, conteúdo sólido):

```
┌──────────────────────────────────┐
│ ‹ Coach e IA      O que é enviado │
│ PARA QUEM                         │
│ ┌ FJRecipientCard (cadeia+links) ┐│
│ PERMISSÕES                        │
│ Importar com IA            [ ● ]  │ privacy.toggle.import
│  Arquivos, fotos e texto que você │
│  escolher, e suas respostas       │
│ Registrar refeições        [ ○ ]  │ privacy.toggle.mealLog
│  Texto, fotos, data e hora        │
│ Coach                      [ ● ]  │ privacy.toggle.coach
│  Suas mensagens e a conversa      │
│ rodapé                            │
│ O COACH TAMBÉM PODE LER           │ (desabilitado com Coach desligado)
│ Perfil [○] Treinos [●] Dieta [●]  │ privacy.toggle.<categoria>
│ Saúde  [○]                        │
│ [ Revogar tudo para a OpenAI ]    │ privacy.revokeAll (destrutivo)
│ OUTROS PROVEDORES JÁ AUTORIZADOS  │
│ Anthropic · Importar, Coach       │ deslizar: Remover
│ [ Esquecer os outros provedores ] │ privacy.forgetOthers
└──────────────────────────────────┘
```

| pt-BR | en-US |
|---|---|
| Título: O que é enviado | What's Shared |
| Seções: Para quem · Permissões · O Coach também pode ler · Outros provedores já autorizados | Recipient · Permissions · The Coach Can Also Read · Other Providers You've Allowed |
| Rodapé de Permissões: Desligar vale para os próximos envios. O que já foi enviado fica com quem recebeu, conforme a política de privacidade dele. | Turning off applies to future requests. Data already sent stays with the recipient, under its privacy policy. |
| Revogar tudo para {destino} | Revoke Everything for {Company} |
| Diálogo: Revogar tudo para {destino}? · O FitJourney para de enviar dados para {destino} e volta a perguntar antes do próximo envio. O que já foi enviado fica com quem recebeu. · Revogar · Cancelar | Revoke everything for {Company}? · FitJourney stops sending data to {Company} and will ask again before the next request. Data already sent stays with the recipient. · Revoke · Cancel |
| Esquecer os outros provedores | Forget Other Providers |
| Sem provedor pronto: Configure um provedor para ver para quem os dados iriam. | Set up a provider to see who would receive your data. |

Ligar um toggle aqui conta como permissão: a tela nomeia o destino e o dado.

### 3.8 Acessibilidade

- O título é cabeçalho. "O que é enviado" e "Para quem" são cabeçalhos. Cada linha é um elemento ("O arquivo que você escolheu. Tudo o que estiver escrito…"). Cada elo é um elemento ("OpenCode (Anomaly). Recebe e repassa…"), e os links ficam como elementos próprios.
- Permitir e Não permitir têm o mesmo tamanho (56/48 pt) e ficam presos à base. Em AX1+ vão para o fim do conteúdo, que rola inteiro (já está no componente).
- Ao abrir a folha, o foco vai para o título. Ao Permitir, o anúncio é "Permitido. Enviando para {Empresa}".
- Reduzir Movimento: orbe parado. Reduzir Transparência: botões sólidos (`fjGlass`). O contraste usa só tokens `coach`/`textSecondary`. Claro e escuro pelo sistema.

---

## 4. Demonstração para a revisão (2.1(a))

### 4.1 Onde e como

- **Folha de importação (treino), estado vazio**, logo abaixo da grade de fontes: botão secundário em largura total, `FJSecondaryButton("Experimentar com um exemplo", systemImage: "doc.text.image")`, id `import.sample`. Ele adiciona **uma** ficha fictícia (imagem). A miniatura ganha `FJTag("Exemplo")` e a legenda "Ficha fictícia, criada para demonstração." Abaixo das miniaturas, enquanto só houver o exemplo: link "Adicionar as outras 3 fichas do exemplo" (`import.sample.addMore`), que completa um programa de 4 fichas (mostra a etapa "Várias fichas detectadas").
- **Folha de importação (dieta)**: o mesmo botão adiciona o plano de exemplo (PDF de 7 páginas).
- **Registro de refeição**: chip "Experimentar com um exemplo" (`mealLog.sample`) sob o campo vazio. Ele preenche o texto de exemplo e não envia sozinho.
- O exemplo passa pelo **mesmo** consentimento. Nada é enviado antes de Permitir.
- O botão só existe onde a IA aparece (regra `AIAvailability`). O revisor configura a chave do OpenCode Go antes (notas da revisão, §7).

| Elemento | pt-BR | en-US |
|---|---|---|
| Botão | Experimentar com um exemplo | Try with a sample |
| Nome do anexo (treino) | Ficha de exemplo.jpg | Sample workout sheet.jpg |
| Nome do anexo (dieta) | Plano alimentar de exemplo.pdf | Sample meal plan.pdf |
| Legenda | Ficha fictícia, criada para demonstração. | A fictional sheet made for demonstration. |
| Link | Adicionar as outras 3 fichas do exemplo | Add the other 3 sample sheets |
| Tag | Exemplo | Sample |
| Texto de exemplo (registro) | Café da manhã: 2 ovos mexidos, 1 pão francês com manteiga e café com leite. À tarde, um açaí de 300 ml com granola. | Breakfast: 2 scrambled eggs, a bread roll with butter and coffee with milk. In the afternoon, a 300 ml açaí bowl with granola. |

### 4.2 Arquivos a empacotar (de `/Users/renato/Downloads/FitJourney Files`, marcados "APP REVIEW SAMPLE", nomes fictícios)

| Origem | Destino no app | Conversão |
|---|---|---|
| `Chest_and_Biceps_Workout.pdf` (1 pág., 12 exercícios com reps, faixas, duração, carga e cardio: o mais variado) | `FitJourney/Resources/Samples/SampleWorkoutChestBiceps.jpg` | página 1 → JPEG 1448×2048, qualidade 0,8, sRGB, sem metadados (`pdftoppm -jpeg -r 175 -scale-to 2048`) |
| `Back_and_Triceps_Workout.pdf`, `Leg_Workout.pdf`, `Shoulder_Workout.pdf` | `SampleWorkoutBackTriceps.jpg`, `SampleWorkoutLegs.jpg`, `SampleWorkoutShoulders.jpg` | igual |
| `Meal_Plan.pdf` (7 pág., 81 KB) | `SampleMealPlan.pdf` | copiar como está (mostra a importação de PDF) |

São arquivos soltos no bundle (não asset catalog), lidos como `Data` → `RawAttachment`. Script versionado: `scripts/make-review-samples.sh <pasta>`. O conteúdo está em inglês nos dois idiomas (Q-AC3). Foto de prato de exemplo é opcional (Q-AC4).

---

## 5. Modelos sempre atuais (decisão 47)

| Provedor | Descoberta | Filtro | Padrão (sem escolha do usuário) | Reserva estática |
|---|---|---|---|---|
| OpenAI | `GET https://api.openai.com/v1/models` (Bearer) | ids `gpt-*` e `o<n>*`; fora: `audio`, `realtime`, `transcribe`, `tts`, `image`, `search`, `embedding`, `moderation`, `instruct`, `codex`, `-pro` e instantâneos datados `-AAAA-MM-DD` | `*-luna` de maior versão numérica (regra C1 do Fireplaice); senão `*-mini` mais novo; senão o primeiro | `gpt-6-luna`, `gpt-6.1-terra`, `gpt-6.1-sol` (**conferir com chave real no dia**) |
| Anthropic | `GET https://api.anthropic.com/v1/models?limit=1000` (`x-api-key`, `anthropic-version: 2023-06-01`) | `claude-*`; preferir o alias sem data; todos leem imagens | `claude-haiku-*` de maior versão | `claude-haiku-5-5`, `claude-sonnet-5-5`, `claude-opus-5-5` (haiku primeiro; hoje o padrão é opus) |
| OpenRouter | `GET https://openrouter.ai/api/v1/models` | `architecture.input_modalities` ∋ `image`, `supported_parameters` ∋ `tools`, sem `:free` | `openai/gpt-*-luna` mais novo; senão `anthropic/claude-haiku-*` mais novo | `openai/gpt-6-luna`, `anthropic/claude-haiku-5.5` + o "flash" mais novo do Google na lista pública do dia (troca `google/gemini-2.5-pro`) |
| OpenCode Go | já existe (decisão 40) | idem | a regra do luna sobre a lista descoberta (Luna mais novo vira padrão sozinho) | inalterada |
| ChatGPT (login) | já existe | idem | regra C1 do luna (hoje "o primeiro da lista") | inalterada |
| URL própria | `GET {base}/models` (opcional) | nenhum | o atual | `llama3.1` |

Comportamento (mínimo):
- Ao abrir Ajustes de IA, a lista do provedor atual é **buscada de novo** (ignora o TTL de 24 h). Enquanto isso, aparece a lista em cache e um indicador no cabeçalho "Modelo". Falha = cache ou reserva, sem erro. Puxar a tela (`.refreshable`) repete a busca.
- Cache por provedor: `coach.models.<provedor>.v1`. Trocar a chave limpa o cache.
- Escolha do usuário nunca é desfeita. Se o modelo escolhido sumir de uma lista nova, aparece uma linha de atenção com "Usar {padrão}". Sem escolha (`models[provider] == nil`), o padrão segue a regra sozinho.
- Até 8 linhas. "Ver todos os modelos ({n})" empurra uma lista com busca (OpenRouter, OpenAI).

| Texto | pt-BR | en-US |
|---|---|---|
| Subtítulo do padrão | Padrão · mais leve e rápido | Default · lightest and fastest |
| Atualizando (VO) | Atualizando a lista de modelos | Updating the model list |
| Modelo sumiu | {modelo} não aparece mais na lista de {Empresa}. · Usar {padrão} | {model} is no longer listed by {Company}. · Use {default} |
| Ver todos | Ver todos os modelos ({n}) | See All Models ({n}) |
| Rodapé OpenRouter | Só modelos que leem imagens e usam ferramentas. O OpenRouter só repassa a serviços que não guardam seus dados. | Only models that read images and use tools. OpenRouter only forwards to services that don't store your data. |
| Rodapé offline | Lista salva em {data}. Puxe para atualizar. | List saved on {date}. Pull to refresh. |

---

## 6. Política de privacidade: seção de IA (substitui "AI features")

### pt-BR

**Recursos de IA (opcionais)**

O Coach, o Importar com IA e o Registrar refeições com IA são opcionais e ficam desligados até você configurar um provedor de IA com a sua própria conta. O FitJourney não tem servidor: o que você permitir vai direto do seu iPhone para o provedor escolhido. O desenvolvedor não recebe nem guarda esses dados.

*O que é enviado, e quando.* Nada é enviado antes de o app mostrar o que vai, para quem vai, e você tocar em "Permitir". A permissão é separada para cada recurso e para cada destinatário. Trocar de provedor, de criador do modelo ou de servidor pede permissão de novo.
- Importar com IA: os arquivos, fotos ou textos que você escolher (inteiros, inclusive nomes e anotações que contenham), suas respostas às dúvidas da importação e nomes de exercícios do catálogo do app.
- Registrar refeições com IA: o texto e as fotos que você escolher, a data e a hora do registro e, se você permitir "Dieta", as refeições planejadas do dia.
- Coach: suas mensagens e o histórico da conversa. Se você ligar cada categoria (todas começam desligadas): Perfil (idade, sexo, altura, peso, nível, objetivo, restrições e lesões, equipamentos, preferências alimentares), Treinos (programas, fichas, treinos feitos com séries e cargas), Dieta (planos e registros de até 31 dias) e Saúde (resumos diários do app Saúde de até 31 dias: treinos, minutos, frequência cardíaca média e em repouso, energia ativa e passos).

Fotos são reduzidas e enviadas sem localização nem dados da câmera. Arquivos e fotos não ficam guardados no app depois da análise.

*Como é usado.* Somente para responder ao seu pedido: ler o arquivo e montar um rascunho, estimar a refeição ou responder no Coach. Nada é usado para publicidade, perfil de marketing ou venda de dados. Dados do app Saúde nunca são usados para publicidade nem mineração de dados.

*Quem recebe.* O provedor que você configurar, sempre identificado no app antes do envio, com link para a política dele:
- OpenAI (OpenAI, L.L.C.): openai.com/policies/privacy-policy
- Anthropic (Anthropic PBC): anthropic.com/legal/privacy
- OpenRouter: openrouter.ai/privacy. O OpenRouter repassa o pedido a um serviço que executa o modelo escolhido. O app nomeia o criador do modelo e pede ao OpenRouter só serviços que não guardam nem usam seus dados para treinar.
- OpenCode Go (Anomaly): opencode.ai/legal/privacy-policy. O OpenCode repassa ao serviço que executa o modelo. O app nomeia o criador do modelo e só oferece modelos que não usam seus dados para treinar.
- Um servidor que você mesmo configurar (por exemplo, Ollama no seu computador). Ele é operado por você ou por quem você escolher. O FitJourney não pode verificar como ele trata os dados e avisa isso antes do envio.

*Proteção.* O FitJourney só se integra a provedores cujos termos publicados para uso da API protegem os dados no mínimo como esta política: não vendem os dados e, por padrão, não usam o conteúdo enviado pela API para treinar modelos. Cada provedor trata os dados conforme a política dele e os termos da sua conta, inclusive o prazo de retenção.

*Seu controle.* Em Ajustes › Coach e IA › O que é enviado e para quem, você vê o que está permitido e para quem, desliga cada recurso ou categoria e revoga tudo. Desligar vale para os próximos envios. O que já foi enviado fica com o provedor, conforme a política dele. A chave de API e o login ficam no Keychain do iPhone e não entram em exportações.

### en-US

**AI features (optional)**

The Coach, Import with AI and Log Meals with AI are optional and stay off until you set up an AI provider with your own account. FitJourney has no server: what you allow goes straight from your iPhone to the provider you chose. The developer doesn't receive or store this data.

*What is sent, and when.* Nothing is sent until the app shows you what will be sent and who will receive it, and you tap "Allow". Permission is separate for each feature and each recipient. Switching providers, model creators or servers asks again.
- Import with AI: the files, photos or text you choose (in full, including any names and notes they contain), your answers to the import questions, and exercise names from the app's catalog.
- Log Meals with AI: the text and photos you choose, the date and time of the entry and, if you allow "Diet", that day's planned meals.
- Coach: your messages and the conversation history. Each category below is off until you turn it on: Profile (age, sex, height, weight, level, goal, restrictions and injuries, equipment, food preferences), Workouts (programs, routines, completed workouts with sets and loads), Diet (meal plans and logs for up to 31 days) and Health (daily summaries from Apple Health for up to 31 days: workouts, minutes, average and resting heart rate, active energy and steps).

Photos are resized and sent without location or camera data. Files and photos aren't kept in the app after analysis.

*How it's used.* Only to fulfil your request: to read a file and build a draft, to estimate a meal, or to answer in the Coach. Nothing is used for advertising or marketing profiles, and data is never sold. Apple Health data is never used for advertising or data mining.

*Who receives it.* The provider you set up. The app always names it before sending and links to its privacy policy:
- OpenAI (OpenAI, L.L.C.): openai.com/policies/privacy-policy
- Anthropic (Anthropic PBC): anthropic.com/legal/privacy
- OpenRouter: openrouter.ai/privacy. OpenRouter forwards the request to a service that runs the chosen model. The app names the model's creator and asks OpenRouter to use only services that don't store your data or use it for training.
- OpenCode Go (Anomaly): opencode.ai/legal/privacy-policy. OpenCode forwards the request to the service that runs the model. The app names the model's creator and only offers models that don't train on your data.
- A server you set up yourself (for example, Ollama on your computer). You, or whoever you choose, operate it. FitJourney can't verify how it handles data, and the app tells you so before sending.

*Protection.* FitJourney only integrates with providers whose published API terms protect your data at least as well as this policy: they don't sell it and, by default, don't use content sent through the API to train their models. Each provider handles the data under its own privacy policy and your account terms, including how long it is kept.

*Your control.* In Settings › Coach & AI › What's shared and with whom, you can see what is allowed and for whom, turn off any feature or category, and revoke everything. Turning something off applies to future requests. Data already sent stays with the provider, under its policy. Your API key and sign-in are kept in the iPhone Keychain and aren't included in exports.

> Se o ChatGPT (login) continuar no build da loja, a frase de proteção não vale para ele (conta de consumidor). Ver Q-AC1.

---

## 7. Notas para a App Review (rascunho, en)

> AI features are optional and use the user's own provider account. FitJourney has no server. To review them with the OpenCode Go key below: (1) Today › profile icon › Coach & AI › Provider: OpenCode Go › paste the key › Save Key. (2) Workouts › + › Import with AI › **Try with a sample** › Analyze. Before anything is sent, a screen shows exactly what will be sent, names the recipient (OpenCode, and the company that created the model) with links to their privacy policies, and offers **Allow** / **Don't Allow**. Don't Allow keeps the app fully usable without AI. (3) Diet › What did you eat? › Try with a sample. (4) Coach tab: the same consent, with optional categories, all off by default. Review or revoke permissions anytime in Settings › Coach & AI › What's shared and with whom. Key: <chave>

---

## 8. Identificadores de acessibilidade

| Área | Identificador | Controle |
|---|---|---|
| Ajustes | `settings.open` | avatar em Hoje (abre Ajustes) |
| | `settings.ai` | linha "Coach e IA" |
| | `settings.ai.provider` | Picker de provedor |
| | `settings.ai.key.field` · `settings.ai.key.save` · `settings.ai.key.remove` | chave |
| | `settings.ai.model.<id>` · `settings.ai.model.custom` · `settings.ai.model.refreshing` · `settings.ai.model.missing` · `settings.ai.model.useDefault` · `settings.ai.model.all` | modelo |
| | `settings.ai.privacy` | linha "O que é enviado e para quem" |
| Privacidade | `privacy.recipient` · `privacy.toggle.import` · `privacy.toggle.mealLog` · `privacy.toggle.coach` · `privacy.toggle.profile` · `privacy.toggle.workouts` · `privacy.toggle.nutrition` · `privacy.toggle.health` · `privacy.revokeAll` · `privacy.revokeAll.confirm` · `privacy.other.<chave>` · `privacy.forgetOthers` | tela 3.7 |
| Entradas | `today.import` · `training.empty.import` · `training.add` · `training.add.import` · `programEditor.importRoutines` · `nutrition.empty.import` · `nutrition.menu` · `nutrition.menu.import` | pontos de entrada do §4.15.2 (`ImportWithAIButton`/`ImportWithAIMenuItem` ganham parâmetro `identifier`) |
| Importar | `import.sheet` · `import.cancel` · `import.source.files` · `import.source.photos` · `import.source.camera` · `import.source.paste` · `import.sample` · `import.sample.addMore` · `import.attachment.<n>` · `import.attachment.<n>.remove` · `import.privacyNote` · `import.denied` · `import.setup` · `import.analyze` | folha de arquivos |
| | `import.analysis` · `import.analysis.status` · `import.analysis.cancel` · `import.interview.skip` · `import.interview.reply.<n>` · `import.groups.continue` · `import.review.create` · `import.review.activate` · `import.done` | etapas seguintes |
| Consentimento (`FJConsentView`, já implementado) | `aiConsent.title` · `aiConsent.recipient` · `aiConsent.policyLink.primary` · `aiConsent.policyLink.secondary` · `aiConsent.allow` · `aiConsent.deny` | folha e aba Coach |
| | `aiConsent.sheet` (raiz da folha, no chamador) · `aiConsent.row.<n>` | |
| Registro | `mealLog.field` · `mealLog.sample` · `mealLog.camera` · `mealLog.photos` · `mealLog.analyze` · `mealLog.denied` · `mealLog.review.save` · `mealLog.dietOffer.allow` | |
| Coach | `coach.consent.toggle.profile` · `.workouts` · `.nutrition` · `.health` · `coach.off.review` · `coach.composer.field` · `coach.composer.send` · `coach.settings` | |

---

## 9. Pacotes

Ordem: **P-C1 ∥ P-C2** (núcleo, worktrees próprios) → **P-S1** (depende de C1) ∥ **P-S3** (depende de C2) → **P-S2** (depende de S1 para o teste de UI) → **P-D**. `review-code` antes de cada integração e `qa-accessibility` depois de S1/S2.

### P-C1 · Núcleo de consentimento (`core-engineer`, Opus)

Arquivos:
- **Novos**: `FitJourney/Services/AI/Consent/AIRecipient.swift` (`AIRecipient`, `AIRecipientResolver.resolve(settings:)`, tabela de criadores com artigo pt, URLs de política, `isLocalNetwork`), `AIConsentStore.swift` (v2, migração, `grant/revoke/revokeAll/forgetOthers`, `categories(for:)`, notificação `.aiConsentChanged`), `AIConsentGate.swift` (`require(_:recipient:)`, erro `AIConsentRequired`).
- **Alterados**:
  - `ImportSession.swift:246, 769`: gate `importFiles`; `ImportError.consentRequired(AIRecipient)`.
  - `ImportCoordinator.swift:89-91`.
  - `MealLogSession.swift:192`, e `correct()` (`:237`) com o gate.
  - `MealLogPreferences.swift`: Dieta pela categoria do destino; sem consentimento implícito.
  - `SendMessage.swift`: gate `coach` antes de cada volta.
  - `FitnessToolbox.swift:80-99, 172`: closure `sharing` do destino atual.
  - `CoachProfile.swift`: `sharing` fica só para decodificação/pré-seleção.
  - `CoachLogic.swift:88-96`: `CoachGate` com `needsProvider` antes de `needsConsent`.
  - `ProviderFactory.swift:34-36` + `OpenAICompatibleWire.swift`: quirk do OpenRouter `provider.data_collection = "deny"` e mensagem para "sem host".
  - `BackupSupport.swift`: `coach.aiConsent.v2` apagável e nunca exportado; `consentedAt` informativo.
  - `MealLogSessionFactory.swift` e `StoreDemo`: concessão de demonstração em DEBUG.
- **Conferir antes de integrar**: as URLs de política (abrir cada uma) e o campo `provider` do OpenRouter numa chamada real.

Aceite: nenhum envio sem permissão para o destino atual; trocar de provedor ou de criador bloqueia até permitir; voltar ao destino anterior restaura; a correção do registro respeita a revogação; as ferramentas do Coach seguem as categorias do destino.

Testes (Swift Testing, `AIConsentTests.swift`):
- resolução por provedor: os 6, o criador pelo id em OpenRouter e OpenCode, host local × internet, ChatGPT ≠ OpenAI;
- chave estável;
- modelo do mesmo criador mantém, criador diferente pede;
- migração: v1 ignorado, toggles viram pré-seleção;
- `revoke`, `revokeAll`, `forgetOthers`;
- `ImportSession.analyze/reviseWithAI` lança `consentRequired` com o destino certo, e a permissão de outro destino não conta;
- `MealLogSession.analyze/correct`;
- `CoachConversationService` recusa depois da troca de provedor;
- `FitnessToolbox.specs` por destino;
- corpo do OpenRouter com `data_collection: deny`;
- backup não exporta nem importa o consentimento; "Apagar tudo" limpa.

### P-C2 · Descoberta de modelos (`core-engineer`)

Arquivos:
- **Novos**: `Services/AI/Providers/ModelDiscovery.swift` (OpenAI, Anthropic, OpenRouter e custom: requisição, parse, filtro), `ModelDefaults.swift` (versão numérica, regra do modelo leve), `ModelCache.swift` (por provedor, TTL 24 h, `refresh`).
- **Alterados**:
  - `ProviderCatalog.swift:35, 41, 47`: reservas e ordem.
  - `ChatGPTModelLister.swift`: `models(refresh:)`, regra do luna.
  - `OpenCodeModels.swift`: `discover(refresh:)`, luna.
  - `AttachmentTypes.swift`/`AIAvailability.swift`: capacidades do OpenRouter pelo cache.

Aceite: a lista de cada provedor vem da conta; o padrão é o modelo leve mais novo; falha cai no cache e depois na reserva, nunca vazia; a chave nunca vai para log.

Testes (`AIModelDiscoveryTests.swift`, fixtures JSON de cada endpoint):
- filtros: tipos excluídos e datados da OpenAI; alias do Anthropic; imagem + tools e `:free` no OpenRouter;
- ordem por versão;
- regra do padrão: luna, haiku, empate, sem leve;
- `refresh` ignora o TTL; troca de chave limpa;
- cabeçalhos do Anthropic;
- escolha do usuário preservada; modelo ausente sinalizado.

### P-S1 · Telas de consentimento (`ios-implementation`, Sonnet)

Arquivos:
- **Novos**: `Features/Privacy/AIConsentPresentation.swift` (texto por uso e destino, puro e testável: títulos, linhas, elos, rodapés, artigo), `Features/Privacy/AIConsentSheet.swift` (monta `FJConsentView`), `Features/Settings/AIPrivacyView.swift` (§3.7).
- **Alterados**:
  - `ImportFilesView.swift`: troca `ImportConsentSheet` (`:76-82, :334-…`) pela folha; banner de negado; aviso com cadeia (`:183-…`).
  - `MealLogSheet.swift` (`:77-80`); remove `MealLogConsentSheet.swift`.
  - `MealLogReviewView.swift:429-438`: folha de categoria.
  - `CoachWelcomeView.swift`: provedor primeiro, consentimento inline e cópia de Saúde corrigida.
  - `CoachRootView.swift`, `CoachChatView.swift:190-208`: folha quando o destino mudou; 1ª linha.
  - Rodapé de `ConversationListView`.
  - `AISettingsView.swift:111-112, 360-384`: seção Privacidade.
  - `ImportAnalysisView.swift`: subtítulo.
  - `Localizable.xcstrings`: toda a cópia do §3 em pt + en, inclusive as strings do `FJConsent.swift` ("O que é enviado", "Para quem", "Permitir", "Não permitir").
  - Os identificadores do §8 nessas telas.

Aceite: critérios 28as–28ba do `DESIGN_DIRECTION.md`.

Testes:
- `AIConsentPresentationTests.swift`: os 6 destinos (nome, artigo pt, elos, links, nota de servidor/ChatGPT); linhas por uso; linha de Dieta condicional; contagem de arquivos; linha extra da conversa.
- Lógica de estado (negado mantém os arquivos).
- Previews: empresa, roteador, servidor local, AX3, escuro.

### P-S2 · Demonstração + alvo de teste de UI (`ios-implementation`)

Arquivos:
- `scripts/make-review-samples.sh` + `FitJourney/Resources/Samples/*` (§4.2, gerados pelo pacote a partir da pasta do dono).
- `project.yml`: recursos + alvo **`FitJourneyUITests`** (`bundle.ui-testing`; não existe hoje).
- `ImportFilesView.swift`: `import.sample`, `import.sample.addMore`, tag/legenda.
- `MealLogSheet.swift`: chip de exemplo.
- `ImportEntryPoints.swift`: parâmetro `identifier`.
- DEBUG apenas: `-fj.uiTestReset` (defaults/Keychain limpos) e `-fj.uiTestProviderKey` (lê a variável `FJ_UITEST_OPENCODE_KEY` e grava no Keychain; nunca no Release; teste que garante isso).
- `FitJourneyUITests/ReviewDemoUITests.swift`.
- `Makefile`: `make uitest`.
- `scripts/record-review-demo.sh` (`simctl io recordVideo` + `test-without-building`, simulador próprio, desligado ao fim).

Aceite: com chave, o fluxo vai de Ajustes até a revisão da importação sem toque manual, e o vídeo é gravado. Sem chave, o teste de consentimento roda com um gateway falso (DEBUG `-fj.uiTestFakeAI`).

Testes de UI:
1. `testConsentSheetShowsRecipientAndDenyKeepsFiles`: sample → Analyze → `aiConsent.title` contém "OpenCode", existe `aiConsent.policyLink.primary`; Deny → `import.denied` aparece e `import.attachment.0` continua.
2. `testAllowStartsAnalysis`: Allow → `import.analysis`.
3. `testReviewDemoFlow` (chave real, opcional): Ajustes → provedor → chave → Treinos → Importar → exemplo → Analisar → Permitir → revisão → `import.review.create`.
4. Unitário: os recursos do exemplo existem no bundle e passam no `AttachmentPreparer`.

### P-S3 · Seletor de modelo (`ios-implementation`)

Arquivos: `AISettingsView.swift` (seção de modelo: refresh ao aparecer, `.refreshable`, indicador, subtítulo do padrão, linha "sumiu" + "Usar…", "Ver todos"), novo `Features/Settings/ModelListView.swift` (`.searchable`), cópia do §5, identificadores `settings.ai.model.*`.

Aceite: ao abrir, a lista é buscada de novo; offline mostra o cache sem erro; nenhum nome antigo (`gpt-4.1-mini`, `gpt-5-mini`) aparece na reserva.

Testes: lógica de apresentação (ordem, limite de 8, "Ver todos (n)", linha de ausente).

### P-D · Documentos e loja (supervisor / dono)

- SPEC §7, §7A.1, §7.x e §9 (privacidade por destino e permissão por uso): **o dono edita**.
- `docs/ia.md` (consentimento + descoberta).
- Política (§6) no CV_Website (push autorizado pelo dono).
- Notas da revisão (§7).
- Rótulos de privacidade no App Store Connect (Q-AC5).
- Cartographer.
- `CURRENT_PROJECT_VERSION` +1.

---

## 10. Perguntas ao dono

- **Q-AC1** Esconder o **ChatGPT (login) · experimental** no Release? É login não oficial (risco à parte na revisão) e conta de consumidor, para a qual não dá para afirmar proteção equivalente. **Recomendo esconder no Release** (manter em DEBUG).
- **Q-AC2** Padrão = modelo **leve** em todos (Haiku em vez de Opus no Anthropic, Luna na OpenAI). Confirma?
- **Q-AC3** Os exemplos estão só em inglês. Vale gerar versões em pt-BR para a UI em português?
- **Q-AC4** Foto de prato de exemplo para o registro: o dono fornece uma foto própria (direitos), ou fica só o texto de exemplo?
- **Q-AC5** Rótulos de privacidade da loja: hoje "Dados não coletados". Recomendo declarar, por cautela, Saúde e fitness, Conteúdo do usuário (fotos, arquivos, mensagens) e Outros (perfil) como "usados para funcionalidade do app, não vinculados, sem rastreamento", porque a Apple tratou o envio como compartilhamento. Confirma?
- **Q-AC6** URL própria fora da rede local no Release: manter (com o aviso de que não sabemos quem opera) ou limitar à rede local?
- **Q-AC7** Pedir de novo ao trocar o **criador** do modelo num roteador (proposto). Ou só ao trocar de provedor?

### Respostas do dono (19/11/2026)

- **Q-AC1:** o ChatGPT (login) **continua na App Store**. Ele entra como destino próprio, "OpenAI (sua conta ChatGPT)", com a nota sobre os controles de dados da conta. A política diz que, nesse caso, valem os termos da conta ChatGPT, e a frase de proteção equivalente não se aplica a ele.
- **Q-AC2:** sim, o padrão é o modelo leve (Luna/Haiku).
- **Q-AC3:** os exemplos ficam só em inglês.
- **Q-AC4:** o registro de refeição usa só o texto de exemplo.
- **Q-AC5:** os rótulos de privacidade são configurados pelo dono no painel. A recomendação foi registrada.
- **Q-AC6:** a URL própria continua aceitando endereços na internet, com o aviso.
- **Q-AC7:** o app pede de novo quando muda o criador do modelo.
- A chave do OpenCode Go vai nas notas de revisão. A China continental foi removida da disponibilidade pela API.

### Ajuste do dono (19/11/2026): aceite com cara de termo

- A folha "Antes de enviar" e a tela de consentimento do Coach ganham, logo acima de Permitir / Não permitir, a frase: "Ao tocar em Permitir, você concorda com o envio descrito acima e com a [Política de Privacidade do FitJourney]." / "By tapping Allow, you agree to the sharing described above and to the [FitJourney Privacy Policy]." O link abre `https://renatocorrea.com.br/FitJourney/pt/privacy/#ia` (pt) ou `/en/privacy/#ai` (en), conforme o idioma do app, com id `aiConsent.appPolicyLink`.
- Ajustes › Sobre: o texto de privacidade é corrigido. Hoje ele diz que "só o Coach envia texto", o que está errado, porque importação e registro de refeição também enviam. A tela ganha a linha "Política de privacidade" (id `about.privacyPolicy`), que abre a mesma página.
- A tela "O que é enviado e para quem" ganha o mesmo link no rodapé.
- Não haverá tela de termos no primeiro uso do app. O aceite acontece no momento do envio, com o destinatário nomeado, como a Apple pede.
