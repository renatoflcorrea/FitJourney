import Foundation

/// Regras puras de apresentação da sessão (textos, VoiceOver, modo da doca). Sem SwiftUI: testável.
enum SessionPresentation {
    // MARK: Plurais (frases inteiras localizáveis)

    static func seriesCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 série") : String(localized: "\(n) séries")
    }

    static func repsDone(_ n: Int) -> String {
        n == 1 ? String(localized: "1 repetição feita") : String(localized: "\(n) repetições feitas")
    }

    static func sessionsCount(_ n: Int) -> String {
        n == 1 ? String(localized: "1 sessão") : String(localized: "\(n) sessões")
    }

    /// "4 de 5 séries" (concordância pelo total).
    static func setsDone(_ done: Int, of total: Int) -> String {
        total == 1 ? String(localized: "\(done) de 1 série") : String(localized: "\(done) de \(total) séries")
    }

    /// Bi-set (2), Tri-set (3), Circuito (4+).
    static func groupName(memberCount: Int) -> String {
        switch memberCount {
        case ...2: String(localized: "Bi-set")
        case 3: String(localized: "Tri-set")
        default: String(localized: "Circuito")
        }
    }

    // MARK: Cargas

    /// "26 kg", "+10 kg" / "−20 kg" (peso corporal com lastro/assistência), "Peso corporal".
    static func loadText(_ load: WatchLoad?, display: WeightUnit = WeightUnitPreference.current) -> String? {
        guard let load else { return nil }
        let shown = displayed(load, display: display)
        let unit = shown.unit == .kg ? "kg" : "lb"
        let number = FJFormat.number(abs(shown.value), maxFractionDigits: 2)
        if load.isBodyweight {
            if load.value == 0 { return String(localized: "Peso corporal") }
            return load.value > 0 ? "+\(number) \(unit)" : "−\(number) \(unit)"
        }
        return "\(number) \(unit)"
    }

    /// Valor/unidade na unidade de exibição (conversão só na exibição).
    private static func displayed(_ load: WatchLoad, display: WeightUnit) -> (value: Double, unit: WeightUnit) {
        let native = WeightUnit(rawValue: load.unit.rawValue) ?? .kg
        return LoadDisplay.shown(load.value, unit: native, display: display)
    }

    /// "26 quilos", "peso corporal mais 10 quilos".
    static func spokenLoad(_ load: WatchLoad?, display: WeightUnit = WeightUnitPreference.current) -> String? {
        guard let load else { return nil }
        let shown = displayed(load, display: display)
        let unit = shown.unit == .kg ? String(localized: "quilos") : String(localized: "libras")
        let number = FJFormat.number(abs(shown.value), maxFractionDigits: 2)
        if load.isBodyweight {
            if load.value == 0 { return String(localized: "peso corporal") }
            return load.value > 0
                ? String(localized: "peso corporal mais \(number) \(unit)")
                : String(localized: "peso corporal menos \(number) \(unit)")
        }
        return "\(number) \(unit)"
    }

    /// Carga exibida da série: a registrada, senão a planejada.
    static func displayLoad(_ set: SessionSnapshot.ExerciseSet) -> WatchLoad? { set.load ?? set.plannedLoad }

    /// "8–12" → "8 a 12"; "45 s" → "45 segundos"; "20 min" → "20 minutos"; "AMRAP" → "máximo de repetições".
    static func spokenTarget(_ text: String) -> String {
        if text.uppercased() == "AMRAP" { return String(localized: "máximo de repetições") }
        var spoken = text.replacingOccurrences(of: "–", with: String(localized: " a ", comment: "Faixa falada: 8 a 12"))
        if spoken.hasSuffix(" s") { spoken = String(localized: "\(String(spoken.dropLast(2))) segundos") }
        if spoken.hasSuffix(" min") { spoken = String(localized: "\(String(spoken.dropLast(4))) minutos") }
        if spoken.hasSuffix(" km") { spoken = String(localized: "\(String(spoken.dropLast(3))) quilômetros") }
        return spoken
    }

    /// "Série 2 de 3, alvo 8 a 12, 26 quilos" (+ "9 repetições feitas").
    static func spokenSet(index: Int, of total: Int, set: SessionSnapshot.ExerciseSet) -> String {
        var parts = [String(localized: "Série \(index) de \(total)")]
        if !set.targetText.isEmpty { parts.append(String(localized: "alvo \(spokenTarget(set.targetText))")) }
        if let load = spokenLoad(displayLoad(set)) { parts.append(load) }
        if let reps = set.reps { parts.append(repsDone(reps)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Linhas

    /// Valores de uma série compacta: "24 kg · alvo 8–12"; concluída com reps: "24 kg × 9".
    static func compactSetText(_ set: SessionSnapshot.ExerciseSet, kind: WatchMeasurementKind) -> String {
        let load = loadText(displayLoad(set))
        if set.isCompleted {
            switch kind {
            case .isometric:
                if let seconds = set.durationSeconds { return join([load, "\(Int(seconds.rounded())) s"]) }
            case .timeOrDistance:
                let parts = [set.durationSeconds.map { FJFormat.clock(Int($0.rounded())) }, distanceText(set.distanceMeters)]
                if parts.contains(where: { $0 != nil }) { return join(parts) }
            default:
                if let reps = set.reps { return join([load, "× \(reps)"], separator: " ") }
            }
        }
        return join([load, targetPart(set)])
    }

    private static func targetPart(_ set: SessionSnapshot.ExerciseSet) -> String? {
        set.targetText.isEmpty ? nil : String(localized: "alvo \(set.targetText)")
    }

    private static func distanceText(_ meters: Double?) -> String? {
        guard let meters, meters > 0 else { return nil }
        return meters >= 1_000 ? "\(FJFormat.number(meters / 1_000, maxFractionDigits: 2)) km" : "\(Int(meters)) m"
    }

    private static func join(_ parts: [String?], separator: String = " · ") -> String {
        parts.compactMap { $0 }.joined(separator: separator)
    }

    /// Resumo do exercício recolhido: "4 × 8–12 · 32,5 kg" ou, concluído, "4 de 4 séries · 32,5 kg".
    static func exerciseSummary(_ exercise: SessionSnapshot.Exercise) -> String {
        let working = exercise.sets.filter { $0.kind != .warmup && $0.kind != .feeder }
        let base = working.isEmpty ? exercise.sets : working
        guard let first = base.first else { return String(localized: "Sem séries") }
        let load = loadText(displayLoad(first))
        switch exercise.status {
        case .completed, .partial:
            let done = exercise.sets.filter(\.isCompleted).count
            return join([setsDone(done, of: exercise.sets.count), load])
        case .skipped:
            return String(localized: "Pulado")
        default:
            let count = first.targetText.isEmpty ? seriesCount(base.count) : "\(base.count) × \(first.targetText)"
            return join([count, load])
        }
    }

    /// "última vez: 3 × 10 com 24 kg" a partir das séries da última execução.
    static func lastPerformanceText(_ sets: [PerformedSet]) -> String? {
        let done = sets.filter(\.counts)
        guard !done.isEmpty else { return nil }
        let top = done.compactMap(\.load).max { $0.externalKilograms < $1.externalKilograms }
        let loadText: String? = top.flatMap { load in
            if load.isBodyweight { return load.externalKilograms > 0 ? "+\(LoadDisplay.kgText(load.externalKilograms, maxFractionDigits: 2))" : nil }
            return LoadDisplay.kgText(load.externalKilograms, maxFractionDigits: 2)
        }
        let reps = done.compactMap(\.reps)
        let countText: String
        if reps.count == done.count, Set(reps).count == 1, let first = reps.first {
            countText = "\(done.count) × \(first)"
        } else {
            countText = seriesCount(done.count)
        }
        let text = loadText.map { String(localized: "\(countText) com \($0)") } ?? countText
        return String(localized: "última vez: \(text)")
    }

    // MARK: Grupos (bi-set / circuito)

    /// "Bi-set · rodada 2 de 3" para o grupo de `exercise`; `nil` se solto.
    static func groupLabel(for exercise: SessionSnapshot.Exercise, in all: [SessionSnapshot.Exercise]) -> String? {
        guard let groupID = exercise.groupID else { return nil }
        let members = all.filter { $0.groupID == groupID }
        guard members.count > 1 else { return nil }
        let rounds = max(members.map(\.sets.count).max() ?? 1, 1)
        let done = members.map { $0.sets.filter(\.isCompleted).count }.min() ?? 0
        let name = groupName(memberCount: members.count)
        return String(localized: "\(name) · rodada \(min(done + 1, rounds)) de \(rounds)")
    }

    /// Primeiro membro do grupo (só ele mostra o rótulo).
    static func isFirstInGroup(_ exercise: SessionSnapshot.Exercise, in all: [SessionSnapshot.Exercise]) -> Bool {
        guard let groupID = exercise.groupID else { return false }
        return all.first { $0.groupID == groupID }?.id == exercise.id
    }

    // MARK: Doca

    enum DockMode: Equatable {
        /// Treino livre vazio.
        case empty
        case paused
        case rest(endsAt: Date, total: TimeInterval, nextUp: String?)
        /// Sustentação (isométrico) ou cronômetro (cardio) em curso. O tempo vem de `SessionSnapshot.holdElapsed(at:)`;
        /// `startedAt` só alinha o tique do relógio. Cardio: alvo de duração/distância da série.
        case holding(setID: UUID, startedAt: Date, targetSeconds: Int?, isCardio: Bool, targetDistanceMeters: Double?)
        case set(setID: UUID, title: String, detail: String, measurement: WatchMeasurementKind, targetSeconds: Int?)
        case next(exerciseID: UUID, name: String)
        case finish
    }

    /// Janela em que "Descanso concluído" continua na doca depois de zerar (design §4.5).
    static let restFinishedLinger: TimeInterval = 10

    static func dockMode(snapshot: SessionSnapshot, now: Date, advanceTo: UUID? = nil) -> DockMode {
        if snapshot.exercises.isEmpty { return .empty }
        if snapshot.status == .paused { return .paused }
        if let setID = snapshot.holdSetID, let started = snapshot.holdStartedAt {
            let owner = snapshot.exercises.first { $0.sets.contains { $0.id == setID } }
            let set = owner?.sets.first { $0.id == setID }
            let isCardio = owner?.measurementKind == .timeOrDistance
            return .holding(setID: setID, startedAt: started,
                            targetSeconds: isCardio ? set?.targetDurationSeconds : set?.targetHoldSeconds,
                            isCardio: isCardio, targetDistanceMeters: isCardio ? set?.targetDistanceMeters : nil)
        }
        // O descanso vencido some sozinho depois do `restFinishedLinger` (derivado da data) ou ao tocar em
        // "Continuar" (`skipRest` limpa o descanso no motor).
        if let end = snapshot.restEndsAt, now.timeIntervalSince(end) <= restFinishedLinger {
            return .rest(endsAt: end, total: restTotal(snapshot, endsAt: end, now: now), nextUp: nextUp(snapshot))
        }
        guard let exercise = snapshot.currentExercise else { return .finish }
        if let advanceTo, advanceTo == exercise.id { return .next(exerciseID: exercise.id, name: exercise.name) }
        guard let setID = snapshot.currentSetID, let position = snapshot.currentSetPosition,
              let set = exercise.sets.first(where: { $0.id == setID }) else {
            // Exercício aberto sem séries pendentes: o usuário avança ou conclui no menu.
            return .next(exerciseID: exercise.id, name: exercise.name)
        }
        let title: String
        switch exercise.measurementKind {
        case .isometric: title = String(localized: "Iniciar sustentação")
        case .timeOrDistance: title = String(localized: "Iniciar cronômetro")
        default: title = String(localized: "Concluir série \(position.index)")
        }
        return .set(setID: setID, title: title, detail: setDetail(exercise: exercise, set: set),
                    measurement: exercise.measurementKind,
                    targetSeconds: exercise.measurementKind == .timeOrDistance ? set.targetDurationSeconds : set.targetHoldSeconds)
    }

    /// "Supino inclinado · 26 kg · alvo 8–12" (em grupo: "Agora: …").
    static func setDetail(exercise: SessionSnapshot.Exercise, set: SessionSnapshot.ExerciseSet) -> String {
        let text = join([exercise.name, loadText(displayLoad(set)), targetPart(set)])
        return exercise.groupID == nil ? text : String(localized: "Agora: \(text)")
    }

    /// O que vem a seguir no descanso: "Série 3 de 4 · 26 kg · alvo 8–12" (com o nome em grupo).
    static func nextUp(_ snapshot: SessionSnapshot) -> String? {
        guard let exercise = snapshot.currentExercise, let setID = snapshot.currentSetID,
              let position = snapshot.currentSetPosition,
              let set = exercise.sets.first(where: { $0.id == setID }) else { return nil }
        let head = String(localized: "Série \(position.index) de \(position.of)")
        return join([exercise.groupID == nil ? nil : exercise.name, head, loadText(displayLoad(set)), targetPart(set)])
    }

    /// Duração total do descanso em curso (inclui os ajustes de ±15 s): `restTotalSeconds` do snapshot.
    /// Nunca menor que o restante (snapshot antigo sem o campo cai no restante).
    static func restTotal(_ snapshot: SessionSnapshot, endsAt: Date, now: Date) -> TimeInterval {
        let remaining = max(1, endsAt.timeIntervalSince(snapshot.pausedAt ?? now))
        return max(remaining, snapshot.restTotalSeconds ?? remaining)
    }

    static func progressFraction(_ snapshot: SessionSnapshot) -> Double {
        let total = snapshot.metrics.exercisesTotal
        guard total > 0 else { return 0 }
        return Double(snapshot.metrics.exercisesDone) / Double(total)
    }

    /// Detalhe do acessório: "Supino inclinado · série 2 de 4".
    static func accessoryDetail(_ snapshot: SessionSnapshot) -> String? {
        guard let exercise = snapshot.currentExercise else {
            return snapshot.exercises.isEmpty ? nil : String(localized: "Pronto para finalizar")
        }
        guard let position = snapshot.currentSetPosition else { return exercise.name }
        return String(localized: "\(exercise.name) · série \(position.index) de \(position.of)")
    }

    /// Nome exibido da ficha ("Treino livre" quando vazio).
    static func routineTitle(_ snapshot: SessionSnapshot) -> String {
        snapshot.routineName.isEmpty ? String(localized: "Treino livre") : snapshot.routineName
    }
}

// MARK: - Notas, dor, humor, cardio, grupos, relógio

extension SessionPresentation {
    /// Nomes dos tipos de série (menu e VoiceOver).
    static func kindName(_ kind: WatchSetKind) -> String {
        switch kind {
        case .working, .unknown: String(localized: "Normal")
        case .warmup: String(localized: "Aquecimento")
        case .feeder: String(localized: "Preparatória")
        case .dropSet: String(localized: "Drop set")
        case .restPause: String(localized: "Rest-pause")
        case .toFailure: String(localized: "Até a falha")
        case .backOff: String(localized: "Back-off")
        }
    }

    /// Tipos oferecidos no menu "Tipo da série".
    static let selectableKinds: [WatchSetKind] = [.working, .warmup, .feeder, .dropSet, .restPause, .toFailure, .backOff]

    /// "Dor 4/10 · Ombro direito" (VoiceOver incluso: "Dor ou desconforto 4 de 10, ombro direito").
    static func painText(score: Int?, location: String?) -> String? {
        let place = location.flatMap { $0.isEmpty ? nil : $0 }
        switch (score, place) {
        case (nil, nil): return nil
        case (let score?, let place?): return String(localized: "Dor \(score)/10 · \(place)")
        case (let score?, nil): return String(localized: "Dor \(score)/10")
        case (nil, let place?): return String(localized: "Desconforto · \(place)")
        }
    }

    static func spokenPain(score: Int?, location: String?) -> String? {
        let place = location.flatMap { $0.isEmpty ? nil : $0 }
        switch (score, place) {
        case (nil, nil): return nil
        case (let score?, let place?): return String(localized: "Dor ou desconforto \(score) de 10, \(place)")
        case (let score?, nil): return String(localized: "Dor ou desconforto \(score) de 10")
        case (nil, let place?): return String(localized: "Desconforto em \(place)")
        }
    }

    /// Humor/energia 1–5: rótulo curto e falado.
    static func moodLabel(_ value: Int) -> String {
        switch value {
        case 1: String(localized: "Muito baixo")
        case 2: String(localized: "Baixo")
        case 3: String(localized: "Normal")
        case 4: String(localized: "Bom")
        default: String(localized: "Ótimo")
        }
    }

    /// "nível 6 · 9,5 km/h · inclinação 2 %" da série (campos opcionais; `nil` sem nada).
    static func cardioDetailText(_ set: SessionSnapshot.ExerciseSet) -> String? {
        cardioDetailText(level: set.level, speedKmh: set.speedKmh, inclinePercent: set.inclinePercent)
    }

    static func cardioDetailText(level: Int?, speedKmh: Double?, inclinePercent: Double?) -> String? {
        var parts: [String] = []
        if let level { parts.append(String(localized: "nível \(level)")) }
        if let speedKmh { parts.append("\(FJFormat.number(speedKmh, maxFractionDigits: 1)) km/h") }
        if let inclinePercent { parts.append(String(localized: "inclinação \(FJFormat.number(inclinePercent, maxFractionDigits: 1)) %")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Alvo do cardio: "20:00 · 3 km" (duração em relógio, distância em km ou m) a partir de `targetDurationSeconds`/`targetDistanceMeters`.
    static func cardioTargetText(durationSeconds: Int?, distanceMeters: Double?) -> String? {
        var parts: [String] = []
        if let durationSeconds, durationSeconds > 0 { parts.append(FJFormat.clock(durationSeconds)) }
        if let text = distanceText(distanceMeters) { parts.append(text) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Indicação da rodada no bi-set/tri-set/circuito para o exercício atual: "Fim da rodada: descanso em seguida"
    /// ou "Em seguida: Rosca direta" (sem descanso). `nil` fora de grupo.
    static func groupRoundHint(_ snapshot: SessionSnapshot) -> String? {
        guard let round = snapshot.currentGroup else { return nil }
        if round.completesRound { return String(localized: "Fim da rodada \(round.round) de \(round.totalRounds): descanso em seguida") }
        guard let next = snapshot.exercises.first(where: { $0.id == round.nextExerciseID }) else { return nil }
        return String(localized: "Em seguida, sem descanso: \(next.name)")
    }

    /// Estado do botão/selo do Apple Watch na sessão.
    enum WatchBadge: Equatable {
        case none
        /// Relógio alcançável e não gravando: oferecer "Gravar no relógio".
        case offer
        case recording
        /// O relógio (ou o iPhone) não entende a versão do outro.
        case incompatible(phoneIsOutdated: Bool)
    }

    static func watchBadge(canRequest: Bool, recordingSessionID: UUID?, currentSessionID: UUID?,
                           incompatibility: WatchLinkCompatibility?) -> WatchBadge {
        if let incompatibility { return .incompatible(phoneIsOutdated: !incompatibility.peerIsOutdated) }
        if let currentSessionID, recordingSessionID == currentSessionID { return .recording }
        return canRequest ? .offer : .none
    }
}
