import Foundation

/// Rascunho do editor de carga (W4 · DESIGN §9.4 "Editor de carga"). A Coroa, os botões − / + e o VoiceOver mexem
/// só aqui: nada sai para o iPhone até "Salvar" (`WatchSessionModel.saveLoad(_:)`), e "Cancelar" (ou qualquer
/// outro jeito de fechar o editor) apenas descarta o rascunho.
///
/// O ajuste é **relativo**: o valor é `base + offset × passo`, levado à grade de 0,5. Assim uma carga em libras com
/// ",5" anda de 1 em 1 lb sem ser arredondada no primeiro detente, e uma carga fora da grade (22,25 kg) só muda
/// quando o usuário mexe — sem mexer, o valor é exatamente a base e nada é enviado.
struct WatchLoadDraft: Equatable, Sendable {
    let setID: UUID
    /// Carga de partida: a mostrada, senão a última usada no exercício, senão 0 (`SessionReducer.loadBase`).
    /// A unidade e o peso corporal vêm dela.
    let base: WatchLoad
    /// A série ainda não tinha carga ("Definir carga"): salvar sem mexer grava a carga mostrada como a da série.
    let wasUnset: Bool
    /// Detentes/toques desde a base (positivo = mais carga).
    private(set) var offset: Int = 0
    private(set) var value: Double

    init(setID: UUID, base: WatchLoad, wasUnset: Bool) {
        self.setID = setID
        self.base = base
        self.wasUnset = wasUnset
        self.value = base.value
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
    /// Detentes possíveis a partir da base (a Coroa usa este intervalo, de 1 em 1).
    var offsetRange: ClosedRange<Int> {
        Int(((range.lowerBound - base.value) / step).rounded(.down))...Int(((range.upperBound - base.value) / step).rounded(.up))
    }
    var hasChanges: Bool { abs(value - base.value) > 0.001 }
    /// "Salvar" faz algo: o valor mudou, ou a série não tinha carga e há uma carga real para gravar (0 kg não conta).
    var canSave: Bool { hasChanges || (wasUnset && (base.isBodyweight || base.value != 0)) }
    var canDecrement: Bool { value > range.lowerBound }
    var canIncrement: Bool { value < range.upperBound }

    mutating func increment() { if canIncrement { setOffset(offset + 1) } }
    mutating func decrement() { if canDecrement { setOffset(offset - 1) } }

    /// Posição da Coroa (detentes relativos à base).
    mutating func setOffset(_ newOffset: Int) {
        offset = min(max(newOffset, offsetRange.lowerBound), offsetRange.upperBound)
        value = offset == 0 ? base.value : WatchLoadStepping.clamp(base.value + Double(offset) * step, for: base)
    }

    /// Valor absoluto aproximado (testes): vira o número de passos mais próximo.
    mutating func set(_ newValue: Double) {
        setOffset(Int(((newValue - base.value) / step).rounded()))
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
