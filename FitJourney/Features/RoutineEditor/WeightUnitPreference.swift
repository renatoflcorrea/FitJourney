import Foundation

/// Preferência global de unidade de carga (kg padrão). Arquivo isolado para mover para Ajustes:
/// a tela de Ajustes deve gravar em `UserDefaults` / `@AppStorage` com esta chave.
enum WeightUnitPreference {
    static let key = "fj.weightUnit"

    static var current: WeightUnit {
        UserDefaults.standard.string(forKey: key).flatMap(WeightUnit.init(rawValue:)) ?? .kg
    }
}
