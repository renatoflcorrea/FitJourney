import Foundation
import os
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

/// Leitor do Saúde que fica pendurado na leitura de treinos até ser cancelado.
private final class HangingHealthReader: HealthDataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    var entered: Bool { lock.withLock { didEnter } }

    func workouts(in interval: DateInterval) async throws -> HealthReading<[HealthWorkoutRecord]> {
        lock.withLock { didEnter = true }
        try await Task.sleep(for: .seconds(30))
        return .noData
    }

    func heartRateSamples(in interval: DateInterval) async throws -> HealthReading<[HeartRateSample]> { .noData }
    func heartRateBuckets(in interval: DateInterval, bucket: TimeInterval) async throws -> HealthReading<[HeartRateBucket]> { .noData }
    func workoutPauses(workoutID: UUID) async throws -> HealthReading<[DateInterval]> { .noData }
    func activeEnergyKcal(in interval: DateInterval) async throws -> HealthReading<Double> { .noData }
    func steps(in interval: DateInterval) async throws -> HealthReading<Double> { .noData }
    func restingHeartRate(days interval: DateInterval) async throws -> HealthReading<[HealthDailyValue]> { .noData }
    func latestBodyMassKg() async throws -> HealthReading<Double> { .noData }
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

    @Test("máximo de 6 voltas; a última vai com toolChoice none e, se insistir, falha com texto claro")
    func maxRounds() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let steps = (0 ..< CoachConversationService.maxToolRounds).map { index in
            ScriptedGateway.Step.events([.toolCall(id: "c\(index)", name: "get_profile", argumentsJSON: "{}"), .finished(reason: .toolCalls)])
        }
        let gateway = ScriptedGateway(steps)
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation) == false)
        #expect(service.lastError == .incomplete(.toolRoundLimit))
        #expect(conversation.sortedMessages.last?.state == .failed)
        #expect(conversation.sortedMessages.last?.failureReason == AIError.IncompleteReason.toolRoundLimit.localizedDescription)
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

    @Test("parar durante uma ferramenta (leitura do Saúde) não grava resultado \"cancelled\"")
    func cancellationDuringTool() async throws {
        var fixture = try ToolboxFixture(seed: false)
        fixture.profile.sharing.health = true
        let reader = HangingHealthReader()
        fixture.healthReader = reader
        let gateway = ScriptedGateway([
            .events([.toolCall(id: "h1", name: "get_health_summary", argumentsJSON: #"{"from":null,"to":null}"#),
                     .finished(reason: .toolCalls)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        let sending = Task { await service.send("como foi minha semana?", in: conversation) }
        for _ in 0 ..< 300 where !reader.entered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(reader.entered)
        service.stop()
        let ok = await sending.value
        #expect(!ok)
        #expect(service.lastError == nil)
        #expect(!conversation.sortedMessages.contains { $0.role == .tool })
        #expect(!conversation.sortedMessages.contains { $0.content.contains("cancelled") })
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

    @Test("regenerate: refaz o turno com a mesma mensagem do usuário, sem duplicar")
    func regenerate() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([
            .events([.delta("parcial"), .finished(reason: .length)]),
            .events([.delta("completo"), .finished(reason: .stop)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("monte um treino", in: conversation) == false)
        let stopped = try #require(conversation.sortedMessages.last)
        #expect(stopped.state == .stopped)
        #expect(service.lastErrorConversationID == conversation.id)

        #expect(await service.regenerate(after: stopped, in: conversation))
        #expect(service.lastError == nil)
        #expect(service.lastErrorConversationID == nil)
        let messages = conversation.sortedMessages
        #expect(messages.filter { $0.role == .user }.count == 1)
        #expect(messages.filter { $0.role == .assistant }.count == 1)
        let answer = try #require(messages.last)
        #expect(answer.content == "completo")
        #expect(answer.state == .complete)
        #expect(gateway.requests.count == 2)
        #expect(gateway.requests[1].messages.filter { $0.role == .user }.count == 1)

        // Resposta completa não é elegível; só a última mensagem vale.
        #expect(await service.regenerate(after: answer, in: conversation) == false)
    }

    @Test("regenerate sem provedor configurado não apaga a resposta anterior")
    func regenerateKeepsMessageOnConfigError() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let configured = OSAllocatedUnfairLock(initialState: true)
        let gateway = ScriptedGateway([.events([.delta("parcial"), .finished(reason: .length)])])
        let service = makeService(fixture) {
            if !configured.withLock({ $0 }) { throw AIError.notConfigured(reason: "chave") }
            return ResolvedChat(gateway: gateway, model: "m")
        }
        let conversation = try service.createConversation()
        _ = await service.send("oi", in: conversation)
        let stopped = try #require(conversation.sortedMessages.last)
        configured.withLock { $0 = false }
        #expect(await service.regenerate(after: stopped, in: conversation) == false)
        #expect(conversation.sortedMessages.last?.id == stopped.id)
    }

    @Test("apagar conversa em streaming espera a tarefa terminar")
    func deleteWhileStreaming() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([.hang("Começando")])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        let sending = Task { await service.send("oi", in: conversation) }
        for _ in 0 ..< 200 where !service.isRunning || gateway.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        try await service.delete(conversation)
        #expect(!service.isRunning)
        #expect(await sending.value == false)
        #expect(try fixture.context.fetch(FetchDescriptor<ChatConversation>()).isEmpty)
        #expect(try fixture.context.fetch(FetchDescriptor<ChatMessage>()).isEmpty)
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

    @Test("janela: o turno atual nunca é cortado; prefixo começa no usuário e perde o raciocínio")
    func contextWindow() {
        let long = String(repeating: "a", count: 100)
        let prefix: [LLMMessage] = [
            .user(long), .assistant(long),
            .user("q"), LLMMessage(role: .assistant, content: "", toolCalls: [ToolCall(id: "t1", name: "x", argumentsJSON: "{}")],
                                   reasoningBlocks: [ReasoningBlock(kind: .thinking, text: "velho", signature: "s")]),
            .toolResult(id: "t1", name: "x", content: long),
            .assistant("resposta"),
        ]
        let current: [LLMMessage] = [.user("nova")]
        let fitted = ContextWindow.fitPrefix(prefix, current: current, budgetCharacters: 4 + 130)
        #expect(fitted.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
        #expect(fitted.messages.allSatisfy { $0.reasoningBlocks.isEmpty })
        #expect(fitted.droppedCount == 2)

        // Turno atual maior que o orçamento: prefixo some, turno fica (quem decide é o chamador).
        let huge = ContextWindow.fitPrefix(prefix, current: [.user(String(repeating: "b", count: 10_000))], budgetCharacters: 500)
        #expect(huge.messages.isEmpty)
        #expect(huge.droppedCount == prefix.count)
    }

    @Test("janela: prefixo [assistant, tool] sem usuário é descartado inteiro")
    func prefixWithoutUser() {
        let prefix: [LLMMessage] = [
            .assistant("", toolCalls: [ToolCall(id: "a", name: "x", argumentsJSON: "{}")]),
            .toolResult(id: "a", name: "x", content: "r"),
        ]
        let fitted = ContextWindow.fitPrefix(prefix, current: [.user("oi")], budgetCharacters: 10_000)
        #expect(fitted.messages.isEmpty)
        #expect(fitted.droppedCount == 2)
    }

    @Test("sanitize: chamada sem resultado e resultado sem chamada somem")
    func sanitize() {
        let broken: [LLMMessage] = [
            .user("oi"), .assistant("vou ver", toolCalls: [ToolCall(id: "a", name: "x", argumentsJSON: "{}")]),
            .toolResult(id: "zzz", name: "x", content: "órfão"),
            .assistant("  ", toolCalls: [ToolCall(id: "b", name: "x", argumentsJSON: "{}")]),
        ]
        let clean = ContextWindow.sanitize(broken)
        #expect(clean.map(\.role) == [.user, .assistant])
        #expect(clean[1].toolCalls.isEmpty)
        #expect(clean[1].content == "vou ver")
    }

    @Test("o orçamento conta system e schemas das ferramentas")
    func budgetCountsTools() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([.events([.delta("a"), .finished(reason: .stop)]),
                                       .events([.delta("b"), .finished(reason: .stop)])])
        let toolsCost = ContextWindow.toolsCost(fixture.toolbox().specs)
        let tokens = (CoachPrompt.system.count + toolsCost) / ContextWindow.charactersPerToken + 30
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m", contextBudgetTokens: tokens) }
        let conversation = try service.createConversation()
        // Sobram ~120 caracteres além de system + ferramentas: a 1ª troca (200 + 1) não cabe mais.
        #expect(await service.send(String(repeating: "x", count: 200), in: conversation))
        #expect(await service.send("segunda", in: conversation))
        let second = try #require(gateway.requests.last)
        #expect(second.messages.map(\.role) == [.system, .user])
        #expect(second.messages.last?.content.hasSuffix("segunda") == true)
        #expect(second.messages.last?.content.contains("2 mensagens anteriores") == true)
        #expect(second.tools.count == fixture.toolbox().specs.count)
    }

    @Test("A1: system/tools fixos, pedidos só-anexar e raciocínio só do turno atual")
    func appendOnlyTurn() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let thinking = ReasoningBlock(kind: .thinking, text: "pensei", signature: "sig")
        let gateway = ScriptedGateway([
            // turno 1
            .events([.reasoningBlock(thinking), .delta("Olá!"), .finished(reason: .stop)]),
            // turno 2, volta 1: pede ferramenta com raciocínio
            .events([.reasoningBlock(thinking), .toolCall(id: "c1", name: "get_profile", argumentsJSON: "{}"),
                     .finished(reason: .toolCalls)]),
            // turno 2, volta 2: texto final
            .events([.delta("Pronto."), .finished(reason: .stop)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("oi", in: conversation))
        #expect(await service.send("meu perfil?", in: conversation))
        #expect(gateway.requests.count == 3)
        let round1 = gateway.requests[1], round2 = gateway.requests[2]

        // Turno anterior: texto fica, raciocínio sai.
        let previous = try #require(round1.messages.first { $0.role == .assistant })
        #expect(previous.content == "Olá!")
        #expect(previous.reasoningBlocks.isEmpty)
        // Turno atual: o raciocínio da volta 1 é reenviado na volta 2.
        let currentAssistant = try #require(round2.messages.last { $0.role == .assistant })
        #expect(currentAssistant.reasoningBlocks == [thinking])
        // Mesmo system e mesmas ferramentas; a volta 2 só acrescenta à volta 1.
        #expect(round1.messages.first == round2.messages.first)
        #expect(round1.tools == round2.tools)
        #expect(Array(round2.messages.prefix(round1.messages.count)) == round1.messages)
        #expect(round2.messages.count == round1.messages.count + 2)
    }

    @Test("A2: término por limite não executa ferramentas e para como .stopped")
    func lengthStops() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([
            .events([.delta("Plano parcial"), .toolCall(id: "p", name: "propose_program", argumentsJSON: #"{"name":"#),
                     .finished(reason: .length)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("treino", in: conversation) == false)
        #expect(service.lastError == .incomplete(.length))
        #expect(gateway.requests.count == 1)
        #expect(!conversation.sortedMessages.contains { $0.role == .tool })
        let assistant = try #require(conversation.sortedMessages.last)
        #expect(assistant.state == .stopped)
        #expect(assistant.content == "Plano parcial")
        #expect(assistant.toolCalls.isEmpty)
        #expect(assistant.failureReason == AIError.IncompleteReason.length.localizedDescription)
    }

    @Test("A2: recusa descarta o parcial e falha; filtro de conteúdo falha")
    func refusalFails() async throws {
        let fixture = try ToolboxFixture(seed: false)
        let gateway = ScriptedGateway([
            .events([.delta("Começo"), .finished(reason: .refusal)]),
            .events([.delta("x"), .finished(reason: .contentFilter)]),
        ])
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("a", in: conversation) == false)
        #expect(service.lastError == .incomplete(.refusal))
        #expect(conversation.sortedMessages.last?.state == .failed)
        #expect(conversation.sortedMessages.last?.content == "")
        #expect(await service.send("b", in: conversation) == false)
        #expect(service.lastError == .incomplete(.contentFilter))
    }

    @Test("A3/M7: resultado grande é truncado em JSON válido; antigos são compactados, propostas ficam")
    func toolResultLimitsAndRetention() async throws {
        let big = String(repeating: "z", count: CoachConversationService.maxToolResultCharacters + 500)
        let limited = CoachConversationService.limitToolResult(big)
        #expect(limited.count <= CoachConversationService.maxToolResultCharacters)
        let parsed = try JSONValue.parse(limited)
        #expect(parsed["truncated"] == .bool(true))
        #expect(CoachConversationService.limitToolResult("{}") == "{}")

        let fixture = try ToolboxFixture()
        var steps: [ScriptedGateway.Step] = [
            .events([.toolCall(id: "p0", name: "propose_program", argumentsJSON: DraftExamples.program), .finished(reason: .toolCalls)]),
            .events([.delta("ok"), .finished(reason: .stop)]),
        ]
        for _ in 0 ... CoachConversationService.toolResultRetentionTurns {
            steps.append(.events([.delta("ok"), .finished(reason: .stop)]))
        }
        let gateway = ScriptedGateway(steps)
        let service = makeService(fixture) { ResolvedChat(gateway: gateway, model: "m") }
        let conversation = try service.createConversation()
        #expect(await service.send("proponha", in: conversation))
        for index in 0 ... CoachConversationService.toolResultRetentionTurns {
            #expect(await service.send("mais \(index)", in: conversation))
        }
        let tool = try #require(conversation.sortedMessages.first { $0.role == .tool })
        #expect(tool.content == CoachConversationService.compactedToolResult)
        #expect(tool.proposal != nil) // o cartão continua disponível
    }
}
