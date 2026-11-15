# Revisão: "Adicionar fichas com IA" está lento

Data: 15 de novembro de 2026 · Autor: `ios-design` · Status: **análise de código, nada alterado**

**Como li isto:** revisão estática do código. Não fiz chamadas a provedores nem medi tempo em aparelho. Os tamanhos de schema e de saída foram calculados; as durações são estimativas e estão marcadas como tal. O primeiro item da lista é medir.

## 1. Conclusão

O tempo está na **saída do modelo**, não no prompt. O contrato de extração faz a IA escrever um objeto de 13 campos para **cada série**, e esse JSON inteiro é gerado de novo no reparo e a cada "Revisar com IA". Enquanto isso a tela não mostra nada novo, promete "menos de 1 minuto" e não sobrevive a sair do app.

## 2. Onde está o tempo

| Tema | O que o código faz | Onde |
|---|---|---|
| **Chamadas** | 1 de extração com todos os arquivos. Se a validação falha, 1 de reparo que reenvia o JSON e pede **o objeto completo** de novo. Cada lote de respostas a dúvidas da IA é mais 1 chamada, também com JSON completo na ida e na volta. Tudo sequencial. | `ImportSession.extract`, `ImportSession.reviseWithAI`, `CopilotPrompt.repairMessage`, `reviseMessage` |
| **Schema (entrada)** | Pequeno: `program-import-v1` tem 7,9 mil caracteres minificado (cerca de 2 mil tokens), 57 propriedades. Não é o gargalo. | `ImportSchemas.programImportV1` |
| **Saída** | Cada série é um objeto de cerca de 308 caracteres, com `source`, `confidence`, `notes` e 8 campos quase sempre nulos. Um programa de 4 fichas × 7 exercícios × 4 séries dá cerca de 41,7 mil caracteres (estimo 12 a 15 mil tokens); as séries são 83% disso. O mesmo conteúdo em forma compacta ("4 × 8–12, 32 kg, 60 s") cabe em cerca de 4,2 mil caracteres. | `$defs.set` do contrato; regra "3x12 vira 3 séries" em `CopilotPrompt.importSystem` |
| **Corte silencioso** | Reparo e revisão enviam `json.prefix(60_000)`. Um programa de 5 fichas × 8 × 4 já tem cerca de 59 mil caracteres: acima disso o modelo recebe JSON truncado. Risco de correção, não só de tempo. | `CopilotPrompt.repairMessage`, `reviseMessage` |
| **Modelo e esforço** | Usa o modelo do Coach. Padrões: `gpt-5-mini` (OpenAI), `claude-opus-5-5` (Anthropic, o primeiro sugerido), `gpt-6-luna` (ChatGPT). `ChatRequest` não tem campo de esforço: Anthropic fixa `effort: medium` com pensamento adaptativo; OpenAI e ChatGPT ficam no padrão do provedor. A extração é transcrição e não precisa disso. | `ProviderCatalog`, `AnthropicMessagesGateway.effort`, `OpenAICompatibleChatGateway.makeRequest`, `ChatGPTResponsesGateway.body` |
| **Streaming** | A chamada usa stream, mas só para não estourar o timeout: `ChatStreamCollector.collect` junta tudo. Os gateways acumulam os argumentos da ferramenta e só emitem `.toolCall` no fim. A UI não tem como mostrar progresso. | `ChatStreamCollector`, `ToolCallAccumulator`, `StreamState` da Anthropic |
| **Imagens e PDF** | Fotos em até 2.048 px, JPEG 0,82. PDF nativo quando o provedor aceita; senão até 20 páginas a 1.600 px. Base64 e rasterização acontecem **depois** do toque em "Analisar". Teto de 22 MB preparados (cerca de 29 MB em base64). | `AttachmentPreparer`, `PDFRasterizer`, `AttachmentEncoder.encode` chamado em `ImportSession.analyze` |
| **Timeout e retentativa** | Timeout ocioso de 120 s (300 s no endereço próprio). Até 2 retentativas em 429, 503 e 529 antes do stream, cada uma reenviando o corpo inteiro. Stream caído vira falha; "Tentar de novo" recomeça do zero. | `HTTPClient.Timeouts`, `RetryPolicy`, `ImportFailureView.retry` |
| **Segundo plano** | O texto diz "Pode fechar: eu aviso quando terminar", mas não há `beginBackgroundTask` nem notificação no fluxo. Fechar a folha mantém a sessão viva só com o app aberto; sair do app deve derrubar o stream (inferência, não testei em aparelho). | `ImportAnalysisPresentation.make`, `ImportCoordinator` |
| **Espera do usuário** | Uma pergunta por exercício sem casamento, uma por vez; o casamento é por nome normalizado exato. Não há agrupamento nem o teto de 12 do §4.15.5. Depois de responder, o usuário ainda toca em "Revisar com IA" e volta para a tela de análise. | `ProgramInterview.gaps`, `matchEntry`, `ImportInterviewView.doneBlock` |
| **Progresso** | Etapas fixas; "Lendo exercícios e séries" fica ativa do início ao fim. Subtítulo "menos de 1 minuto" e, aos 60 s, "Está demorando mais que o normal". | `ImportAnalysisPresentation.make`, `ImportAnalysisView` |

## 3. Otimizações técnicas (por ganho e esforço)

| # | O que muda | Onde | Ganho esperado | Esforço |
|---|---|---|---|---|
| T0 | **Medir.** Registrar por chamada: tempo até o primeiro evento, tempo total, tokens de entrada e saída (o `TokenUsage` já chega). Sem conteúdo. | `ImportSession.extract` | Confirma ou corrige esta análise | Baixo |
| T1 | **Saída compacta.** Trocar séries expandidas por grupos (`count` + alvo + carga + descanso); `source`, `confidence` e `notes` só no exercício e só quando diferem; o app expande para o `ProgramImport` atual. | Contrato `program-import-v2`, `ImportSchemas`, `ImportModels`, `CopilotPrompt.importSystem` | Estimo 5 a 8 vezes menos tokens de saída nas séries; a geração cai de minutos para dezenas de segundos, se a medição confirmar que a saída domina | Médio |
| T2 | **Revisão por remendo.** `reviseWithAI` pede só as alterações (caminho + valor) ou só os exercícios afetados; o app aplica. O mesmo para o reparo, depois de consertar localmente o que for trivial. | `ImportSession.reviseWithAI`, `extract`, `CopilotPrompt.reviseMessage`, `repairMessage` | Segunda e terceira chamadas passam de "tudo de novo" para segundos; elimina o corte em 60 mil | Médio |
| T3 | **Esforço baixo e modelo rápido para importar.** Campo `reasoningEffort` em `ChatRequest`, mapeado nos três gateways; a importação pede baixo. Opção "modelo para importação" com um padrão rápido por provedor. | `ChatTypes.ChatRequest`, os três gateways, `ProviderSettings`, `AISettingsView` | Menos espera antes do primeiro token; no padrão da Anthropic, sair do Opus tende a ser o maior ganho isolado | Baixo a médio |
| T4 | **Parciais do stream.** Evento `.toolCallDelta` nos gateways e um leitor tolerante de JSON incompleto que conta fichas e exercícios. | `ChatEvent`, gateways, `ChatStreamCollector`, `ImportSession` | Não reduz o tempo; habilita U1 e U3 | Médio |
| T5 | **Preparar antes.** Base64 e rasterização ao adicionar o arquivo; fotos em 1.568 px e qualidade 0,7 (conferir o limite de cada provedor); enviar o texto embutido do PDF quando existir. | `ImportSession.add`, `AttachmentPreparer`, `AttachmentEncoder` | Segundos no envio, mais em rede móvel | Baixo a médio |
| T6 | **Timeout e segundo plano.** `beginBackgroundTask` na análise; notificação local ao terminar; timeout maior para a importação; uma retentativa automática em stream caído. | `ImportSession.analyze`, `ImportCoordinator`, `HTTPClient.Timeouts` | Menos falhas que obrigam a recomeçar | Médio |
| T7 | **Paralelo por arquivo.** Uma chamada por arquivo e junção no aparelho. | `ImportSession.analyze` | Tempo do arquivo mais lento, não a soma. Só vale depois de T1 | Alto |

## 4. Otimizações de UX (percepção de espera)

| # | O que muda | Onde | Ganho |
|---|---|---|---|
| U1 | **Progresso verdadeiro.** Tirar "menos de 1 minuto"; mostrar tempo decorrido e os achados reais ("Ficha B · Ombro · 6 exercícios") vindos de T4. | `ImportAnalysisPresentation.make`, `FJAnalysisProgress` | A espera passa a ter conteúdo |
| U2 | **Cumprir o "eu aviso".** Enquanto T6 não existir, trocar o texto por "Mantenha o FitJourney aberto". | `ImportAnalysisPresentation.make` | Remove a promessa falsa. Custo mínimo |
| U3 | **Resultado parcial.** Abrir "Fichas encontradas" assim que a primeira ficha fechar no stream; o usuário renomeia e escolhe enquanto o resto chega. | `ImportFlowView`, `ImportGroupsView` | Parte da espera vira trabalho útil |
| U4 | **Perguntas em lote.** Exercícios sem casamento numa lista só, com "Criar todos como novos"; teto de 12; casamento aproximado antes de perguntar. | `ProgramInterview.gaps`, `ImportInterviewView` | De 8 a 14 telas para 1 |
| U5 | **Revisar sem voltar à análise.** Com T2, aplicar as respostas no lugar; sem T2, disparar a revisão ao responder a última dúvida. | `ImportInterviewView.doneBlock`, `finish` | Tira um toque e uma tela de espera |
| U6 | **Dúvidas opcionais na revisão.** Baixa confiança vira selo "Conferir" na revisão final, não pergunta. | `ProgramInterview.gaps` | Entrevista só com o obrigatório |

## 5. Ordem sugerida

1. T0, U2 e T3: baixo esforço; T0 valida o resto.
2. T1 e T2: o ganho principal, se T0 confirmar que a saída domina.
3. T4, U1 e U3; depois U4 a U6.
4. T5 e T6. T7 só se ainda for preciso.

Mudar o contrato (T1) pede a regra de sempre: versão nova em `contracts/`, cópia em `ImportSchemas` e teste de identidade.
