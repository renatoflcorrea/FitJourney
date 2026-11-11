import Foundation

/// Nomes em inglês do catálogo embutido por chave (índice estático; hoje vive aqui para não tocar em
/// Persistence — mover para junto de `ExerciseCatalog`).
enum ExerciseCatalogIndex {
    static let englishNames: [String: String] = Dictionary(uniqueKeysWithValues: ExerciseCatalog.all.map { ($0.key, $0.nameEN) })
    /// Nome pt-BR embutido → nome en (exercício embutido que o usuário ainda não renomeou).
    static let englishByPortugueseName: [String: String] = Dictionary(ExerciseCatalog.all.map { ($0.name, $0.nameEN) }, uniquingKeysWith: { first, _ in first })

    /// `true` quando o app está em inglês (qualquer idioma que não seja pt).
    static var prefersEnglish: Bool { !(Bundle.main.preferredLocalizations.first ?? "pt").hasPrefix("pt") }

    /// Nome para exibir: em en, o nome en do catálogo se `stored` ainda é o nome embutido; senão o gravado.
    /// Não altera o dado gravado.
    static func displayName(_ stored: String, english: Bool = prefersEnglish) -> String {
        english ? (englishByPortugueseName[stored] ?? stored) : stored
    }
}

extension String {
    /// Nome de exercício localizado para exibição (ver `ExerciseCatalogIndex.displayName`).
    var exerciseDisplayName: String { ExerciseCatalogIndex.displayName(self) }
}

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

    /// Nome normalizado em cache (a lista re-filtra a cada tecla; normalizar 60+ nomes toda vez é desperdício).
    nonisolated(unsafe) private static let normalizedNames: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 2000
        return cache
    }()

    static func normalizedCached(_ text: String) -> String {
        if let hit = normalizedNames.object(forKey: text as NSString) { return hit as String }
        let value = normalize(text)
        normalizedNames.setObject(value as NSString, forKey: text as NSString)
        return value
    }

    /// Consulta já preparada: palavras normalizadas uma vez por busca, não por exercício.
    struct Prepared: Sendable {
        fileprivate let words: [String]
        fileprivate let muscles: Set<MuscleGroup>
        fileprivate let equipment: Set<Equipment>

        /// Cada palavra da busca precisa aparecer no nome (ou no nome em inglês do catálogo embutido).
        func matches(name: String, englishName: String? = nil, primary: [MuscleGroup], secondary: [MuscleGroup], equipment eq: Equipment) -> Bool {
            if !words.isEmpty {
                let haystack = ExerciseFilter.normalizedCached(name) + " " + (englishName.map(ExerciseFilter.normalizedCached) ?? "")
                guard words.allSatisfy(haystack.contains) else { return false }
            }
            if !muscles.isEmpty, muscles.isDisjoint(with: primary + secondary) { return false }
            if !equipment.isEmpty, !equipment.contains(eq) { return false }
            return true
        }

        func matches(_ exercise: Exercise) -> Bool {
            matches(name: exercise.name, englishName: exercise.catalogKey.flatMap { ExerciseCatalogIndex.englishNames[$0] },
                    primary: exercise.primaryMuscles, secondary: exercise.secondaryMuscles, equipment: exercise.equipment)
        }
    }

    func prepared() -> Prepared {
        Prepared(words: Self.normalize(query).split(separator: " ").map(String.init), muscles: muscles, equipment: equipment)
    }

    func matches(name: String, englishName: String? = nil, primary: [MuscleGroup], secondary: [MuscleGroup], equipment eq: Equipment) -> Bool {
        prepared().matches(name: name, englishName: englishName, primary: primary, secondary: secondary, equipment: eq)
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
