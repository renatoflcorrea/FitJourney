import Foundation

/// IDs determinísticos da sessão (protocolo v2): relógio e iPhone calculam os mesmos IDs de
/// `SessionExercise`/`SetLog` a partir do ID da sessão e da prescrição de origem, então um comando
/// emitido no relógio antes do 1º snapshot já cita os IDs que o iPhone vai criar — sem reter nem remapear.
///
/// UUID versão 5 (RFC 9562, SHA-1) com o ID da sessão como *namespace* e um nome com prefixo por tipo:
/// - exercício da ficha: `"exercise:" + RoutineExercise.id`
/// - série prescrita: `"set:" + SetPrescription.id`
/// - série extra (`addSet`): `"extra-set:" + commandID`
/// - exercício adicionado (`addExercise`): `"added-exercise:" + commandID`, e suas séries
///   `"added-set:" + commandID + ":" + índice`.
///
/// NUNCA mude prefixos nem a codificação (UUID em maiúsculas, `uuidString`): os dois lados precisam bater.
enum WatchLinkIDs {
    static func sessionExerciseID(sessionID: UUID, routineExerciseID: UUID) -> UUID {
        uuid5(namespace: sessionID, name: "exercise:" + routineExerciseID.uuidString)
    }

    static func setLogID(sessionID: UUID, prescriptionID: UUID) -> UUID {
        uuid5(namespace: sessionID, name: "set:" + prescriptionID.uuidString)
    }

    /// Série extra criada pelo comando `addSet` com este `commandID`.
    static func extraSetID(sessionID: UUID, commandID: UUID) -> UUID {
        uuid5(namespace: sessionID, name: "extra-set:" + commandID.uuidString)
    }

    /// Exercício criado pelo comando `addExercise` com este `commandID`.
    static func addedExerciseID(sessionID: UUID, commandID: UUID) -> UUID {
        uuid5(namespace: sessionID, name: "added-exercise:" + commandID.uuidString)
    }

    /// Série `index` (0-based) do exercício criado por `addExercise`.
    static func addedSetID(sessionID: UUID, commandID: UUID, index: Int) -> UUID {
        uuid5(namespace: sessionID, name: "added-set:" + commandID.uuidString + ":" + String(index))
    }

    /// UUID v5 (RFC 9562 §5.5): SHA-1(namespace ‖ nome UTF-8), versão 5, variante RFC.
    static func uuid5(namespace: UUID, name: String) -> UUID {
        let ns = namespace.uuid
        var bytes: [UInt8] = [ns.0, ns.1, ns.2, ns.3, ns.4, ns.5, ns.6, ns.7,
                              ns.8, ns.9, ns.10, ns.11, ns.12, ns.13, ns.14, ns.15]
        bytes.append(contentsOf: Array(name.utf8))
        var hash = SHA1.digest(bytes)
        hash[6] = (hash[6] & 0x0F) | 0x50
        hash[8] = (hash[8] & 0x3F) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }
}

/// SHA-1 mínimo (FIPS 180-4) só para o UUID v5 — `Shared/WatchLink` é só Foundation. Não é uso criptográfico.
private enum SHA1 {
    static func digest(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x6745_2301, h1: UInt32 = 0xEFCD_AB89, h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476, h4: UInt32 = 0xC3D2_E1F0
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A82_7999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9_EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1B_BCDC
                default: f = b ^ c ^ d; k = 0xCA62_C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = temp
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].flatMap { value in (0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32(24 - $0 * 8)) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}
