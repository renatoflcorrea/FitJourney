import Foundation

struct ModelPickerPresentation: Equatable {
    let visibleModels: [String]
    let remainingCount: Int
    let preferredModel: String?
    let missingModel: String?

    init(models: [String], preferredModel: String?, chosenModel: String?, limit: Int = 8) {
        let unique = models.reduce(into: [String]()) { result, model in
            if !result.contains(model) { result.append(model) }
        }
        self.visibleModels = Array(unique.prefix(max(0, limit)))
        self.remainingCount = max(0, unique.count - self.visibleModels.count)
        self.preferredModel = preferredModel
        self.missingModel = chosenModel.flatMap { unique.contains($0) ? nil : $0 }
    }
}
