# Plano: provedor "OpenCode Go"

Data: 19 de novembro de 2026 · Autor: `ios-design` · Status: **plano, nada de Swift alterado**

**Como li isto:** leitura do código atual (`Services/AI/`, `AISettingsView`, backup) e da implementação de referência do Fireplaice (`OpenCodePreset`, `ProviderFactory`, mapeamento de erros no `HTTPClient`, `docs/04-provider-integration.md`). Os fatos sobre o Go (endpoints, campos da lista, modelos, preços) foram verificados hoje com uma chave real e vieram no pedido. **O que não foi verificado** aparece marcado como tal e tem item de conferência na seção 11.

## 1. Resumo

O OpenCode Go é uma assinatura paga com um endpoint compatível com Chat Completions. Encaixa no gateway que já existe (`OpenAICompatibleChatGateway`), sem gateway novo. O que muda de verdade:

1. Um caso novo em `AIProviderID` e um descritor no catálogo.
2. Configuração de endpoint com dois cabeçalhos obrigatórios (`User-Agent` e `x-opencode-session`) e ajustes de fio.
3. **Capacidade de anexo por modelo**, porque o Go mistura modelos com e sem visão. PDF nunca vai nativo: rasteriza sempre.
4. Descoberta de modelos (opcional, com cache), que filtra modelos gratuitos e **modelos que treinam com os dados**.
5. Mensagens próprias para chave recusada, limite da assinatura, modelo gratuito e assinatura inativa.
6. Ajustes de IA: o provedor entra na lista e o seletor de modelo mostra só modelos que leem imagens (decisão 40 do `DESIGN_DIRECTION.md`).

## 2. Identificador e migração

- `AIProviderID.openCode`, raw value **`"openCode"`**, **acrescentado no fim** do enum: `openAI, anthropic, openRouter, custom, chatGPT, openCode`. O raw value nunca muda (vai para UserDefaults, Keychain, `ChatConversation.providerRaw` e o backup).
- Ordem no fim porque `BackupTests` compara o enum `aiProvider` do schema com `AIProviderID.allCases` **na ordem**.
- Chave no Keychain: `SecretKey.apiKey(.openCode)` = `"apiKey.openCode"` (regra existente, nada novo).
- **Versão antiga lendo dados novos** (TestFlight antigo, downgrade): `ProviderSettings.init(from:)` já cai para `.openAI` quando o provedor é desconhecido e descarta o modelo de chave desconhecida; `providerRaw` da conversa é `String?` livre. Nada quebra.
- **Backup:** o schema de exportação (`contracts/fitjourney-export-v1.schema.json` e a cópia em `BackupSchema.swift`) ganha `"openCode"` no enum `aiProvider`. Efeito colateral aceito: um build antigo recusa um backup novo que tenha `openCode` em `coachProvider`. É raro e não perde dados do aparelho. O provedor continua nunca sendo aplicado na importação (regra existente).
- Identificador de instalação (seção 4) fica em `coach.openCode.installationID`: o prefixo `coach.` já é apagado por "Apagar tudo" (`BackupPreferenceKeys.erasablePrefixes`) e a chave não entra na exportação.

## 3. Descritor (`ProviderCatalog`)

| Campo | Valor |
|---|---|
| `id` | `.openCode` |
| `name` | `"OpenCode Go"` (marca, sem tradução) |
| `defaultBaseURL` | `https://opencode.ai/inference/go/openai/v1` |
| `requiresAPIKey` | `true` |
| `suggestedModels` | `gpt-6-luna`, `claude-haiku-5-5`, `glm-5.3-flash`, `qwen3.8-flash` (o primeiro é o padrão) |
| `keyHelpURL` | `https://opencode.ai/auth` |
| `shortName` | `nil` (o nome já é curto) |
| `isExperimental` | `false` (API paga e documentada pelo OpenCode) |

Posição na lista de provedores: depois do OpenRouter e antes de "Compatível com OpenAI (URL própria)". A ordem do catálogo é independente da ordem do enum.

A URL base **não** é editável (diferente do Fireplaice). O FitJourney só deixa editar URL no provedor `custom`; manter assim evita que a chave do Go vá para outro host.

## 4. Endpoint e particularidades (`ProviderFactory.endpoint`)

```
EndpointConfiguration(
  provider: .openCode, baseURL: <defaultBaseURL>, auth: .bearer(key),
  extraHeaders: ["User-Agent": "FitJourney/<CFBundleShortVersionString>",
                 "x-opencode-session": <sessão estável>],
  timeouts: HTTPClient.Timeouts(chat: 180),
  quirks: ProviderQuirks(tokenParameter: "max_tokens", includeStreamUsage: true,
                         strictTools: false, errorDialect: .openCode))
```

- **Sessão estável:** `OpenCodeGo.sessionID(installationID:)` = FNV-1a 64 bits em hexadecimal, igual ao Fireplaice. A semente é um UUID aleatório gerado uma vez e guardado em `coach.openCode.installationID` (UserDefaults). Não é segredo e não identifica a pessoa: a chave Bearer já identifica a conta. O hash só deixa o valor opaco e com o mesmo formato do Fireplaice.
- **Versão:** reaproveitar `ChatGPTResponsesGateway.appVersion` (lê `CFBundleShortVersionString`). Mover para um lugar neutro é opcional e fica fora deste plano.
- **`max_tokens` forçado:** o Go normaliza para Chat Completions clássico (como o OpenRouter). Hoje nenhum fluxo manda `maxTokens`, então o efeito é só preventivo.
- **`strictTools: false`:** o Go repassa a fornecedores diferentes (OpenAI, Anthropic, Zhipu, DeepSeek…). O app já valida localmente (schema, depois Codable). Mesmo motivo do Anthropic e do `custom`.
- **`includeStreamUsage: true`:** o padrão do Fireplaice funcionou. Não verificado com `stream_options` no stream: se der 400, trocar para `false` (seção 11).
- **Timeout 180 s:** é o tempo ocioso entre bytes. O `mimo-v2.6-flash` levou até 67 s; os sugeridos ficam bem abaixo.
- `structuredOutputFallback` e o rebaixamento de `strict` em 400 continuam como estão.
- `reasoning_effort`: o gateway só manda para gpt-5.x e série o (`ModelCapabilities`). Para `gpt-6-luna` não manda, o que bate com o teste ao vivo. Nada a mudar.
- Gateway: `OpenAICompatibleChatGateway` (entra no mesmo ramo de `.openAI`, `.openRouter`, `.custom`).
- Os dois cabeçalhos extras entram em `sensitiveHeaderNames` (regra atual: todo `extraHeaders`). Não são segredos, mas é inofensivo: só faz o corpo de erro trocar esses valores por `<redacted>`.

**Recusas antes da rede** (no `ProviderFactory`, com `AIError.notConfigured`):

- id terminado em `-free` → "modelos “-free” só funcionam dentro do OpenCode; escolha outro modelo". Puro, pelo sufixo.
- modelo marcado com `go.training: true` no cache de descoberta (seção 6) → "este modelo pode treinar com seus dados; escolha outro em Ajustes de IA". Só em `makeChat(settings:secrets:)`, que lê o cache; `endpoint(settings:apiKey:)` continua puro.

`AIAvailability` não conhece essas recusas e mostra os botões de IA. Na primeira tentativa, o fluxo mostra o erro "Coach não configurado" com "Configurar chave". É aceitável porque só acontece se a pessoa digitar o modelo à mão em "Outro modelo"; o seletor nunca lista esses modelos.

**Redator:** acrescentar `oc_sk_[A-Za-z0-9_-]{8,}` ao `Redactor`, antes dos padrões genéricos. O padrão `sk-` não pega `oc_sk_` (o separador é sublinhado) e o genérico só pega a partir de 32 caracteres. O app não valida o prefixo da chave: o formato pode mudar.

## 5. Capacidade de anexo por modelo

`AttachmentCapabilities.resolve(provider: .openCode, model:)`:

- **PDF: sempre `false`.** A maioria dos modelos recusa PDF em `chat/completions`, mesmo quando a lista diz `application/pdf`. O `PDFRasterizer` já existe: as páginas viram JPEG só para o envio (decisão 32, conversão silenciosa).
- **Imagem**, nesta ordem:
  1. Cache de descoberta: `true` se `modalities.input` tem algum `image/*`.
  2. Tabela estática de modelos verificados com visão: `gpt-6-luna`, `claude-haiku-5-5`, `glm-5.3-flash`, `deepseek-v4.1-flash`, `mimo-v2.6-flash`, `qwen3.8-flash`, mais os prefixos `gpt-` e `claude-`.
  3. Modelos conhecidos como só texto (`glm-5.3`, `deepseek-v4-pro`, `hy3`…) e qualquer modelo desconhecido: `false`.

Desconhecido vira `false` (diferente do `custom`, que assume `true`) porque o Go tem lista própria: o cache é preenchido assim que a chave é salva. Mandar imagem a um modelo só de texto daria um 400 opaco; bloquear dá a mensagem certa.

Com `supportsImages == false`, o que já existe cobre os fluxos: `AttachmentError.imagesNotSupported` na importação, `MealLogError.modelWithoutVision` na foto da refeição, e `visibleWhenAIAvailable(requiringImages:)` esconde câmera e galeria. Nenhuma tela nova.

Assinatura proposta (testável sem UserDefaults global):

```swift
static func resolve(provider: AIProviderID, model: String,
                    openCodeModels: OpenCodeModelCache.Snapshot? = nil) -> AttachmentCapabilities
// nil + .openCode → lê OpenCodeModelCache(defaults: .standard).load()
```

`AIAvailability.evaluate` passa o cache lido do seu próprio `defaults`.

## 6. Descoberta de modelos (opcional, com cache)

`GET https://opencode.ai/inference/go/v1/models` (mesma autenticação e mesmos cabeçalhos; a URL é a base sem o `/openai/v1` final, como em `OpenCodePreset.modelsURL`).

**`OpenCodeModelLister`** (actor), no molde do `ChatGPTModelLister`:

- `discover() async -> OpenCodeDiscovery`, onde `OpenCodeDiscovery = (models: [OpenCodeModel], keyRejected: Bool)`. Nunca lança. Ordem: cache fresco, depois rede, depois cache vencido, depois lista estática.
- 401 → `keyRejected = true` (não vai para o cache) e devolve o cache ou a lista estática. Assim os Ajustes avisam que a chave foi recusada logo depois de salvar, já que não existe "Testar conexão".
- `HTTPClient` sem repetição (`.none`), timeout de 15 s, `Accept: application/json`.

**`OpenCodeModel`** (Codable, sem segredo): `id`, `name`, `readsImages`, `structuredOutput`, `inputPrice`, `outputPrice` (US$ por 1M de tokens, opcionais), `trainsOnData`, `zeroDataRetention`.

**`OpenCodeModelCatalog.parse(_ data:)`**, puro:

- mantém só `type == "chat"` (campo ausente conta como chat);
- descarta ids terminados em `-free` e ids repetidos;
- `readsImages` = algum `modalities.input` começa com `image/`;
- `trainsOnData` = `go.training == true`, e esses **ficam no cache** (marcados) para a fábrica poder recusar quem digitar o id;
- ignora entradas sem `id` e campos desconhecidos (`go.monthly_usage` não é usado).

**`OpenCodeModelCache`** (UserDefaults `coach.openCodeModels.v1`): `{fetchedAt, models}`. TTL de 24 h para buscar de novo; vencido continua valendo como capacidade. A lista é a mesma para qualquer conta Go, então o cache não depende da chave. Quando o conteúdo muda, `AIAvailability.postChange()` faz a disponibilidade de fotos se reavaliar.

**`OpenCodeModelCatalog.pickerModels(discovered:suggested:limit: 8)`**, puro:

1. Sugeridos, na ordem do catálogo, que estejam na descoberta, leiam imagens e não treinem com os dados. Sem descoberta, os sugeridos estáticos.
2. Depois os demais que leem imagens e não treinam, **por custo**: `inputPrice` crescente, depois `outputPrice`, depois `id`. Preço ausente vai para o fim. A entrada pesa mais porque importar é quase tudo imagem.
3. No máximo 8 linhas.

**Na interface:** modelos só de texto **não aparecem** no seletor, e **não há selo** "Lê imagens" por linha (seria igual em todas). Quem quiser um modelo só de texto para conversar digita o id em "Outro modelo" e vê o aviso da seção 8. Modelos que treinam com os dados nunca aparecem. Preço não aparece; a ordem é explicada no rodapé.

**Modelo padrão que sumiu da lista:** mesma regra do ChatGPT. Se a pessoa nunca escolheu (`settings.models[.openCode] == nil`) e o padrão não está entre os listados, vale o primeiro do seletor.

## 7. Erros

Um "dialeto" de erro no `HTTPClient`, ativado pela particularidade do endpoint (`ProviderQuirks.errorDialect`, aplicado no `init` do `OpenAICompatibleChatGateway` e no lister). Ele é avaliado em `validate` **antes** do mapeamento genérico, para os caminhos `data` e `bytes`. As credenciais já são removidas do corpo antes, como hoje.

| Status | Condição | Vira | Mensagem (pt-BR · en) |
|---|---|---|---|
| 401 | qualquer | `.unauthorized` (já existe) | "A chave do provedor foi recusada. Confira a chave em Ajustes." (já traduzida) |
| 403 | corpo cita `free tier` / `within OpenCode` | `.notConfigured(reason:)` | "modelos “-free” só funcionam dentro do OpenCode; escolha outro modelo" · "“-free” models only work inside OpenCode; pick another model" |
| 403 | outro | `.unauthorized` (como hoje) | idem 401 |
| 402 | qualquer | `.notConfigured(reason:)` | "a assinatura do OpenCode Go não está ativa; confira em opencode.ai" · "your OpenCode Go subscription isn't active; check opencode.ai" |
| 429 | `Retry-After` ≤ 20 s | `.rateLimited` (já existe, repete sozinho) | a atual |
| 429 | sem `Retry-After` ou > 20 s | **`.usageLimitReached(retryAfter:)`** (caso novo) | ver abaixo |

**`AIError.usageLimitReached(retryAfter: TimeInterval?)`** é novo e genérico (serve depois ao ChatGPT por login). Não repete: fica fora do `RetryPolicy`, e `isRetryable` é `false`.

- Com espera: "Limite de uso da sua assinatura atingido. Tente de novo em cerca de \(duração) ou troque de provedor em Ajustes de IA." · "You've reached your subscription's usage limit. Try again in about \(duration) or switch providers in AI Settings." A duração usa uma unidade abreviada ("40 min", "3 h"), com `Duration.UnitsFormatStyle`.
- Sem espera: "… Tente de novo mais tarde ou troque de provedor em Ajustes de IA." · "… Try again later or switch providers in AI Settings."
- `CoachErrorPresentation`: título "Limite da assinatura atingido" · "Subscription limit reached", ação `.none`.

Os 403 e 402 viram `notConfigured` de propósito: no Coach isso dá o título "Coach não configurado" e o botão que abre os Ajustes, que é a saída certa (trocar modelo ou conferir a assinatura). Um `badRequest` ofereceria "Tentar de novo", que não resolve.

**Não verificado:** o texto exato dos corpos 429, 402 e 403 do Go (o do 403 gratuito vem do Fireplaice). Os testes usam esses corpos; o primeiro erro real registrado na verificação manual atualiza os casos.

## 8. Ajustes › Coach e IA (`AISettingsView`)

Mudanças mínimas, dentro das seções que já existem. Nenhum componente novo, nenhum vidro (é um `Form`).

1. **Provedor:** "OpenCode Go" aparece no `Picker` (vem do catálogo). Rodapé quando escolhido:
   - pt: "Use a chave da sua assinatura OpenCode Go. As requisições vão direto do aparelho ao OpenCode, que as repassa a quem hospeda o modelo escolhido. Conta no limite de uso do seu plano."
   - en: "Use your OpenCode Go subscription key. Requests go straight from this device to OpenCode, which forwards them to whoever hosts the chosen model. Counts toward your plan's usage limit."
2. **Modelo:** as linhas vêm de `pickerModels` (descoberta) ou dos sugeridos. "Outro modelo" continua. Rodapé da seção (só no Go):
   - pt: "Só modelos que leem imagens e não usam seus dados para treinar, do que menos gasta o limite do Go ao que mais gasta."
   - en: "Only models that read images and don't train on your data, from the one that uses the least of your Go limit to the most."

   Linhas de aviso dentro da seção, com `Label`, `FJFont.caption` e `FJTone.attention` (texto e símbolo, nunca só cor). No máximo uma aparece, nesta prioridade:
   - termina em `-free` (`exclamationmark.triangle.fill`): "Modelos “-free” só funcionam dentro do OpenCode. Escolha outro." · "“-free” models only work inside OpenCode. Pick another." (`settings.opencode.free`)
   - treina com os dados (`hand.raised.fill`): "Este modelo pode usar o que você envia para treinar a IA. O FitJourney não o usa com seus dados de saúde: escolha outro." · "This model may use what you send to train AI. FitJourney won't use it with your health data: pick another." (`settings.opencode.training`)
   - não lê imagens (`eye.slash`): "Este modelo não lê imagens: importar PDF ou foto e a foto da refeição ficam indisponíveis." · "This model can't read images: importing PDFs or photos and meal photos are unavailable." (`settings.opencode.textOnly`)
3. **Chave de API:** a mesma seção de hoje. "Onde criar a chave" abre `https://opencode.ai/auth`. Se a descoberta voltou com `keyRejected`, aparece uma linha de atenção abaixo do campo: "O OpenCode recusou esta chave. Confira se é a chave do Go em opencode.ai/auth." · "OpenCode rejected this key. Make sure it's your Go key from opencode.ai/auth." (`settings.opencode.keyRejected`)
4. **Descoberta:** `.task(id:)` com `provider == .openCode && hasKey` mais um contador que sobe ao salvar outra chave, porque trocar a chave com `hasKey` já verdadeiro não muda o id. Sem spinner: a lista se atualiza quando chega, como no ChatGPT.
5. Prontidão, compartilhamento e consentimento: sem mudança. "Salve a chave do OpenCode Go para começar." já sai do texto atual. O resumo em Ajustes fica "OpenCode Go · gpt-6-luna".

A lógica do que mostrar (linhas e qual aviso) fica em `AISettingsText`/`OpenCodeModelCatalog`, pura e testável. A view só desenha.

**Acessibilidade:** linhas de modelo com `isSelected` (como hoje); avisos como texto lido pelo VoiceOver; nada depende de cor; o `Form` já cresce até AX5.

## 9. Privacidade

- Caminho: aparelho → OpenCode (`opencode.ai`) → quem hospeda o modelo. Sem servidor do FitJourney. A chave fica só no Keychain (regra existente).
- Política por modelo: o seletor e a fábrica excluem `go.training: true`. Exemplo: `muse-spark-1.3-contributor` funciona e é barato, mas fica de fora. `go.zdr` é guardado no cache e não aparece na interface nesta versão.
- O aviso de importação já usa o nome do provedor: "Os arquivos inteiros vão para **OpenCode Go**…". Nada a mudar.
- `x-opencode-session` não carrega dado pessoal; o UUID de origem nunca sai do aparelho.

## 10. Documentação

- `docs/ia.md`: seção "OpenCode Go" com endpoint, cabeçalhos, particularidades, capacidade por modelo (PDF sempre rasterizado), descoberta e filtros, mapeamento de erros e a lista de modelos verificados. O catálogo da tabela "Portar do fireplaice" passa a citar `openCode`.
- `SPEC.md` §7, a lista de provedores, já está defasada (cita Gemini e não cita ChatGPT por login). **Não editável pelos agentes de implementação:** fica para o supervisor ou o usuário trocar por "OpenAI (padrão), Anthropic, OpenRouter, OpenCode Go (assinatura), compatível com OpenAI (URL própria) e ChatGPT por login (experimental)".
- `docs/CODEBASE_MAP.md`: o Cartographer refaz depois da integração (regra do `AGENTS.md`).
- `DESIGN_DIRECTION.md`: decisão 40 (já registrada).

## 11. Verificação manual com chave real (iPhone, depois do pacote 3)

> **Atualização 19/11 (teste ao vivo com stream + `tool_choice` de função + imagem):** `gpt-6-luna` 5 s, `claude-haiku-5-5` 2 s, `glm-5.3-flash` 7 s, `qwen3.8-flash` 10 s, `mimo-v2.6-flash` 27 s e `deepseek-v4.1-flash` 82 s — todos chamaram a ferramenta com os 12 exercícios, `finish_reason=tool_calls` e `usage` no stream (`stream_options.include_usage` aceito). `deepseek-v4.1-flash` saiu dos sugeridos (lento) e entrou `qwen3.8-flash`. Falta só conferir o Coach (várias voltas de ferramenta) no aparelho.

Os testes ao vivo cobriram `response_format: json_schema` sem stream. **O app usa outra coisa:** importação e registro de refeição forçam uma ferramenta (`tool_choice` de função) com stream, e o Coach usa `tool_calls` em stream. Conferir com cada sugerido (`gpt-6-luna`, `claude-haiku-5-5`, `glm-5.3-flash`, `deepseek-v4.1-flash`):

1. Coach: conversa com uma ferramenta de leitura (`list_programs`); os `tool_calls` chegam montados e a resposta termina.
2. Importar uma ficha em foto e um PDF de várias páginas (a rasterização aparece como etapa comum).
3. Foto de refeição pelo registro com IA.
4. `stream_options.include_usage` aceito (sem 400). Se recusar, `includeStreamUsage: false`.
5. Chave errada → aviso em Ajustes e "Chave recusada" no Coach.
6. `xyz-free` digitado → aviso em Ajustes e recusa antes da rede.
7. Modelo só de texto digitado (`glm-5.3`) → aviso em Ajustes, câmera da refeição some, importar PDF dá "não aceita imagens".
8. Anotar o corpo do primeiro 429 real e ajustar o teste do dialeto.

Um sugerido que falhe em 1 a 3 sai de `suggestedModels`. Fallback de ferramenta para `response_format` fica fora deste plano.

## 12. Pacotes

Sequenciais (cada um depende do anterior). Cada um cabe numa execução de agente OpenCode. Todos terminam com `make build` e `make test` verdes, em simulador próprio (`FJ-opencode-pN`), desligado no fim.

### P1 · [Luna] Provedor básico (sem descoberta)

**Arquivos**
- `FitJourney/Services/AI/Core/ChatTypes.swift`: `case openCode` no fim de `AIProviderID`.
- `FitJourney/Services/AI/Providers/OpenCodeGo.swift` (novo): `enum OpenCodeGo` com `baseURL`, `modelsURL`, `suggestedModels`, `staticVisionModels`/prefixos, `textOnlyModels`, `isFreeModel(_:)`, `sessionID(installationID:)` (FNV-1a), `installationID(defaults:)` (UUID uma vez em `coach.openCode.installationID`).
- `FitJourney/Services/AI/Providers/ProviderCatalog.swift`: descritor (seção 3), depois do OpenRouter.
- `FitJourney/Services/AI/Providers/ProviderFactory.swift`: ramo `.openCode` em `endpoint` (seção 4, ainda sem `errorDialect`), ramo do gateway, recusa de `-free`. `endpoint(settings:apiKey:sessionID:)`, com o padrão lendo `UserDefaults.standard`.
- `FitJourney/Services/AI/Attachments/AttachmentTypes.swift`: caso `.openCode` estático (imagem pela tabela, PDF `false`).
- `FitJourney/Services/AI/Core/AIError.swift`: padrão `oc_sk_` no `Redactor`.
- `contracts/fitjourney-export-v1.schema.json` e `FitJourney/Services/Backup/BackupSchema.swift`: `"openCode"` no fim do enum `aiProvider`.

**Aceite**
- O pedido a `chat/completions` sai com Bearer, `User-Agent: FitJourney/…`, `x-opencode-session` estável (o mesmo em duas montagens com os mesmos defaults), `max_tokens` e ferramentas sem `strict`.
- Configurações com `openCode` sobrevivem a ida e volta; JSON com provedor desconhecido continua caindo em `.openAI`.
- O teste de identidade do schema de backup passa.

**Testes** (`FitJourneyTests/AIProviderTests.swift`, `CopilotAttachmentTests.swift`)
- descritor: URL, chave obrigatória, padrão `gpt-6-luna`, link de ajuda;
- `sessionID` determinístico (valor fixo para uma semente conhecida) e com formato hexadecimal;
- `makeRequest` com `StubURLProtocol`: cabeçalhos, `max_tokens`, `strict` ausente, `stream_options` presente;
- fábrica: `OpenAICompatibleChatGateway`, `notConfigured` sem chave e com `foo-free`;
- capacidades: `gpt-6-luna` imagem sim e PDF não; `glm-5.3` e `modelo-desconhecido` imagem não;
- `Redactor` apaga `oc_sk_abc123def456`.

### P2 · [Terra] Descoberta, capacidades dinâmicas e erros

**Arquivos**
- `FitJourney/Services/AI/Providers/OpenCodeModels.swift` (novo): `OpenCodeModel`, `OpenCodeModelCache` (`coach.openCodeModels.v1`, TTL 24 h, `postChange` quando muda), `OpenCodeModelCatalog.parse` / `pickerModels` / `capabilities(model:cache:)` / `trainsOnData(model:cache:)`, actor `OpenCodeModelLister` com `discover() -> OpenCodeDiscovery`.
- `FitJourney/Services/AI/HTTP/HTTPClient.swift`: `enum ErrorDialect { case standard, openCode }`, `withErrorDialect(_:)`, mapeamento da seção 7 dentro de `validate`.
- `FitJourney/Services/AI/Providers/EndpointConfiguration.swift`: `ProviderQuirks.errorDialect`.
- `FitJourney/Services/AI/Providers/OpenAICompatibleChatGateway.swift`: aplica o dialeto no `init`.
- `FitJourney/Services/AI/Providers/ProviderFactory.swift`: `errorDialect: .openCode`; recusa de modelo que treina com os dados em `makeChat(settings:secrets:)`.
- `FitJourney/Services/AI/Core/AIError.swift`: `usageLimitReached(retryAfter:)` e as descrições.
- `FitJourney/Features/Coach/CoachLogic.swift`: caso em `CoachErrorPresentation`. Procurar com grep outros `switch` exaustivos sobre `AIError`, inclusive nos testes.
- `FitJourney/Services/AI/Attachments/AttachmentTypes.swift`: `resolve(…, openCodeModels:)` com cache, depois tabela estática.
- `FitJourney/Services/AI/Availability/AIAvailability.swift`: passa o cache do próprio `defaults`.
- `FitJourney/Localizable.xcstrings`: en das strings novas deste pacote (seção 7).

**Aceite**
- `parse` de uma resposta real de exemplo (fixture com os campos da seção 6): descarta `-free` e não-chat, marca visão e `trainsOnData`.
- `pickerModels`: sugeridos primeiro e depois por custo; nunca só texto, nunca treino; no máximo 8; sem descoberta, os sugeridos.
- Lister: cache fresco evita rede; falha devolve cache vencido e depois a lista estática; 401 dá `keyRejected` sem gravar.
- Erros: 401 → `unauthorized`; 403 com corpo de "free tier" → `notConfigured`; 403 outro → `unauthorized`; 402 → `notConfigured`; 429 com `Retry-After: 5` → `rateLimited`; 429 sem cabeçalho ou com 3600 → `usageLimitReached`, sem repetição. O dialeto `.standard` não muda nada (os testes atuais de `AIHTTPTests` passam).
- Capacidades: o cache manda (modelo do cache sem `image/*` → imagem não, mesmo com prefixo `gpt-`); sem cache, vale a tabela.

**Testes**: `FitJourneyTests/AIOpenCodeTests.swift` (novo), com `StubURLProtocol` e UserDefaults de suíte própria; `CoachUITests.swift` para o título e a ação do caso novo.

### P3 · [Luna] Ajustes de IA, textos e documentação

**Arquivos**
- `FitJourney/Features/Settings/AISettingsView.swift`: rodapés, linhas do seletor por `pickerModels`, avisos, `keyRejected`, `.task(id:)` com contador de chave, regra do padrão que sumiu (seção 8).
- `AISettingsText` (no mesmo arquivo): `openCodeModelWarning(model:cache:) -> Warning?` (`free`/`training`/`textOnly`) e textos.
- `FitJourney/Localizable.xcstrings`: pt-BR e en da seção 8.
- `docs/ia.md`: seção 10.

**Aceite**
- Escolher OpenCode Go mostra o rodapé, a lista e o link certos; salvar a chave dispara a descoberta e a lista se atualiza; com a chave recusada aparece o aviso.
- Avisos na prioridade certa, com identificadores de acessibilidade; nenhum aviso para os sugeridos.
- Todas as strings novas com en `translated`; prévia em claro, escuro e AX5 sem corte.
- `docs/ia.md` atualizado. `SPEC.md`, `DESIGN_DIRECTION.md` e `work/STATUS.md` intocados (o supervisor aplica a linha do SPEC).

**Testes** (`FitJourneyTests/CoachUITests.swift` ou `SettingsTests.swift`): `openCodeModelWarning` para `-free`, treino, só texto, sugerido (nenhum); linhas do seletor com e sem cache; regra do modelo padrão quando ele some da descoberta.
