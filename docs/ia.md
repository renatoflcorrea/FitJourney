# Coach de IA — arquitetura (fase 2)

Base: desenho de provedores do fireplaice (`/Users/renato/Code/fireplaice/Packages/FireplaceKit/Sources/`). Portar adaptando, sem copiar o que não serve (Portkey, ChatGPT OAuth não oficial, transcrição/voz).

## Camadas

```
Features/Coach (UI: lista de conversas, chat com streaming, cartões de proposta)
   │
Services/AI
   ├─ Core/        ChatGateway, StructuredCompleting, ChatRequest/ChatEvent, ResponseFormat,
   │               Conversation/Message (estado streaming/complete/stopped/failed), ToolSpec, ToolCall
   ├─ Providers/   OpenAICompatibleChatGateway (OpenAI, OpenRouter, Ollama, Groq),
   │               AnthropicMessagesGateway, GeminiGateway (opcional), EndpointConfiguration, Quirks
   ├─ HTTP/        HTTPClient (sem logar headers sensíveis), SSEParser, StructuredDecoder
   ├─ Tools/       FitnessToolbox: executa as ferramentas do SPEC §7 sobre o repositório local
   ├─ Drafts/      ProgramDraft, NutritionPlanDraft (Codable + JSON Schema estrito) → contracts/
   └─ Secrets/     SecretStore + KeychainSecretStore (service br.com.renatocorrea.fitjourney)
```

## Portar do fireplaice

| Origem (`FireplaceKit/Sources/…`) | Destino | Ajuste |
|---|---|---|
| `FireplaceCore/Protocols/Gateways.swift` | `Services/AI/Core/` | **Adicionar** `tools`, `toolChoice` em `ChatRequest`; evento `.toolCall(id,name,argumentsJSON)`; papel `tool` |
| `FireplaceCore/Model/Conversation.swift` | `Persistence` (SwiftData `ChatConversation`/`ChatMessage`) | Mesmo `MessageState`; reparo de `.streaming` → `.stopped` no launch |
| `FireplaceProviders/HTTP/SSEParser.swift`, `HTTPClient.swift`, `StructuredDecoder.swift` | `Services/AI/HTTP/` | Direto |
| `FireplaceProviders/OpenAICompatible/*` | `Services/AI/Providers/` | Acrescentar `tools`/`tool_calls` (streaming de argumentos por índice) |
| `FireplaceProviders/ProviderFactory.swift`, `GatewayRouter.swift`, `ProviderCatalog.swift`, `ProviderSettings.swift` | `Services/AI/Providers/` | Catálogo: openAI (padrão), anthropic, openRouter, openAICompatible(custom URL) |
| `FireplaceCore/UseCases/SendMessage.swift` (+ `ContextWindow`) | `Services/AI/Core/SendMessage.swift` | Laço de ferramentas: modelo → tool_calls → executar local → devolver → continuar (máx. 6 voltas) |
| `Apps/Fireplace/Platform/KeychainSecretStore.swift` | `Services/AI/Secrets/` | Só iOS (sem fallback macOS) |

Novos (não existem no fireplaice): **function calling** e **gateway Anthropic nativo** (Messages API, SSE `content_block_delta`, `tool_use`).

## Fluxo de proposta

1. Usuário pede um treino. Sistema: perfil + regras (sem diagnóstico; rascunho para revisão).
2. Modelo chama `get_workout_history`, `list_programs`… (executadas localmente, resultado JSON compacto, limites de período).
3. Modelo chama a ferramenta `propose_program(ProgramDraft)` (ou responde com `response_format: json_schema`). O argumento é validado contra o schema; inválido → uma tentativa de reparo.
4. UI mostra cartão → "Revisar e salvar" abre o editor com o rascunho (`origin = .ai`). Nada salvo sem confirmação.

## Contratos

`contracts/program-draft-v1.schema.json`, `contracts/nutrition-plan-draft-v1.schema.json`, `contracts/fitjourney-export-v1.schema.json`. Os mesmos servirão ao plugin do ChatGPT (servidor MCP/Apps SDK) e ao HealthProject.

## Provedor experimental "ChatGPT (login)" (P5.5)

Exceção à regra acima, a pedido do usuário: `Services/AI/ChatGPT/` porta o login da assinatura ChatGPT do fireplaice (pesquisa e riscos em `fireplaice/work/CHATGPT_OAUTH.md`). Rotulado **"ChatGPT (login) · Experimental / não oficial"**, só para uso pessoal.

- OAuth PKCE em `auth.openai.com` com o client_id público do Codex CLI, redirect `http://localhost:1455/auth/callback` recebido por `ChatGPTLoopbackListener` (uso único, só loopback) enquanto a página abre numa `ASWebAuthenticationSession`; porta ocupada → colar a URL. `state` verificado (`ChatGPTLoginValidation`).
- Tokens num único blob no Keychain (`SecretKey.chatGPTAuth`); o `id_token` (com e-mail) não é guardado. Renovação com folga de 2 min, serializada no processo (`ChatGPTRefreshCoordinator`); recusa permanente apaga o blob e vira `AIError.signInRequired`.
- `ChatGPTResponsesGateway`: `chatgpt.com/backend-api/codex/responses` (SSE, `store:false`, `stream:true`, `instructions`), ferramentas no formato da Responses API (`function_call`/`function_call_output` por `call_id`), resumos de raciocínio, 401/403 → renova e repete uma vez. `ChatGPTModelLister` descobre os modelos da conta.

## OpenCode Go

Provedor BYOK da assinatura OpenCode Go. Endpoint Chat Completions: `https://opencode.ai/inference/go/openai/v1`; descoberta: `https://opencode.ai/inference/go/v1/models`. As chamadas usam Bearer, `User-Agent: FitJourney/<versão>` e `x-opencode-session` estável por instalação. As requisições vão do aparelho ao OpenCode, que as encaminha ao hospedeiro do modelo; a chave permanece no Keychain.

O seletor usa `OpenCodeModelLister` e o cache `coach.openCodeModels.v1` (24 h), excluindo modelos `-free`, sem visão e que treinam com os dados. Sugestões aparecem primeiro; os demais modelos de visão vêm por custo crescente de entrada, depois saída e id. Modelos text-only podem ser digitados em “Outro modelo” e exibem aviso; modelos `-free` e marcados `go.training` são recusados pela fábrica. PDF é sempre rasterizado em imagens, nunca enviado como PDF nativo. Capacidades descobertas prevalecem sobre a tabela estática.

Erros: 401/403 genérico → chave recusada; 403 free tier e 402 → configuração/assinatura; 429 com `Retry-After` até 20 s → limite temporário com repetição; ausente ou maior → limite de uso da assinatura sem repetição. Modelos de visão verificados: `gpt-6-luna`, `claude-haiku-5-5`, `glm-5.3-flash`, `qwen3.8-flash`, `mimo-v2.6-flash` e `deepseek-v4.1-flash` (mais prefixos `gpt-` e `claude-`).

## Copiloto — importar e editar (C7.2, SPEC §7A)

`Services/AI/Attachments/` e `Services/AI/Copilot/`.

- **Anexos**: `LLMMessage.parts` (`LLMContentPart`: texto, imagem base64, PDF base64, texto de arquivo) — fora do `Codable`, nunca em `ChatMessage.content`, log ou backup. Fio: OpenAI `image_url`/`file` (data URL), Anthropic `image`/`document` (base64, antes do texto), ChatGPT `input_image`/`input_file`. `AttachmentCapabilities` por provedor/modelo; sem PDF nativo (ChatGPT login, URL própria) → `PDFRasterizer` (PDFKit → JPEG, até 20 páginas, aviso). `AttachmentPreparer`: ≤ 10 arquivos, 20 MB cada, 22 MB no total, imagens reencodadas ≤ 2048 px sem EXIF/GPS.
- **Import**: contratos `contracts/program-import-v1.schema.json` e `nutrition-import-v1.schema.json` (cópias em `ImportSchemas`, teste de identidade). `ImportSession` (`selecting → analyzing → interviewing → reviewing → applying → done/failed`): ferramenta `submit_extraction`, validação local (schema → Codable → regras) com um reparo só de texto, bytes descartados após a análise, estado em `Application Support/ImportSessions/` (sem bytes). Entrevista determinística (`ProgramInterview`/`NutritionInterview`); dúvidas levantadas pela IA vão em lote por `reviseWithAI()` (sem reenviar arquivos). `apply` via `DraftApplier` (`makeProgram`/`addRoutines`/`makeNutritionPlan`), inativo, `origin = .ai`.
- **Edição**: `propose_routine_changes`, `propose_nutrition_changes`, `propose_food_log` no `FitnessToolbox` (por `Sharing`) → `CopilotPlanner` resolve ids e calcula o diff sobre `RoutineSnapshot`/`NutritionPlanSnapshot` → `CopilotChangeSet` guardado no `CopilotChangeStore` (id = `ChatMessage.toolCallID`). `ChangeApplier` grava pelos stores (`ProgramStore.write`/`NutritionStore.write`/`logFood`), recusa ficha com treino em andamento, pede reconfirmação se a impressão digital mudou e desfaz em até 24 h (só se nada mudou depois).
