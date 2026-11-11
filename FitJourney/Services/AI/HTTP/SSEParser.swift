import Foundation

/// Parser incremental de `text/event-stream` (porta direta do fireplaice).
///
/// Linhas de comentário são keep-alive, um quadro pode chegar partido entre pedaços de bytes,
/// e linhas `event:`/`id:` são ignoradas (o tipo do evento Anthropic também vem no JSON).
struct SSEParser: Sendable {
    enum Event: Sendable, Hashable {
        case data(String)
        case done
    }

    private var buffer = ""

    init() {}

    /// Consome uma linha; devolve um evento quando a linha fecha um quadro.
    mutating func consume(line: String) -> Event? {
        guard !line.hasPrefix(":") else { return nil }

        if line.isEmpty {
            defer { buffer = "" }
            guard !buffer.isEmpty else { return nil }
            return buffer == "[DONE]" ? .done : .data(buffer)
        }

        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }

        // Quadros `data:` de várias linhas juntam-se com "\n" (spec SSE).
        buffer = buffer.isEmpty ? payload : buffer + "\n" + payload
        return nil
    }

    /// Entrega o que sobrou quando o stream termina sem linha em branco.
    mutating func flush() -> Event? {
        defer { buffer = "" }
        guard !buffer.isEmpty else { return nil }
        return buffer == "[DONE]" ? .done : .data(buffer)
    }
}

extension SSEParser {
    /// Divide bytes em linhas **mantendo as vazias**.
    ///
    /// `URLSession.AsyncBytes.lines` descarta linhas em branco — justamente o que fecha um quadro SSE.
    static func lines<Bytes: AsyncSequence & Sendable>(from bytes: Bytes) -> AsyncThrowingStream<String, any Error>
    where Bytes.Element == UInt8 {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
