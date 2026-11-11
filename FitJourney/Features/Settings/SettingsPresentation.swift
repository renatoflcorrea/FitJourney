import Foundation

/// Textos e estados de Ajustes (apresentação pura, testável sem SwiftUI).
enum SettingsPresentation {
    // MARK: Perfil

    /// "34 anos · 78 kg · intermediário"; `nil` se nada foi informado.
    static func profileSummary(_ profile: CoachProfile) -> String? {
        var parts: [String] = []
        if let age = profile.age { parts.append(String(localized: "\(age) anos")) }
        if let weight = profile.weightKg {
            parts.append("\(FJFormat.number(weight, maxFractionDigits: 1)) kg")
        }
        if let level = profile.level {
            switch level {
            case .beginner: parts.append(String(localized: "iniciante"))
            case .intermediate: parts.append(String(localized: "intermediário"))
            case .advanced: parts.append(String(localized: "avançado"))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Integrações

    enum NotificationState: Equatable {
        case allowed, notRequested, denied

        init(_ authorization: RestNotificationAuthorization?) {
            switch authorization {
            case .authorized: self = .allowed
            case .denied: self = .denied
            case .notDetermined, nil: self = .notRequested
            }
        }

        var title: String {
            switch self {
            case .allowed: String(localized: "Permitidas")
            case .notRequested: String(localized: "Ainda não solicitadas")
            case .denied: String(localized: "Desativadas")
            }
        }

        /// Os toggles ficam desabilitados (mantendo o valor) quando o sistema bloqueia.
        var togglesEnabled: Bool { self != .denied }
    }

    static func healthTitle(_ state: HealthConnectionState) -> String {
        switch state {
        case .unavailable: String(localized: "Indisponível")
        case .notConnected: String(localized: "Não conectado")
        case .connected: String(localized: "Conectado")
        }
    }

    /// "OpenAI · gpt-5-mini" ou "Não configurado".
    static func aiTitle(settings: ProviderSettings, hasAPIKey: Bool) -> String {
        guard ProviderReadiness.evaluate(settings, hasAPIKey: hasAPIKey).isReady else {
            return String(localized: "Não configurado")
        }
        return "\(ProviderCatalog.descriptor(for: settings.provider).name) · \(settings.model)"
    }

    // MARK: Treino

    static func restText(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(seconds) s" }
        let minutes = seconds / 60, rest = seconds % 60
        return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
    }

    /// FC máxima efetiva para a explicação ("Pela idade (186 bpm)").
    static func maxHeartRateSummary(stored: Double, age: Int?) -> String {
        switch HeartRateZones.resolve(configuredMax: stored > 0 ? stored : nil, age: age) {
        case .resolved(let bpm, .configured): String(localized: "Manual (\(Int(bpm.rounded())) bpm)")
        case .resolved(let bpm, .ageEstimate): String(localized: "Pela idade (\(Int(bpm.rounded())) bpm)")
        case .needsInput: String(localized: "Informe sua idade no Perfil ou digite um valor")
        }
    }

    static func stepText(_ step: Double, unit: WeightUnit) -> String {
        "\(FJFormat.number(step, maxFractionDigits: 1)) \(PrescriptionFormat.unitText(unit))"
    }

    // MARK: Dados

    /// "3 programas · 142 treinos · 2 dietas · 1.204 registros alimentares".
    static func countsLines(_ counts: BackupCounts) -> [String] {
        var lines: [String] = []
        func add(_ entity: BackupEntity, _ text: (Int) -> String) {
            let n = counts[entity]
            if n > 0 { lines.append(text(n)) }
        }
        add(.programs) { String(localized: "\($0) programas") }
        add(.sessions) { String(localized: "\($0) treinos") }
        add(.exercises) { String(localized: "\($0) exercícios") }
        add(.nutritionPlans) { String(localized: "\($0) dietas") }
        add(.foodEntries) { String(localized: "\($0) registros alimentares") }
        add(.waterLogs) { String(localized: "\($0) registros de água") }
        add(.foods) { String(localized: "\($0) alimentos salvos") }
        add(.coachConversations) { String(localized: "\($0) conversas do Coach") }
        return lines
    }

    /// "Importado: 142 treinos, 3 programas…" a partir do relatório.
    static func importSummary(_ report: BackupImportReport) -> String {
        let created = report.inserted, updated = report.updated
        var parts: [String] = []
        for (entity, label): (BackupEntity, (Int) -> String) in [
            (.sessions, { String(localized: "\($0) treinos") }),
            (.programs, { String(localized: "\($0) programas") }),
            (.nutritionPlans, { String(localized: "\($0) dietas") }),
            (.foodEntries, { String(localized: "\($0) registros alimentares") }),
        ] {
            let n = created[entity] + updated[entity]
            if n > 0 { parts.append(label(n)) }
        }
        if parts.isEmpty { return String(localized: "Nada novo: o aparelho já tinha tudo.") }
        return String(localized: "Importado: \(parts.joined(separator: ", ")).")
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Tamanho da pasta de mídia (síncrono: chame fora da main).
    static func mediaByteCount(in root: URL = MediaStore.defaultRoot) -> Int64 {
        guard let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }
}
