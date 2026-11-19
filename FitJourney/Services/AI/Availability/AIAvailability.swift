import Foundation
import Observation
import SwiftUI
import UIKit

extension Notification.Name {
    /// Configuração de IA mudou (provedor/modelo/URL em `ProviderSettingsStore.save`, chave ou login no Keychain em
    /// `KeychainSecretStore.set`). `AIAvailability` reavalia.
    static let aiSettingsDidChange = Notification.Name("fj.ai.settingsDidChange")
}

/// Fonte única e observável de "IA disponível" (SPEC §7.x: recursos de IA só aparecem com a IA configurada).
///
/// Disponível = provedor pronto (`ProviderReadiness.evaluate`: modelo, URL aceitável) com chave ou login guardado.
/// Não testa a chave na rede. Reavalia quando os Ajustes de IA mudam (`.aiSettingsDidChange`) e quando o app volta
/// ao primeiro plano. Um por app (`FitJourneyApp`), no ambiente: `.environment(aiAvailability)`.
/// As telas escondem botões/menus de IA com `.visibleWhenAIAvailable()`; a aba Coach e os Ajustes ficam sempre
/// visíveis (é por eles que se configura a IA).
@MainActor
@Observable
final class AIAvailability {
    private(set) var readiness: ProviderReadiness
    private(set) var provider: AIProviderID
    /// Nome curto do provedor para avisos ("vai para a OpenAI").
    private(set) var providerName: String
    private(set) var model: String

    var isAvailable: Bool { readiness.isReady }
    /// O modelo configurado lê fotos (câmera/galeria do registro com IA).
    var supportsImages: Bool { isAvailable && modelSupportsImages }
    private(set) var modelSupportsImages: Bool

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let observers: ObserverBag

    init(defaults: UserDefaults = .standard, secrets: any SecretStore = KeychainSecretStore(),
         center: NotificationCenter = .default) {
        self.defaults = defaults
        self.secrets = secrets
        let snapshot = Self.evaluate(defaults: defaults, secrets: secrets)
        readiness = snapshot.readiness
        provider = snapshot.provider
        providerName = snapshot.providerName
        model = snapshot.model
        modelSupportsImages = snapshot.modelSupportsImages
        observers = ObserverBag(center: center)
        for name in [Notification.Name.aiSettingsDidChange, UIApplication.didBecomeActiveNotification] {
            observers.observe(name) { [weak self] in self?.refresh() }
        }
    }

    /// Relê configurações e Keychain. Só publica o que mudou.
    func refresh() {
        let snapshot = Self.evaluate(defaults: defaults, secrets: secrets)
        if readiness != snapshot.readiness { readiness = snapshot.readiness }
        if provider != snapshot.provider { provider = snapshot.provider }
        if providerName != snapshot.providerName { providerName = snapshot.providerName }
        if model != snapshot.model { model = snapshot.model }
        if modelSupportsImages != snapshot.modelSupportsImages { modelSupportsImages = snapshot.modelSupportsImages }
    }

    struct Snapshot: Equatable {
        var readiness: ProviderReadiness
        var provider: AIProviderID
        var providerName: String
        var model: String
        var modelSupportsImages: Bool
    }

    static func evaluate(defaults: UserDefaults, secrets: any SecretStore) -> Snapshot {
        let settings = ProviderSettingsStore(defaults: defaults).load()
        let descriptor = ProviderCatalog.descriptor(for: settings.provider)
        let readiness = ProviderReadiness.evaluate(settings, hasAPIKey: descriptor.hasCredential(in: secrets))
        return Snapshot(readiness: readiness, provider: settings.provider, providerName: descriptor.displayShortName,
                        model: settings.model, modelSupportsImages: settings.provider == .openCode
                            ? OpenCodeModelCatalog.capabilities(model: settings.model, cache: OpenCodeModelCache(defaults: defaults).load()).supportsImages
                            : AttachmentCapabilities.resolve(provider: settings.provider, model: settings.model, modelCache: ModelCache(defaults: defaults).load(settings.provider)).supportsImages)
    }

    /// Avisa que a configuração de IA mudou (de qualquer thread).
    nonisolated static func postChange(center: NotificationCenter = .default) {
        center.post(name: .aiSettingsDidChange, object: nil)
    }
}

/// Observadores de notificação removidos junto com o dono. Os blocos rodam na fila principal.
private final class ObserverBag: @unchecked Sendable {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }

    @MainActor
    func observe(_ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    deinit { tokens.forEach(center.removeObserver) }
}

// MARK: - SwiftUI

private struct AIAvailabilityVisibility: ViewModifier {
    @Environment(AIAvailability.self) private var availability: AIAvailability?
    let requiresImages: Bool

    func body(content: Content) -> some View {
        if let availability, requiresImages ? availability.supportsImages : availability.isAvailable {
            content
        }
    }
}

extension View {
    /// Mostra a view só com a IA configurada (`AIAvailability` no ambiente). Sem `AIAvailability` injetada, esconde.
    /// - Parameter requiringImages: também exige que o modelo leia fotos (botões de câmera/galeria da IA).
    func visibleWhenAIAvailable(requiringImages: Bool = false) -> some View {
        modifier(AIAvailabilityVisibility(requiresImages: requiringImages))
    }
}
