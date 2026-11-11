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
