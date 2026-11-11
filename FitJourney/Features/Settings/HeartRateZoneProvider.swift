import Foundation

/// Zonas de FC para a sessão ao vivo. Lê a FC máxima (`fj.maxHeartRate`) e a idade do perfil uma vez e só
/// relê quando os `UserDefaults` mudam (não a cada amostra de FC).
@MainActor
final class HeartRateZoneProvider {
    private let defaults: UserDefaults
    private var zones: HeartRateZones?
    private var watcher: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
        watcher = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification).map({ _ in () }) {
                self?.reload()
            }
        }
    }

    deinit { watcher?.cancel() }

    func reload() {
        let stored = defaults.double(forKey: AppPreferenceKeys.maxHeartRate)
        let age = CoachProfileStore(defaults: defaults).load().age
        zones = HeartRateZones.resolve(configuredMax: stored > 0 ? stored : nil, age: age).zones
    }

    /// Zona do bpm no desenho do design system; `nil` sem FC máxima/idade ou abaixo de 50 %.
    func zone(for bpm: Double) -> FJHeartRateZone? {
        zones?.zone(for: bpm).map(HealthPresentation.designZone)
    }
}
