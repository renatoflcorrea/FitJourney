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
    /// Qualquer lado: recebi uma mensagem de versão que não suporto. Formato estável, legível por
    /// qualquer versão — o emissor mostra "atualize o app" (o lado com `currentVersion` menor).
    case incompatible(WatchLinkCompatibility)
}

/// Faixa de versões que um lado entende.
struct WatchLinkCompatibility: Codable, Sendable, Hashable {
    var minimumVersion: Int
    var currentVersion: Int

    static let current = WatchLinkCompatibility(minimumVersion: WatchLinkProtocol.minimumSupportedVersion,
                                                currentVersion: WatchLinkProtocol.schemaVersion)

    /// Quem precisa atualizar, do ponto de vista de quem recebeu este aviso do outro lado.
    var peerIsOutdated: Bool { currentVersion < WatchLinkProtocol.schemaVersion }
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
        var incompatible: WatchLinkCompatibility?
    }

    /// Formato estável do aviso de incompatibilidade (sem `message`).
    private struct IncompatibleNotice: Codable {
        var schemaVersion: Int
        var incompatible: WatchLinkCompatibility
    }

    /// Resposta a uma mensagem com `unsupportedVersion`: aviso legível por qualquer versão.
    static func incompatibilityNotice() throws -> Data {
        try encode(.incompatible(.current))
    }

    static func encode(_ message: WatchLinkMessage) throws -> Data {
        try encode(WatchLinkEnvelope(message: message))
    }

    static func encode(_ envelope: WatchLinkEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            if case .incompatible(let compatibility) = envelope.message {
                return try encoder.encode(IncompatibleNotice(schemaVersion: envelope.schemaVersion, incompatible: compatibility))
            }
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
        // O aviso de incompatibilidade é lido em qualquer versão.
        if let compatibility = probe.incompatible {
            return WatchLinkEnvelope(message: .incompatible(compatibility), schemaVersion: probe.schemaVersion)
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
