import Foundation

/// Mensagens do protocolo relógio ↔ iPhone.
enum WatchLinkMessage: Codable, Sendable, Hashable {
    /// Relógio/iPhone → iPhone: comando sobre a sessão.
    case command(SessionCommand)
    /// iPhone → relógio: resultado do comando.
    case commandReply(SessionCommandReply)
    /// iPhone → relógio: estado atual da sessão (`nil` = nenhuma sessão em andamento).
    case snapshot(SessionSnapshot?)
    /// Relógio → iPhone: pede o snapshot atual (ao abrir/reconectar).
    case snapshotRequest
    /// iPhone → relógio: programa ativo (`nil` = sem programa ativo).
    case programDigest(ProgramDigest?)
}

/// Envelope versionado: o receptor lê `schemaVersion` antes de decodificar o resto.
struct WatchLinkEnvelope: Codable, Sendable, Hashable {
    var schemaVersion: Int
    var message: WatchLinkMessage

    init(message: WatchLinkMessage, schemaVersion: Int = WatchLinkProtocol.schemaVersion) {
        self.schemaVersion = schemaVersion
        self.message = message
    }
}

enum WatchLinkCodecError: Error, Equatable, Sendable {
    /// Versão fora de `[minimumSupportedVersion, schemaVersion]`: o lado antigo deve pedir atualização.
    case unsupportedVersion(Int)
    /// JSON inválido ou mensagem desconhecida na mesma versão: ignorar.
    case malformed
}

/// Codec JSON do protocolo. Datas no formato padrão do `JSONEncoder` (segundos desde 2001, `Double`),
/// que faz ida e volta exata.
enum WatchLinkCodec {
    private struct VersionProbe: Decodable {
        var schemaVersion: Int
    }

    static func encode(_ message: WatchLinkMessage) throws -> Data {
        try encode(WatchLinkEnvelope(message: message))
    }

    static func encode(_ envelope: WatchLinkEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            return try encoder.encode(envelope)
        } catch {
            throw WatchLinkCodecError.malformed
        }
    }

    static func decode(_ data: Data) throws -> WatchLinkMessage {
        try decodeEnvelope(data).message
    }

    static func decodeEnvelope(_ data: Data) throws -> WatchLinkEnvelope {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            throw WatchLinkCodecError.malformed
        }
        guard probe.schemaVersion >= WatchLinkProtocol.minimumSupportedVersion,
              probe.schemaVersion <= WatchLinkProtocol.schemaVersion else {
            throw WatchLinkCodecError.unsupportedVersion(probe.schemaVersion)
        }
        guard let envelope = try? decoder.decode(WatchLinkEnvelope.self, from: data) else {
            throw WatchLinkCodecError.malformed
        }
        return envelope
    }
}
