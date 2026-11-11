import Foundation
import SwiftData
import Testing
@testable import FitJourney

/// Gateway roteirizado (sem rede) para cancelamento e limites do laço.
private final class ScriptedGateway: ChatGateway, StructuredCompleting, @unchecked Sendable {
    enum Step {
        case events([ChatEvent])
        /// Emite o texto e fica pendurado até ser cancelado.
        case hang(String)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [ChatRequest] = []
    var provider: AIProviderID { .openAI }

    init(_ steps: [Step]) { self.steps = steps }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        let step: Step? = lock.withLock {
            requests.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch step {
                case let .events(events)?:
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                case let .hang(text)?:
                    continuation.yield(.delta(text))
                    do {
                        try await Task.sleep(for: .seconds(30))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                case nil:
                    continuation.finish(throwing: AIError.server(status: 500, message: "sem roteiro"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func complete(_ request: ChatRequest) async throws -> ChatCompletion {
        throw AIError.server(status: 500, message: "não usado")
    }
}

@MainActor
private func makeService(_ fixture: ToolboxFixture, chat: @escaping @MainActor () throws -> ResolvedChat) -> CoachConversationService {
    CoachConversationService(context: fixture.context, toolbox: fixture.toolbox(), resolveChat: chat)
}

private func toolCallFrames(id: String, name: String, arguments: String, chunk: Int = 40) -> [String] {
    // Fragmenta os argumentos como a OpenAI faz.
    var frames = [#"{"id":"r","model":"gpt-5-mini","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"\#(id)","type":"function","function":{"name":"\#(name)","arguments":""}}]}}]}"#]
    var rest = Substring(arguments)
    while !rest.isEmpty {
        let piece = String(rest.prefix(chunk))
        rest = rest.dropFirst(chunk)
        let escaped = JSONValue.string(piece).jsonString()
        frames.append(#"{"id":"r","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":\#(escaped)}}]}}]}"#)
    }
    frames.append(#"{"id":"r","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
    return frames
}

@Suite("AI · Laço do Coach")
@MainActor
struct AICoachLoopTests {
    @Test("laço completo via HTTP: list_programs → resultado → propose_program → texto final")
    func fullToolLoop() async throws {
        let fixture = try ToolboxFixture()
        _ = try fixture.persistence.makeProgram(name: "Atual", activate: true)
        let host = StubURLProtocol.uniqueHost()
        let compactDraft = JSONValue.object((try JSONValue.parse(DraftExamples.program)).objectValue!).jsonString()
        StubURLProtocol.enqueue([
            .sse(sseBody(toolCallFrames(id: "call_list", name: "list_programs", arguments: #"{"include_archived":false}"#))),
            .sse(sseBody(toolCallFrames(id: "call_prop", name: "propose_program", arguments: compactDraft))),
            .sse(sseBody([
                #"{"id":"r","model":"gpt-5-mini","choices":[{"index":0,"delta":{"content":"Montei um ABC "}}]}"#,
                #"{"id":"r","choices":[{"index":0,"delta":{"content":"para você revisar."},"finish_reason":"stop"}]}"#,
                #"{"id":"r","choices":[],"usage":{"prompt_tokens":900,"completion_tokens":20}}"#,
            ])),
        ], host: host)
        let session = StubURLProtocol.makeSession()
        let service = makeService(fixture) {
            ResolvedChat(gateway: OpenAICompatibleChatGateway(
                configuration: EndpointConfiguration(provider: .openAI, baseURL: URL(string: "https://\(host)/v1")!,
                                                     auth: .bearer("test-key-not-real")),
                client: HTTPClient(session: session)), model: "gpt-5-mini")
        }
        let conversation = try service.createConversation()

        let ok = await service.send("Monte um ABC de hipertrofia, 4x/semana", in: conversation)
        #expect(ok)
        #expect(service.lastError == nil)
        #expect(!service.isRunning)

        let messages = conversation.sortedMessages
        #expect(messages.map(\.role) == [.user, .assistant, .tool, .assistant, .tool, .assistant])
        #expect(messages.allSatisfy { $0.state == .complete })
        #expect(messages[1].toolCalls.map(\.name) == ["list_programs"])
        #expect(messages[2].toolCallID == "call_list")
        #expect(messages[2].content.contains("Atual"))
        #expect(messages[4].toolName == "propose_program")
        #expect(!messages[4].toolResultIsError)
        guard case let .program(draft)? = messages[4].proposal?.content else { Issue.record("sem proposta"); return }
        #expect(draft.routines.count == 2)
        #expect(messages[5].content == "Montei um ABC para você revisar.")
        #expect(messages[5].usage == TokenUsage(promptTokens: 900, completionTokens: 20))
        #expect(conversation.title == "Monte um ABC de hipertrofia, 4x/semana")
        #expect(conversation.visibleMessages.contains { $0.proposal != nil })
        #expect(try fixture.persistence.count(TrainingProgram.self) == 1) // proposta não grava

        // Os pedidos carregam o prompt de sistema, as ferramentas e o resultado da anterior.
        let bodies = StubURLProtocol.bodies(host: host)
        #expect(bodies.count == 3)
        let first = try #require(bodies[0]["messages"]?.arrayValue)
        #expect(first[0]["role"] == .string("system"))
        #expect(first[0]["content"]?.stringValue?.contains("Coach do FitJourney") == true)
        #expect(bodies[0]["tools"]?.arrayValue?.contains { $0["function"]?["name"] == .string("propose_program") } == true)
        let second = try #require(bodies[1]["messages"]?.arrayValue)
        #expect(second.map { $0["role"] } == [.string("system"), .string("user"), .string("assistant"), .string("tool")])
        #expect(second[3]["tool_call_id"] == .string("call_list"))
        let third = try #require(bodies[2]["messages"]?.arrayValue)
        #expect(third.count == 6)
        #expect(third[5]["content"]?.stringValue?.contains("proposed") == true)
    }

    @Test("proposta inválida volta como erro para o modelo corrigir")
    func invalidProposalRoundTrip() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([
            .events([.toolCall(id: "p1", name: "propose_program", argumentsJSON: #"{"name":"x"}"#), .finished(reason: .toolCalls)]),
            .events([.delta("Corrigindo…"), .finished(reason: .stop)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("treino", in: conversation))
        let tool = try #require(conversation.sortedMessages.first { $0.role == .tool })
        #expect(tool.toolResultIsError)
        #expect(tool.proposal == nil)
        let resent = try #require(gateway.requests.last?.messages.last)
        #expect(resent.role == .tool)
        #expect(resent.isError)
    }

    @Test("máximo de 6 voltas; a última vai com toolChoice none")
    func maxRounds() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let steps = (0 ..< CoachConversationService.maxToolRounds).map { index in
            ScriptedGateway.Step.events([.toolCall(id: "c\(index)", name: "get_profile", argumentsJSON: "{}"), .finished(reason: .toolCalls)])
        }
        let gateway = ScriptedGateway(steps)
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation))
        #expect(gateway.requests.count == CoachConversationService.maxToolRounds)
        #expect(gateway.requests.dropLast().allSatisfy { $0.toolChoice == .auto })
        #expect(gateway.requests.last?.toolChoice == ToolChoice.none)
        // Chamadas da última volta ficam sem resultado e não são reenviadas.
        #expect(conversation.sortedMessages.filter { $0.role == .tool }.count == CoachConversationService.maxToolRounds - 1)
    }

    @Test("cancelar mantém o parcial como .stopped e não registra erro")
    func cancellation() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([.hang("Começando a resp")])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        let sending = Task { await service.send("oi", in: conversation) }
        // Espera o delta chegar.
        for _ in 0 ..< 200 where !service.isRunning || gateway.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        service.stop()
        let ok = await sending.value
        #expect(!ok)
        #expect(service.lastError == nil)
        let assistant = try #require(conversation.sortedMessages.last)
        #expect(assistant.role == .assistant)
        #expect(assistant.state == .stopped)
        #expect(assistant.content == "Começando a resp")
    }

    @Test("erro do provedor: mensagem .failed com motivo sem segredo e lastError preenchido")
    func failure() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let host = StubURLProtocol.uniqueHost()
        StubURLProtocol.enqueue([.json(#"{"error":{"message":"Incorrect API key test-key-not-real"}}"#, status: 401)], host: host)
        let session = StubURLProtocol.makeSession()
        let service = makeService(fixture) {
            ResolvedChat(gateway: OpenAICompatibleChatGateway(
                configuration: EndpointConfiguration(provider: .openAI, baseURL: URL(string: "https://\(host)/v1")!,
                                                     auth: .bearer("test-key-not-real")),
                client: HTTPClient(session: session)), model: "m")
        }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation) == false)
        guard case .unauthorized? = service.lastError else { Issue.record("esperado unauthorized"); return }
        let assistant = try #require(conversation.sortedMessages.last)
        #expect(assistant.state == .failed)
        #expect(!(assistant.failureReason ?? "").contains("test-key-not-real"))
    }

    @Test("sem configuração: notConfigured e nada é gravado")
    func notConfigured() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let service = makeService(fixture) {
            try ProviderFactory.makeChat(settings: ProviderSettings(provider: .openAI), apiKey: nil)
        }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation) == false)
        guard case .notConfigured? = service.lastError else { Issue.record("esperado notConfigured"); return }
        #expect(conversation.sortedMessages.isEmpty)
    }

    @Test("reparo no launch: .streaming vira .stopped mantendo o texto")
    func repair() throws {
        let fixture = try ToolboxFixture(seed: false)
        let conversation = ChatConversation(title: "x")
        fixture.context.insert(conversation)
        let stuck = ChatMessage(role: .assistant, content: "parcial", state: .streaming, sortIndex: 1)
        let done = ChatMessage(role: .assistant, content: "ok", state: .complete, sortIndex: 2)
        for message in [stuck, done] {
            fixture.context.insert(message)
            message.conversation = conversation
        }
        try fixture.context.save()
        #expect(try CoachConversationService.repairInterruptedMessages(in: fixture.context) == 1)
        #expect(stuck.state == .stopped)
        #expect(stuck.content == "parcial")
        #expect(done.state == .complete)
        #expect(try CoachConversationService.repairInterruptedMessages(in: fixture.context) == 0)
    }

    @Test("janela de contexto: orçamento, começa no usuário e não deixa ferramenta órfã")
    func contextWindow() {
        let long = String(repeating: "a", count: 100)
        let history: [LLMMessage] = [
            .user(long), .assistant(long),
            .user("q"), .assistant("", toolCalls: [ToolCall(id: "t1", name: "x", argumentsJSON: "{}")]),
            .toolResult(id: "t1", name: "x", content: long),
            .assistant("resposta"),
            .user("nova"),
        ]
        let fitted = ContextWindow.fit(history, limit: 130)
        #expect(fitted.messages.first?.role == .user)
        #expect(fitted.messages.map(\.role) == [.user, .assistant, .tool, .assistant, .user])
        #expect(fitted.droppedCount == 2)

        // Chamada sem resultado (cancelada) e resultado sem chamada somem.
        let broken: [LLMMessage] = [
            .user("oi"), .assistant("vou ver", toolCalls: [ToolCall(id: "a", name: "x", argumentsJSON: "{}")]),
            .toolResult(id: "zzz", name: "x", content: "órfão"),
            .assistant("", toolCalls: [ToolCall(id: "b", name: "x", argumentsJSON: "{}")]),
        ]
        let clean = ContextWindow.sanitize(broken)
        #expect(clean.map(\.role) == [.user, .assistant])
        #expect(clean[1].toolCalls.isEmpty)
        #expect(clean[1].content == "vou ver")
    }
}
