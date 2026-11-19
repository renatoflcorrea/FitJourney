import Foundation

/// Lista do seletor de modelo (decisão 47): sem repetidos, o padrão e a escolha atual sempre visíveis no topo,
/// no máximo `limit` linhas e o resto em "Ver todos".
struct ModelPickerPresentation: Equatable {
    let visibleModels: [String]
    let remainingCount: Int
    let preferredModel: String?
    let missingModel: String?

    /// - sortByVersion: listas de API sem ordem útil (OpenAI, Anthropic, OpenRouter) vão da versão mais nova à mais antiga;
    ///   OpenCode (custo) e ChatGPT (prioridade da conta) mantêm a ordem recebida.
    init(models: [String], preferredModel: String?, chosenModel: String?, limit: Int = 8, sortByVersion: Bool = false) {
        var unique = models.reduce(into: [String]()) { result, model in
            if !result.contains(model) { result.append(model) }
        }
        if sortByVersion {
            unique = unique.enumerated().sorted { lhs, rhs in
                let (a, b) = (ModelDefaults.version(of: lhs.element), ModelDefaults.version(of: rhs.element))
                if ModelDefaults.isNewer(a, than: b) { return true }
                if ModelDefaults.isNewer(b, than: a) { return false }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        let pinned = [preferredModel, chosenModel].compactMap { $0 }.filter(unique.contains)
        var ordered: [String] = []
        for model in pinned + unique where !ordered.contains(model) { ordered.append(model) }
        visibleModels = Array(ordered.prefix(max(0, limit)))
        remainingCount = max(0, ordered.count - visibleModels.count)
        self.preferredModel = preferredModel
        missingModel = chosenModel.flatMap { unique.contains($0) ? nil : $0 }
    }
}
