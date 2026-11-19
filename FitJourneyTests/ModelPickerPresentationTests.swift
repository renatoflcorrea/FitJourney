import Testing
@testable import FitJourney

struct ModelPickerPresentationTests {
    @Test func ordersAsProvidedAndLimitsToEight() {
        let names = (1...10).map { "model-\($0)" }
        let value = ModelPickerPresentation(models: names, preferredModel: "model-9", chosenModel: nil)
        #expect(value.visibleModels == Array(names.prefix(8)))
        #expect(value.remainingCount == 2)
    }

    @Test func countsAllAndMarksPreferredModel() {
        let value = ModelPickerPresentation(models: ["b", "a"], preferredModel: "a", chosenModel: nil)
        #expect(value.remainingCount == 0)
        #expect(value.preferredModel == "a")
    }

    @Test func flagsMissingUserChoiceWithoutChangingIt() {
        let value = ModelPickerPresentation(models: ["fresh"], preferredModel: "fresh", chosenModel: "old")
        #expect(value.missingModel == "old")
        #expect(value.preferredModel == "fresh")
    }

    @Test func doesNotFlagChoiceStillAvailableAndDeduplicates() {
        let value = ModelPickerPresentation(models: ["one", "one"], preferredModel: "one", chosenModel: "one")
        #expect(value.visibleModels == ["one"])
        #expect(value.missingModel == nil)
    }
}
