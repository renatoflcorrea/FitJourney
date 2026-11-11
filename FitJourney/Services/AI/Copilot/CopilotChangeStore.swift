import Foundation
import Observation

/// Estado do cartão de alteração.
enum CopilotChangeState: String, Codable, Sendable, Hashable {
    /// Aguardando "Aplicar"/"Descartar".
    case proposed
    /// O estado mudou desde a proposta: o diff foi recalculado e precisa de nova confirmação.
    case needsConfirmation
    case applied
    case discarded
    case undone
}

/// Como desfazer uma alteração aplicada.
enum CopilotUndo: Codable, Sendable, Hashable {
    /// Fotografia da ficha antes; só desfaz se a ficha ainda está como ficou (`afterFingerprint`).
    case routine(before: RoutineSnapshot, afterFingerprint: String)
    case nutritionPlan(before: NutritionPlanSnapshot, afterFingerprint: String)
    /// Registros criados (apagados ao desfazer).
    case foodLog(entryIDs: [UUID])
}

/// Cartões de alteração do copiloto e seus estados, por id do changeset (= `ChatMessage.toolCallID`).
/// Fica num JSON em `Application Support/Copilot/` (fora do backup do app e do iCloud); registros com mais de
/// 30 dias são descartados. Nada aqui contém segredos.
@MainActor
@Observable
final class CopilotChangeStore {
    struct Record: Codable, Sendable, Hashable {
        var changeSet: CopilotChangeSet
        /// Mensagem `tool` que carrega o cartão.
        var messageID: UUID?
        var state: CopilotChangeState
        var appliedAt: Date?
        var undo: CopilotUndo?
        var updatedAt: Date
    }

    static let undoWindow: TimeInterval = 24 * 3600
    static let retention: TimeInterval = 30 * 24 * 3600

    /// Instância do app (arquivo em disco).
    static let shared = CopilotChangeStore(
        fileURL: URL.applicationSupportDirectory.appending(path: "Copilot", directoryHint: .isDirectory).appending(path: "changes.json"))

    private(set) var records: [String: Record] = [:]
    @ObservationIgnored private let fileURL: URL?

    /// - Parameter fileURL: `nil` = só em memória (testes, previews).
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        load()
    }

    func record(for id: String) -> Record? { records[id] }
    func changeSet(for id: String) -> CopilotChangeSet? { records[id]?.changeSet }
    func state(for id: String) -> CopilotChangeState? { records[id]?.state }

    /// Cartão da mensagem `tool` (pelo id da chamada).
    func record(for message: ChatMessage) -> Record? {
        guard message.role == .tool, let id = message.toolCallID else { return nil }
        return records[id]
    }

    /// Registra uma proposta nova (ou substitui a mesma proposta, se o id repetir).
    func register(_ changeSet: CopilotChangeSet, messageID: UUID? = nil, now: Date = .now) {
        records[changeSet.id] = Record(changeSet: changeSet, messageID: messageID, state: .proposed, appliedAt: nil, undo: nil,
                                       updatedAt: now)
        save()
    }

    func attach(messageID: UUID, to id: String) {
        guard records[id] != nil else { return }
        records[id]?.messageID = messageID
        save()
    }

    func update(_ record: Record) {
        records[record.changeSet.id] = record
        save()
    }

    func removeAll() {
        records = [:]
        save()
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: Record].self, from: data) else { return }
        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        records = decoded.filter { $0.value.updatedAt >= cutoff }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // Falha de disco: os cartões continuam em memória nesta execução.
        }
    }
}
