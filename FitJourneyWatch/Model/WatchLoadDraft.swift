import Foundation

/// Rascunho do editor de carga (W4 · DESIGN §9.4 "Editor de carga"). A Coroa, os botões − / + e o VoiceOver mexem
/// só aqui: nada sai para o iPhone até "Salvar" (`WatchSessionModel.saveLoad(_:)`), e "Cancelar" (ou qualquer
/// outro jeito de fechar o editor) apenas descarta o rascunho.
struct WatchLoadDraft: Equatable, Sendable {
    let setID: UUID
    /// Carga de partida: a mostrada, senão a última usada no exercício, senão 0 (`SessionReducer.loadBase`).
    /// A unidade e o peso corporal vêm dela.
    let base: WatchLoad
    /// A série ainda não tinha carga ("Definir carga"): salvar sem mexer grava a carga mostrada como a da série.
    let wasUnset: Bool
    private(set) var value: Double

    init(setID: UUID, base: WatchLoad, wasUnset: Bool) {
        self.setID = setID
        self.base = base
        self.wasUnset = wasUnset
        self.value = WatchLoadStepping.clamp(base.value, for: base)
    }

    /// Carga que será gravada (mesma unidade/peso corporal da base).
    var load: WatchLoad {
        var load = base
        load.value = value
        return load
    }

    /// 0,5 kg ou 1 lb por detente/toque.
    var step: Double { WatchLoadStepping.step(for: base) }
    /// Carga absoluta 0…1000; peso corporal (lastro/assistência) −150…+150.
    var range: ClosedRange<Double> { WatchLoadStepping.range(for: base) }
    var hasChanges: Bool { abs(value - base.value) >= WatchLoadStepping.step / 2 }
    var canDecrement: Bool { value > range.lowerBound }
    var canIncrement: Bool { value < range.upperBound }

    mutating func increment() { set(value + step) }
    mutating func decrement() { set(value - step) }

    /// Valor absoluto (Coroa): arredonda à grade e limita ao intervalo.
    mutating func set(_ newValue: Double) {
        value = WatchLoadStepping.clamp(newValue, for: base)
    }
}

extension WatchLoadDraft: Identifiable {
    var id: UUID { setID }
}

// MARK: - Carga exibida

/// Carga efetiva exibida de uma série (`nil` = o exercício não usa carga). Sem carga definida, a base do editor
/// é 0 — mas a tela mostra "Definir carga" (`isLoadUnset`), nunca "0 kg" como se fosse prescrito (P2.8).
func effectiveLoad(of set: SessionSnapshot.ExerciseSet, in exercise: SessionSnapshot.Exercise) -> WatchLoad? {
    if let load = set.load ?? set.plannedLoad { return load }
    return exercise.measurementKind == .repsAndLoad ? WatchLoad(value: 0) : nil
}

/// Série sem carga registrada nem planejada (peso 0 planejado conta como sem carga; peso corporal é carga).
func isLoadUnset(_ set: SessionSnapshot.ExerciseSet) -> Bool {
    guard set.load == nil else { return false }
    guard let planned = set.plannedLoad else { return true }
    return !planned.isBodyweight && planned.value == 0
}
