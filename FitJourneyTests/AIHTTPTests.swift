import Foundation
import Testing
@testable import FitJourney

// MARK: - Suporte: URLProtocol com respostas enfileiradas por host

/// Serve respostas prontas a uma `URLSession`, para que os testes exercitem a montagem real dos
/// pedidos e o parsing sem rede. Filas por host: cada teste usa `uniqueHost()` e roda em paralelo.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func json(_ raw: String, status: Int = 200, headers: [String: String] = [:]) -> Stub {
            Stub(statusCode: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, body: Data(raw.utf8))
        }

        static func sse(_ raw: String) -> Stub {
            Stub(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: Data(raw.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Stub]] = [:]
    nonisolated(unsafe) private static var recorded: [String: [URLRequest]] = [:]

    static func enqueue(_ stubs: [Stub], host: String) {
        lock.withLock {
            queues[host] = stubs
            recorded[host] = []
        }
    }

    static func requests(host: String) -> [URLRequest] { lock.withLock { recorded[host] ?? [] } }

    static func bodies(host: String) -> [JSONValue] {
        requests(host: host).compactMap { $0.httpBody.flatMap { try? JSONValue.parse(String(decoding: $0, as: UTF8.self)) } }
    }

    static func uniqueHost() -> String { "t\(UUID().uuidString.prefix(8).lowercased()).example" }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream { copy.httpBody = Self.readAll(stream) }
        let host = request.url?.host() ?? ""
        let stub: Stub? = Self.lock.withLock {
            Self.recorded[host, default: []].append(copy)
            guard var pending = Self.queues[host], !pending.isEmpty else { return nil }
            let next = pending.removeFirst()
            Self.queues[host] = pending
            return next
        }
        guard let stub else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        if let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: stub.statusCode,
                                          httpVersion: "HTTP/1.1", headerFields: stub.headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Monta um corpo SSE a partir de objetos JSON (`data: …\n\n`), com `[DONE]` opcional.
func sseBody(_ frames: [String], done: Bool = true, events: [String]? = nil) -> String {
    var out = ""
    for (index, frame) in frames.enumerated() {
        if let events { out += "event: \(events[index])\n" }
        out += "data: \(frame)\n\n"
    }
    if done { out += "data: [DONE]\n\n" }
    return out
}

func collect(_ stream: AsyncThrowingStream<ChatEvent, any Error>) async throws -> [ChatEvent] {
    var events: [ChatEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

// MARK: - SSE

@Suite("AI · SSE parser")
struct AISSEParserTests {
    private func events(of raw: String) -> [SSEParser.Event] {
        var parser = SSEParser()
        var result: [SSEParser.Event] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if let event = parser.consume(line: String(line)) { result.append(event) }
        }
        if let event = parser.flush() { result.append(event) }
        return result
    }

    @Test func singleFrame() { #expect(events(of: "data: {\"a\":1}\n\n") == [.data("{\"a\":1}")]) }
    @Test func ignoresComments() { #expect(events(of: ": ping\ndata: {\"a\":1}\n\n") == [.data("{\"a\":1}")]) }
    @Test func doneMarker() { #expect(events(of: "data: {\"a\":1}\n\ndata: [DONE]\n") == [.data("{\"a\":1}"), .done]) }
    @Test func multiLineFrame() { #expect(events(of: "data: line one\ndata: line two\n\n") == [.data("line one\nline two")]) }
    @Test func flushesTrailingFrame() { #expect(events(of: "data: {\"a\":1}") == [.data("{\"a\":1}")]) }
    @Test func skipsUnknownFields() {
        #expect(events(of: "event: message\nid: 7\ndata: {\"a\":1}\n\n") == [.data("{\"a\":1}")])
    }

    @Test("linhas em branco são preservadas ao dividir bytes (CRLF incluso)")
    func linesKeepBlanks() async throws {
        let bytes = Array("data: a\r\n\r\ndata: b\n\n".utf8)
        let source = AsyncStream<UInt8> { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in SSEParser.lines(from: source) { lines.append(line) }
        #expect(lines == ["data: a", "", "data: b", ""])
    }
}

// MARK: - Decodificador estruturado

@Suite("AI · Structured decoder")
struct AIStructuredDecoderTests {
    private struct Payload: Decodable, Equatable {
        var title: String
        var count: Int?
    }

    @Test func plainJSON() throws {
        #expect(try StructuredDecoder.decode(Payload.self, from: #"{"title":"olá"}"#) == Payload(title: "olá"))
    }

    @Test func fencedJSON() throws {
        let raw = "```json\n{\"title\":\"olá\",\"count\":2}\n```"
        #expect(try StructuredDecoder.decode(Payload.self, from: raw) == Payload(title: "olá", count: 2))
    }

    @Test func proseAroundJSON() throws {
        let raw = "Claro! Aqui está:\n{\"title\":\"olá\"}\nEspero que ajude."
        #expect(try StructuredDecoder.decode(Payload.self, from: raw) == Payload(title: "olá"))
    }

    @Test func bracesInsideStrings() throws {
        #expect(try StructuredDecoder.decode(Payload.self, from: #"{"title":"a } b"}"#).title == "a } b")
    }

    @Test func escapedQuotes() throws {
        #expect(try StructuredDecoder.decode(Payload.self, from: #"{"title":"diz \"oi\""}"#).title == #"diz "oi""#)
    }

    @Test func noObject() {
        #expect(throws: AIError.self) { try StructuredDecoder.decode(Payload.self, from: "desculpe, não consegui") }
    }

    @Test func truncatedObject() {
        #expect(throws: AIError.self) { try StructuredDecoder.decode(Payload.self, from: #"{"title":"olá""#) }
    }
}

// MARK: - HTTP

@Suite("AI · HTTP error mapping")
struct AIHTTPErrorTests {
    private func response(_ status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://example.invalid"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
    }

    @Test("429 vira rateLimited com Retry-After")
    func rateLimit() throws {
        #expect(throws: AIError.rateLimited(retryAfter: 42)) {
            try HTTPClient.validate(try response(429, headers: ["Retry-After": "42"]), data: Data())
        }
    }

    @Test("401 e 403 viram unauthorized; 400 badRequest; 5xx server")
    func statusMapping() throws {
        for status in [401, 403] {
            do { try HTTPClient.validate(try response(status), data: Data()); Issue.record("não lançou") } catch let error as AIError {
                guard case .unauthorized = error else { Issue.record("esperado unauthorized, veio \(error)"); continue }
            }
        }
        #expect(throws: AIError.badRequest(status: 400, message: "bad")) {
            try HTTPClient.validate(try response(400), data: Data(#"{"error":{"message":"bad"}}"#.utf8))
        }
        do { try HTTPClient.validate(try response(503), data: Data()) } catch let error as AIError {
            #expect(error.isRetryable)
        }
    }

    @Test("a mensagem do provedor aparece, onde quer que esteja", arguments: [
        (#"{"error":{"message":"model not found"}}"#, "model not found"),
        (#"{"message":"Workflow execution failed"}"#, "Workflow execution failed"),
        (#"{"error":"bad request"}"#, "bad request"),
    ])
    func errorMessages(pair: (String, String)) {
        #expect(HTTPClient.errorMessage(from: Data(pair.0.utf8)) == pair.1)
    }

    @Test("a chave ecoada pelo provedor é removida da mensagem de erro")
    func redactsEchoedCredential() throws {
        var request = URLRequest(url: try #require(URL(string: "https://example.invalid/v1")))
        request.setValue("Bearer weird-key-value-123", forHTTPHeaderField: "Authorization")
        request.setValue("anthropic-secret-456", forHTTPHeaderField: "x-api-key")
        let body = #"{"error":{"message":"invalid key weird-key-value-123 / anthropic-secret-456 / sk-proj-abcdefghijkl"}}"#
        do {
            try HTTPClient.validate(try response(401), data: Data(body.utf8), request: request)
            Issue.record("não lançou")
        } catch let AIError.unauthorized(message) {
            #expect(!message.contains("weird-key-value-123"))
            #expect(!message.contains("anthropic-secret-456"))
            #expect(!message.contains("sk-proj-abcdefghijkl"))
        }
    }

    @Test("URLError cancelado não é falha de rede")
    func cancellation() {
        #expect(HTTPClient.map(URLError(.cancelled)) == .cancelled)
        #expect(HTTPClient.map(URLError(.timedOut)).isRetryable)
        #expect(!HTTPClient.map(URLError(.badURL)).isRetryable)
    }

    @Test("parâmetro de limite segue a família do modelo", arguments: [
        ("gpt-4.1-mini", "max_tokens"), ("gpt-5-mini", "max_completion_tokens"),
        ("openai/gpt-5", "max_completion_tokens"), ("o3-mini", "max_completion_tokens"), ("llama3.1", "max_tokens"),
    ])
    func tokenParameter(pair: (String, String)) {
        #expect(ModelCapabilities.tokenParameter(for: pair.0) == pair.1)
    }

    @Test("a mensagem de erro localizada não carrega segredo")
    func localizedDescriptionIsSafe() {
        let error = AIError.unauthorized(message: "sk-abcdefghijklmnop")
        #expect(!(error.errorDescription ?? "").contains("sk-abcdefghijklmnop"))
    }
}
