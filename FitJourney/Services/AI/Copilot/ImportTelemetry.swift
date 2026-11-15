import Foundation
import os
import UIKit

private let importLog = Logger(subsystem: "br.com.renatocorrea.fitjourney", category: "ai-import")

/// Medição por chamada da importação (T0): só números e o nome do modelo, nunca conteúdo do usuário.
struct ImportCallMetrics: Sendable, Hashable {
    enum Stage: String, Sendable, Hashable { case extract, repair, revise }

    var stage: Stage
    var model: String
    var timeToFirstEvent: Duration?
    var total: Duration
    /// Caracteres da mensagem enviada (sem os anexos) e da saída (argumentos da ferramenta ou texto).
    var inputCharacters: Int
    var outputCharacters: Int
    var usage: TokenUsage?

    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    func log() {
        let first = timeToFirstEvent.map(Self.milliseconds) ?? -1
        importLog.info("""
            import \(stage.rawValue, privacy: .public) model=\(model, privacy: .public) \
            firstEventMs=\(first) totalMs=\(Self.milliseconds(total)) \
            inChars=\(inputCharacters) outChars=\(outputCharacters) \
            inTokens=\(usage?.promptTokens ?? -1) outTokens=\(usage?.completionTokens ?? -1)
            """)
    }
}

/// Pede ao sistema alguns segundos a mais em segundo plano para a chamada terminar se o usuário sair rápido do app.
/// Não promete mais que isso: o sistema encerra a tarefa quando o tempo acaba (a chamada falha e dá para tentar de novo).
@MainActor
final class BackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(_ name: String) -> BackgroundExecution {
        let token = BackgroundExecution()
        token.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [token] in
            token.end()
        }
        return token
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
