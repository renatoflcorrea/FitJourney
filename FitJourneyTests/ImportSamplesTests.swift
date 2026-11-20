import Foundation
import Testing
@testable import FitJourney

/// Exemplos para a App Review (proposta ai-consent-review §4): estão no bundle e passam pelo preparo de anexos.
@MainActor
struct ImportSamplesTests {
    @Test func everyWorkoutSampleIsBundledAsJPEG() {
        for resource in [ImportSamples.mainWorkout] + ImportSamples.otherWorkouts {
            let sample = ImportSamples.workout(resource)
            #expect(sample != nil, "missing \(resource)")
            #expect((sample?.data.count ?? 0) > 50_000)
        }
    }

    @Test func mealPlanSampleIsBundledAsPDF() throws {
        let sample = try #require(ImportSamples.mealPlanAttachment())
        #expect(sample.data.starts(with: Data("%PDF".utf8)))
    }

    @Test func samplesHaveDistinctNamesThatMarkThemAsSamples() {
        let names = ([ImportSamples.mainWorkout] + ImportSamples.otherWorkouts).map(ImportSamples.filename(for:))
        #expect(Set(names).count == 4)
        #expect(ImportSamples.sampleFilenames.isSuperset(of: names))
    }

    @Test func mealLogSampleFitsTheTextLimit() {
        #expect(!ImportSamples.mealLogText.isEmpty)
        #expect(ImportSamples.mealLogText.count <= MealLogSession.maxTextLength)
    }

    @Test func samplesPassTheAttachmentPreparer() throws {
        let raws = ([ImportSamples.mainWorkout] + ImportSamples.otherWorkouts).compactMap { ImportSamples.workout($0) }
            + [try #require(ImportSamples.mealPlanAttachment())]
        let prepared = try AttachmentPreparer().prepare(raws)
        #expect(prepared.count == 5)
        #expect(prepared.map(\.filename) == raws.map(\.filename))
    }
}
