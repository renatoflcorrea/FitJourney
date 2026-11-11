import Foundation

/// Busca e filtros da biblioteca (lógica pura, testável).
struct ExerciseFilter: Equatable, Sendable {
    var query: String = ""
    var muscles: Set<MuscleGroup> = []
    var equipment: Set<Equipment> = []

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty || !muscles.isEmpty || !equipment.isEmpty }

    /// Minúsculas e sem acento: "Ombro", "ombro" e "ômbro" casam entre si.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cada palavra da busca precisa aparecer no nome (ou no nome em inglês do catálogo embutido).
    func matches(name: String, englishName: String? = nil, primary: [MuscleGroup], secondary: [MuscleGroup], equipment eq: Equipment) -> Bool {
        let words = Self.normalize(query).split(separator: " ").map(String.init)
        if !words.isEmpty {
            let haystack = Self.normalize(name + " " + (englishName ?? ""))
            guard words.allSatisfy(haystack.contains) else { return false }
        }
        if !muscles.isEmpty, muscles.isDisjoint(with: primary + secondary) { return false }
        if !equipment.isEmpty, !equipment.contains(eq) { return false }
        return true
    }

    func matches(_ exercise: Exercise) -> Bool {
        let english = exercise.catalogKey.flatMap { ExerciseCatalog.entry(forKey: $0)?.nameEN }
        return matches(name: exercise.name, englishName: english, primary: exercise.primaryMuscles,
                       secondary: exercise.secondaryMuscles, equipment: exercise.equipment)
    }
}

/// Textos de exibição dos enums que ainda não têm `localizedName` no domínio.
extension MeasurementKind {
    var displayName: String {
        switch self {
        case .repsAndLoad: String(localized: "Repetições e carga")
        case .repsOnly: String(localized: "Só repetições")
        case .isometric: String(localized: "Isométrico")
        case .timeOrDistance: String(localized: "Tempo ou distância")
        }
    }

    var example: String {
        switch self {
        case .repsAndLoad: String(localized: "Ex.: supino, agachamento — 10 × 60 kg")
        case .repsOnly: String(localized: "Ex.: flexão, barra fixa — peso corporal, lastro opcional")
        case .isometric: String(localized: "Ex.: prancha — segurar por tempo")
        case .timeOrDistance: String(localized: "Ex.: esteira, bicicleta — duração e distância")
        }
    }
}

extension Laterality {
    var displayName: String {
        switch self {
        case .bilateral: String(localized: "Bilateral")
        case .unilateral: String(localized: "Unilateral (por lado)")
        }
    }
}

extension Exercise {
    /// "Peito · Barra" (grupos primários + equipamento), usado nas linhas e no VoiceOver.
    var summaryLine: String {
        let muscles = primaryMuscles.map(\.localizedName).joined(separator: ", ")
        return muscles.isEmpty ? equipment.localizedName : "\(muscles) · \(equipment.localizedName)"
    }
}

extension Equipment {
    var systemImage: String {
        switch self {
        case .barbell, .dumbbell, .kettlebell: "dumbbell"
        case .machine, .cable: "gearshape.2"
        case .bodyweight: "figure.strengthtraining.functional"
        case .band: "lasso"
        case .cardio: "figure.run"
        case .other: "figure.mixed.cardio"
        }
    }
}
